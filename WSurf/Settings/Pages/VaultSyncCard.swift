// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import WSurfCore

/// At the top of the Vault tab, whatever the vault's state: a vault another Mac synced that this Mac does not hold, entries that
/// changed here and on another device, and a vault that was removed from iCloud. Present only while vault sync exists, and never
/// asking for anything but the person's own click.
struct VaultSyncCard: View {
    let model: CredentialSettingsModel
    let withWindow: (@escaping (NSWindow) async -> Void) -> Void
    let showSettings: () -> Void

    var body: some View {
        if model.vaultSync != nil {
            ForEach(model.addableSyncedVaults) { remote in
                remoteCard(remote)
            }
            if let selected = model.selectedVaultID, let status = model.syncStatus {
                switch status {
                case .needsReview(let count):
                    SettingsCard {
                        DetailRow(title: "Entries need a choice", caption: "\(count) entries don’t sync until you choose.") {
                            Button("Review…") { Task { await model.openSyncReview() } }
                                .buttonStyle(.bordered)
                                .disabled(model.isBusy || !model.isUnlocked)
                        }
                    }
                case .removed, .accountChanged:
                    if !model.dismissedSyncNotices.contains(selected) {
                        removedCard(selected, status)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    private func remoteCard(_ remote: RemoteVault) -> some View {
        SettingsCard {
            DetailRow(title: "Vault on your other devices", caption: caption(for: remote)) {
                if case .keyDiffers = failure(for: remote) {
                    Button("Try Again…") { add(remote) }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                } else if model.canAddSyncedVault(remote) {
                    Button("Add to This Mac…") { add(remote) }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    /// Only a passkey that gave a different key is remembered; a missing authority is read afresh from the page every time.
    private func failure(for remote: RemoteVault) -> SyncAddFailure? {
        guard case .keyDiffers(let id, _)? = model.syncAddFailure, id == remote.vaultID else { return nil }
        return model.syncAddFailure
    }

    private func caption(for remote: RemoteVault) -> LocalizedStringResource {
        if case .keyDiffers(_, let check) = failure(for: remote) {
            return """
                Locked on this Mac: your passkey gives a different key here, so this vault can’t open on this Mac. Nothing was changed. \
                Key check on this Mac: \(check)
                """
        }
        if !model.canAddSyncedVault(remote) {
            return "Unlock one of this profile’s vaults first, then add this vault."
        }
        return "Add it to this Mac with your unlock passkey. Its entries download when you unlock it."
    }

    private func add(_ remote: RemoteVault) {
        withWindow { window in await model.addSyncedVault(remote, in: window) }
    }

    private func removedCard(_ vaultID: UUID, _ status: VaultSyncStatus) -> some View {
        SettingsCard {
            DetailRow(verbatimTitle: String(localized: "Removed from iCloud"), verbatimCaption: CloudVaultRow.statusText(status, isUnlocked: true)) {
                HStack(spacing: 8) {
                    Button("Show in Settings", action: showSettings).buttonStyle(.bordered)
                    Button("Dismiss") { model.dismissedSyncNotices.insert(vaultID) }.buttonStyle(.bordered)
                }
            }
        }
    }
}
