// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WSurfVault

// MARK: - Backup

/// What the backup sheet was opened for. The epoch travels with the selection, so a lock or re-unlock makes the export fail
/// instead of writing a different vault than the user chose from.
struct VaultBackupExportContext: Identifiable {
    let id = UUID()
    let epoch: UInt64
    /// A `.wsurfvault` file sealed under a backup password, instead of a plain JSON file.
    let encrypted: Bool
}

/// An encrypted backup the user chose to import, waiting for its password.
struct VaultBackupImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    /// The encrypted file as read once (`CredentialSettingsModel.readBackup`).
    let container: Data
    let epoch: UInt64
}

extension UTType {
    /// WSurf's encrypted backup file. Not declared by the app, so the system treats it as data with this extension.
    static let wsurfBackup = UTType(filenameExtension: "wsurfvault", conformingTo: .data) ?? .data
}

extension CredentialSettings {
    func openBackupExport(encrypted: Bool) {
        guard let epoch = model.authorizationEpoch else { return }
        backupExport = VaultBackupExportContext(epoch: epoch, encrypted: encrypted)
    }

    /// The save panel runs only after the user clicked Choose File…, and the vault is read and the selection proved current only
    /// after it returns, so a change made while the panel was open writes nothing. The panel itself asks before replacing a file.
    func saveBackup(_ accountIDs: [UUID], password: String?, epoch: UInt64) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [password == nil ? .json : .wsurfBackup]
        panel.nameFieldStringValue = password == nil ? String(localized: "WSurf Backup.json") : String(localized: "WSurf Backup.wsurfvault")
        panel.message = password == nil
            ? String(localized: "The file will not be encrypted. Anyone who can open it can read everything in it.")
            : String(localized: "The file is encrypted with your backup password.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            guard model.authorizationEpoch == epoch else { return }
            if await model.exportBackup(accountIDs: accountIDs, epoch: epoch, to: url, password: password) {
                backupExport = nil
            }
        }
    }

    func importBackup() {
        // The authorization the user was looking at; checked again after the panel, which can stay open past a lock.
        guard let epoch = model.authorizationEpoch else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wsurfBackup, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a WSurf backup: an encrypted .wsurfvault file or an unencrypted .json file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            switch await model.readBackup(from: url, epoch: epoch) {
            case let .backup(backup):
                await model.beginBackupImport(backup, epoch: epoch)
            case let .needsPassword(container):
                backupImport = VaultBackupImportRequest(url: url, container: container, epoch: epoch)
            case .wrongPassword, .failed:
                break
            }
        }
    }

    /// Decrypts the requested backup with `password`. Returns false to keep the sheet open for another try. The review is staged
    /// only once the sheet is gone (`stagePendingBackup`), so the two sheets never overlap.
    func openBackup(_ request: VaultBackupImportRequest, password: String) async -> Bool {
        switch await model.openBackup(request.container, password: password, epoch: request.epoch) {
        case let .backup(backup):
            // The model checked the epoch after the key derivation; this page's own state may have moved on since.
            guard model.authorizationEpoch == request.epoch else { return true }
            pendingBackup = PendingBackup(backup: backup, epoch: request.epoch)
            return true
        case .needsPassword, .wrongPassword:
            return false
        case .failed:
            return true
        }
    }

    func stagePendingBackup() {
        guard let pending = pendingBackup else { return }
        pendingBackup = nil
        guard model.authorizationEpoch == pending.epoch else { return }
        run { await model.beginBackupImport(pending.backup, epoch: pending.epoch) }
    }
}

/// A decrypted backup between its password sheet and its review.
struct PendingBackup {
    let backup: VaultBackup
    let epoch: UInt64
}

/// Chooses the entries of a full backup, and for an encrypted one its password. Every entry starts selected: a backup is meant to
/// hold everything. Nothing is read until Choose File….
struct VaultBackupExportSheet: View {
    let model: CredentialSettingsModel
    let encrypted: Bool
    let export: ([UUID], String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var excluded: Set<UUID> = []
    @State private var query = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var attempted = false

    /// The shortest backup password the sheet accepts.
    static let minimumPasswordLength = 8

    private var listed: [CredentialSummary] {
        CredentialListFilter.visible(model.summaries, query: query, filter: .all)
    }

    private var chosen: [UUID] {
        model.summaries.map(\.id).filter { !excluded.contains($0) }
    }

    private var passwordProblem: LocalizedStringResource? {
        guard encrypted else { return nil }
        if password.count < Self.minimumPasswordLength {
            return "Use a backup password of at least 8 characters."
        }
        if password != confirmation {
            return "The two passwords don’t match."
        }
        return nil
    }

    private var exportSource: String {
        guard let vault = model.vaultName else {
            return String(localized: "Exporting from the profile “\(model.profile.name)”.")
        }
        return String(localized: "Exporting from the vault “\(vault)” of the profile “\(model.profile.name)”.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(encrypted ? "Export Encrypted Backup" : "Export Unencrypted Backup").font(.headline)
            Text(verbatim: exportSource)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if encrypted {
                Text("""
                    This saves every part of the selected entries to one file encrypted with a backup password: passwords, \
                    passkeys, verification code setups, notes, cards and other items, and attached files. You can import it into \
                    WSurf on any Mac. WSurf can’t recover a forgotten backup password, and without it the file can’t be opened.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                passwordFields
            } else {
                Label {
                    Text("""
                        This file is NOT encrypted. It holds every password, passkey, verification code setup, card, note and \
                        attached file of the selected entries in plain text: anyone who can open it can read and use all of \
                        them. You are responsible for protecting it. Encrypt it or delete it as soon as you no longer need it; \
                        WSurf never deletes it for you. To keep a copy safely, choose Export Encrypted Backup instead.
                        """)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Saving the file asks for Touch ID or your Mac password first.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if attempted, let message = model.transferMessage {
                Text(verbatim: message.text)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
            selectionBar
            ScrollView {
                // Lazy: the sheet lists every entry, and a vault holds thousands.
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(listed) { summary in
                        Toggle(isOn: binding(summary.id)) {
                            Text(verbatim: summary.title).font(Theme.Font.rowTitle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            if let error = model.error {
                Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.error = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose File…") {
                    attempted = true
                    export(chosen, encrypted ? password : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || passwordProblem != nil || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear {
            password = ""
            confirmation = ""
        }
    }

    private var passwordFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.newPassword)
            SecureField("Confirm backup password", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .textContentType(.newPassword)
            if let passwordProblem, !password.isEmpty {
                Text(passwordProblem).font(Theme.Font.label).foregroundStyle(.secondary)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            TextField("Search by name, username or website", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search credentials")
            Button("Select All") { excluded.subtract(listed.map(\.id)) }
            Button("Select None") { excluded.formUnion(listed.map(\.id)) }
            Text("\(chosen.count) selected").foregroundStyle(.secondary).fixedSize()
        }
        .controlSize(.small)
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(id) },
            set: { on in
                if on {
                    excluded.remove(id)
                } else {
                    excluded.insert(id)
                }
            }
        )
    }
}

/// Asks for the password of an encrypted backup the user chose to import. A wrong password keeps the sheet open and says so;
/// the password is never kept after the sheet closes.
struct VaultBackupPasswordSheet: View {
    let request: VaultBackupImportRequest
    /// Returns whether the sheet should close: false for a wrong password.
    let open: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var wrong = false
    @State private var opening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Encrypted Backup").font(.headline)
            Text(verbatim: String(localized: "Enter the backup password of “\(request.url.lastPathComponent)”."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit(submit)
            if wrong {
                Text("The password is wrong, or the file was changed or damaged. Nothing was imported.")
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if opening {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Backup", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || opening)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onDisappear { password = "" }
    }

    private func submit() {
        guard !password.isEmpty, !opening else { return }
        opening = true
        wrong = false
        Task {
            let closes = await open(password)
            opening = false
            if closes {
                password = ""
                dismiss()
            } else {
                wrong = true
            }
        }
    }
}
