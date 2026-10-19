// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Quick search over the rows of one fill dropdown. It runs in WSurf, over the rows that were already read for this origin: the
/// page never sees the query or the other rows, and nothing here reads a vault or touches the page. The dropdown's key monitor
/// turns each key into a `KeyInput`; `reduce` says what happens to it. Bounded: the rows are indexed once when the dropdown
/// opens, a keystroke is one pass over those keys, and the query is capped.
nonisolated enum AutofillSuggestionSearch {
    /// Search exists only above this many rows. A shorter list is always fully visible.
    static let threshold = 5
    /// Further characters are consumed and ignored, so the query and the work per keystroke stay bounded.
    static let queryLimit = 100

    /// The folding that makes a match ignore case and accents. Locale-independent on purpose.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// What a screen reader hears when the number of matching rows changes. It carries the count only, never the query.
    static func announcement(matching count: Int) -> String {
        guard count > 0 else { return String(localized: "No matches") }
        return String(AttributedString(localized: "^[\(count) matching credential](inflect: true)").characters)
    }

    /// The folded text of every row, built once per dropdown. Positions are indexes into the dropdown's row list.
    struct Index: Sendable {
        let ids: [UUID]
        /// Whether this dropdown has a search row: only a password list, and only above `threshold` rows.
        let isSearchable: Bool
        private let keys: [String]

        init(_ rows: [AutofillSuggestion], searchable: Bool) {
            ids = rows.map(\.id)
            isSearchable = searchable && rows.count > AutofillSuggestionSearch.threshold
            keys = isSearchable ? rows.map { AutofillSuggestionSearch.fold($0.title + "\n" + $0.detail) } : []
        }

        /// The positions of the rows whose title and detail contain every word of `query`, in list order. A blank query matches all.
        func matches(_ query: String) -> [Int] {
            let words = AutofillSuggestionSearch.fold(query).split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return Array(ids.indices) }
            return keys.indices.filter { position in words.allSatisfy { keys[position].contains($0) } }
        }
    }

    /// What the dropdown shows and where the keyboard is. The view reads it; only `reduce` and the click on the search row change it.
    struct State: Equatable {
        fileprivate(set) var query = ""
        fileprivate(set) var isSearching = false
        /// The row the arrow keys reached. Always one of `matches`.
        fileprivate(set) var keyboard: Int?
        /// The positions of the rows to draw, in list order.
        fileprivate(set) var matches: [Int]

        init(rowCount: Int) {
            matches = Array(0..<rowCount)
        }

        /// The click on the search row: from now on typed characters are the query. A typed password never gets here by itself.
        mutating func beginSearching() {
            isSearching = true
        }

        fileprivate mutating func setQuery(_ query: String, in index: Index) {
            self.query = query
            matches = index.matches(query)
            keyboard = query.isEmpty ? nil : matches.first
        }
    }

    enum KeyInput: Equatable {
        /// One printable character.
        case character(String)
        case backspace, escape, up, down, enter
        /// Any other key.
        case other
    }

    enum Effect: Equatable {
        /// The key was ours: it does not reach the page.
        case consume
        /// The key is not ours and the dropdown stays: the page gets it.
        case pass
        case dismissAndPass
        case dismiss
        case choose(UUID)
    }

    /// The outcome of one key. Without a search row (five rows or fewer, or a card or contact list) this is exactly the arrows,
    /// Return and Escape of any dropdown, and every other key closes it and reaches the page.
    ///
    /// Typing starts a search by itself only when `typeToSearch` holds (the focused field is a username field). In any other field
    /// a search starts with the click on the search row, so characters typed for a password are never taken as a query. While
    /// searching, characters and Backspace edit the query and never reach the page; Escape clears the query, then closes; the
    /// arrows and Return use only the rows that match.
    static func reduce(_ state: State, _ key: KeyInput, index: Index, typeToSearch: Bool) -> (State, Effect) {
        var state = state
        switch key {
        case .up, .down:
            guard !state.matches.isEmpty else { return (state, state.isSearching ? .consume : .pass) }
            let count = state.matches.count
            let current = state.keyboard.flatMap { state.matches.firstIndex(of: $0) }
            let next = current.map { ($0 + (key == .down ? 1 : -1) + count) % count } ?? (key == .down ? 0 : count - 1)
            state.keyboard = state.matches[next]
            return (state, .consume)
        case .enter:
            if let position = state.keyboard {
                return (state, .choose(index.ids[position]))
            }
            // A query that matches nothing is not a request to submit the page's form.
            return (state, state.query.isEmpty ? .dismissAndPass : .consume)
        case .escape:
            guard state.isSearching, !state.query.isEmpty else { return (state, .dismiss) }
            state.setQuery("", in: index)
            return (state, .consume)
        case .backspace:
            guard state.isSearching, !state.query.isEmpty else { return (state, .dismissAndPass) }
            state.setQuery(String(state.query.dropLast()), in: index)
            return (state, .consume)
        case .character(let text):
            guard index.isSearchable, state.isSearching || typeToSearch else { return (state, .dismissAndPass) }
            state.isSearching = true
            if state.query.count < queryLimit {
                state.setQuery(state.query + text, in: index)
            }
            return (state, .consume)
        case .other:
            return (state, .dismissAndPass)
        }
    }
}
