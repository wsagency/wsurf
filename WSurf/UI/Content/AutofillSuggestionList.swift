// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

enum AutofillSuggestionLayout {
    static let footerHeight: CGFloat = 34
    static let searchRowHeight: CGFloat = 34
    static let rowHeight: CGFloat = 46
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 5
    static let chromeHeight = footerHeight + 1
    static let minimumHeight = chromeHeight + rowHeight + listPadding * 2

    /// The panel's height for `count` rows. It never changes while the list is filtered.
    static func height(for count: Int, searchable: Bool = false) -> CGFloat {
        let rows = CGFloat(max(1, min(count, AutofillSuggestionSearch.threshold)))
        let search = searchable ? searchRowHeight + 1 : 0
        return chromeHeight + search + listPadding * 2 + rows * rowHeight + (rows - 1) * rowSpacing
    }
}

@Observable
final class AutofillSuggestionSelection {
    var state = AutofillSuggestionSearch.State(rowCount: 0)
}

struct AutofillSuggestionList: View {
    let kind: AutofillSaveKind
    let origin: String
    let suggestions: [AutofillSuggestion]
    /// Whether the list has a search row (see `AutofillSuggestionSearch.Index`).
    let searchable: Bool
    let selection: AutofillSuggestionSelection
    let choose: (UUID) -> Void
    let beginSearch: () -> Void
    let manage: () -> Void

    private var symbol: String {
        switch kind {
        case .password:
            "key"
        case .card:
            "creditcard"
        case .contact:
            "person.crop.rectangle"
        }
    }

    var body: some View {
        let state = selection.state
        VStack(alignment: .leading, spacing: 0) {
            if searchable {
                AutofillSuggestionSearchRow(
                    query: state.query, isSearching: state.isSearching, count: suggestions.count, begin: beginSearch
                )
                Divider()
            }
            if state.matches.isEmpty {
                Text("No matches")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: AutofillSuggestionLayout.rowSpacing) {
                            ForEach(state.matches, id: \.self) { position in
                                AutofillSuggestionRow(
                                    suggestion: suggestions[position], symbol: symbol,
                                    selected: state.keyboard == position,
                                    choose: { choose(suggestions[position].id) }
                                )
                            }
                        }
                        .padding(AutofillSuggestionLayout.listPadding)
                    }
                    .onChange(of: state.keyboard) { _, position in
                        if let position {
                            proxy.scrollTo(position)
                        }
                    }
                }
            }
            Divider()
            Button("Autofill Settings…", action: manage)
                .buttonStyle(.plain).focusable(false).font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: AutofillSuggestionLayout.footerHeight)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Autofill suggestions for \(origin)")
        .onChange(of: state.matches.count) { _, count in
            if state.isSearching {
                AccessibilityNotification.Announcement(AutofillSuggestionSearch.announcement(matching: count)).post()
            }
        }
    }
}

/// The top row of a long list. Before the first click it is a button that starts a search; once searching it shows the query and a
/// caret. The page's field keeps the keyboard focus the whole time: what is typed is read by WSurf and never sent to the page.
private struct AutofillSuggestionSearchRow: View {
    let query: String
    let isSearching: Bool
    let count: Int
    let begin: () -> Void

    var body: some View {
        if isSearching {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isSearchField)
                .accessibilityLabel("Search credentials")
                .accessibilityValue(query)
        } else {
            Button(action: begin) { row }
                .buttonStyle(.plain).focusable(false)
                .accessibilityLabel("Search credentials")
                .accessibilityHint("Select, then type to filter the list. What you type is not sent to the page.")
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            if isSearching {
                if !query.isEmpty {
                    Text(verbatim: query).font(.system(size: 13)).lineLimit(1).truncationMode(.head)
                }
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 15).accessibilityHidden(true)
                if query.isEmpty {
                    Text("Search \(count) credentials").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Search \(count) credentials").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AutofillSuggestionLayout.searchRowHeight)
        .contentShape(.rect)
    }
}

private struct AutofillSuggestionRow: View {
    let suggestion: AutofillSuggestion
    let symbol: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: suggestion.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !suggestion.detail.isEmpty {
                        Text(verbatim: suggestion.detail).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: AutofillSuggestionLayout.rowHeight)
            .contentShape(.rect)
            .background(selected || hovered ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovered = $0 }
    }
}
