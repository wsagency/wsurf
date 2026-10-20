// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension RecordSubject {
    /// What a change to this part is called in the version list.
    var historyLabel: LocalizedStringResource {
        self == .metadata ? "Name or websites" : label
    }
}

/// A credential's earlier versions beside the editor. Read-only: "Use This" and "Add" copy a value into the draft, and nothing is
/// stored until the user chooses Save, which keeps the value it replaces as a new earlier version. Passwords and notes stay masked
/// until "Show Secrets"; a verification code's setup key is never shown. Every value shown has a copy button that puts it on the
/// clipboard (the model reads it under the current unlock, masked or not); non-secret text can also be selected and copied.
struct CredentialHistoryPanel: View {
    let model: CredentialSettingsModel
    @State private var work: Task<Void, Never>?

    private static let mask = "••••••••"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History").font(.headline)
            if let state = model.history, let draft = model.draft {
                if state.versions.count < 2 {
                    Text("No earlier versions are kept.").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    header(state)
                    if let version = state.shown {
                        ScrollView {
                            fields(version, draft: draft, reveals: state.revealsSecrets)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("Nothing changes until you choose Save.").font(Theme.Font.label).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { work?.cancel() }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        work?.cancel()
        work = Task { await model.attempt(operation) }
    }

    // MARK: Header

    private func header(_ state: HistoryState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(state.versions) { version in
                        Button {
                            model.selectVersion(version.id)
                        } label: {
                            if version.id == state.selected {
                                Label(title(of: version), systemImage: "checkmark")
                            } else {
                                Text(verbatim: title(of: version))
                            }
                        }
                    }
                    if state.next != nil {
                        Divider()
                        Button("Load Older Versions…") { perform { try await model.loadOlderVersions() } }
                    }
                } label: {
                    Text(verbatim: state.shown.map(title(of:)) ?? "")
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityLabel("Version")
                Spacer()
                if state.revealsSecrets {
                    Button("Hide Secrets") { model.hideHistorySecrets() }
                } else {
                    Button("Show Secrets") { perform { try await model.revealHistorySecrets() } }
                }
            }
            if let cause = state.shown.flatMap({ CredentialChangeCause.text(for: $0.cause) }) {
                Text(verbatim: cause).font(Theme.Font.label).foregroundStyle(.secondary)
            }
        }
    }

    private func title(of version: CredentialVersion) -> String {
        guard let replacedAt = version.replacedAt else { return String(localized: "Current") }
        let when = replacedAt.formatted(date: .abbreviated, time: .shortened)
        let parts = version.changed.sorted { $0.rawValue < $1.rawValue }.map { String(localized: $0.historyLabel) }.joined(separator: ", ")
        return String(localized: "Until \(when) · \(parts)")
    }

    // MARK: Fields

    @ViewBuilder
    private func fields(_ version: CredentialVersion, draft: CredentialDraft, reveals: Bool) -> some View {
        let from = version.account
        let currentLabel = draft.changesNothing ? String(localized: "Current") : String(localized: "Current — not saved")
        LazyVStack(alignment: .leading, spacing: 0) {
            nameRow(from, draft, currentLabel)
            RowSeparator()
            loginRow(from, draft, currentLabel, reveals: reveals)
            RowSeparator()
            websitesRow(from, draft)
            RowSeparator()
            codeRow(from, draft, currentLabel)
            RowSeparator()
            notesRow(from, draft, reveals: reveals)
            RowSeparator()
            itemsRow(from, draft, reveals: reveals)
            RowSeparator()
            Text("Passkeys have no earlier versions; a removed passkey is in Trash.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
        }
    }

    private func use(_ field: CredentialHistoryField) {
        model.copyToDraft(field, from: model.history?.selected)
    }

    /// `current` is the draft's value (the "Current" line); otherwise the shown version's. A failure shows in the editor's footer. It
    /// has its own task, so a copy never cancels a load of older versions.
    private func copier(_ part: CredentialCopyPart, current: Bool) -> () -> Void {
        { Task { await model.attempt { try await model.copy(part, of: current ? .draft : .version) } } }
    }

    private func nameRow(_ from: CredentialAccount, _ draft: CredentialDraft, _ currentLabel: String) -> some View {
        VersionFieldRow(title: "Name", differs: from.displayName != draft.displayName, use: { use(.name) }) {
            VersionValues(
                this: from.displayName ?? "", current: draft.displayName ?? "", currentLabel: currentLabel, copyName: "name",
                copyThis: copier(.name, current: false), copyCurrent: copier(.name, current: true)
            )
        }
    }

    private func loginRow(_ from: CredentialAccount, _ draft: CredentialDraft, _ currentLabel: String, reveals: Bool) -> some View {
        let hidesUsername = draft.usernameIsConcealed && !reveals
        return VersionFieldRow(
            title: "Login", differs: from.username != draft.username || from.password != draft.password, use: { use(.login) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                VersionValues(
                    caption: "Username", this: secret(from.username, hides: hidesUsername), current: secret(draft.username, hides: hidesUsername),
                    currentLabel: currentLabel, isMasked: hidesUsername, copyName: "username",
                    copyThis: copier(.username, current: false), copyCurrent: copier(.username, current: true)
                )
                VersionValues(
                    caption: "Password", this: secret(from.password ?? "", hides: !reveals), current: secret(draft.password ?? "", hides: !reveals),
                    currentLabel: currentLabel, isMasked: !reveals, copyName: "password",
                    copyThis: copier(.password, current: false), copyCurrent: copier(.password, current: true)
                )
            }
        }
    }

    private func websitesRow(_ from: CredentialAccount, _ draft: CredentialDraft) -> some View {
        let version = CredentialHistory.websites(of: from)
        let now = CredentialCopyParts.websiteLines(of: draft)
        let versionTexts = Set(version.map(\.text))
        let missing = version.filter { !now.contains($0.text) }
        let added = Array(now.enumerated()).filter { !versionTexts.contains($0.element) }
        return VersionFieldRow(title: "Websites", differs: !missing.isEmpty || !added.isEmpty, use: { use(.websites) }) {
            VStack(alignment: .leading, spacing: 4) {
                if version.isEmpty && now.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(Array(version.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 6) {
                        let isCurrent = now.contains(line.text)
                        if !isCurrent {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Not in the current credential")
                        }
                        Text(verbatim: line.text).textSelection(.enabled)
                        Spacer(minLength: 4)
                        CredentialCopyButton(label: "Copy website \(line.text)", extent: 18, action: copier(.website(index), current: false))
                        if !isCurrent, let field = line.field {
                            Button("Add") { use(field) }.controlSize(.small)
                                .accessibilityLabel("Add website \(line.text)")
                        }
                    }
                }
                ForEach(added, id: \.offset) { index, line in
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary).accessibilityLabel("Only in the current credential")
                        Text(verbatim: line).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer(minLength: 4)
                        CredentialCopyButton(label: "Copy current website \(line)", extent: 18, action: copier(.website(index), current: true))
                    }
                }
            }
            .font(Theme.Font.label)
        }
    }

    private func codeRow(_ from: CredentialAccount, _ draft: CredentialDraft, _ currentLabel: String) -> some View {
        func describe(_ generator: TOTPGenerator?) -> String {
            guard let generator else { return "" }
            let names = generator.accountLabel
            return names.isEmpty ? String(localized: "Verification code") : names
        }
        // Only the issuer and account are copied. The setup key is not shown here, so it is never offered.
        let copiesThis = !(from.totp?.accountLabel.isEmpty ?? true), copiesCurrent = !(draft.totp?.accountLabel.isEmpty ?? true)
        return VersionFieldRow(title: "Verification code", differs: from.totp != draft.totp, offersUse: from.totp != nil, use: { use(.code) }) {
            VStack(alignment: .leading, spacing: 4) {
                VersionValues(
                    this: describe(from.totp), current: describe(draft.totp), currentLabel: currentLabel, copyName: "verification code name",
                    copyThis: copiesThis ? copier(.codeLabel, current: false) : nil,
                    copyCurrent: copiesCurrent ? copier(.codeLabel, current: true) : nil
                )
                if let held = from.totp, let now = draft.totp, held != now {
                    Text(held.secret != now.secret ? LocalizedStringKey("Setup key differs") : LocalizedStringKey("Other code settings differ"))
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func notesRow(_ from: CredentialAccount, _ draft: CredentialDraft, reveals: Bool) -> some View {
        let held = from.notes ?? []
        let now = draft.notes.map(\.text).filter { !$0.isEmpty }
        let isFull = draft.notes.count >= CredentialAccount.noteLimit
        return VersionFieldRow(title: "Notes", differs: held.map(\.text) != now, offersUse: !held.isEmpty, use: { use(.notes) }) {
            VStack(alignment: .leading, spacing: 6) {
                if held.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(Array(held.enumerated()), id: \.offset) { index, note in
                    HStack(alignment: .top, spacing: 8) {
                        noteText(note.text, reveals: reveals)
                            .lineLimit(8)
                            .privacySensitive()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CredentialCopyButton(label: "Copy note \(index + 1)", extent: 18, action: copier(.note(index), current: false))
                        if now.contains(note.text) {
                            Text("In the current credential").font(Theme.Font.label).foregroundStyle(.secondary)
                        } else {
                            Button("Add") { use(.note(index)) }
                                .controlSize(.small)
                                .disabled(isFull)
                                .accessibilityLabel("Add note \(index + 1)")
                        }
                    }
                }
            }
        }
    }

    /// The cards, addresses and other items of the version: each value under its item's title, hidden ones masked until shown.
    private func itemsRow(_ from: CredentialAccount, _ draft: CredentialDraft, reveals: Bool) -> some View {
        let held = from.secureItems ?? []
        return VersionFieldRow(
            title: "Cards and other items", differs: held != (try? draft.account().secureItems ?? []), offersUse: !held.isEmpty,
            use: { use(.secureItems) }
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if held.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(held.indices, id: \.self) { index in
                    Text(verbatim: held[index].title).fontWeight(.medium)
                    ForEach(held[index].fields.indices, id: \.self) { position in
                        let item = held[index]
                        let field = item.fields[position]
                        let hides = item.isConcealed(field) && !reveals
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: item.label(of: field)).foregroundStyle(.secondary)
                            noteText(field.value, reveals: !hides)
                                .lineLimit(3)
                                .privacySensitive()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CredentialCopyButton(
                                label: "Copy \(item.label(of: field))", extent: 18,
                                action: copier(.secureField(item: index, field: position), current: false)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func secret(_ value: String, hides: Bool) -> String {
        value.isEmpty || !hides ? value : Self.mask
    }

    /// A shown note can be selected; its mask cannot, so selecting never copies bullets in place of the note.
    @ViewBuilder
    private func noteText(_ text: String, reveals: Bool) -> some View {
        if reveals {
            Text(verbatim: text).textSelection(.enabled)
        } else {
            Text(verbatim: Self.mask)
        }
    }
}

// MARK: - Pieces

/// A field of the version list: its title, "Use This" when the version's value differs from the draft's, and the values.
private struct VersionFieldRow<Content: View>: View {
    let title: LocalizedStringResource
    let differs: Bool
    /// False when the version has nothing to put into the draft (a part it did not have).
    let offersUse: Bool
    let use: () -> Void
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringResource, differs: Bool, offersUse: Bool = true, use: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.differs = differs
        self.offersUse = offersUse
        self.use = use
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.Font.rowTitle)
                Spacer()
                if !differs {
                    Text("Same as current").font(Theme.Font.label).foregroundStyle(.secondary)
                } else if offersUse {
                    Button("Use This", action: use)
                        .controlSize(.small)
                        .accessibilityLabel("Use this version’s \(String(localized: title))")
                }
            }
            content
        }
        .padding(.vertical, 10)
    }
}

/// The value in the shown version above the value in the draft. A copy button follows each value that is not empty.
private struct VersionValues: View {
    var caption: LocalizedStringResource?
    let this: String
    let current: String
    let currentLabel: String
    /// True when the values are masks: a mask is not selectable, so ⌘C never copies bullets in place of the secret.
    var isMasked = false
    /// What the buttons copy, for VoiceOver: "Copy this version’s password".
    let copyName: LocalizedStringResource
    /// `nil` leaves the button out.
    var copyThis: (() -> Void)?
    var copyCurrent: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let caption {
                Text(caption).font(Theme.Font.label).foregroundStyle(.secondary)
            }
            line(Text("This version"), this, copy: copyThis, label: "Copy this version’s \(String(localized: copyName))")
            line(Text(verbatim: currentLabel), current, copy: copyCurrent, label: "Copy the current \(String(localized: copyName))")
        }
        .font(Theme.Font.label)
    }

    private func line(_ label: Text, _ value: String, copy: (() -> Void)?, label copyLabel: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            label.foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
            if value.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                shown(value)
                Spacer(minLength: 4)
                if let copy {
                    CredentialCopyButton(label: copyLabel, extent: 18, action: copy)
                }
            }
        }
    }

    @ViewBuilder
    private func shown(_ value: String) -> some View {
        if isMasked {
            Text(verbatim: value).privacySensitive()
        } else {
            Text(verbatim: value).privacySensitive().textSelection(.enabled)
        }
    }
}
