// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

/// Collects what `get_navigation_entries` reports.
final class NavigationEntryReader {
    private(set) var total: Int?
    private(set) var first: String?
    private(set) var current = -1

    func record(url: String, isCurrent: Bool, index: Int, total: Int) {
        self.total = total
        if index == 0 {
            first = url
        }
        if isCurrent {
            current = index
        }
    }
}
