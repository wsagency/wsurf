// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Editor

/// One credential in one sheet. Its password, verification code, websites, passkeys and notes are parts of the same
/// credential, so they are sections here and not separate items.
struct CredentialEditorSheet: View {
    let model: CredentialSettingsModel
    @State private var totpInput = ""
    @State private var totpError: String?
    @State private var isSaving = false
    @State private var saving: Task<Void, Never>?
    @State private var pendingPasskeyRemoval: PasskeySummary?
    @State private var pendingNoteRemoval: Int?
    @State private var confirmsTOTPRemoval = false
    @State private var confirmsDiscard = false
    /// Open when the credential already has other origins, so nothing saved is hidden.
    @State private var showsOtherOrigins: Bool

    init(model: CredentialSettingsModel) {
        self.model = model
        _showsOtherOrigins = State(initialValue: model.draft?.extraOrigins.isEmpty == false)
    }

    var body: some View {
        if let draft = model.draft {
            let hasChanges = draft.hasUnsavedChanges
            VStack(spacing: 0) {
                Group {
                    if draft.isNew { Text("Add Credential") } else { Text("Edit Credential") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        signIn(draft)
                        websites
                        totp(draft)
                        passkeys(draft)
                        notes(draft)
                        dates(draft)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer(hasChanges: hasChanges)
            }
            .frame(minWidth: 600, idealWidth: 640, minHeight: 480, idealHeight: 680)
            // Escape reaches the Cancel button, which asks first; nothing else may close the sheet over unsaved edits.
            .interactiveDismissDisabled(hasChanges)
            .onDisappear { totpInput = ""; saving?.cancel() }
            .confirmationDialog(
                "Discard Changes?",
                isPresented: $confirmsDiscard
            ) {
                Button("Discard Changes", role: .destructive) { discard() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your changes to this credential aren’t saved.")
            }
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
                Text(verbatim: passkey.removalMessage)
            }
            .confirmationDialog("Remove Verification Code?", isPresented: $confirmsTOTPRemoval) {
                Button("Remove Verification Code", role: .destructive) { model.draft?.removeTOTP() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The setup key moves to Trash when you save.")
            }
            .confirmationDialog(
                "Remove Note?",
                isPresented: Binding(
                    get: { pendingNoteRemoval != nil },
                    set: { if !$0 { pendingNoteRemoval = nil } }
                ),
                presenting: pendingNoteRemoval
            ) { index in
                Button("Remove Note", role: .destructive) {
                    model.draft?.removeNote(at: index)
                    pendingNoteRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingNoteRemoval = nil }
            } message: { _ in
                Text("This note is removed when you save. If you saved it before, you can restore the previous notes from Earlier Versions.")
            }
        }
    }

    // MARK: Layout

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.Font.rowTitle).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.Font.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func footer(hasChanges: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let error = model.error {
                Text(verbatim: error)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    // A save in flight has already read the draft; asking then would only hide its result.
                    if hasChanges && !isSaving {
                        confirmsDiscard = true
                    } else {
                        discard()
                    }
                }
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
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func discard() {
        model.error = nil
        model.cancelEditing()
    }

    // MARK: Sections

    private func signIn(_ draft: CredentialDraft) -> some View {
        section("Sign-in") {
            Form {
                TextField("Name", text: optionalText(\.displayName))
                if draft.usernameIsConcealed {
                    ConcealedUsernameField(username: text(\.username))
                } else {
                    TextField("Username or email", text: text(\.username))
                }
                AutofillPasswordField(password: optionalText(\.password))
                Button("Generate Password") {
                    do {
                        model.draft?.password = try SavedPassword.generate()
                    } catch {
                        model.error = String(localized: "Couldn’t generate a password.")
                    }
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
        }
    }

    private var websites: some View {
        section("Websites") {
            WebsiteListField(
                kind: .websites, label: "Websites (one HTTPS address per line)", lineLimit: 2...6, text: text(\.websites)
            )
            caption("One HTTPS address per line. Passwords and codes fill only on these websites.")
            DisclosureGroup("Other HTTPS origins", isExpanded: $showsOtherOrigins) {
                VStack(alignment: .leading, spacing: 6) {
                    WebsiteListField(
                        kind: .extraOrigins, label: "Other HTTPS origins (one per line)", lineLimit: 1...4, text: text(\.extraOrigins)
                    )
                    caption("More sites where this credential fills, one per line.")
                }
                .padding(.top, 6)
            }
        }
    }

    private func totp(_ draft: CredentialDraft) -> some View {
        section("Verification code") {
            if let generator = draft.totp {
                HStack {
                    Text(verbatim: totpTitle(generator)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove…", role: .destructive) { confirmsTOTPRemoval = true }
                        .accessibilityLabel("Remove verification code")
                }
                // Ticks only while the editor shows a code, which only exists while the vault is unlocked.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let code = try? TOTP.code(generator, at: context.date.timeIntervalSince1970) {
                        HStack(spacing: 8) {
                            Text(verbatim: code.value)
                                .font(.system(.title3, design: .monospaced))
                                .privacySensitive()
                            Spacer(minLength: 8)
                            Text("Expires in \(Int(code.remainingSeconds.rounded(.up))) s")
                                .font(Theme.Font.label)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
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

    private func totpTitle(_ generator: TOTPGenerator) -> String {
        let title = [generator.issuer, generator.userName].compactMap { $0 }.joined(separator: " · ")
        return title.isEmpty ? String(localized: "Code is set up") : title
    }

    @ViewBuilder
    private func passkeys(_ draft: CredentialDraft) -> some View {
        if !draft.passkeySummaries.isEmpty {
            section("Passkeys") {
                ForEach(draft.passkeySummaries) { passkey in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "\(passkey.rpID) · \(passkey.userName)")
                            Text(verbatim: passkeyMetadata(passkey))
                                .font(Theme.Font.label)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove…", role: .destructive) { pendingPasskeyRemoval = passkey }
                            .accessibilityLabel(Text(verbatim: passkey.removeLabel(among: draft.passkeySummaries)))
                    }
                }
            }
        }
    }

    /// Notes can hold secrets, so each one is hidden from screen sharing like the other secret fields.
    private func notes(_ draft: CredentialDraft) -> some View {
        section("Notes") {
            ForEach(draft.notes.indices, id: \.self) { index in
                noteEditor(index)
            }
            Button {
                model.draft?.addNote()
            } label: {
                Label("Add Note", systemImage: "plus")
            }
            .disabled(draft.notes.count >= CredentialAccount.noteLimit)
        }
    }

    /// A roomy editor that grows with its text up to a limit and then scrolls, with a red remove button in its top-right corner.
    private func noteEditor(_ index: Int) -> some View {
        let text = noteText(index)
        return ZStack(alignment: .topLeading) {
            // The same text, laid out but not drawn, sets the height. ponytail: only the first 4,000 characters are laid
            // out, because past that the box is at its 320 pt limit anyway; a longer note scrolls inside the editor.
            Text(verbatim: String(text.wrappedValue.prefix(4_000)) + "\n ")
                .font(.body)
                .padding(.horizontal, 5)
                .padding(.trailing, 24)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .hidden()
                .accessibilityHidden(true)
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.trailing, 24)
                .padding(8)
                .privacySensitive()
                .accessibilityLabel("Note \(index + 1)")
        }
        .frame(minHeight: 120, maxHeight: 320)
        .background(Theme.Wash.faint, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Button {
                requestNoteRemoval(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .padding(4)
            .help("Remove Note")
            .accessibilityLabel("Remove note \(index + 1)")
        }
    }

    /// A note with text asks first; an empty one has nothing to lose.
    private func requestNoteRemoval(at index: Int) {
        guard let draft = model.draft, draft.notes.indices.contains(index) else { return }
        if draft.notes[index].text.isEmpty {
            model.draft?.removeNote(at: index)
        } else {
            pendingNoteRemoval = index
        }
    }

    @ViewBuilder
    private func dates(_ draft: CredentialDraft) -> some View {
        let lines = draft.dateLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text(verbatim: $0) }
            }
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
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

extension PasskeySummary {
    /// What the confirmation says before a passkey leaves the credential. It names the site and the account, never the id.
    var removalMessage: String {
        String(
            localized: """
                The passkey for \(userName) on \(rpID) moves to Trash when you save. \
                The website still lists it; remove it there too if you no longer use it.
                """
        )
    }

    /// What VoiceOver reads for the remove button. The id is added only when another passkey of the list would read the same.
    func removeLabel(among all: [PasskeySummary]) -> String {
        let twins = all.filter { $0.rpID == rpID && $0.userName == userName }.count > 1
        return twins
            ? String(localized: "Remove passkey for \(userName) on \(rpID) (\(id.uuidString))")
            : String(localized: "Remove passkey for \(userName) on \(rpID)")
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
