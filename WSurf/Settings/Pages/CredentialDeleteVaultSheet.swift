// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The first of the two confirmations of Delete Vault: what goes, an Export… way out, and the vault's name typed to confirm. The
/// second is the system's passkey prompt, which the page asks for when `confirm` runs. Nothing here deletes anything.
struct CredentialDeleteVaultSheet: View {
    let pending: PendingVaultDeletion
    let isBusy: Bool
    let confirm: (String) -> Void
    let export: () -> Void
    let cancel: () -> Void

    @State private var typed = ""
    @FocusState private var typing: Bool

    private var canDelete: Bool {
        pending.accepts(typed) && !isBusy
    }

    private var showsNumber: Bool {
        pending.name != String(localized: "Vault \(pending.ordinal)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Vault").font(Theme.Font.row).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: pending.name).font(Theme.Font.row).fontWeight(.medium)
                if showsNumber {
                    Text("Vault \(pending.ordinal)").font(Theme.Font.label).foregroundStyle(.secondary)
                }
            }
            note("This permanently deletes the vault, its Trash and its earlier versions. It can’t be undone.")
            VStack(alignment: .leading, spacing: 4) {
                countRow("Credentials", pending.counts.credentials)
                countRow("Passkeys for websites", pending.counts.passkeys)
                countRow("Verification codes", pending.counts.codes)
                countRow("Items in Trash", pending.counts.inTrash)
                countRow("Earlier versions", pending.counts.earlierVersions)
            }
            if pending.counts.passkeys > 0 {
                note("""
                    Passkeys for websites saved in this vault stop working. Those websites still list them: sign in another way \
                    and remove them there.
                    """)
            }
            if let fallback = pending.fallback {
                note("Autofill and saving will use “\(fallback)” instead.")
            }
            if let backup = pending.preMigrationBackup {
                note("""
                    A copy from before this vault was upgraded still exists at \(backup.path) and still holds its old contents. \
                    WSurf never deletes it; delete it yourself if you want it gone.
                    """)
            }
            note("""
                This removes the vault from WSurf only. It can’t reach copies of the vault saved elsewhere, such as backups. \
                You’ll confirm with this vault’s unlock passkey.
                """)
            HStack(spacing: 8) {
                Button("Export…", action: export)
                    .buttonStyle(.bordered)
                    .disabled(pending.counts.credentials == 0 || isBusy)
                note("Save your credentials to another app first, if you want to keep them.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Type the vault’s name to confirm").font(Theme.Font.label).foregroundStyle(.secondary)
                TextField("Vault name", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit { if canDelete { confirm(typed) } }
                    .accessibilityLabel("Type the vault’s name to confirm")
            }
            HStack(spacing: 8) {
                if isBusy {
                    Spinner(size: 14)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Delete Vault…", role: .destructive) { confirm(typed) }
                    .disabled(!canDelete)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { typing = true }
    }

    private func note(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func countRow(_ title: LocalizedStringResource, _ value: Int) -> some View {
        HStack {
            Text(title).font(Theme.Font.row)
            Spacer()
            Text(value, format: .number).font(Theme.Font.row).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
