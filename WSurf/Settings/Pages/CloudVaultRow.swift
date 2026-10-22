// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WSurfCore
import WSurfVault

/// The selected vault's iCloud rows on the Settings tab: the Sync with iCloud switch with what it is doing in words, Remove from
/// iCloud…, and the key check that tells two Macs apart when a synced vault does not open. Present only while vault sync exists.
struct CloudVaultRow: View {
    let model: CredentialSettingsModel
    let run: (@escaping () async throws -> Void) -> Void

    @State private var confirmsRemoval = false
    @State private var confirmsUpload = false
    @State private var confirmsDeletion = false

    var body: some View {
        if let sync = model.vaultSync, let vaultID = model.selectedVaultID {
            let status = sync.status(profileID: model.profile.id, vaultID: vaultID)
            let tally = sync.tally(profileID: model.profile.id, vaultID: vaultID)
            let held = sync.heldRemovals(profileID: model.profile.id, vaultID: vaultID)
            let isOn = Self.isOn(status)
            RowSeparator()
            DetailRow(
                verbatimTitle: String(localized: "Sync with iCloud"),
                verbatimCaption: Self.caption(status: status, held: held, isUnlocked: model.isUnlocked, tally: tally)
            ) {
                SettingsToggle(Binding(get: { isOn }, set: { turn($0, from: status) }))
                    .disabled(model.isBusy || (!isOn && !model.isUnlocked))
                    .accessibilityLabel("Sync with iCloud")
            }
            .confirmationDialog(
                Text("Upload “\(vaultName)” to iCloud?"), isPresented: $confirmsUpload
            ) {
                Button("Upload") { run { await model.enableSync() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This Mac’s copy is encrypted and uploaded. Entries that differ from iCloud wait for your review.")
            }
            if held > 0 {
                RowSeparator()
                DetailRow(title: "Delete on other devices") {
                    Button("Delete on Other Devices…", role: .destructive) { confirmsDeletion = true }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy || !model.isUnlocked)
                }
                .confirmationDialog(
                    Text("Delete \(held) entries on your other devices?"), isPresented: $confirmsDeletion
                ) {
                    Button("Delete on Other Devices", role: .destructive) { model.releaseSyncRemovals() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("WSurf moves them to Trash on your other devices that sync this vault. You can restore them there.")
                }
            }
            if status == .removalFailed {
                RowSeparator()
                DetailRow(title: "Remove from iCloud") {
                    Button("Try Again") { model.removeSelectedVaultFromICloud() }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                }
            }
            if isOn {
                RowSeparator()
                DetailRow(title: "Remove from iCloud") {
                    Button("Remove from iCloud…", role: .destructive) { confirmsRemoval = true }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                }
                .confirmationDialog(
                    Text("Remove “\(vaultName)” from iCloud?"), isPresented: $confirmsRemoval
                ) {
                    Button("Remove from iCloud", role: .destructive) { model.removeSelectedVaultFromICloud() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("""
                        WSurf deletes this vault’s encrypted copy from your iCloud account and stops syncing it on all your devices. \
                        Each device keeps its own copy. Backups of your devices aren’t affected.
                        """)
                }
            }
            if let check = model.manager?.lastKeyCheck {
                RowSeparator()
                DetailRow(title: "Key check", caption: "The same on every Mac that can open this vault. It isn’t the key.") {
                    Text(verbatim: check)
                        .font(Theme.Font.row.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var vaultName: String {
        model.vaults.first { $0.vaultID == model.selectedVaultID }?.label ?? String(localized: "this vault")
    }

    /// On means this Mac syncs the vault, whatever it is doing right now.
    static func isOn(_ status: VaultSyncStatus) -> Bool {
        switch status {
        case .off, .removed, .removalFailed, .accountChanged:
            false
        case .synced, .sending, .waitingForUnlock, .needsReview, .holdingRemovals, .iCloudFull, .signedOut, .needsUpdate, .rolledBack:
            true
        }
    }

    /// Turning on after a removal or an account change asks first; the dialog is the person's confirmation to upload again.
    private func turn(_ on: Bool, from status: VaultSyncStatus) {
        guard on else {
            model.disableSync()
            return
        }
        switch status {
        case .removed, .accountChanged:
            confirmsUpload = true
        default:
            run { await model.enableSync() }
        }
    }

    /// The status in words, and what else is true of the vault: deletions that wait for the owner, whatever the status is.
    static func caption(status: VaultSyncStatus, held: Int, isUnlocked: Bool, tally: VaultSyncTally) -> String {
        var parts = [Self.statusText(status, isUnlocked: isUnlocked)]
        if held > 0, status != .holdingRemovals(held) {
            parts.append(Self.statusText(.holdingRemovals(held), isUnlocked: isUnlocked))
        }
        if Self.isOn(status) {
            if tally.notSyncable > 0 {
                parts.append(String(localized: "\(tally.notSyncable) entries are too large to sync or hold only files, so they stay on this Mac."))
            }
            if tally.unreadable > 0 {
                parts.append(String(localized: "\(tally.unreadable) changes from iCloud couldn’t be read and were skipped."))
            }
            if tally.newer > 0 {
                parts.append(String(localized: "\(tally.newer) entries are from a newer version of WSurf. Update WSurf to sync them."))
            }
        }
        return parts.joined(separator: " ")
    }

    static func statusText(_ status: VaultSyncStatus, isUnlocked: Bool) -> String {
        switch status {
        case .off:
            if isUnlocked {
                String(localized: """
                    Keeps this vault the same on your Macs signed in to your Apple Account. Entries are encrypted with the vault’s key \
                    before they leave this Mac. Files attached to entries stay on this Mac.
                    """)
            } else {
                String(localized: "Unlock this vault to turn on sync.")
            }
        case .synced:
            String(localized: "Up to date.")
        case .sending:
            String(localized: "Sending changes to iCloud…")
        case .waitingForUnlock(let count):
            String(localized: "\(count) changes from your other devices will be added when you unlock this vault.")
        case .needsReview(let count):
            String(localized: "\(count) entries need a choice. Review them on the Vault tab.")
        case .holdingRemovals(let count):
            String(localized: "\(count) entries were deleted on this Mac. Delete them on your other devices too?")
        case .iCloudFull:
            String(localized: "Your iCloud storage is full. Changes stay on this Mac until there’s room.")
        case .signedOut:
            String(localized: "Sign in with your Apple Account in System Settings to sync.")
        case .needsUpdate:
            String(localized: "This vault was synced by a newer version of WSurf. Update WSurf to keep syncing it.")
        case .rolledBack:
            String(localized: """
                This vault on this Mac is older than when it last synced, so syncing stopped. Turn Sync with iCloud off and on to compare \
                it with iCloud.
                """)
        case .removed(.deleted):
            String(localized: "This vault was removed from iCloud. This Mac keeps its copy. Turn on Sync with iCloud to upload this copy again.")
        case .removed(.purged):
            String(localized: "WSurf’s iCloud data was deleted in iCloud settings. This Mac keeps its copy. Turn on Sync with iCloud to upload it again.")
        case .removed(.encryptedDataReset):
            String(localized: "Your iCloud encrypted data was reset. This Mac keeps its copy. Turn on Sync with iCloud to upload it again.")
        case .removalFailed:
            String(localized: "Couldn’t remove this vault from iCloud. It’s still there, and this Mac no longer syncs it.")
        case .accountChanged:
            String(localized: """
                You’re signed in with a different Apple Account. This Mac keeps its copy. Turn on Sync with iCloud to upload it to this \
                account.
                """)
        }
    }
}
