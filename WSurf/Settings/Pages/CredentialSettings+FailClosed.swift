// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension CredentialSettings {
    /// The one button a locked page offers. Create appears only for a definite miss (`vaultExists == false`); a store that
    /// couldn't be read (`nil`) offers only a retry, and a vault from an older WSurf is never unlocked without the user's
    /// explicit consent to upgrade it.
    @ViewBuilder
    var lockedAction: some View {
        switch model.vaultExists {
        case .some(true):
            if model.needsMigrationConfirmation {
                SettingsButton(title: "Upgrade and Unlock…", isProminent: true) { showsMigrationConfirmation = true }
            } else {
                SettingsButton(verbatimTitle: unlockTitle, isProminent: true) {
                    withWindow { window in await model.unlock(in: window) }
                }
            }
        case .some(false):
            SettingsButton(title: "Create Credential Vault", isProminent: true) {
                showsCreateWarning = true
            }
            .disabled(!model.canCreateVault)
        case .none:
            SettingsButton(title: "Try Again") { run { await model.load() } }
        }
    }

    private var unlockTitle: String {
        guard model.vaults.count > 1, let vault = model.vaults.first(where: { $0.vaultID == model.selectedVaultID }) else {
            return String(localized: "Unlock Credentials")
        }
        return String(localized: "Unlock “\(vault.displayName)”")
    }

    /// Replaces the whole page. The store refused to open, so nothing here creates, resets or acknowledges anything: the only
    /// action is a re-check, which changes no file.
    func failClosedContent(_ closed: StoreFailClosed) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Credentials can’t be opened", systemImage: "exclamationmark.octagon")
                    .font(Theme.Font.row)
                    .fontWeight(.medium)
                Text(closed.cause.explanation)
                    .font(Theme.Font.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text("WSurf won’t create, reset or overwrite anything while this is unresolved. These files are involved:")
                    .font(Theme.Font.label)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(closed.paths, id: \.self) { url in
                    FailClosedPath(url: url, isBackup: url == closed.preMigrationBackup)
                }
                if let backup = closed.preMigrationBackup, !closed.paths.contains(backup) {
                    FailClosedPath(url: backup, isBackup: true)
                }
                if let error = model.error {
                    Text(verbatim: error).font(Theme.Font.secondary).fixedSize(horizontal: false, vertical: true)
                }
                SettingsButton(title: "Check Again", isProminent: true) { run { await model.retry() } }
                    .disabled(model.isBusy)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FailClosedPath: View {
    let url: URL
    let isBackup: Bool

    /// What the file is, from its name: the same names the store routes on.
    private var role: LocalizedStringResource? {
        let name = url.lastPathComponent
        if isBackup || name.hasSuffix(".pre-v2") {
            return "A copy from before the vault was upgraded. It lacks every change made since."
        }
        if name.hasSuffix(".swap") {
            return "Left by an upgrade that was interrupted before it finished."
        }
        if name.contains("cutover-v1") {
            return "A copy of the older vault kept while an upgrade was in progress."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: url.path)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let role {
                Text(role).font(Theme.Font.label).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension StoreFailCause {
    var explanation: LocalizedStringResource {
        switch self {
        case .foreignStore: "The credential store belongs to another profile or installation."
        case .wrongProfile: "The credential store was made for a different profile."
        case .v1AfterMigration: "An older-format vault file reappeared after the vault was upgraded, so WSurf can’t tell which one is current."
        case .storeMissing: "The credential store’s files are missing or incomplete, but parts of it remain."
        case .leftoversWithoutAuthority: "Files from an earlier vault were found without the store that owns them."
        case .unreadableVault, .unreadableStore: "The credential store couldn’t be read. It may be damaged."
        case .cutoverV1Present, .migrationLeftover: "An upgrade of the older vault didn’t finish."
        case .witnessMismatch: "The credential store doesn’t match its own records, so it may have been replaced or rolled back."
        }
    }
}
