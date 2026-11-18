// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

/// Collects what `get_navigation_entries` reports: each entry's address, title and whether a POST made it.
final class NavigationEntryReader {
    nonisolated struct Entry: Equatable, Sendable {
        var url: String
        var title: String
        var hasPostData: Bool
    }

    private(set) var total: Int?
    private(set) var current = -1
    private var visited: [Int: Entry] = [:]

    var first: String? {
        visited[0]?.url
    }

    /// Every entry in order; nil unless each one was reported.
    var entries: [Entry]? {
        guard let total else { return nil }
        let list = (0..<total).compactMap { visited[$0] }
        return list.count == total ? list : nil
    }

    func record(_ entry: Entry, isCurrent: Bool, index: Int, total: Int) {
        self.total = total
        visited[index] = entry
        if isCurrent {
            current = index
        }
    }
}
