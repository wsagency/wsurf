// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Observation
import SwiftUI

// MARK: - State

/// Where the merge sheet starts.
enum CredentialMergeRoute: Hashable {
    /// Every suggestion the vault has.
    case suggestions
    /// These credentials, for the user to review before merging.
    case review([UUID])
}

/// The merge suggestions of the vault on screen, and the merge sheet that is open. It holds ids, the reasons and the summaries a
/// row shows: no password, note, code seed or key. A lock, another vault or a changed vault computes it again.
@MainActor
@Observable
final class CredentialMergeState {
    /// The sheet that is open, if any.
    var route: CredentialMergeRoute?
    private(set) var index: CredentialMergeIndex?
    /// The suggestion the sheet shows selected, and the one at the top of its list, by identity. When the list is computed again
    /// without one (it was merged, or marked Not the Same), it moves to the next one that is still there (`kept`), so the sheet stays
    /// where it was.
    var focus: Set<UUID>?
    var scrollAnchor: Set<UUID>?
    /// The sheet lists the dismissed groups instead of the suggestions.
    private(set) var showsDismissed = false
    /// The credentials by id, for the suggestion list.
    private(set) var summaries: [UUID: CredentialSummary] = [:]
    /// The first suggestion that names each credential, by its position in `index`.
    @ObservationIgnored private var suggestionOf: [UUID: Int] = [:]
    @ObservationIgnored private var key: Key?

    /// What the suggestions were last computed from.
    struct Key: Equatable {
        let vault: UUID?
        let epoch: UInt64?
        let revision: UInt64

        init(_ model: CredentialSettingsModel) {
            vault = model.selectedVaultID
            epoch = model.authorizationEpoch
            revision = model.revision
        }
    }

    var suggestionCount: Int {
        index?.suggestions.count ?? 0
    }

    var identicalCount: Int {
        index?.identical.count ?? 0
    }

    var dismissedCount: Int {
        index?.dismissed.count ?? 0
    }

    /// What the sheet lists, by identity: the suggestions, or the dismissed groups.
    var shown: [Set<UUID>] {
        showsDismissed ? (index?.dismissed ?? []).map(\.members) : index?.suggestions.map(\.id) ?? []
    }

    func showDismissed(_ dismissed: Bool) {
        guard dismissed != showsDismissed else { return }
        showsDismissed = dismissed
        focus = nil
        scrollAnchor = nil
    }

    /// Computes the suggestions for the model's vault as it is now, off the main actor. Nothing is kept from another vault or unlock,
    /// so a stale answer is never shown.
    func refresh(_ model: CredentialSettingsModel) async {
        let next = Key(model)
        guard next != key else { return }
        guard next.epoch != nil, model.isLoaded else {
            clear()
            return
        }
        let all = model.summaries
        let found = try? await model.mergeSuggestions()
        guard !Task.isCancelled, next == Key(model) else { return }
        show(found, summaries: all)
        key = next
    }

    /// Shows `found` and keeps the selection and the top of the list where they were, by identity.
    func show(_ found: CredentialMergeIndex?, summaries all: [CredentialSummary]) {
        let before = shown
        index = found
        let now = shown
        focus = Self.kept(focus, from: before, in: now)
        scrollAnchor = Self.kept(scrollAnchor, from: before, in: now)
        summaries = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        suggestionOf = [:]
        for (position, suggestion) in (found?.suggestions ?? []).enumerated() {
            for id in suggestion.ids where suggestionOf[id] == nil {
                suggestionOf[id] = position
            }
        }
    }

    /// `id` if `now` still lists it; else the first after it in `before` that `now` lists, else the last before it, else the one now at
    /// its place. Never by index alone: the suggestions around it keep their identity when one is merged.
    static func kept(_ id: Set<UUID>?, from before: [Set<UUID>], in now: [Set<UUID>]) -> Set<UUID>? {
        guard let id, !now.contains(id) else { return id }
        let present = Set(now)
        guard let at = before.firstIndex(of: id) else { return now.first }
        return before[(at + 1)...].first(where: present.contains) ?? before[..<at].last(where: present.contains)
            ?? (now.isEmpty ? nil : now[min(at, now.count - 1)])
    }

    /// Forgets everything, for a lock or another vault.
    func clear() {
        route = nil
        index = nil
        focus = nil
        scrollAnchor = nil
        showsDismissed = false
        summaries = [:]
        suggestionOf = [:]
        key = nil
    }

    /// The credentials "Review Merge…" opens for `group`: the first suggestion that names two or more of its credentials.
    func review(in group: SiteGroup) -> [UUID]? {
        guard let suggestions = index?.suggestions else { return nil }
        var named = Set<Int>()
        for id in group.ids {
            if let position = suggestionOf[id], !named.insert(position).inserted {
                return suggestions[position].ids
            }
        }
        return nil
    }
}

extension [UUID] {
    /// A group's members in any order: what names a suggestion or a dismissed group in the sheet.
    var members: Set<UUID> {
        Set(self)
    }
}

extension CredentialMergeSuggestion {
    /// Why the vault suggests it, in a short line: "Same website and username", "Copy (1) of “ada@example.test”". `summaries` give the
    /// usernames the list shows; a concealed one is not named.
    func reasonText(_ summaries: [UUID: CredentialSummary]) -> LocalizedStringResource {
        switch reason {
        case .sameLogin:
            return isIdentical ? "Same website, username and password" : "Same website and username"
        case .numberedCopies:
            let usernames = ids.compactMap { summaries[$0]?.username }
            guard usernames.count == ids.count, let first = usernames.first else { return "Numbered copies of one username" }
            let base = CredentialMergeSuggestions.baseUsername(first)
            let copies = usernames.filter { $0 != base }.map { $0.dropFirst(base.count).trimmingCharacters(in: .whitespaces) }
            let numbers = ListFormatter.localizedString(byJoining: copies)
            switch (copies.count == 1, isIdentical) {
            case (true, false):
                return "Copy \(numbers) of “\(base)”"
            case (true, true):
                return "Copy \(numbers) of “\(base)”, same password"
            case (false, false):
                return "Copies \(numbers) of “\(base)”"
            case (false, true):
                return "Copies \(numbers) of “\(base)”, same password"
            }
        case .splitParts:
            return "Password, passkey or code for the same website, saved separately"
        }
    }
}

// MARK: - Groups

/// The credentials under a heading per site. Lazy, like the flat list: only the rows on screen are built, so a vault of thousands
/// stays light. `row` draws one credential, so the page keeps its own row.
struct CredentialSiteGroupsList<Row: View>: View {
    let groups: [SiteGroup]
    /// The rows `groups` names, by id.
    let rows: [UUID: CredentialSummary]
    let merge: CredentialMergeState
    let row: (CredentialSummary) -> Row

    var body: some View {
        ForEach(groups) { group in
            header(group)
            ForEach(group.ids, id: \.self) { id in
                if let summary = rows[id] {
                    row(summary)
                }
            }
        }
    }

    private func header(_ group: SiteGroup) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title(of: group))
                .font(Theme.Font.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let ids = merge.review(in: group) {
                Button("Review Merge…") { merge.route = .review(ids) }
                    .controlSize(.small)
                    .accessibilityLabel("Review merge of \(group.site ?? String(localized: "credentials without a website"))")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func title(of group: SiteGroup) -> String {
        if let site = group.site {
            return "\(site) · \(group.ids.count.formatted())"
        }
        return String(localized: "No website · \(group.ids.count.formatted())")
    }
}

// MARK: - Suggestions

/// Every merge the vault suggests, to review one at a time. "Merge All Identical" merges the groups whose logins are byte-equal and
/// whose websites are the same, which loses nothing and adds no website on another site. "Not the Same" hides a suggestion for good;
/// the Dismissed list shows those and takes one back with "Suggest Again". After a merge or a dismissal the sheet stays where it was,
/// with the next suggestion selected (`CredentialMergeState.kept`).
struct CredentialSuggestionsSheet: View {
    let model: CredentialSettingsModel
    let merge: CredentialMergeState
    let review: ([UUID]) -> Void
    let close: () -> Void
    @State private var message: String?
    @State private var isWorking = false
    @State private var confirming = false
    /// The last Not the Same or Suggest Again of this sheet can be taken back here; the page's notice is behind the sheet.
    @State private var offersUndo = false

    /// A list computed for another revision than the vault's (a merge just landed and the new one is on its way) is not acted on.
    private var isCurrent: Bool {
        merge.index?.revision == model.revision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggested Merges").font(.headline)
            Text("These credentials look like one. Nothing is merged until you review it and confirm.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if merge.dismissedCount > 0 || merge.showsDismissed {
                Picker("Suggestions", selection: Binding(get: { merge.showsDismissed }, set: { merge.showDismissed($0) })) {
                    Text("Suggested (\(merge.suggestionCount.formatted()))").tag(false)
                    Text("Dismissed (\(merge.dismissedCount.formatted()))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !merge.shown.isEmpty {
                ScrollView {
                    // Lazy: a vault of thousands can have hundreds of suggestions.
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if merge.showsDismissed {
                            ForEach(merge.index?.dismissed ?? [], id: \.members) { ids in
                                row(ids, reason: "Marked as not the same") { dismissedActions(ids) }
                            }
                        } else {
                            ForEach(merge.index?.suggestions ?? []) { suggestion in
                                row(suggestion.ids, reason: suggestion.reasonText(merge.summaries)) { suggestionActions(suggestion) }
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition(id: Binding(get: { merge.scrollAnchor }, set: { merge.scrollAnchor = $0 }), anchor: .top)
                .frame(height: 360)
            } else {
                (merge.showsDismissed ? Text("No dismissed suggestions") : Text("No suggested merges"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }
            if let message {
                HStack(spacing: 8) {
                    Text(verbatim: message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if offersUndo, model.canUndo {
                        Button("Undo") { undo() }.controlSize(.small)
                    }
                }
            }
            HStack {
                if merge.identicalCount > 0, !merge.showsDismissed {
                    Button("Merge All Identical (\(merge.identicalCount.formatted()))") { confirming = true }
                        .disabled(isWorking || model.isBusy || !isCurrent)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .confirmationDialog("Merge All Identical?", isPresented: $confirming) {
            Button("Merge \(merge.identicalCount.formatted()) Groups") { mergeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each group has the same login on the same sites. The extra copies move to Trash with their history. No website on another site is added.")
        }
    }

    /// One group: its titles, why, and its buttons. A click selects it; the selected one is the one the sheet comes back to.
    private func row<Actions: View>(_ ids: [UUID], reason: LocalizedStringResource, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: names(of: ids)).font(Theme.Font.row).fixedSize(horizontal: false, vertical: true)
                Text(reason)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions()
                .controlSize(.small)
                .disabled(isWorking || model.isBusy || !isCurrent)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(merge.focus == ids.members ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { merge.focus = ids.members }
    }

    private func suggestionActions(_ suggestion: CredentialMergeSuggestion) -> some View {
        HStack(spacing: 6) {
            Button("Not the Same") { apart(suggestion.ids, again: false) }
                .help("Don’t suggest merging these credentials again")
            Button("Review Merge…") {
                merge.focus = suggestion.id
                review(suggestion.ids)
            }
        }
    }

    private func dismissedActions(_ ids: [UUID]) -> some View {
        Button("Suggest Again") { apart(ids, again: true) }
    }

    /// The first few titles; the rest are counted.
    private func names(of ids: [UUID]) -> String {
        let titles = ids.prefix(3).map { merge.summaries[$0]?.title ?? String(localized: "Credential") }
        let more = ids.count - titles.count
        let list = ListFormatter.localizedString(byJoining: titles)
        return more > 0 ? list + " " + String(localized: "+\(more) more") : list
    }

    /// Not the Same, or Suggest Again for a dismissed group. The group is selected first, so the list comes back to the one after it.
    private func apart(_ ids: [UUID], again: Bool) {
        merge.focus = ids.members
        isWorking = true
        Task {
            do {
                if again {
                    try await model.suggestAgain(ids)
                    message = String(localized: "These can be suggested for merging again.")
                } else {
                    try await model.markNotTheSame(ids)
                    message = String(localized: "These won’t be suggested for merging again.")
                }
                offersUndo = true
            } catch {
                message = CredentialSettingsModel.mergeMessage(for: error)
                offersUndo = false
            }
            isWorking = false
        }
    }

    private func undo() {
        offersUndo = false
        message = nil
        Task { await model.undo() }
    }

    private func mergeAll() {
        guard let revision = merge.index?.revision else { return }
        isWorking = true
        Task {
            do {
                let result = try await model.mergeAllIdentical(revision: revision)
                message = summary(of: result)
            } catch {
                message = CredentialSettingsModel.mergeMessage(for: error)
            }
            offersUndo = false
            isWorking = false
        }
    }

    private func summary(of result: CredentialMergeAllResult) -> String {
        guard result.merged > 0 else {
            return String(localized: "Nothing was merged.")
        }
        let done = String(localized: "Merged \(result.merged.formatted()) groups. \(result.absorbed.formatted()) credentials moved to Trash.")
        guard result.skipped > 0 else { return done }
        return done + " " + String(localized: "\(result.skipped.formatted()) groups were left as they were because merging them would pass a limit.")
    }
}

// MARK: - Flow

/// The one sheet of the merge flow: the suggestions and the merge itself. It moves between them itself, so the page presents a single
/// sheet however the user got here. Which credentials to merge is chosen in the list (Select, or the selection's Merge…).
struct CredentialMergeFlow: View {
    let model: CredentialSettingsModel
    let merge: CredentialMergeState
    let route: CredentialMergeRoute
    let close: () -> Void
    @State private var step: CredentialMergeRoute?

    var body: some View {
        switch step ?? route {
        case .suggestions:
            CredentialSuggestionsSheet(model: model, merge: merge, review: { step = .review($0) }, close: close)
        case let .review(ids):
            CredentialMergeSheet(model: model, ids: ids) { _ in
                // From the suggestions, a written or a cancelled merge returns to them, where it was, with the next one selected; from
                // the list, the flow ends.
                if route == .suggestions {
                    step = .suggestions
                } else {
                    close()
                }
            }
        }
    }
}
