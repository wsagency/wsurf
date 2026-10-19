// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Editor

struct CredentialEditorSheet: View {
    let model: CredentialSettingsModel
    @State private var totpInput = ""
    @State private var totpError: String?
    @State private var isSaving = false
    @State private var saving: Task<Void, Never>?
    @State private var pendingPasskeyRemoval: PasskeySummary?

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if draft.isNew { Text("Add Credential") } else { Text("Edit Credential") }
                }
                .font(.headline)
                Form {
                    TextField("Name", text: optionalText(\.displayName))
                    if draft.usernameIsConcealed {
                        ConcealedUsernameField(username: text(\.username))
                    } else {
                        TextField("Username or email", text: text(\.username))
                    }
                    AutofillPasswordField(password: optionalText(\.password))
                    Button("Generate Strong Password") {
                        do {
                            model.draft?.password = try SavedPassword.generate()
                        } catch {
                            model.error = String(localized: "Couldn’t generate a password.")
                        }
                    }
                    LabeledContent("Websites (one HTTPS address per line)") {
                        WebsiteListField(
                            kind: .websites, label: "Websites (one HTTPS address per line)", lineLimit: 1...4, text: text(\.websites)
                        )
                    }
                    LabeledContent("Other HTTPS origins (one per line)") {
                        WebsiteListField(
                            kind: .extraOrigins, label: "Other HTTPS origins (one per line)", lineLimit: 1...3, text: text(\.extraOrigins)
                        )
                    }
                }
                .textFieldStyle(.roundedBorder)
                totp(draft)
                notes(draft)
                passkeys(draft)
                if let error = model.error {
                    Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.error = nil; model.cancelEditing() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        isSaving = true
                        saving = Task {
                            await model.attempt { _ = try await model.commitDraft() }
                            isSaving = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
            }
            .padding(24)
            .frame(width: 520)
            .onDisappear { totpInput = ""; saving?.cancel() }
            .confirmationDialog(
                "Remove Passkey?",
                isPresented: Binding(
                    get: { pendingPasskeyRemoval != nil },
                    set: { if !$0 { pendingPasskeyRemoval = nil } }
                ),
                presenting: pendingPasskeyRemoval
            ) { passkey in
                Button("Remove Passkey", role: .destructive) {
                    model.draft?.removePasskey(passkey.id)
                    pendingPasskeyRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingPasskeyRemoval = nil }
            } message: { passkey in
                Text("""
                    Remove passkey \(passkey.id.uuidString) for \(passkey.rpID)?
                    Only this local copy is removed.
                    The website registration and any other exported copies remain. Save to apply.
                    """)
            }
        }
    }

    @ViewBuilder
    private func totp(_ draft: CredentialDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification code").font(Theme.Font.rowTitle)
            if let generator = draft.totp {
                HStack {
                    Text(verbatim: [generator.issuer, generator.userName].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Verification Code", role: .destructive) { model.draft?.removeTOTP() }
                }
            } else {
                HStack {
                    SecureField("Setup key or otpauth:// link", text: $totpInput).textFieldStyle(.roundedBorder)
                    Button("Set Up") {
                        do {
                            try model.draft?.setUpTOTP(totpInput)
                            totpInput = ""
                            totpError = nil
                        } catch {
                            totpError = String(localized: "Enter a valid setup key or otpauth:// link.")
                        }
                    }
                    .disabled(totpInput.isEmpty)
                }
                if let totpError {
                    Text(verbatim: totpError).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Notes can hold secrets, so each one is hidden from screen sharing like the other secret fields.
    private func notes(_ draft: CredentialDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(Theme.Font.rowTitle)
            ForEach(draft.notes.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    TextEditor(text: noteText(index))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 80)
                        .background(Theme.Wash.faint, in: RoundedRectangle(cornerRadius: 8))
                        .privacySensitive()
                        .accessibilityLabel("Note \(index + 1)")
                    Button("Remove", role: .destructive) { model.draft?.removeNote(at: index) }
                        .accessibilityLabel("Remove note \(index + 1)")
                }
            }
            Button("Add Note") { model.draft?.addNote() }
        }
    }

    @ViewBuilder
    private func passkeys(_ draft: CredentialDraft) -> some View {
        if !draft.passkeySummaries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Passkeys").font(Theme.Font.rowTitle)
                ForEach(draft.passkeySummaries) { passkey in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "\(passkey.rpID) · \(passkey.userName) · \(passkey.id.uuidString)")
                            Text(verbatim: passkeyMetadata(passkey))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { pendingPasskeyRemoval = passkey }
                            .accessibilityLabel("Remove passkey \(passkey.id.uuidString) for \(passkey.rpID)")
                    }
                }
            }
        }
    }

    private func passkeyMetadata(_ passkey: PasskeySummary) -> String {
        let source: String
        switch passkey.source {
        case .some(.created):
            source = String(localized: "Created in WSurf")
        case .some(.imported):
            source = String(localized: "Imported")
        case nil:
            source = String(localized: "Source unknown")
        }
        let created = passkey.createdAt.map { date in
            let timestamp = date.formatted(date: .abbreviated, time: .shortened)
            let relativeAge = date.formatted(.relative(presentation: .named))
            return String(localized: "Created \(timestamp) (\(relativeAge))")
        } ?? String(localized: "Creation date unknown")
        let signed = passkey.lastSignedAt.map {
            String(localized: "Last local signature \($0.formatted(date: .abbreviated, time: .shortened))")
        } ?? String(localized: "No local signature recorded")
        return [source, created, signed].joined(separator: " · ")
    }

    private func noteText(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.draft.flatMap { $0.notes.indices.contains(index) ? $0.notes[index].text : nil } ?? "" },
            set: { text in
                guard model.draft?.notes.indices.contains(index) == true else { return }
                model.draft?.notes[index].text = text
            }
        )
    }

    private func text(_ keyPath: WritableKeyPath<CredentialDraft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? "" }, set: { model.draft?[keyPath: keyPath] = $0 })
    }

    /// An emptied field means "absent", matching how the vault stores optional values.
    private func optionalText(_ keyPath: WritableKeyPath<CredentialDraft, String?>) -> Binding<String> {
        Binding(
            get: { model.draft?[keyPath: keyPath] ?? "" },
            set: { model.draft?[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct ConcealedUsernameField: View {
    @Binding var username: String
    @State private var isRevealed = false

    private var toggleLabel: LocalizedStringKey { isRevealed ? "Hide username" : "Show username" }

    var body: some View {
        LabeledContent("Username") {
            HStack(spacing: 6) {
                Group {
                    if isRevealed {
                        TextField("Username", text: $username).autocorrectionDisabled()
                    } else {
                        SecureField("Username", text: $username)
                    }
                }
                .labelsHidden()
                .privacySensitive()
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(toggleLabel)
                .help(toggleLabel)
            }
        }
        .onDisappear { isRevealed = false }
    }
}
