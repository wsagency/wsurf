// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Observation
import SwiftUI

// MARK: - State

/// Where the merge sheet starts.
enum CredentialMergeRoute: Hashable {
    /// Every suggestion the vault has.
    case suggestions
    /// These credentials, for the user to review before merging.
    case review([UUID])
    /// Choose the credential to merge this one with.
    case pick(UUID)
}

/// The merge suggestions of the vault on screen, and the merge sheet that is open. It holds ids, the reasons and the summaries a
/// row shows: no password, note, code seed or key. A lock, another vault or a changed vault computes it again.
@MainActor
@Observable
final class CredentialMergeState {
    /// The sheet that is open, if any.
    var route: CredentialMergeRoute?
    private(set) var index: CredentialMergeIndex?
    /// The credentials by id, for the suggestion list and the picker.
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
        index = found
        summaries = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        suggestionOf = [:]
        for (position, suggestion) in (found?.suggestions ?? []).enumerated() {
            for id in suggestion.ids where suggestionOf[id] == nil {
                suggestionOf[id] = position
            }
        }
        key = next
    }

    /// Forgets everything, for a lock or another vault.
    func clear() {
        route = nil
        index = nil
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

extension CredentialMergeReason {
    var text: LocalizedStringResource {
        switch self {
        case .sameLogin:
            "Same site and username"
        case .splitParts:
            "Password, passkey or code saved separately"
        case .relatedSite:
            "Same username on a related site"
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
/// whose websites are on the same sites, which loses nothing and adds no website on another site.
struct CredentialSuggestionsSheet: View {
    let model: CredentialSettingsModel
    let merge: CredentialMergeState
    let review: ([UUID]) -> Void
    let close: () -> Void
    @State private var message: String?
    @State private var isWorking = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggested Merges").font(.headline)
            Text("These credentials look like one. Nothing is merged until you review it and confirm.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let index = merge.index, !index.suggestions.isEmpty {
                ScrollView {
                    // Lazy: a vault of thousands can have hundreds of suggestions.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(index.suggestions) { suggestion in
                            row(suggestion)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 360)
            } else {
                Text("No suggested merges").foregroundStyle(.secondary).padding(.vertical, 24).frame(maxWidth: .infinity)
            }
            if let message {
                Text(verbatim: message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if merge.identicalCount > 0 {
                    Button("Merge All Identical (\(merge.identicalCount.formatted()))") { confirming = true }
                        .disabled(isWorking || model.isBusy)
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

    private func row(_ suggestion: CredentialMergeSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: names(of: suggestion)).font(Theme.Font.row).fixedSize(horizontal: false, vertical: true)
                Group {
                    if suggestion.isIdentical {
                        Text("Same site, username and password")
                    } else {
                        Text(suggestion.reason.text)
                    }
                }
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Review Merge…") { review(suggestion.ids) }
                .controlSize(.small)
                .disabled(isWorking)
        }
    }

    /// The first few titles; the rest are counted.
    private func names(of suggestion: CredentialMergeSuggestion) -> String {
        let titles = suggestion.ids.prefix(3).map { merge.summaries[$0]?.title ?? String(localized: "Credential") }
        let more = suggestion.ids.count - titles.count
        let list = ListFormatter.localizedString(byJoining: titles)
        return more > 0 ? list + " " + String(localized: "+\(more) more") : list
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

/// The one sheet of the merge flow: the suggestions, the choice of a credential to merge with, and the merge itself. It moves between
/// them itself, so the page presents a single sheet however the user got here.
struct CredentialMergeFlow: View {
    let model: CredentialSettingsModel
    let merge: CredentialMergeState
    /// The credentials that match a search, for "Merge With…".
    let matches: (String) -> [CredentialSummary]
    let route: CredentialMergeRoute
    let close: () -> Void
    @State private var step: CredentialMergeRoute?

    var body: some View {
        switch step ?? route {
        case .suggestions:
            CredentialSuggestionsSheet(model: model, merge: merge, review: { step = .review($0) }, close: close)
        case let .pick(id):
            if let source = merge.summaries[id] ?? model.summaries.first(where: { $0.id == id }) {
                CredentialMergePicker(source: source, matches: matches, choose: { step = .review([id, $0.id]) }, cancel: close)
            }
        case let .review(ids):
            CredentialMergeSheet(model: model, ids: ids) { merged in
                // A written merge ends the flow; a cancelled one returns to the suggestions it came from.
                if merged || route != .suggestions {
                    close()
                } else {
                    step = .suggestions
                }
            }
        }
    }
}
