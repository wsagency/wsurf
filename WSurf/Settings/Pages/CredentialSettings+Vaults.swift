// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension CredentialSettings {
    /// Switching vaults only rebinds the page: a locked vault stays locked, shows no content and offers its own Unlock.
    @ViewBuilder
    var vaultsSection: some View {
        if let first = model.vaults.first {
            SettingsSection(
                title: "Vaults",
                symbol: "lock.rectangle.stack",
                footnote: "Each vault has its own unlock passkeys. The default vault is the one autofill and saving use when they don’t need to ask.",
                accessory: {
                    ToolbarChip(symbol: "plus", label: "New Vault") { showsCreateWarning = true }
                        .disabled(model.isBusy || !model.canCreateVault)
                },
                content: {
                    DetailRow(title: "Vault") {
                        SettingsMenu(
                            options: model.vaults.sorted { $0.ordinal < $1.ordinal }.map { listing in
                                let notes = [
                                    listing.isUnlocked && listing.name != nil ? listing.numberedName : nil,
                                    model.defaultVaultID == listing.vaultID ? String(localized: "Default") : nil,
                                    listing.isUnlocked ? nil : String(localized: "Locked"),
                                ].compactMap { $0 }
                                return .init(value: listing.vaultID, label: listing.displayName, detail: notes.joined(separator: " · "))
                            },
                            selection: Binding(
                                get: { model.selectedVaultID ?? first.vaultID },
                                set: { id in run { await model.select(vaultID: id) } }
                            )
                        )
                        .disabled(model.isBusy)
                    }
                    if let selected = model.selectedVaultID {
                        RowSeparator()
                        DetailRow(title: "Default vault") {
                            if model.defaultVaultID == selected {
                                Text("This vault").foregroundStyle(.secondary)
                            } else {
                                Button("Make Default") { run { await model.setDefaultVault(selected) } }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isBusy)
                            }
                        }
                    }
                }
            )
        }
    }

    /// The selected manager's own state, never a copy: a non-fatal note that never changes whether the vault opened. It is shown
    /// on its own at the top of the page, so a locked vault, a failed unlock and a profile with one vault all still show it.
    @ViewBuilder
    var scratchWarnings: some View {
        if !model.scratchCleanupWarnings.isEmpty {
            SettingsSection(title: "Vault check", symbol: "exclamationmark.triangle") {
                ForEach(model.scratchCleanupWarnings, id: \.self) { url in
                    DetailRow(
                        verbatimTitle: url.path,
                        verbatimCaption: String(localized: """
                            A temporary file from checking the vault couldn’t be removed. It holds only opaque ids and digests, \
                            and you can delete it yourself.
                            """)
                    ) { EmptyView() }
                }
            }
        }
    }
}

/// The name, the creation choice and the warning in one step, so nothing is chosen before the user has read what losing
/// every unlock passkey means. Exactly two ways to protect the vault: a new passkey, or a passkey already enrolled in one of
/// this profile's vaults (also while that vault is locked: it is asserted again for this creation). Neither falls back to the
/// other, and nothing is preselected: the same passkey can be enrolled in several vaults, so the pick is the
/// (vault, credential) pair and is dropped if a refresh no longer lists it.
struct CredentialNewVaultSheet: View {
    typealias Existing = (vault: VaultListing, unlock: VaultUnlock)

    private struct Pick: Hashable {
        let vaultID: UUID
        let credentialID: Data
    }

    let canUseNewPasskey: Bool
    let existingPasskeys: [Existing]
    let create: (String, NewVaultChoice) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var usesExisting: Bool
    @State private var picked: Pick?

    /// `suggestedName` is the name the store would give the vault, so an unedited name reads the same locked and unlocked.
    init(
        suggestedName: String, canUseNewPasskey: Bool, existingPasskeys: [Existing],
        create: @escaping (String, NewVaultChoice) -> Void, cancel: @escaping () -> Void
    ) {
        self.canUseNewPasskey = canUseNewPasskey
        self.existingPasskeys = existingPasskeys
        self.create = create
        self.cancel = cancel
        _name = State(initialValue: suggestedName)
        _usesExisting = State(initialValue: !canUseNewPasskey && !existingPasskeys.isEmpty)
    }

    private var listed: [Pick] {
        existingPasskeys.map { Pick(vaultID: $0.vault.vaultID, credentialID: $0.unlock.credentialID) }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsValid: Bool {
        !trimmed.isEmpty && trimmed.count <= StoreFormat.nameLimit
    }

    private var choice: NewVaultChoice? {
        if usesExisting {
            guard let picked, let chosen = existingPasskeys.first(where: {
                $0.vault.vaultID == picked.vaultID && $0.unlock.credentialID == picked.credentialID
            }) else { return nil }
            return .existing(sourceVaultID: chosen.vault.vaultID, credentialID: chosen.unlock.credentialID, prfInput: chosen.unlock.prfInput)
        }
        // The model supplies the authorizing vault itself (none only for a confirmed first vault); this names the choice.
        return canUseNewPasskey ? .newPasskey(authorizedBy: nil) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Credential Vault").font(Theme.Font.row).fontWeight(.semibold)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Vault name")
            if trimmed.count > StoreFormat.nameLimit {
                Text("Use at most \(StoreFormat.nameLimit) characters.").font(Theme.Font.label).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                choiceRow("New passkey", detail: "Creates a passkey in your passkey provider just for this vault.", isOn: !usesExisting, isEnabled: canUseNewPasskey) {
                    usesExisting = false
                }
                if !canUseNewPasskey {
                    Text("A new passkey for an additional vault needs one of your other vaults unlocked first.")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !existingPasskeys.isEmpty {
                    choiceRow("Use existing passkey", detail: "Protects this vault with a passkey one of your vaults already uses. You’ll confirm with it.", isOn: usesExisting, isEnabled: true) {
                        usesExisting = true
                    }
                    if usesExisting {
                        Picker("Passkey", selection: $picked) {
                            Text("Choose a passkey").tag(Pick?.none)
                            ForEach(Array(existingPasskeys.enumerated()), id: \.offset) { _, item in
                                Text("Unlock passkey of “\(item.vault.displayName)”")
                                    .tag(Pick?.some(Pick(vaultID: item.vault.vaultID, credentialID: item.unlock.credentialID)))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            Text("""
                The vault is encrypted with your unlock passkeys. If you lose every unlock passkey, WSurf cannot \
                recover the vault or anything stored in it, and there is no recovery option. Removing an unlock \
                passkey does not change the vault’s encryption key. Someone with that passkey and an older vault \
                file can still decrypt later copies of this vault they obtain. Deleting the vault does not delete \
                backups.
                """)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Create Vault") { choice.map { create(trimmed, $0) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameIsValid || choice == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        // A refresh that no longer lists the picked passkey drops the pick; nothing else is chosen in its place.
        .onChange(of: listed) {
            if let picked, !listed.contains(picked) {
                self.picked = nil
            }
        }
    }

    private func choiceRow(
        _ title: LocalizedStringResource, detail: LocalizedStringResource, isOn: Bool, isEnabled: Bool, select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.row)
                    Text(detail).font(Theme.Font.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
