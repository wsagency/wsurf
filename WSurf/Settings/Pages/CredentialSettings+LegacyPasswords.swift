// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The one-time import of the passwords saved before Credential Manager, on the Credential Manager page. Every row appears only
/// while that move is not finished, and nothing here reads the old list until the user chooses Review…
extension CredentialSettings {
    /// A line under the locked or no-vault caption, so the page says what to do first.
    @ViewBuilder
    var legacyLockedHint: some View {
        if let state = model.legacy.state, state != .done {
            switch model.vaultExists {
            case .some(true):
                Text("Unlock the vault to import the passwords saved before Credential Manager.")
                    .font(Theme.Font.label)
                    .fixedSize(horizontal: false, vertical: true)
            case .some(false):
                Text("Create a vault to import the passwords saved before Credential Manager.")
                    .font(Theme.Font.label)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                EmptyView()
            }
        }
    }

    /// The first rows of Import & Export while the vault is open.
    @ViewBuilder
    var legacyImportRows: some View {
        if let state = model.legacy.state, state != .done {
            DetailRow(
                title: "Passwords saved before Credential Manager",
                caption: "Nothing is saved until you review and confirm. The old list stays until you remove it."
            ) {
                HStack(spacing: 8) {
                    Button("Review…") { reviewLegacyPasswords() }
                    if state == .imported {
                        Button("Remove Old List…", role: .destructive) { run { await model.requestLegacyRemoval() } }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            }
            RowSeparator()
        } else if model.legacy.didRemove {
            DetailRow(
                title: "Old Passwords list removed",
                caption: "Your saved passwords are now only in Credential Manager."
            ) { EmptyView() }
            RowSeparator()
        }
    }

    private func reviewLegacyPasswords() {
        // The authorization the user was looking at; the model checks it again after the system's prompt.
        guard let epoch = model.authorizationEpoch else { return }
        run { await model.beginLegacyImport(epoch: epoch) }
    }
}

extension View {
    /// Confirms the removal of the old list with the counts the model read, which it reads again before deleting anything.
    func legacyRemovalDialog(model: CredentialSettingsModel, run: @escaping (@escaping () async throws -> Void) -> Void) -> some View {
        confirmationDialog(
            "Remove the Old Passwords List?",
            isPresented: Binding(get: { model.legacy.removal != nil }, set: { if !$0 { model.legacy.dismissRemoval() } }),
            presenting: model.legacy.removal
        ) { tally in
            Button("Remove Old List", role: .destructive) { run { await model.confirmLegacyRemoval(tally) } }
            Button("Keep for Now", role: .cancel) {}
        } message: { tally in
            Text(verbatim: CredentialSettingsModel.legacyRemovalText(tally))
        }
    }
}
