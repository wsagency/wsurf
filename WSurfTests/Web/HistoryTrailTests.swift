// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// What a tab writes to History as it moves: one visit per page, trails of visits inside one site, and nothing at all
/// in a private window. Every model here saves to a database of the test's own.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct HistoryTrailTests {
    private func makeModel() -> BrowserModel {
        BrowserModel(database: .temporary())
    }

    /// A finished load, as the engines report it: the address and title are in, then the navigation ends.
    private func visit(_ tab: BrowserTab, _ url: String, _ transition: HistoryStore.Transition = .link) {
        tab.noteTransition(transition)
        tab.noteNavigationStarted()
        tab.urlString = url
        tab.pageTitle = url
        tab.onNavigationFinished?(false)
    }

    // MARK: - Clear History

    /// A tab remembers its last visit by id. After Clear History the next link names a visit that no longer exists, and
    /// the foreign key on `fromVisit` used to reject the whole insert.
    @Test func aLinkInAnOpenTabIsRecordedAfterHistoryIsCleared() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://example.com/a", .typed)
        visit(tab, "https://example.com/b")
        model.history.clear()
        #expect(model.history.visits.isEmpty)

        visit(tab, "https://example.com/c")

        #expect(model.history.visits.map(\.url) == ["https://example.com/c"])
    }

    @Test func aLinkInAnOpenTabIsRecordedAfterAPartOfHistoryIsCleared() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://example.com/a", .typed)
        visit(tab, "https://example.com/b")
        model.history.removeEntries(since: .distantPast)

        visit(tab, "https://example.com/c")

        #expect(model.history.visits.map(\.url) == ["https://example.com/c"])
    }
}
