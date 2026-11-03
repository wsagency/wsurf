// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import Testing
import WebKit

@testable import WSurf

/// What a tab writes to History as it moves: one visit per page, trails of visits inside one site, and nothing at all
/// in a private window. Every model here saves to a database of the test's own. The cases that load a page run on both
/// engines; the others drive the tab's events directly.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct HistoryTrailTests {
    private func makeModel(database: AppDatabase = .temporary()) -> BrowserModel {
        BrowserModel(database: database)
    }

    private func makePermissions() -> SitePermissions {
        SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("HistoryTrailPermissions-\(UUID().uuidString).json")
        )
    }

    /// A model in private browsing, as `PrivateBrowsingTests` makes one: the profile is private, and so is its database.
    private func makePrivateModel(database: AppDatabase = .temporary()) -> BrowserModel {
        let permissions = makePermissions()
        let model = BrowserModel(database: database, sitePermissions: permissions)
        model.adopt(database: database, sitePermissions: permissions, privately: true)
        return model
    }

    /// A finished load, as the engines report it: the navigation starts, the address and title are in, then it ends.
    private func visit(
        _ tab: BrowserTab,
        _ url: String,
        _ transition: HistoryStore.Transition = .link,
        title: String? = nil
    ) {
        tab.noteTransition(transition)
        tab.noteNavigationStarted()
        tab.urlString = url
        tab.pageTitle = title ?? url
        tab.onNavigationFinished?(false)
    }

    private func urls(_ model: BrowserModel) -> [String] {
        model.history.visits.map(\.url)
    }

    private func trails(_ model: BrowserModel) -> [Int64?] {
        model.history.visits.map(\.trail)
    }

    /// Runs a script whose effect is a navigation. Chromium may answer for a document that is already gone.
    private func navigate(_ tab: BrowserTab, by script: String) async throws {
        do {
            _ = try await tab.page.evaluateJavaScript(script)
        } catch ChromiumError.staleFrame {
            // The navigation committed before Chromium checked the old document's answer.
        }
    }

    private func count(_ table: String, in database: AppDatabase, where condition: String = "1") throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(condition)") ?? -1
        }
    }

    // MARK: - Clear History

    /// A tab remembers its last visit by id. After Clear History the next link names a visit that no longer exists, and
    /// the foreign key on `fromVisit` used to reject the whole insert.
    @Test func aLinkInAnOpenTabIsRecordedAfterHistoryIsCleared() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://example.com/a", .typed)
        visit(tab, "https://example.com/b")
        let before = trails(model)
        model.history.clear()
        #expect(model.history.visits.isEmpty)

        visit(tab, "https://example.com/c")
        visit(tab, "https://example.com/d")

        #expect(urls(model) == ["https://example.com/d", "https://example.com/c"])
        let after = trails(model)
        #expect(after[0] == after[1], "the visits after the clear are one trail")
        #expect(after[0] == model.history.visits.last?.id, "which starts with the first of them")
        #expect(!before.contains { $0 == after[0] }, "and is not the trail that was cleared")
    }

    @Test func aLinkInAnOpenTabIsRecordedAfterAPartOfHistoryIsCleared() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://example.com/a", .typed)
        visit(tab, "https://example.com/b")
        model.history.removeEntries(since: .distantPast)

        visit(tab, "https://example.com/c")

        #expect(urls(model) == ["https://example.com/c"])
        #expect(model.history.visits.first?.trail == model.history.visits.first?.id)
    }

    /// Only the visits in the range go. The tab's trail goes on through the ones that stay.
    @Test func aRangeThatKeepsTheTabsLastVisitKeepsItsTrail() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://example.com/a", .typed)
        let cutoff = Date()
        model.history.removeEntries(since: cutoff)

        visit(tab, "https://example.com/b")

        #expect(Set(trails(model)).count == 1)
    }

    @Test func aTabRestoredAfterHistoryWasClearedIsRecordedOnANewTrail() throws {
        let database = AppDatabase.temporary()
        let model = BrowserModel(windowID: UUID(), database: database)
        visit(model.newTab(), "https://duckduckgo.com/?q=rover", .typed)
        model.saveBlocking()
        model.history.clear()

        let restored = BrowserModel(windowID: model.windowID, database: database)
        restored.restoreSession()
        let tab = try #require(restored.tabs.first)
        visit(tab, "https://duckduckgo.com/?q=rover&ia=images")

        #expect(urls(restored) == ["https://duckduckgo.com/?q=rover&ia=images"])
        #expect(restored.history.visits.first?.trail == restored.history.visits.first?.id)
    }

    // MARK: - Titles

    @Test func aTitleSetAfterLoadReachesHistory() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/browse/ENEY-6039", title: "Jira")

        tab.pageTitle = "[ENEY-6039] Tour cards stay on top - Jira"

        #expect(model.history.entries.first?.title == "[ENEY-6039] Tour cards stay on top - Jira")
    }

    @Test func aTitleAfterAnInPageMoveKeepsTheLoadedPageName() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/browse/ENEY-6039", title: "[ENEY-6039] Tour cards stay on top - Jira")

        tab.urlString = "https://jira.example/jira/your-work"
        tab.pageTitle = "Your work - Jira"

        #expect(model.history.entries.map(\.title) == ["[ENEY-6039] Tour cards stay on top - Jira"])
    }

    /// The name a person gives a tab belongs to the tab. History records what the page calls itself.
    @Test func aCustomTabNameNeverReachesHistory() {
        let model = makeModel()
        let tab = model.newTab()
        tab.customTitle = "My own name"
        visit(tab, "https://docs.example/spec", .typed, title: "Spec - Docs")
        #expect(tab.title == "My own name")
        #expect(model.history.entries.first?.title == "Spec - Docs")

        tab.pageTitle = "Spec v2 - Docs"
        #expect(model.history.entries.first?.title == "Spec v2 - Docs", "a late title names the page, not the tab")

        tab.urlString = "https://docs.example/spec/changes"
        tab.pageTitle = "Changes - Docs"
        tab.onInPageMove?()
        #expect(model.history.visits.first?.url == "https://docs.example/spec/changes")
        #expect(model.history.visits.first?.title == "Changes - Docs")
        #expect(!model.history.entries.contains { $0.title == "My own name" })
    }

    // MARK: - Trails

    @Test func aTrailStaysInsideOneSite() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/board", .typed)
        visit(tab, "https://jira.example/browse/1")
        visit(tab, "https://jira.example/browse/1", .reload)
        visit(tab, "https://docs.example/spec")
        visit(tab, "https://jira.example/browse/1", .backForward)

        let found = trails(model)
        #expect(found.count == 5)
        #expect(Set(found[2...]).count == 1)
        #expect(found[1] != found[2], "a link to another site starts a trail")
        #expect(found[0] != found[1] && found[0] != found[2], "going back to a site starts a trail")
    }

    @Test func aNewTabStartsANewTrail() {
        let model = makeModel()
        let first = model.newTab()
        visit(first, "https://jira.example/board", .typed)
        let second = model.newTab()
        visit(second, "https://jira.example/board", .typed)
        visit(first, "https://jira.example/browse/1")

        let found = trails(model)
        #expect(found[0] == found[2])
        #expect(found[1] != found[0])
    }

    /// A tab a page opened comes from that page's visit, but a trail is one tab's journey.
    @Test func aTabAPageOpenedTakesItsVisitAsReferrerButStartsItsOwnTrail() throws {
        let model = makeModel()
        let opener = model.newTab()
        visit(opener, "https://jira.example/board", .typed)
        opener.onOpenInNewTab?(URL(string: "https://jira.example/browse/1")!, false)
        let opened = try #require(model.tabs.first { $0.id != opener.id })

        visit(opened, "https://jira.example/browse/1")

        let newest = try #require(model.history.visits.first)
        #expect(newest.trail == newest.id)
        #expect(newest.trail != model.history.visits.last?.trail)
        #expect(model.history.referrerChain(to: newest.id).map(\.url)
            == ["https://jira.example/board", "https://jira.example/browse/1"])
    }

    @Test func typingAnotherSiteStartsANewTrail() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/board", .typed)
        visit(tab, "https://www.jira.example/browse/1", .typed)
        visit(tab, "https://twitch.example/", .typed)

        let found = trails(model)
        #expect(found[1] == found[2], "the same site typed again keeps the trail")
        #expect(found[0] != found[1])
    }

    @Test func aRestoredTabContinuesItsTrail() throws {
        let database = AppDatabase.temporary()
        let model = BrowserModel(windowID: UUID(), database: database)
        visit(model.newTab(), "https://duckduckgo.com/?q=rover", .typed)
        model.saveBlocking()

        let restored = BrowserModel(windowID: model.windowID, database: database)
        restored.restoreSession()
        let tab = try #require(restored.tabs.first)
        visit(tab, "https://duckduckgo.com/?q=rover&ia=images")

        #expect(urls(restored) == ["https://duckduckgo.com/?q=rover&ia=images", "https://duckduckgo.com/?q=rover"])
        #expect(Set(trails(restored)).count == 1)
    }

    @Test func aTabMovedToAnotherWindowKeepsItsTrail() throws {
        let context = BrowserProfileContext.shared(for: .original())
        let database = AppDatabase.temporary()
        let history = HistoryStore(database: database)
        let source = BrowserModel(context: context, windowID: UUID(), database: database, history: history)
        let destination = BrowserModel(context: context, windowID: UUID(), database: database, history: history)
        defer { source.closeAllTabs(saving: false); destination.closeAllTabs(saving: false) }
        let tab = source.newTab()
        visit(tab, "https://jira.example/board", .typed)
        visit(tab, "https://jira.example/browse/1")
        try #require(destination.adoptTab(tab, from: source))

        visit(tab, "https://jira.example/browse/2")

        #expect(history.visits.count == 3)
        #expect(Set(history.visits.map(\.trail)).count == 1)
    }

    // MARK: - Moves a page makes itself

    @Test func anInPageMoveWithTheSameTitleAddsNoRow() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://duckduckgo.com/?q=martian", .typed, title: "martian at DuckDuckGo")

        tab.urlString = "https://duckduckgo.com/?q=martian&ia=images"
        tab.onInPageMove?()
        tab.urlString = "https://duckduckgo.com/?q=martian&ia=web"
        tab.onInPageMove?()
        tab.onTitleChanged?()

        #expect(model.history.visits.count == 1)
    }

    @Test func anInPageMoveCountsOnceItsTitleArrives() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/board", .typed, title: "Board - Jira")

        tab.urlString = "https://jira.example/browse/ENEY-6039"
        tab.onInPageMove?()
        #expect(model.history.visits.count == 1)

        tab.pageTitle = "[ENEY-6039] Tour cards stay on top - Jira"

        #expect(urls(model) == ["https://jira.example/browse/ENEY-6039", "https://jira.example/board"])
        #expect(model.history.visits.first?.title == "[ENEY-6039] Tour cards stay on top - Jira")
        #expect(model.history.visits.first?.transition == .inPage)
        #expect(model.history.entries.first { $0.url == "https://jira.example/board" }?.title == "Board - Jira")
        #expect(Set(trails(model)).count == 1)
    }

    /// A move whose title is already new is a visit at once, and it knows the page it came from.
    @Test func anInPageMoveWithANewTitleIsAVisitAtOnce() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/board", .typed, title: "Board - Jira")

        tab.urlString = "https://jira.example/browse/1"
        tab.pageTitle = "Ticket - Jira"
        tab.onInPageMove?()

        #expect(urls(model) == ["https://jira.example/browse/1", "https://jira.example/board"])
        let ticket = model.history.visits.first
        #expect(model.history.referrerChain(to: ticket?.id ?? 0).map(\.url)
            == ["https://jira.example/board", "https://jira.example/browse/1"])
    }

    /// While a load is under way an address change is the load's own: the visit is recorded when the load ends.
    @Test func anInPageMoveDuringALoadBelongsToTheLoad() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/a", .typed)

        tab.noteTransition(.typed)
        tab.noteNavigationStarted()
        tab.urlString = "https://jira.example/b"
        tab.pageTitle = "B"
        tab.urlString = "https://jira.example/b?ready"
        tab.onInPageMove?()
        #expect(model.history.visits.count == 1)

        tab.onNavigationFinished?(false)

        #expect(urls(model) == ["https://jira.example/b?ready", "https://jira.example/a"])
        #expect(model.history.visits.map(\.transition) == [.typed, .typed])
    }

    @Test func aStoppedLoadLeavesInPageMovesAsVisits() {
        let model = makeModel()
        let tab = model.newTab()
        visit(tab, "https://jira.example/a", .typed, title: "A")
        tab.noteNavigationStarted()
        tab.stopLoading()
        #expect(!tab.awaitsVisit)

        tab.urlString = "https://jira.example/a2"
        tab.pageTitle = "A2"
        tab.onInPageMove?()

        #expect(model.history.visits.map(\.transition) == [.inPage, .typed])
    }

    @Test func aFailedLoadEndsTheWaitOnlyForItself() {
        let tab = BrowserTab(opensBlank: false, privately: true, context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        let replaced = PageNavigation()
        let current = PageNavigation()
        tab.navigationStarted(current, url: URL(string: "https://example.invalid/b"))
        #expect(tab.awaitsVisit)

        tab.navigationFailed(replaced, error: URLError(.cancelled))
        #expect(tab.awaitsVisit, "the failure of a navigation that was replaced is not the end of this one")

        tab.navigationFailed(current, error: URLError(.cancelled))
        #expect(!tab.awaitsVisit)
    }

    // MARK: - Private windows

    @Test func aPrivateTabWritesNoVisitTrailOrInPageMove() throws {
        let database = AppDatabase.temporary()
        let model = makePrivateModel(database: database)
        let tab = model.newTab()
        visit(tab, "https://private.example/a", .typed, title: "A")
        tab.urlString = "https://private.example/b"
        tab.pageTitle = "B"
        tab.onInPageMove?()
        tab.pageTitle = "B again"
        tab.onTitleChanged?()
        visit(tab, "https://private.example/c")
        tab.noteNavigationStarted()
        tab.urlString = "https://private.example/d"
        tab.onInPageMove?()
        tab.onNavigationFinished?(false)
        model.saveBlocking()

        #expect(model.history.visits.isEmpty)
        #expect(model.lastVisitID.isEmpty)
        #expect(try count("historyPage", in: database) == 0)
        #expect(try count("historyVisit", in: database) == 0)
        #expect(try count("sessionTab", in: database) == 1, "the session was saved")
        #expect(try count("sessionTab", in: database, where: "lastVisit IS NOT NULL OR visitTrail IS NOT NULL") == 0)
    }

    /// The control: the same events in an ordinary window do write, or the test above would pass by writing nothing for anyone.
    @Test func anOrdinaryTabWritesTheSameEventsDown() throws {
        let database = AppDatabase.temporary()
        let model = makeModel(database: database)
        let tab = model.newTab()
        visit(tab, "https://ordinary.example/a", .typed, title: "A")
        tab.urlString = "https://ordinary.example/b"
        tab.pageTitle = "B"
        tab.onInPageMove?()
        model.saveBlocking()

        #expect(urls(model) == ["https://ordinary.example/b", "https://ordinary.example/a"])
        #expect(try count("historyVisit", in: database, where: "trail IS NOT NULL") == 2)
        #expect(try count("sessionTab", in: database, where: "lastVisit IS NOT NULL AND visitTrail IS NOT NULL") == 1)
    }

    // MARK: - Opening a History entry in the background

    /// What a middle-click on a History or Start row calls: a background tab of the window's own browsing context. A
    /// normal window opens a normal tab; a private tab is only ever opened from a private window.
    @Test func aBackgroundTabStaysInItsWindowsContext() throws {
        let address = try #require(URL(string: "https://example.invalid/visited"))
        let normal = makeModel()
        let opened = normal.newTab(url: address, activate: false, after: normal.activeTab)
        #expect(!normal.opensPrivately)
        #expect(!opened.isPrivate)
        #expect(opened.context === normal.context)

        let privateModel = makePrivateModel()
        let privateOpened = privateModel.newTab(url: address, activate: false, after: privateModel.activeTab)
        #expect(privateModel.opensPrivately)
        #expect(privateOpened.isPrivate)
        #expect(privateOpened.context === privateModel.context)
        #expect(privateOpened.context !== normal.context)
    }

    // MARK: - Loading pages, on both engines

    @Test(arguments: BrowserEngine.allCases)
    func aFullLoadIsOneVisit(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/a": .html("<!doctype html><title>A</title><p>A</p>"),
            "/b": .html("<!doctype html><title>B</title><p>B</p>"),
            "/end": .html("<!doctype html><title>End</title><p>End</p>"),
        ]) { rig in
            let a = try rig.url("/a"), b = try rig.url("/b"), end = try rig.url("/end")
            // Each page is waited for until it has its title: the engine may report the title just after the load ends, and a
            // title that arrives once the tab has gone on to the next page names nothing.
            let tab = rig.open(a)
            try #require(await waitUntil { rig.urls == [a.absoluteString] && rig.titles == ["A"] }, "\(engine)")

            tab.load(b)
            try #require(await waitUntil { rig.urls.first == b.absoluteString && rig.titles.first == "B" }, "\(engine)")
            tab.load(end)
            try #require(await waitUntil { rig.urls.first == end.absoluteString && rig.titles.first == "End" }, "\(engine)")

            let visits = rig.model.history.visits
            #expect(visits.map(\.url) == [end.absoluteString, b.absoluteString, a.absoluteString], "\(engine)")
            #expect(!visits.contains { $0.transition == .inPage }, "a load is not an in-page move on \(engine)")
            #expect(Set(visits.map(\.trail)).count == 1, "one site, one trail on \(engine)")
            #expect(visits.map(\.title) == ["End", "B", "A"], "\(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aLinkClickIsOneVisit(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/a": .html("<!doctype html><title>A</title><a id=\"next\" href=\"/b\">B</a>"),
            "/b": .html("<!doctype html><title>B</title><p>B</p>"),
            "/end": .html("<!doctype html><title>End</title><p>End</p>"),
        ]) { rig in
            let a = try rig.url("/a"), b = try rig.url("/b"), end = try rig.url("/end")
            let tab = rig.open(a)
            try #require(await waitUntil { rig.urls == [a.absoluteString] }, "\(engine)")

            try await navigate(tab, by: "document.getElementById('next').click(); true")
            try #require(await waitUntil { rig.urls.first == b.absoluteString }, "\(engine)")
            tab.load(end)
            try #require(await waitUntil { rig.urls.first == end.absoluteString }, "\(engine)")

            let visits = rig.model.history.visits
            #expect(visits.map(\.url) == [end.absoluteString, b.absoluteString, a.absoluteString], "\(engine)")
            #expect(!visits.contains { $0.transition == .inPage }, "\(engine)")
            #expect(Set(visits.map(\.trail)).count == 1, "\(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aRedirectIsOneVisitAtItsEnd(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/a": .html("<!doctype html><title>A</title><p>A</p>"),
            "/go": HTTPFixtureServer.Response(status: "302 Found", headers: ["Location": "/b"], body: Data()),
            "/b": .html("<!doctype html><title>B</title><p>B</p>"),
            "/end": .html("<!doctype html><title>End</title><p>End</p>"),
        ]) { rig in
            let a = try rig.url("/a"), go = try rig.url("/go"), b = try rig.url("/b"), end = try rig.url("/end")
            let tab = rig.open(a)
            try #require(await waitUntil { rig.urls == [a.absoluteString] }, "\(engine)")

            tab.load(go)
            try #require(await waitUntil { rig.urls.first == b.absoluteString }, "\(engine)")
            tab.load(end)
            try #require(await waitUntil { rig.urls.first == end.absoluteString }, "\(engine)")

            let visits = rig.model.history.visits
            #expect(visits.map(\.url) == [end.absoluteString, b.absoluteString, a.absoluteString], "\(engine)")
            #expect(!visits.contains { $0.transition == .inPage }, "\(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aReloadIsOneMoreVisit(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/a": .html("<!doctype html><title>A</title><p>A</p>"),
            "/end": .html("<!doctype html><title>End</title><p>End</p>"),
        ]) { rig in
            let a = try rig.url("/a"), end = try rig.url("/end")
            let tab = rig.open(a)
            try #require(await waitUntil { rig.urls == [a.absoluteString] }, "\(engine)")

            tab.reload()
            try #require(await waitUntil { rig.urls == [a.absoluteString, a.absoluteString] }, "\(engine)")
            tab.load(end)
            try #require(await waitUntil { rig.urls.first == end.absoluteString }, "\(engine)")

            #expect(rig.urls == [end.absoluteString, a.absoluteString, a.absoluteString], "\(engine)")
            #expect(!rig.model.history.visits.contains { $0.transition == .inPage }, "\(engine)")
        }
    }

    /// Going back to an earlier document is a visit to it, once, and not a move the page made itself.
    @Test(arguments: BrowserEngine.allCases)
    func aBackNavigationIsOneVisit(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/a": .html("<!doctype html><title>A</title><p>A</p>"),
            "/b": .html("<!doctype html><title>B</title><p>B</p>"),
            "/end": .html("<!doctype html><title>End</title><p>End</p>"),
        ]) { rig in
            let a = try rig.url("/a"), b = try rig.url("/b"), end = try rig.url("/end")
            let tab = rig.open(a)
            try #require(await waitUntil { rig.urls == [a.absoluteString] }, "\(engine)")
            tab.load(b)
            try #require(await waitUntil { rig.urls.first == b.absoluteString }, "\(engine)")

            tab.goBack()
            try #require(await waitUntil { rig.urls == [a.absoluteString, b.absoluteString, a.absoluteString] }, "\(engine)")
            tab.load(end)
            try #require(await waitUntil { rig.urls.first == end.absoluteString }, "\(engine)")

            let visits = rig.model.history.visits
            #expect(visits.map(\.url) == [end.absoluteString, a.absoluteString, b.absoluteString, a.absoluteString], "\(engine)")
            #expect(!visits.contains { $0.transition == .inPage }, "going back is not an in-page move on \(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func anInPageMoveIsAVisitOfItsOwn(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/board": .html("<!doctype html><title>Board - Jira</title><p>Board</p>"),
        ]) { rig in
            let board = try rig.url("/board"), ticket = try rig.url("/browse/ENEY-6039")
            let tab = rig.open(board)
            try #require(await waitUntil { rig.urls == [board.absoluteString] }, "\(engine)")

            _ = try await tab.page.evaluateJavaScript("""
                history.pushState({}, '', '/browse/ENEY-6039');
                document.title = '[ENEY-6039] Tour cards stay on top - Jira';
                true
                """)

            let title = "[ENEY-6039] Tour cards stay on top - Jira"
            try #require(await waitUntil { rig.model.history.visits.first?.title == title }, "\(engine)")
            let visits = rig.model.history.visits
            #expect(visits.map(\.url) == [ticket.absoluteString, board.absoluteString], "\(engine)")
            #expect(visits.first?.transition == .inPage, "\(engine)")
            #expect(Set(visits.map(\.trail)).count == 1, "\(engine)")
            #expect(rig.model.history.entries.first { $0.url == board.absoluteString }?.title == "Board - Jira", "\(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func anAnchorJumpIsNotAVisit(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/docs": .html("<!doctype html><title>Docs</title><p id=\"usage\">Usage</p>"),
            "/end": .html("<!doctype html><title>End</title><p>End</p>"),
        ]) { rig in
            let docs = try rig.url("/docs"), end = try rig.url("/end")
            let tab = rig.open(docs)
            try #require(await waitUntil { rig.urls == [docs.absoluteString] }, "\(engine)")

            _ = try await tab.page.evaluateJavaScript("location.hash = 'usage'; true")
            try #require(await waitUntil { tab.urlString.hasSuffix("#usage") }, "\(engine)")
            // The next load is the barrier: a visit the jump had made would be recorded before it.
            tab.load(end)
            try #require(await waitUntil { rig.urls.first == end.absoluteString }, "\(engine)")

            #expect(rig.urls == [end.absoluteString, docs.absoluteString], "\(engine)")
        }
    }

    /// A second move to an address with the same title waits for a title, and the page's own title change releases it.
    @Test(arguments: BrowserEngine.allCases)
    func aMoveWaitsForItsTitleAndTheTitleReleasesIt(engine: BrowserEngine) async throws {
        try await withRig(engine, routes: [
            "/board": .html("<!doctype html><title>Board</title><p>Board</p>"),
        ]) { rig in
            let board = try rig.url("/board"), ticket = try rig.url("/browse/1")
            let tab = rig.open(board)
            try #require(await waitUntil { rig.urls == [board.absoluteString] }, "\(engine)")

            _ = try await tab.page.evaluateJavaScript("history.pushState({}, '', '/browse/1'); true")
            try #require(await waitUntil { tab.urlString == ticket.absoluteString }, "\(engine)")
            #expect(rig.model.history.visits.count == 1, "the old title still stands on \(engine)")

            _ = try await tab.page.evaluateJavaScript("document.title = 'Ticket 1'; true")
            try #require(await waitUntil { rig.urls.first == ticket.absoluteString }, "\(engine)")
            #expect(rig.model.history.visits.first?.title == "Ticket 1", "\(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases, ["A", "B"])
    func anAddressChangeWhileLoadingBelongsToTheLoad(engine: BrowserEngine, title: String) async throws {
        let image = ResponseGate()
        defer { image.open() }
        try await withRig(engine, routes: [
            "/a": .html("<!doctype html><title>A</title><p>A</p>"),
            "/b": .html("""
                <!doctype html><title>\(title)</title>
                <script>history.replaceState({}, '', '/b?ready')</script>
                <img src="/slow">
                """),
            "/slow": .html("", gate: image),
        ]) { rig in
            let a = try rig.url("/a")
            let ready = try rig.url("/b?ready")
            let tab = rig.open(a)
            try #require(await waitUntil { rig.urls == [a.absoluteString] }, "\(engine)")

            tab.load(try rig.url("/b"))
            try #require(await waitUntil { tab.urlString == ready.absoluteString }, "\(engine)")
            _ = try await tab.page.evaluateJavaScript("document.title = 'Loaded'; true")
            try #require(await waitUntil { tab.pageTitle == "Loaded" }, "\(engine)")
            image.open()
            try #require(await waitUntil { rig.urls.first == ready.absoluteString && !tab.isLoading }, "\(engine)")

            let visits = rig.model.history.visits
            #expect(visits.map(\.url) == [ready.absoluteString, a.absoluteString], "\(engine)")
            #expect(visits.map(\.transition) == [.typed, .typed], "\(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func anInPageMoveDuringASlowLoadIsKept(engine: BrowserEngine) async throws {
        let image = ResponseGate()
        defer { image.open() }
        try await withRig(engine, routes: [
            "/board": .html("<!doctype html><title>Board</title><img src=\"/slow\">"),
            "/slow": .html("", gate: image),
        ]) { rig in
            let first = try rig.url("/browse/1"), second = try rig.url("/browse/2")
            let tab = rig.open(try rig.url("/board"))
            try #require(await waitUntil { tab.pageTitle == "Board" }, "\(engine)")

            _ = try await tab.page.evaluateJavaScript("""
                history.pushState({}, '', '/browse/1');
                document.title = 'Ticket 1';
                true
                """)
            try #require(await waitUntil { tab.urlString == first.absoluteString && tab.pageTitle == "Ticket 1" }, "\(engine)")
            // The move belongs to the load. Which of the two events records it, the title or the end of the load, depends on
            // the order the engine reports them in; either way it is one visit, at the moved address.
            image.open()
            try #require(await waitUntil { rig.urls.first == first.absoluteString && !tab.page.isLoading && !tab.awaitsVisit }, "\(engine)")
            #expect(rig.model.history.visits.count == 1, "\(engine)")

            _ = try await tab.page.evaluateJavaScript("""
                history.pushState({}, '', '/browse/2');
                document.title = 'Ticket 2';
                true
                """)
            try #require(await waitUntil { rig.urls.first == second.absoluteString }, "\(engine)")

            let visits = rig.model.history.visits
            #expect(visits.map(\.url) == [second.absoluteString, first.absoluteString], "\(engine)")
            #expect(visits.map(\.transition) == [.inPage, .typed], "\(engine)")
            #expect(Set(visits.map(\.trail)).count == 1, "\(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPrivateTabWritesNothingWhateverItLoadsOrMoves(engine: BrowserEngine) async throws {
        let database = AppDatabase.temporary()
        let model = makePrivateModel(database: database)
        let server = try await HTTPFixtureServer.start(routes: [
            "/a": .html("<!doctype html><title>A</title><a id=\"next\" href=\"/b\">B</a>"),
            "/b": .html("<!doctype html><title>B</title><p>B</p>"),
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func cleanUp() async {
            let tabs = model.tabs
            model.closeAllTabs(saving: false)
            for tab in tabs {
                await tab.waitForRetirement()
            }
            window.contentView = nil
            window.close()
            await model.context.endPrivateSession()
        }
        do {
            let a = try server.url("/a"), b = try server.url("/b")
            let tab = model.newTab(url: a, engine: engine)
            #expect(tab.isPrivate)
            #expect(tab.page.engine == engine, "the tab runs on \(engine)")
            window.contentView = tab.page
            window.orderFront(nil)
            try #require(await waitUntil { tab.urlString == a.absoluteString && !tab.page.isLoading && !tab.isLoading })

            try await navigate(tab, by: "document.getElementById('next').click(); true")
            try #require(await waitUntil { tab.urlString == b.absoluteString && !tab.page.isLoading && !tab.isLoading })
            _ = try await tab.page.evaluateJavaScript("""
                history.pushState({}, '', '/b/moved');
                document.title = 'Moved';
                true
                """)
            try #require(await waitUntil { tab.pageTitle == "Moved" && tab.urlString.hasSuffix("/b/moved") })
            _ = try await tab.page.evaluateJavaScript("document.title = 'Moved again'; true")
            try #require(await waitUntil { tab.pageTitle == "Moved again" })
            model.saveBlocking()

            #expect(model.history.visits.isEmpty, "\(engine)")
            #expect(model.lastVisitID.isEmpty, "\(engine)")
            #expect(try count("historyVisit", in: database) == 0, "\(engine)")
            #expect(try count("historyPage", in: database) == 0, "\(engine)")
            #expect(try count("sessionTab", in: database, where: "lastVisit IS NOT NULL OR visitTrail IS NOT NULL") == 0)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    // MARK: - Rig

    /// An ordinary profile of its own, a model over a temporary database, and a window to show the tabs in: a Chromium
    /// page loads only once it is in a window. `open` loads a page in the engine under test, whatever the site's setting is.
    @MainActor
    private struct Rig {
        let engine: BrowserEngine
        let server: HTTPFixtureServer
        let model: BrowserModel
        let window: NSWindow

        var urls: [String] {
            model.history.visits.map(\.url)
        }

        var titles: [String] {
            model.history.visits.map(\.title)
        }

        func url(_ path: String) throws -> URL {
            try server.url(path)
        }

        func open(_ url: URL) -> BrowserTab {
            let tab = model.newTab(url: url, engine: engine)
            #expect(tab.page.engine == engine, "the tab runs on \(engine)")
            window.contentView = tab.page
            window.orderFront(nil)
            return tab
        }
    }

    private func withRig(
        _ engine: BrowserEngine,
        routes: [String: HTTPFixtureServer.Response],
        body: (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: routes)
        let profile = Profile(id: UUID(), name: "History trails", symbol: "clock", color: .gray)
        let context = BrowserProfileContext.shared(for: profile)
        let model = BrowserModel(context: context, windowID: UUID(), database: .temporary())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func cleanUp() async {
            let tabs = model.tabs
            model.closeAllTabs(saving: false)
            for tab in tabs {
                await tab.waitForRetirement()
            }
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            await context.sitePermissions.waitForPendingSave()
            window.contentView = nil
            window.close()
            BrowserProfileContext.forget(profile.id)
            ProfileSettingsStore.forget(profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        }
        do {
            try await body(Rig(engine: engine, server: server, model: model, window: window))
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
