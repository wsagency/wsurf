// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Observation
import SwiftUI
import WSurfVault

/// The two tabs of the Autofill page: everything the vault holds (and, until it moves into the vault, Input History), and every
/// setting.
enum CredentialPageTab: Hashable {
    case vault
    case settings
}

/// The search, the kind filter and the rows they leave. A keystroke or a kind change narrows the rows in the same update that makes
/// it (one pass of the view, not a stale one and a fresh one), from summaries whose search keys were built once with them; a task
/// recomputes everything when the vault or its revision changes. A view body only reads the result.
@MainActor
@Observable
final class CredentialListState {
    private var queryText = ""
    private var kind = CredentialListFilter.all
    /// What the search field holds. Setting it narrows the rows at once, from the summaries the last `refresh` was given.
    var query: String {
        get { queryText }
        set {
            guard newValue != queryText else { return }
            queryText = newValue
            narrow()
        }
    }

    /// The kind the list shows. Setting it narrows the rows at once.
    var filter: CredentialListFilter {
        get { kind }
        set {
            guard newValue != kind else { return }
            kind = newValue
            narrow()
        }
    }

    /// The Vault tab's Input History section instead of the entries. It is the profile's, not a vault's, so `reset()` keeps it.
    var showsInputHistory = false
    /// "By Site": the rows under a heading per site. A way of looking, so it stays across vaults and unlocks.
    var bySite = false
    /// The rows by site while `bySite` is on, `nil` otherwise; `rowsByID` holds the rows they name.
    private(set) var siteGroups: [SiteGroup]?
    private(set) var rowsByID: [UUID: CredentialSummary] = [:]
    /// How many credentials each kind holds; `nil` until the first refresh. It depends on the vault, not on the search, so a keystroke
    /// leaves it alone.
    private(set) var counts: [CredentialListFilter: Int]?
    /// What the last narrowing found, `nil` while nothing narrowed the list then. Until the first `refresh` there are no summaries to
    /// narrow, so the whole list shows.
    private var matches: [CredentialSummary]?
    /// The summaries the last `refresh` was given, which a keystroke narrows.
    @ObservationIgnored private var source: [CredentialSummary]?
    /// The rows the list showed last, to tell a keystroke that changes them from one that does not.
    @ObservationIgnored private var shown: [Int] = []
    /// Told the ids of the rows the list shows, in order, each time they may have changed: the selection drops what left the list.
    @ObservationIgnored var didNarrow: (([UUID]) -> Void)?
    /// How many times the rows were narrowed: the performance tests' probe for the work behind a keystroke.
    @ObservationIgnored private(set) var narrowCount = 0

    var isFiltering: Bool {
        kind != .all || !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the list shows: every credential until a search or a kind narrows it, else what the last narrowing found.
    func rows(of summaries: [CredentialSummary]) -> [CredentialSummary] {
        isFiltering ? matches ?? summaries : summaries
    }

    /// The ids of the rows in the order the list shows them, for the selection.
    func visibleIDs(of summaries: [CredentialSummary]) -> [UUID] {
        siteGroups?.flatMap(\.ids) ?? rows(of: summaries).map(\.id)
    }

    // ponytail: filtered on the main actor, one pass over precomputed keys (3,000 credentials take a few milliseconds);
    // move it to a detached task if a vault ever holds tens of thousands.
    func refresh(_ summaries: [CredentialSummary]) {
        let kinds = CredentialListFilter.counts(summaries)
        if kinds != counts {
            counts = kinds
        }
        source = summaries
        narrow(sourceChanged: true)
    }

    /// Finds the rows for the query and the kind. A keystroke that leaves the same rows changes nothing a view reads, so the list is
    /// not evaluated for it: laying out 3,000 unchanged rows again was the larger part of such a keystroke.
    private func narrow(sourceChanged: Bool = false) {
        guard let summaries = source else { return }
        narrowCount += 1
        // Positions in `summaries`, which come from the same summaries in their order: the same positions are the same rows.
        let found = CredentialListFilter.visibleIndices(summaries, query: queryText, filter: kind)
        guard sourceChanged || found != shown else { return }
        shown = found
        let rows = found.map { summaries[$0] }
        matches = isFiltering ? rows : nil
        // ponytail: grouped on the main actor too, one registrable-domain lookup per host; detach it with the filter if it shows.
        siteGroups = bySite ? CredentialSiteGroups.groups(rows) : nil
        rowsByID = bySite ? Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        didNarrow?(visibleIDs(of: summaries))
    }

    /// Back to the whole list, for another vault or another unlock. Input History stays open: it belongs to no vault.
    func reset() {
        queryText = ""
        kind = .all
        matches = nil
        shown = []
    }
}

/// What the list was last computed from; a change starts a new computation. The search and the kind are not part of it: they narrow
/// the rows themselves (`CredentialListState.query`), so typing starts no task.
private struct CredentialListKey: Equatable {
    let vault: UUID?
    let epoch: UInt64?
    let revision: UInt64
    let bySite: Bool
}

extension CredentialListFilter {
    var title: LocalizedStringResource {
        switch self {
        case .all:
            "All"
        case .logins:
            "Logins"
        case .passkeys:
            "Passkeys"
        case .codes:
            "Verification codes"
        case .notes:
            "Notes"
        case .identities:
            "Identities"
        case .cards:
            "Cards"
        case .addresses:
            "Addresses"
        case .contacts:
            "Contacts"
        case .documents:
            "IDs"
        case .otherItems:
            "Other"
        case .files:
            "Files"
        }
    }
}

// MARK: - Credentials tab

extension CredentialSettings {
    /// What the vault holds, for an unlocked vault: anything waiting for the user first, then the list or the Trash.
    @ViewBuilder
    var credentialsTab: some View {
        unconfirmedPasskeysNotice
        pendingImportCard
        if showsTrash {
            trashSection
        } else {
            CredentialListView(model: model, list: list, selection: selection, run: run, switcher: listSwitch)
        }
    }

    @ViewBuilder
    private var unconfirmedPasskeysNotice: some View {
        if model.hasUnconfirmedPasskeys {
            SettingsSection(
                title: "Passkeys not confirmed with the website",
                symbol: "exclamationmark.triangle",
                footnote: """
                    These passkeys were saved here, but WSurf could not confirm that the website received them. \
                    Test sign-in on the website; remove any passkey that does not work. Dismiss only hides this \
                    notice.
                    """
            ) {
                ForEach(model.unconfirmedPasskeys) { item in
                    DetailRow(verbatimTitle: String(localized: "\(item.userName) on \(item.rpID)")) { EmptyView() }
                }
                DetailRow(title: "Notice") {
                    Button("Dismiss") { model.dismissUnconfirmedPasskeys() }.buttonStyle(.bordered)
                }
            }
        }
    }

    /// Credentials another app sent, waiting for the user to review them. Nothing is saved until the user confirms.
    @ViewBuilder
    private var pendingImportCard: some View {
        if let token = model.pendingImportToken {
            SettingsCard {
                DetailRow(
                    verbatimTitle: String(localized: "Credentials from another app"),
                    verbatimCaption: String(localized: """
                        Sent to the profile “\(model.profile.name)”. Nothing is saved until you review and confirm. \
                        Dismiss declines them; to import them later, send them again from the other app.
                        """)
                ) {
                    HStack(spacing: 8) {
                        Button("Review…") { run { await model.beginImport() } }
                        Button("Dismiss") { model.discardPendingImport(token: token) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
            }
        }
    }
}

// MARK: - List

/// The search, the kind filter and the lazy list of one vault's credentials. A section of its own, so a keystroke or a change to the
/// list re-evaluates this view and not the page around it.
struct CredentialListView<Switcher: View>: View {
    let model: CredentialSettingsModel
    @Bindable var list: CredentialListState
    let selection: CredentialSelection
    let run: (@escaping () async throws -> Void) -> Void
    /// The Active and Trash switch, which the Trash section shows too.
    let switcher: Switcher
    /// The merge suggestions and the merge sheet of this list.
    @State private var merge = CredentialMergeState()
    /// The Move to Trash in flight. A second one waits until it is done, so a key held down never cancels a write half way.
    @State private var removal: Task<Void, Never>?
    /// What the rows call, one object for all of them: the rows are not given new closures on every pass of this view, so a row whose
    /// credential has not changed is not drawn again.
    @State private var rowActions = CredentialRowActions()

    private var key: CredentialListKey {
        CredentialListKey(vault: model.selectedVaultID, epoch: model.authorizationEpoch, revision: model.revision, bySite: list.bySite)
    }

    /// The vault's name; the page is about one vault at a time.
    private var title: String {
        model.vaults.first { $0.vaultID == model.selectedVaultID }?.label ?? String(localized: "Credentials")
    }

    var body: some View {
        // The rows call what this pass bound; a view body cannot discard a result with `_ =`.
        // swiftlint:disable:next redundant_discardable_let
        let _ = bindActions()
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            AutofillPageStatus(isBusy: model.isBusy, error: model.error, kind: .password)
            CredentialPageNotice(model: model, undo: { run { await model.undo() } })
            CredentialBulkBar(
                model: model, selection: selection, visibleCount: visibleCount,
                moveToTrash: trash, merge: startMerge
            )
            // A vault holds thousands of credentials: the list is lazy, so only the rows on screen are built and laid out.
            SettingsSection(
                title: LocalizedStringResource("\(title)"),
                symbol: "key",
                footnote: list.filter == .files ? filesFootnote : "Passwords, passkeys and verification codes stay hidden until you reveal or copy them.",
                isLongList: true
            ) {
                let rows = list.rows(of: model.summaries)
                if model.summaries.isEmpty {
                    SettingsEmptyState(symbol: "key", title: "No credentials", caption: "Add a login, passkey or verification code to see it here.")
                } else if rows.isEmpty {
                    SettingsEmptyState(symbol: "magnifyingglass", title: "No matches", caption: "Nothing in this vault matches your search or filter.")
                }
                if let groups = list.siteGroups {
                    CredentialSiteGroupsList(groups: groups, rows: list.rowsByID, merge: merge, row: row)
                } else {
                    CredentialFlatRows(rows: rows, model: model, selection: selection, actions: rowActions)
                }
            }
        }
        .background {
            CredentialKeyboardHost(
                selection: selection, inTrash: false, perform: perform, undo: { run { await model.undo() } },
                redo: { run { await model.redo() } }, undoTitle: { model.undoMenuTitle }, redoTitle: { model.redoMenuTitle }
            )
        }
        .task(id: key) {
            // The list hands the selection the rows it shows each time it narrows them, a keystroke included.
            list.didNarrow = { [selection] ids in selection.show(ids) }
            list.refresh(model.summaries)
        }
        .task(id: CredentialMergeState.Key(model)) { await merge.refresh(model) }
        // A merge changes the vault while its sheet is open: what was selected has been merged, so the selection ends.
        .onChange(of: model.revision) {
            if merge.route != nil {
                selection.clear()
            }
        }
        .sheet(isPresented: Binding(get: { merge.route != nil }, set: { if !$0 { merge.route = nil } })) {
            if let route = merge.route {
                CredentialMergeFlow(model: model, merge: merge, route: route, close: { merge.route = nil })
            }
        }
    }

    /// The Files section's use of the vault's room. Earlier versions and the Trash keep their files until the Trash is emptied.
    private var filesFootnote: LocalizedStringResource {
        let usage = model.fileUsage
        let used = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: CredentialAttachment.vaultBytes, countStyle: .file)
        return "\(usage.count) files use \(used) of this vault’s \(limit). Files are encrypted in the vault and open only while it is unlocked."
    }

    private var visibleCount: Int {
        list.siteGroups == nil ? list.rows(of: model.summaries).count : list.rowsByID.count
    }

    private func row(_ summary: CredentialSummary) -> some View {
        CredentialRow(model: model, summary: summary, selection: selection, actions: rowActions).equatable()
    }

    private func bindActions() {
        rowActions.bind(
            run: run, trash: trash, merge: startMerge, open: open,
            history: { id in run { try await model.openHistory(accountID: id) } }
        )
    }

    /// Merge… from a row or the bar. Two or more credentials open the review. One opens its merge suggestion, else starts selection
    /// mode with it selected, so the others are picked in the list itself.
    private func startMerge(_ ids: [UUID]) {
        if ids.count > 1 {
            merge.route = .review(ids)
        } else if let id = ids.first {
            if let suggested = merge.index?.suggestions(containing: id).first?.ids {
                merge.route = .review(suggested)
            } else {
                selection.beginSelecting(with: id)
            }
        }
    }

    /// Opens the editor on a credential; the cursor stays on its row for when the editor closes.
    private func open(_ id: UUID) {
        selection.place(cursor: id)
        run { try await model.beginEditing(accountID: id) }
    }

    /// Moves credentials to the Trash with no dialog. The cursor goes to the row that takes their place once the move has happened.
    private func trash(_ ids: [UUID]) {
        guard removal == nil, !model.isBusy, !ids.isEmpty else { return }
        let next = selection.cursorAfterRemoving(ids)
        let epoch = model.authorizationEpoch
        removal = Task {
            defer { removal = nil }
            guard model.authorizationEpoch == epoch else { return }
            await model.attempt {
                try await model.moveToTrash(ids: ids)
                selection.clear()
                selection.place(cursor: next)
                // After a click on a button, the next X or Command-Z acts on the list.
                selection.takeKeyboard()
            }
        }
    }

    /// What a key does while the list has the keyboard (`CredentialListKeys` decides which key means what).
    private func perform(_ command: CredentialListKeys.Command) {
        switch command {
        case .move(let delta, let extending):
            selection.moveCursor(by: delta, extending: extending)
        case .toggle:
            selection.toggleCursor()
        case .open:
            if let cursor = selection.cursor {
                open(cursor)
            }
        case .clear:
            selection.clear()
        case .remove:
            trash(selection.targets)
        case .none:
            break
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A narrow window puts the buttons under the search field instead of squeezing it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    searchField.frame(minWidth: 160, idealWidth: 220, maxWidth: .infinity)
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    actions
                }
            }
            // The kind chips are the Vault tab's sections, above this list (`VaultSectionBar`); the vault picker is beside the tabs.
            HStack(spacing: 6) {
                Toggle("By Site", isOn: $list.bySite)
                    .toggleStyle(.button)
                    .controlSize(.small)
                // Also with none left to suggest, while some are dismissed: the sheet lists those to take back.
                if merge.suggestionCount > 0 || merge.dismissedCount > 0 {
                    Button("Suggested Merges (\(merge.suggestionCount.formatted()))") { merge.route = .suggestions }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            switcher
            // A click adds a login, as before; the arrow offers the other templates (an identity, a card, an address, a note).
            Menu {
                ForEach(CredentialTemplate.allCases, id: \.self) { template in
                    Button {
                        run { try await model.beginEditing(accountID: nil, template: template) }
                    } label: {
                        Label(template.title, systemImage: template.symbol)
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                run { try await model.beginEditing(accountID: nil) }
            }
            .fixedSize()
            .help("Add a login, or choose what to add from the menu")
            .accessibilityLabel("Add Credential")
            .disabled(model.isBusy)
            ToolbarChip(symbol: "lock", label: "Lock Credentials", showsLabel: false) { model.lock() }
        }
    }

    private var searchField: some View {
        SearchFieldChrome {
            TextField("", text: $list.query)
                .textFieldStyle(.plain)
                .font(Theme.Font.secondary)
                .fieldPlaceholder("Search by name, username or website", isShowing: list.query.isEmpty)
                .accessibilityLabel("Search credentials")
                // Down moves into the list. Escape clears a search and, with none, returns to the list.
                .onKeyPress(.downArrow) {
                    selection.takeKeyboard()
                    return .handled
                }
                .onKeyPress(.escape) {
                    if list.query.isEmpty {
                        selection.takeKeyboard()
                    } else {
                        list.query = ""
                    }
                    return .handled
                }
            if !list.query.isEmpty {
                ChromeIcon(symbol: "xmark", size: 9, extent: 18, help: String(localized: "Clear Search")) {
                    list.query = ""
                }
            }
        }
    }
}

/// The flat list's rows, a view of its own with no closure among its inputs: SwiftUI compares what it is given and leaves it alone
/// while it is the same, so a keystroke that keeps the rows does not evaluate 3,000 of them again.
private struct CredentialFlatRows: View {
    let rows: [CredentialSummary]
    let model: CredentialSettingsModel
    let selection: CredentialSelection
    let actions: CredentialRowActions

    var body: some View {
        ForEach(rows) { summary in
            CredentialRow(model: model, summary: summary, selection: selection, actions: actions).equatable()
        }
    }
}

/// The Vault tab's sections: the vault's entries by kind (`CredentialListFilter.chips`), then Input History. Shown whether the vault
/// is open, locked or not created yet, so Input History stays reachable; the counts are shown only while it is open.
struct VaultSectionBar: View {
    let list: CredentialListState
    /// Only while the vault is open.
    let showsCounts: Bool
    let offersInputHistory: Bool

    /// Read here, not by the page, so a change of the counts redraws only this bar.
    private var counts: [CredentialListFilter: Int]? {
        showsCounts ? list.counts : nil
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CredentialListFilter.chips(counts: counts, selected: list.filter), id: \.self, content: chip)
                if offersInputHistory {
                    Toggle("Input History", isOn: Binding(get: { list.showsInputHistory }, set: { _ in list.showsInputHistory = true }))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func chip(_ kind: CredentialListFilter) -> some View {
        let name = String(localized: kind.title)
        return Toggle(
            isOn: Binding(
                get: { list.filter == kind && !list.showsInputHistory },
                set: { _ in
                    list.filter = kind
                    list.showsInputHistory = false
                }
            )
        ) {
            Text(verbatim: counts?[kind].map { "\(name) \($0.formatted())" } ?? name)
        }
        .toggleStyle(.button)
        .controlSize(.small)
    }
}

/// Switching vaults only rebinds the page: a locked vault stays locked and offers its own Unlock. Shown only when there is a choice;
/// the vault's own settings are on the Settings tab.
struct CredentialVaultPicker: View {
    let model: CredentialSettingsModel
    let run: (@escaping () async throws -> Void) -> Void

    var body: some View {
        if let first = model.vaults.first, model.vaults.count > 1 {
            SettingsMenu(
                options: model.vaults.sorted { $0.ordinal < $1.ordinal }.map { listing in
                    .init(
                        value: listing.vaultID, label: listing.label,
                        detail: model.defaultVaultID == listing.vaultID ? String(localized: "Default") : ""
                    )
                },
                selection: Binding(
                    get: { model.selectedVaultID ?? first.vaultID },
                    set: { id in run { await model.select(vaultID: id) } }
                )
            )
            .disabled(model.isBusy)
            .accessibilityLabel("Vault")
        }
    }
}
