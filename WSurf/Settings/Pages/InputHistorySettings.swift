// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

extension InputHistoryRetention {
    var label: LocalizedStringResource {
        switch self {
        case .thirtyMinutes:
            "30 minutes"
        case .twoHours:
            "2 hours"
        case .oneDay:
            "1 day"
        case .oneWeek:
            "1 week"
        case .untilDeleted:
            "Until I delete"
        }
    }
}

/// Settings > Autofill > Input History: the switch, how long entries stay, the excluded websites, and the entries themselves.
///
/// Opening the page asks for nothing. The entries stay encrypted until the person asks to see them, which needs Touch ID or the
/// Mac password. They are dropped two minutes after the page closes, and at once on any vault lock event.
struct InputHistorySettings: View {
    @Bindable var settings: BrowserSettings
    let profile: Profile
    @State private var model: InputHistoryListModel
    @State private var asksConsent = false
    @State private var asksTurnOff = false
    @State private var asksUntilDeleted = false

    init(context: BrowserProfileContext) {
        settings = context.settings
        profile = context.profile
        _model = State(initialValue: InputHistoryListModel(profile: context.profile, settings: context.settings))
    }

    /// The switch only moves after the person has answered: on needs consent, off deletes everything.
    private var recording: Binding<Bool> {
        Binding(
            get: { settings.recordsInputHistory },
            set: { isOn in
                if isOn {
                    asksConsent = true
                } else {
                    asksTurnOff = true
                }
            }
        )
    }

    private var retention: Binding<InputHistoryRetention> {
        Binding(
            get: { settings.inputHistoryRetention },
            set: { choice in
                if choice == .untilDeleted, settings.inputHistoryRetention != .untilDeleted {
                    asksUntilDeleted = true
                } else {
                    settings.inputHistoryRetention = choice
                }
            }
        )
    }

    /// Lines are kept as typed, so a new empty line survives the round trip through the field. A blank line matches nothing.
    private var excludedSites: Binding<String> {
        Binding(
            get: { settings.inputHistoryExcludedSites.joined(separator: "\n") },
            set: { settings.inputHistoryExcludedSites = $0.components(separatedBy: .newlines) }
        )
    }

    var body: some View {
        SettingsPageHeader(title: "Input History", caption: "Find text you typed on websites, including passwords you didn’t save.")
        SettingsCard {
            DetailRow(
                title: "Remember what I type",
                caption: """
                Keeps what you type on websites, including passwords, encrypted on this Mac for the time you choose. \
                Opening it needs Touch ID or your Mac password. Private windows are never recorded.
                """
            ) {
                SettingsToggle(recording)
            }
            .settingsAnchor("autofill.inputHistory")
            RowSeparator()
            DetailRow(title: "Keep entries for", caption: "Each entry is deleted when this time has passed.") {
                SettingsMenu(
                    options: InputHistoryRetention.allCases.map { .init(value: $0, label: String(localized: $0.label)) },
                    selection: retention
                )
            }
            RowSeparator()
            DetailRow(
                title: "Excluded websites",
                caption: "Nothing typed on these websites or their subdomains is recorded. One per line.",
                layout: .stacked
            ) {
                WebsiteListField(kind: .websites, label: "Excluded websites (one per line)", lineLimit: 2...6, text: excludedSites)
            }
        }
        .disabled(profile.isPrivate)
        InputHistoryEntries(model: model, isRecording: settings.recordsInputHistory)
            .disabled(profile.isPrivate)
            .alert("Turn on Input History?", isPresented: $asksConsent) {
                Button("Turn On") { settings.recordsInputHistory = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                WSurf will remember text you type on websites in every window of this profile, including passwords. It stays \
                encrypted on this Mac. It is never synced, and never shown to assistants or connected apps. Nothing is recorded in \
                a tab while the assistant or a connected app works in it. Entries are deleted after the time you choose. Anyone who \
                knows your Mac password can open it. Card numbers, security codes and one-time codes are not recorded.
                """)
            }
            .alert("Turn off Input History?", isPresented: $asksTurnOff) {
                Button("Turn Off and Delete", role: .destructive) { model.turnOffAndDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything it kept on this Mac is deleted.")
            }
            .alert("Keep everything you type until you delete it?", isPresented: $asksUntilDeleted) {
                Button("Keep Until I Delete", role: .destructive) { settings.inputHistoryRetention = .untilDeleted }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Passwords and other text will stay on this Mac until you clear them. Anyone who learns your Mac password could read them.")
            }
    }
}

enum InputHistoryRowAction {
    case select, copy, reveal, save, exclude, delete
}

/// The entries, locked until the person asks to see them. The search field keeps the keyboard: Up and Down move the selected row,
/// Return copies it, Escape clears the search. Every other action is a button, a menu item and a VoiceOver action of the row.
private struct InputHistoryEntries: View {
    @Bindable var model: InputHistoryListModel
    let isRecording: Bool
    @State private var saving: InputHistoryCredentialSave?
    @State private var asksClearAll = false
    @FocusState private var searching: Bool
    @Environment(\.settingsScrollProxy) private var scrollProxy

    private var footnote: LocalizedStringResource? {
        model.isLocked ? nil : "\(model.entryCount) entries · kept for \(String(localized: model.retention.label))"
    }

    var body: some View {
        SettingsSection(
            title: "Entries",
            symbol: "list.clipboard",
            footnote: footnote,
            isLongList: !model.isLocked && !model.rows.isEmpty,
            accessory: { accessory },
            content: { content }
        )
        .onAppear {
            model.listDidOpen()
            model.sync()
        }
        .onDisappear { model.listDidClose() }
        // A delete, an expiry or a lock elsewhere changes what may be shown.
        .onChange(of: model.source) { model.sync() }
        .confirmationDialog("Clear Input History?", isPresented: $asksClearAll) {
            Button("Clear Input History", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything it kept on this Mac is deleted.")
        }
        .sheet(item: $saving) { save in
            InputHistorySaveSheet(save: save)
        }
    }

    private var accessory: some View {
        HStack(spacing: 8) {
            if !model.isLocked {
                SettingsButton(title: "Lock", symbol: "lock") { model.lock() }
            }
            SettingsButton(title: "Clear Input History…", isDestructive: true) { asksClearAll = true }
                .disabled(model.isLocked ? model.entryCount == 0 : model.rows.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLocked {
            locked
        } else if model.rows.isEmpty {
            if isRecording {
                SettingsEmptyState(symbol: "list.clipboard", title: "Nothing recorded yet", caption: "Text you type on websites appears here.")
            } else {
                SettingsEmptyState(symbol: "list.clipboard", title: "Nothing recorded yet", caption: "Turn on Remember what I type to start.")
            }
        } else {
            searchField
                .padding(.vertical, 8)
            if model.visible.isEmpty {
                DetailRow(caption: "Nothing matches that.") {
                    EmptyView()
                }
            }
            ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    RowSeparator()
                }
                InputHistoryRowView(
                    row: row,
                    text: model.text(for: row),
                    spokenValue: model.spokenValue(for: row),
                    isRevealed: model.isRevealed(row),
                    isSelected: model.selection == row.id
                ) { action in
                    perform(action, on: row)
                }
                .id(row.id)
            }
        }
        if let error = model.error {
            SettingsNotice(symbol: "exclamationmark.triangle", text: error)
                .padding(.vertical, 8)
        }
        if let notice = model.notice {
            SettingsNotice(symbol: "checkmark.circle", text: notice, level: .idle)
                .padding(.vertical, 8)
        }
    }

    private var locked: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Input History is locked")
                .font(.headline)
            Text("Opening it needs Touch ID or your Mac password.")
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
            Button("Show Entries") {
                Task {
                    await model.unlock()
                    searching = !model.isLocked
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isUnlocking)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(24)
    }

    private var searchField: some View {
        SearchFieldChrome {
            TextField("", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.Font.secondary)
                .fieldPlaceholder("Search by website, field or text", isShowing: model.query.isEmpty)
                .accessibilityLabel("Search Input History")
                .focused($searching)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) {
                    guard model.selectedRow != nil else { return .ignored }
                    model.copySelected()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !model.query.isEmpty else { return .ignored }
                    model.query = ""
                    return .handled
                }
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        model.moveSelection(by: offset)
        if let id = model.selection {
            scrollProxy?.scrollTo(id, anchor: nil)
        }
        return .handled
    }

    private func perform(_ action: InputHistoryRowAction, on row: InputHistoryListModel.Row) {
        switch action {
        case .select:
            model.selection = row.id
        case .copy:
            model.copy(row)
        case .reveal:
            model.toggleReveal(row)
        case .save:
            beginSave(row)
        case .exclude:
            model.excludeSite(of: row)
        case .delete:
            model.delete(row)
        }
    }

    /// The vault is chosen and unlocked on this click, before the sheet: its prompts must not stack on a sheet. Nothing is
    /// written until the person confirms in the sheet.
    private func beginSave(_ row: InputHistoryListModel.Row) {
        guard let window = NSApp.keyWindow, let save = InputHistoryCredentialSave(row: row, profile: model.profile) else { return }
        Task {
            await save.start(in: window)
            if save.stage != .canceled {
                saving = save
            }
        }
    }
}

private struct InputHistoryRowView: View {
    let row: InputHistoryListModel.Row
    let text: String
    let spokenValue: String
    let isRevealed: Bool
    let isSelected: Bool
    let perform: (InputHistoryRowAction) -> Void

    private var caption: String {
        let time = row.createdAt.formatted(.relative(presentation: .named))
        let username = row.isPassword ? row.username ?? "" : ""
        return [row.label, username, time].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(host: row.host)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.host)
                    .font(Theme.Font.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: text)
                    .font(Theme.Font.label)
                    .lineLimit(2)
                    .accessibilityLabel(Text(verbatim: spokenValue))
                Text(verbatim: caption)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(verbatim: row.createdAt.formatted(date: .abbreviated, time: .standard)))
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                revealButton
                Button("Copy") { perform(.copy) }
                Menu {
                    moreItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("More Actions")
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.tight, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { perform(.select) }
        .contextMenu {
            Button("Copy") { perform(.copy) }
            revealButton
            moreItems
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: row.label.isEmpty ? row.host : "\(row.host), \(row.label)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Copy") { perform(.copy) }
        .accessibilityAction(named: "Delete") { perform(.delete) }
    }

    @ViewBuilder
    private var revealButton: some View {
        if row.isPassword {
            if isRevealed {
                Button("Hide") { perform(.reveal) }
            } else {
                Button("Reveal") { perform(.reveal) }
            }
        }
    }

    @ViewBuilder
    private var moreItems: some View {
        if row.canSaveAsCredential {
            Button("Save as Credential…") { perform(.save) }
        }
        Button("Don’t Record This Site") { perform(.exclude) }
        Divider()
        Button("Delete", role: .destructive) { perform(.delete) }
    }
}

/// Shows what saving does and writes only on Save. The vault was chosen and unlocked before this opened.
private struct InputHistorySaveSheet: View {
    let save: InputHistoryCredentialSave
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as Credential")
                .font(.headline)
            stage
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { username = save.username }
        .onChange(of: username) { _, text in
            if text != save.username {
                save.edit(username: text)
            }
        }
        .onDisappear { save.cancel() }
    }

    @ViewBuilder
    private var stage: some View {
        switch save.stage {
        case .working:
            HStack(spacing: 8) {
                Spinner(size: 14)
                Text("Accessing passwords…")
                    .foregroundStyle(.secondary)
            }
        case .confirming:
            Form {
                LabeledContent("Website") {
                    Text(verbatim: save.origin)
                }
                TextField("Username", text: $username)
                LabeledContent("Password") {
                    Text(verbatim: InputHistoryListModel.mask)
                        .accessibilityLabel("Hidden")
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            planCaption
            if let notice = save.notice {
                SettingsNotice(symbol: "exclamationmark.triangle", text: notice)
            }
        case .finished(let outcome):
            outcomeText(outcome)
                .fixedSize(horizontal: false, vertical: true)
        case .canceled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var planCaption: some View {
        Group {
            if save.isUpdate {
                Text("Replaces the saved password for this username.")
            } else {
                Text("Saves a new login for this website.")
            }
        }
        .font(Theme.Font.secondary)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func outcomeText(_ outcome: InputHistoryCredentialSave.Outcome) -> some View {
        switch outcome {
        case .saved:
            Text("Saved to Credential Manager.")
        case .alreadySaved:
            Text("This login is already saved.")
        case .ambiguous:
            Text("More than one saved login matches this username. Change the right one in Credential Manager.")
        case .unavailable:
            Text("Credential Manager has no vault ready. Set one up in Credential Manager first.")
        case .failed(let message):
            Text(verbatim: message)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch save.stage {
        case .working, .confirming:
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if save.stage == .confirming {
                Button("Save") { Task { await save.confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!save.canSave)
            }
        case .finished, .canceled:
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
