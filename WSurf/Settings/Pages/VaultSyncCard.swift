// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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
                        DetailRow(
                            title: "Changed on this Mac and another device",
                            caption: "\(count) entries need a choice. They don’t sync until you choose."
                        ) {
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
                } else if model.canAddSyncedVault(remote), !isMissingAuthority(remote) {
                    Button("Add to This Mac…") { add(remote) }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    private func failure(for remote: RemoteVault) -> SyncAddFailure? {
        guard let failure = model.syncAddFailure else { return nil }
        switch failure {
        case .keyDiffers(let id, _), .noAuthority(let id):
            return id == remote.vaultID ? failure : nil
        }
    }

    private func isMissingAuthority(_ remote: RemoteVault) -> Bool {
        if case .noAuthority = failure(for: remote) {
            return true
        }
        return false
    }

    private func caption(for remote: RemoteVault) -> LocalizedStringResource {
        if case .keyDiffers(_, let check) = failure(for: remote) {
            return """
                Locked on this Mac: your passkey gives a different key here, so this vault can’t open on this Mac. Nothing was changed. \
                Key check on this Mac: \(check)
                """
        }
        if isMissingAuthority(remote) || !model.canAddSyncedVault(remote) {
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
