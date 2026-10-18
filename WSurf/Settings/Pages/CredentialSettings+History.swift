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
/// until "Show Secrets"; a verification code's setup key is never shown.
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
        .frame(minWidth: 380, idealWidth: 420, maxWidth: .infinity, alignment: .topLeading)
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

    private func nameRow(_ from: CredentialAccount, _ draft: CredentialDraft, _ currentLabel: String) -> some View {
        VersionFieldRow(title: "Name", differs: from.displayName != draft.displayName, use: { use(.name) }) {
            VersionValues(this: from.displayName ?? "", current: draft.displayName ?? "", currentLabel: currentLabel)
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
                    currentLabel: currentLabel
                )
                VersionValues(
                    caption: "Password", this: secret(from.password ?? "", hides: !reveals), current: secret(draft.password ?? "", hides: !reveals),
                    currentLabel: currentLabel
                )
            }
        }
    }

    private func websitesRow(_ from: CredentialAccount, _ draft: CredentialDraft) -> some View {
        let version = CredentialHistory.websites(of: from)
        let now = Self.lines(draft.websites) + Self.lines(draft.extraOrigins)
        let versionTexts = Set(version.map(\.text))
        let missing = version.filter { !now.contains($0.text) }
        let added = now.filter { !versionTexts.contains($0) }
        return VersionFieldRow(title: "Websites", differs: !missing.isEmpty || !added.isEmpty, use: { use(.websites) }) {
            VStack(alignment: .leading, spacing: 4) {
                if version.isEmpty && now.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(version, id: \.text) { line in
                    HStack(spacing: 6) {
                        if now.contains(line.text) {
                            Text(verbatim: line.text).textSelection(.enabled)
                        } else {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Not in the current credential")
                            Text(verbatim: line.text).textSelection(.enabled)
                            Spacer(minLength: 4)
                            if let field = line.field {
                                Button("Add") { use(field) }.controlSize(.small)
                                    .accessibilityLabel("Add website \(line.text)")
                            }
                        }
                    }
                }
                ForEach(added, id: \.self) { line in
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary).accessibilityLabel("Only in the current credential")
                        Text(verbatim: line).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .font(Theme.Font.label)
        }
    }

    private func codeRow(_ from: CredentialAccount, _ draft: CredentialDraft, _ currentLabel: String) -> some View {
        func describe(_ generator: TOTPGenerator?) -> String {
            guard let generator else { return "" }
            let names = [generator.issuer, generator.userName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return names.isEmpty ? String(localized: "Verification code") : names
        }
        return VersionFieldRow(title: "Verification code", differs: from.totp != draft.totp, offersUse: from.totp != nil, use: { use(.code) }) {
            VStack(alignment: .leading, spacing: 4) {
                VersionValues(this: describe(from.totp), current: describe(draft.totp), currentLabel: currentLabel)
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
                        Text(verbatim: reveals ? note.text : Self.mask)
                            .lineLimit(8)
                            .privacySensitive()
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Helpers

    private func secret(_ value: String, hides: Bool) -> String {
        value.isEmpty || !hides ? value : Self.mask
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

/// The value in the shown version above the value in the draft.
private struct VersionValues: View {
    var caption: LocalizedStringResource?
    let this: String
    let current: String
    let currentLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let caption {
                Text(caption).font(Theme.Font.label).foregroundStyle(.secondary)
            }
            line(Text("This version"), this)
            line(Text(verbatim: currentLabel), current)
        }
        .font(Theme.Font.label)
    }

    private func line(_ label: Text, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label.foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
            if value.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                Text(verbatim: value).privacySensitive().textSelection(.enabled)
            }
        }
    }
}
