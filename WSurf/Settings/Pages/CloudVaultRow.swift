// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore
import WSurfVault

/// The selected vault's iCloud rows on the Settings tab: the Sync with iCloud switch with what it is doing in words, Remove from
/// iCloud…, and the key check that tells two Macs apart when a synced vault does not open. Present only while vault sync exists.
struct CloudVaultRow: View {
    let model: CredentialSettingsModel
    let run: (@escaping () async throws -> Void) -> Void

    @State private var checkedCopy: (vaultID: UUID, account: String, exists: Bool)?
    @State private var confirmation: (vaultID: UUID, account: String?)?
    @State private var confirmsRemoval = false
    @State private var confirmsUpload = false
    @State private var confirmsDeletion = false

    var body: some View {
        if let sync = model.vaultSync, let vaultID = model.selectedVaultID {
            let status = sync.status(profileID: model.profile.id, vaultID: vaultID)
            let tally = sync.tally(profileID: model.profile.id, vaultID: vaultID)
            let held = sync.heldRemovals(profileID: model.profile.id, vaultID: vaultID)
            let isOn = Self.isOn(status)
            let hasHistory = sync.canManageCloudCopy(profileID: model.profile.id, vaultID: vaultID)
            let account = sync.connectedAccount
            let needsAccount = hasHistory && account == nil
            RowSeparator()
            DetailRow(
                verbatimTitle: String(localized: "Sync with iCloud"),
                verbatimCaption: Self.caption(status: status, held: held, isUnlocked: model.isUnlocked, tally: tally, unownedHistory: hasHistory)
            ) {
                SettingsToggle(Binding(get: { isOn }, set: { turn($0, from: status, vaultID: vaultID) }))
                    .disabled(model.isBusy || needsAccount || status == .removalPending || (!isOn && !model.isUnlocked))
                    .accessibilityLabel("Sync with iCloud")
            }
            .confirmationDialog(
                Text("Upload “\(vaultName)” to iCloud?"), isPresented: $confirmsUpload
            ) {
                Button("Upload") {
                    guard let confirmation else { return }
                    run { await model.enableSync(vaultID: confirmation.vaultID, confirmingAccount: confirmation.account) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This Mac’s copy is encrypted and uploaded. Entries that differ from iCloud wait for your review.")
            }
            .onChange(of: account) {
                checkedCopy = nil
                closeUnavailableConfirmation(account: account)
            }
            .onDisappear { closeUnavailableConfirmation(account: model.vaultSync?.connectedAccount) }
            if hasHistory {
                RowSeparator()
                DetailRow(title: "iCloud storage for this vault", caption: copyCheckText(vaultID: vaultID, account: account)) {
                    Button("Check iCloud") {
                        guard let account else { return }
                        checkedCopy = nil
                        run {
                            let exists = try await sync.checkCloudCopy(profileID: model.profile.id, vaultID: vaultID, for: account)
                            checkedCopy = (vaultID, account, exists)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || needsAccount)
                }
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
            if isOn || status == .removalFailed || hasHistory {
                RowSeparator()
                DetailRow(title: "Remove from iCloud") {
                    let label: LocalizedStringKey = status == .removalFailed ? "Try Again" : "Remove from iCloud…"
                    Button(label, role: .destructive) {
                        confirmation = (vaultID, sync.state.accountUser)
                        confirmsRemoval = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || needsAccount)
                }
                .confirmationDialog(
                    Text("Remove “\(vaultName)” from iCloud?"), isPresented: $confirmsRemoval
                ) {
                    Button("Remove from iCloud", role: .destructive) {
                        guard let confirmation else { return }
                        run { await model.removeVaultFromICloud(vaultID: confirmation.vaultID, confirmingAccount: confirmation.account) }
                    }
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

    private func closeUnavailableConfirmation(account: String?) {
        guard confirmsRemoval || confirmsUpload, let confirmation, confirmation.account != account else { return }
        confirmsRemoval = false
        confirmsUpload = false
        model.error = CredentialSettingsModel.message(for: VaultSyncFailure.unavailable)
    }

    private func copyCheckText(vaultID: UUID, account: String?) -> LocalizedStringResource? {
        guard let checkedCopy, checkedCopy.vaultID == vaultID, checkedCopy.account == account else { return nil }
        if checkedCopy.exists {
            return "iCloud storage for this vault exists in the current Apple Account."
        }
        return "No iCloud storage for this vault was found in the current Apple Account."
    }

    private var vaultName: String {
        model.vaults.first { $0.vaultID == model.selectedVaultID }?.label ?? String(localized: "this vault")
    }

    /// On means this Mac syncs the vault, whatever it is doing right now.
    static func isOn(_ status: VaultSyncStatus) -> Bool {
        switch status {
        case .off, .removed, .removalPending, .removalFailed, .removalUnconfirmed, .accountChanged:
            false
        case .synced, .sending, .waitingForUnlock, .needsReview, .holdingRemovals, .iCloudFull, .signedOut, .needsUpdate, .rolledBack:
            true
        }
    }

    /// Turning on after a removal or an account change asks first; the dialog is the person's confirmation to upload again.
    private func turn(_ on: Bool, from status: VaultSyncStatus, vaultID: UUID) {
        guard on else {
            model.disableSync()
            return
        }
        switch status {
        case .removed, .removalUnconfirmed, .accountChanged:
            confirmation = (vaultID, model.vaultSync?.state.accountUser)
            confirmsUpload = true
        default:
            run { await model.enableSync(vaultID: vaultID) }
        }
    }

    /// The status in words, and what else is true of the vault: deletions that wait for the owner, whatever the status is.
    static func caption(status: VaultSyncStatus, held: Int, isUnlocked: Bool, tally: VaultSyncTally, unownedHistory: Bool = false) -> String {
        var parts = [Self.statusText(status, isUnlocked: isUnlocked, unownedHistory: unownedHistory)]
        if held > 0, status != .holdingRemovals(held) {
            parts.append(Self.statusText(.holdingRemovals(held), isUnlocked: isUnlocked))
        }
        if Self.isOn(status) {
            if tally.notSyncable > 0 {
                parts.append(String(localized: "\(tally.notSyncable) entries couldn’t be prepared for sync. This Mac keeps its copies."))
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

    static func statusText(_ status: VaultSyncStatus, isUnlocked: Bool, unownedHistory: Bool = false) -> String {
        switch status {
        case .off:
            if isUnlocked {
                String(localized: """
                    Keeps this vault the same on your Macs signed in to your Apple Account. Entries and attached files are encrypted \
                    before they leave this Mac.
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
        case .removalUnconfirmed:
            String(localized: "This vault may still be in iCloud. WSurf couldn’t confirm its removal or which Apple Account was used. This Mac keeps its copy.")
        case .removalFailed:
            String(localized: "Couldn’t remove this vault from iCloud. It’s still there, and this Mac no longer syncs it.")
        case .removalPending:
            String(localized: "Waiting for iCloud to confirm removal. This Mac keeps its copy.")
        case .accountChanged where unownedHistory:
            String(localized: "WSurf has no Apple Account saved for this vault. This Mac keeps its copy.")
        case .accountChanged:
            String(localized: """
                You’re signed in with a different Apple Account. This Mac keeps its copy. Turn on Sync with iCloud to upload it to this \
                account.
                """)
        }
    }
}
