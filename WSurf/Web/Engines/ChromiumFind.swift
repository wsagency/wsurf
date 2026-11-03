// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The result of Chromium's native find (`cef_find_handler_t`), kept apart from CEF so its bookkeeping can be driven by tests.
/// CEF numbers each new search, and reports a count and the active match as it goes, last with a final update. A search that
/// another replaced may still report; its numbers are older than the new search's and are ignored.
@MainActor
final class ChromiumFind {
    struct Result: Equatable {
        var total = 0
        /// The 1-based position of the highlighted match; 0 when there is none.
        var active = 0
    }

    /// The text being searched; empty when no search is running.
    private(set) var query = ""
    private(set) var latest = Result()
    private var newest = -1
    private var floor = 0
    private var waiters: [@MainActor (Result) -> Void] = []

    /// Notes a search for `text`. True when it continues the running one (CEF's `findNext`), false when it starts a new search.
    func begin(_ text: String) -> Bool {
        guard text == query else {
            query = text
            latest = Result()
            floor = newest + 1
            return false
        }
        return true
    }

    /// Calls `waiter` with the next final result, once.
    func wait(_ waiter: @escaping @MainActor (Result) -> Void) {
        waiters.append(waiter)
    }

    /// The search is over (`stop_finding`): the next one starts afresh and nobody waits on this one.
    func end() {
        query = ""
        latest = Result()
        waiters = []
    }

    func receive(identifier: Int, count: Int, active: Int, isFinal: Bool) {
        guard identifier >= floor else { return }
        newest = max(newest, identifier)
        // A find-next update may leave the count out (-1): the count is the one already known.
        if count >= 0 {
            latest.total = count
        }
        latest.active = latest.total > 0 ? max(active, 0) : 0
        guard isFinal else { return }
        let ready = waiters
        waiters = []
        for waiter in ready {
            waiter(latest)
        }
    }
}
