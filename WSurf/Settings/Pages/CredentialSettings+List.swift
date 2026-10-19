// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Observation
import SwiftUI

/// The two tabs of the Credentials page.
enum CredentialPageTab: Hashable {
    case credentials
    case settings
}

/// The search, the kind filter and the rows they leave. A task recomputes them when the search, the filter or the vault changes, from
/// summaries whose search keys were built once with them; a view body only reads the result.
@MainActor
@Observable
final class CredentialListState {
    var query = ""
    var filter = CredentialListFilter.all
    /// "By Site": the rows under a heading per site. A way of looking, so it stays across vaults and unlocks.
    var bySite = false
    /// The rows by site while `bySite` is on, `nil` otherwise; `rowsByID` holds the rows they name.
    private(set) var siteGroups: [SiteGroup]?
    private(set) var rowsByID: [UUID: CredentialSummary] = [:]
    /// How many credentials each kind holds; `nil` until the first refresh.
    private(set) var counts: [CredentialListFilter: Int]?
    /// What the last refresh found, `nil` while nothing narrowed the list then. A keystroke shows the previous rows (or the whole
    /// list) for the moment before its own refresh lands, never an empty list.
    private var matches: [CredentialSummary]?

    var isFiltering: Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the list shows: every credential until a search or a kind narrows it, else what the last refresh found.
    func rows(of summaries: [CredentialSummary]) -> [CredentialSummary] {
        isFiltering ? matches ?? summaries : summaries
    }

    // ponytail: filtered on the main actor, one pass over precomputed keys (3,000 credentials take a few milliseconds);
    // move it to a detached task if a vault ever holds tens of thousands.
    func refresh(_ summaries: [CredentialSummary]) {
        counts = CredentialListFilter.counts(summaries)
        matches = isFiltering ? CredentialListFilter.visible(summaries, query: query, filter: filter) : nil
        // ponytail: grouped on the main actor too, one registrable-domain lookup per host; detach it with the filter if it shows.
        let shown = bySite ? rows(of: summaries) : []
        siteGroups = bySite ? CredentialSiteGroups.groups(shown) : nil
        rowsByID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Back to the whole list, for another vault or another unlock.
    func reset() {
        query = ""
        filter = .all
        matches = nil
    }
}

/// What the list was last computed from; a change starts a new computation.
private struct CredentialListKey: Equatable {
    let vault: UUID?
    let epoch: UInt64?
    let revision: UInt64
    let query: String
    let filter: CredentialListFilter
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
            CredentialListView(model: model, list: list, run: run, switcher: listSwitch)
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
    let run: (@escaping () async throws -> Void) -> Void
    /// The Active and Trash switch, which the Trash section shows too.
    let switcher: Switcher
    /// The merge suggestions and the merge sheet of this list.
    @State private var merge = CredentialMergeState()

    private var key: CredentialListKey {
        CredentialListKey(
            vault: model.selectedVaultID, epoch: model.authorizationEpoch, revision: model.revision, query: list.query, filter: list.filter,
            bySite: list.bySite
        )
    }

    /// The vault's name; the page is about one vault at a time.
    private var title: String {
        model.vaults.first { $0.vaultID == model.selectedVaultID }?.label ?? String(localized: "Credentials")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            AutofillPageStatus(isBusy: model.isBusy, error: model.error, kind: .password)
            CredentialPageNotice(model: model)
            // A vault holds thousands of credentials: the list is lazy, so only the rows on screen are built and laid out.
            SettingsSection(
                title: LocalizedStringResource("\(title)"),
                symbol: "key",
                footnote: "Passwords, passkeys and verification codes stay hidden until you reveal or copy them.",
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
                    ForEach(rows, content: row)
                }
            }
        }
        .task(id: key) { list.refresh(model.summaries) }
        .task(id: CredentialMergeState.Key(model)) { await merge.refresh(model) }
        .sheet(isPresented: Binding(get: { merge.route != nil }, set: { if !$0 { merge.route = nil } })) {
            if let route = merge.route {
                CredentialMergeFlow(
                    model: model, merge: merge, matches: { CredentialListFilter.visible(model.summaries, query: $0, filter: .all) },
                    route: route, close: { merge.route = nil }
                )
            }
        }
    }

    private func row(_ summary: CredentialSummary) -> some View {
        CredentialRow(
            model: model, summary: summary, run: run,
            remove: { model.requestRemoval(accountID: summary.id) },
            history: { run { try await model.openHistory(accountID: summary.id) } },
            mergeWith: { merge.route = .pick(summary.id) }
        )
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
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CredentialListFilter.allCases, id: \.self) { kind in
                            chip(kind)
                        }
                        Toggle("By Site", isOn: $list.bySite)
                            .toggleStyle(.button)
                            .controlSize(.small)
                        if merge.suggestionCount > 0 {
                            Button("Suggested Merges (\(merge.suggestionCount.formatted()))") { merge.route = .suggestions }
                                .controlSize(.small)
                                .disabled(model.isBusy)
                        }
                    }
                }
                CredentialVaultPicker(model: model, run: run)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            switcher
            ToolbarChip(symbol: "plus", label: "Add Credential") {
                run { try await model.beginEditing(accountID: nil) }
            }
            .disabled(model.isBusy)
            ToolbarChip(symbol: "lock", label: "Lock") { model.lock() }
        }
    }

    private var searchField: some View {
        SearchFieldChrome {
            TextField("", text: $list.query)
                .textFieldStyle(.plain)
                .font(Theme.Font.secondary)
                .fieldPlaceholder("Search by name, username or website", isShowing: list.query.isEmpty)
                .accessibilityLabel("Search credentials")
            if !list.query.isEmpty {
                ChromeIcon(symbol: "xmark", size: 9, extent: 18, help: String(localized: "Clear Search")) {
                    list.query = ""
                }
            }
        }
    }

    private func chip(_ kind: CredentialListFilter) -> some View {
        let name = String(localized: kind.title)
        return Toggle(isOn: Binding(get: { list.filter == kind }, set: { _ in list.filter = kind })) {
            Text(verbatim: list.counts?[kind].map { "\(name) \($0.formatted())" } ?? name)
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
