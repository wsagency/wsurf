// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Network
import Testing
import WebKit

@testable import WSurf

/// A Chromium tab keeps its Back and Forward list when it sleeps, is restored after a relaunch, duplicated or reopened (D3b). Only
/// the current entry loads; another entry loads by a plain GET only when the person goes Back or Forward to it; an entry a form
/// POST made is dropped, and no POST is ever sent again. The fixture counts every request by method and path, and its pages may not
/// be cached, so each load the browser makes shows up.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ChromiumHistoryRestoreTests {
    nonisolated final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        /// A connection that closed before sending a request line (Chromium's preconnect to a site it just tried) is not a load.
        func record(_ request: HTTPFixtureServer.Request) {
            guard request.path != "/favicon.ico", !request.method.isEmpty else { return }
            lock.withLock { seen.append("\(request.method) \(request.path)") }
        }

        var count: Int {
            lock.withLock { seen.count }
        }

        func since(_ mark: Int) -> [String] {
            lock.withLock { Array(seen.dropFirst(mark)) }
        }
    }

    final class Gate {
        private(set) var reached = false
        private var released = false

        func wait() async {
            reached = true
            while !released {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        func open() {
            released = true
        }
    }

    private static let noStore = ["Cache-Control": "no-store"]

    private static func page(_ name: String) -> HTTPFixtureServer.Response {
        .html("<!doctype html><title>Page \(name)</title><p>\(name)</p>", headers: noStore)
    }

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/a": page("A"), "/b": page("B"), "/c": page("C"), "/d": page("D"), "/b2": page("B2"), "/result": page("Result"),
        "/r": HTTPFixtureServer.Response(status: "302 Found", headers: ["Location": "/b2", "Cache-Control": "no-store"], body: Data()),
        "/form": .html(#"<!doctype html><title>Form</title><form method="post" action="/result"><input name="q" value="1"></form>"#, headers: noStore),
    ]

    private func withRig(engine: BrowserEngine = .chromium, _ body: (LiveWindowRig, RequestLog) async throws -> Void) async throws {
        let log = RequestLog()
        try await LiveWindowRig.with(engine: engine, routes: Self.routes, respond: { request in
            log.record(request)
            return nil
        }) { rig in
            try await body(rig, log)
        }
    }

    private func visit(_ path: String, in tab: BrowserTab, _ rig: LiveWindowRig) async throws {
        let url = try rig.server.url(path)
        tab.load(url)
        try #require(await waitUntil(timeout: .seconds(30)) { tab.page.url == url && !tab.page.isLoading }, "loaded \(path)")
    }

    private func lists(_ tab: BrowserTab) -> String {
        let list = tab.page.backForwardList
        return "\(tab.page.url?.path ?? "-") back \(list.backList.map(\.url.path)) forward \(list.forwardList.map(\.url.path))"
    }

    /// Waits until `tab` has finished loading `path` with these lists.
    private func settles(_ tab: BrowserTab, at path: String, back: [String], forward: [String]) async -> Bool {
        let expected = "\(path) back \(back) forward \(forward)"
        return await waitUntil(timeout: .seconds(30)) { !tab.page.isLoading && lists(tab) == expected }
    }

    /// Whether the requests since `mark` are exactly `expected`: waits for that many, then a moment for any extra one.
    private func requests(_ log: RequestLog, since mark: Int, are expected: [String]) async -> Bool {
        _ = await waitUntil(timeout: .seconds(10)) { log.since(mark).count >= expected.count }
        try? await Task.sleep(for: .milliseconds(300))
        return log.since(mark) == expected
    }

    /// a → b → c, then `back` native Back presses.
    private func history(in rig: LiveWindowRig, back presses: Int = 0) async throws -> BrowserTab {
        let tab = try await rig.open("/a")
        try await visit("/b", in: tab, rig)
        try await visit("/c", in: tab, rig)
        try #require(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")
        for _ in 0..<presses {
            tab.goBack()
            try #require(await waitUntil { !tab.page.isLoading && tab.page.url?.path != "/c" })
        }
        return tab
    }

    /// Puts `tab` to sleep behind another tab and shows it again; the request count from just before it wakes.
    private func sleepAndWake(_ tab: BrowserTab, in rig: LiveWindowRig, log: RequestLog) async throws -> Int {
        _ = try await rig.open("/still")
        rig.coordinator.unloadTab(tab)
        try #require(tab.isDeferred && !tab.isMaterialised)
        let mark = log.count
        rig.browser.activate(tab)
        _ = await tab.waitForPendingNavigation()
        return mark
    }

    /// A saved Chromium state in the format a tab writes, built by hand: entries a test cannot make by browsing (an unreachable site,
    /// an address that now redirects).
    private func state(back: [URL], forward: [URL]) throws -> Data {
        func entries(_ urls: [URL]) -> [[String: String]] {
            urls.map { ["url": $0.absoluteString, "title": $0.lastPathComponent] }
        }
        let saved: [String: Any] = ["engine": "chromium", "chromium": ["back": entries(back), "forward": entries(forward)]]
        return try JSONSerialization.data(withJSONObject: saved)
    }

    /// A tab that wakes at `path` from `state`, and the request count from just before it wakes.
    private func wake(at path: String, from state: Data, in rig: LiveWindowRig, log: RequestLog) async throws -> (BrowserTab, Int) {
        let tab = try await rig.open("/still")
        _ = try await rig.open("/still")
        rig.coordinator.unloadTab(tab)
        tab.deferRestore(state: state, url: try rig.server.url(path))
        let mark = log.count
        rig.browser.activate(tab)
        _ = await tab.waitForPendingNavigation()
        return (tab, mark)
    }

    /// Waits until `tab` shows WSurf's error document with these lists around it.
    private func showsError(_ tab: BrowserTab, back: [String], forward: [String]) async -> Bool {
        await waitUntil(timeout: .seconds(30)) {
            let list = tab.page.backForwardList
            return !tab.page.isLoading && tab.isShowingError && list.backList.map(\.url.path) == back && list.forwardList.map(\.url.path) == forward
        }
    }

    /// A port nothing listens on (a connection to it is refused), where `reopen` later starts a server that logs to `log`.
    private func closedPort(log: RequestLog) async throws -> (dead: URL, reopen: () async throws -> HTTPFixtureServer) {
        let server = try await HTTPFixtureServer.start(routes: [:])
        let dead = try server.url("/dead")
        let port = try #require(server.port)
        await server.stop()
        return (dead, {
            try await HTTPFixtureServer.start(routes: ["/dead": Self.page("Dead")], respond: { request in
                log.record(request)
                return nil
            }, port: port)
        })
    }

    // MARK: Wake

    @Test func aWokenTabLoadsOnlyItsCurrentEntryAndKeepsItsLists() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig, back: 1)
            try #require(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")

            // Saved: addresses and titles, nothing else.
            let state = try #require(tab.sessionState)
            let object = try #require(try JSONSerialization.jsonObject(with: state) as? [String: Any])
            #expect(Set(object.keys) == ["engine", "chromium"] && object["engine"] as? String == "chromium")
            let saved = try #require(object["chromium"] as? [String: [[String: Any]]])
            #expect(Set(saved.keys) == ["back", "forward"])
            #expect(saved.values.joined().allSatisfy { Set($0.keys) == ["url", "title"] }, "\(saved)")

            let mark = try await sleepAndWake(tab, in: rig, log: log)
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /b"]), "\(log.since(mark))")
            #expect(tab.page.canGoBack && tab.page.canGoForward)
            #expect(tab.page.backForwardList.backList.first?.title == "Page A", "with its title")
        }
    }

    @Test func backAndForwardLoadRestoredEntriesByGetOneAtATime() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig)
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")

            var mark = log.count
            tab.goBack()
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /b"]), "\(log.since(mark))")
            mark = log.count
            tab.goBack()
            #expect(await settles(tab, at: "/a", back: [], forward: ["/b", "/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /a"]), "\(log.since(mark))")
            #expect(!tab.page.canGoBack)

            mark = log.count
            tab.goForward()
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            tab.goForward()
            #expect(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /b", "GET /c"]), "\(log.since(mark))")
            #expect(!tab.page.canGoForward)
        }
    }

    @Test func pickingARestoredEntryFromTheListLandsThereAndReformsIt() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig)
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")
            let mark = log.count
            tab.page.go(to: try #require(tab.page.backForwardList.backList.first))
            #expect(await settles(tab, at: "/a", back: [], forward: ["/b", "/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /a"]), "\(log.since(mark))")
        }
    }

    @Test func aNewNavigationDropsTheRestoredForwardEntries() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig, back: 1)
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            _ = try? await tab.page.evaluateJavaScript("location.href = '/d'; 0")
            #expect(await settles(tab, at: "/d", back: ["/a", "/b"], forward: []), "\(lists(tab))")
            #expect(!tab.page.canGoForward)
        }
    }

    @Test func aReplacementKeepsTheRestoredForwardEntries() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig, back: 1)
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            _ = try? await tab.page.evaluateJavaScript("location.replace('/b2'); 0")
            #expect(await settles(tab, at: "/b2", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
        }
    }

    /// The page adds an entry (`pushState`) after a hop committed and before its collapse is sent. The collapse keeps only the
    /// current entry, so it would drop the hop's page: it is not sent, and the entries the hop left stay hidden instead.
    @Test func anEntryAddedBeforeTheCollapseIsNeverLost() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig)
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")
            let gate = Gate()
            defer { gate.open() }
            tab.page.chromium?.historyRecord.beforeCollapse = { await gate.wait() }
            tab.goBack()
            try #require(await waitUntil(timeout: .seconds(30)) { gate.reached })
            // With a gesture, as in PageInteractionTests: without one Chromium's Back skips the page that pushed (its intervention).
            _ = try await tab.page.evaluateJavaScript("history.pushState({}, '', '/pushed'); 0", in: nil, contentWorld: .page, userGesture: true)
            try #require(await waitUntil { tab.page.url?.path == "/pushed" })
            gate.open()
            #expect(await settles(tab, at: "/pushed", back: ["/a", "/b"], forward: []), "\(lists(tab))")

            tab.goBack()
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/pushed"]), "\(lists(tab))")
            tab.goBack()
            #expect(await settles(tab, at: "/a", back: [], forward: ["/b", "/pushed"]), "\(lists(tab))")
            #expect(!tab.page.canGoBack, "never the page the hop left, never the startup page")
        }
    }

    /// Owner decision 2026-11-07: an entry a POST made is dropped from the restored list, and no form is sent again.
    @Test func aFormPostIsNeverSentAgain() async throws {
        try await withRig { rig, log in
            let tab = try await rig.open("/form")
            _ = try? await tab.page.evaluateJavaScript("document.forms[0].submit(); 0")
            try #require(await waitUntil(timeout: .seconds(30)) { tab.page.url?.path == "/result" && !tab.page.isLoading })
            #expect(log.since(0).contains("POST /result"))
            try await visit("/d", in: tab, rig)
            try #require(await settles(tab, at: "/d", back: ["/form", "/result"], forward: []), "\(lists(tab))")

            let mark = try await sleepAndWake(tab, in: rig, log: log)
            #expect(await settles(tab, at: "/d", back: ["/form"], forward: []), "\(lists(tab))")
            tab.goBack()
            #expect(await settles(tab, at: "/form", back: [], forward: ["/d"]), "\(lists(tab))")
            #expect(!tab.page.canGoBack)
            #expect(await requests(log, since: mark, are: ["GET /d", "GET /form"]), "\(log.since(mark))")
        }
    }

    /// Known and documented (the record moves only once a hop's entry appears): a second Back while a hop is still on its way restarts
    /// that hop, so two quick Backs move one step, where native history moves two.
    @Test func aSecondBackWhileAHopIsOnItsWayGoesToTheSameEntry() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig)
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")
            let mark = log.count
            tab.goBack()
            tab.goBack()
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            try? await Task.sleep(for: .milliseconds(300))
            #expect(!log.since(mark).isEmpty && Set(log.since(mark)) == ["GET /b"], "\(log.since(mark))")
        }
    }

    /// A restored entry redirects now: the hop lands where the redirect commits, in the entry's place.
    @Test func aHopToAnEntryThatRedirectsLandsOnTheRedirectsTarget() async throws {
        try await withRig { rig, log in
            let (tab, mark) = try await wake(at: "/c", from: state(back: [rig.server.url("/a"), rig.server.url("/r")], forward: []), in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/r"], forward: []), "\(lists(tab))")
            tab.goBack()
            #expect(await settles(tab, at: "/b2", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            tab.goBack()
            #expect(await settles(tab, at: "/a", back: [], forward: ["/b2", "/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /c", "GET /r", "GET /b2", "GET /a"]), "\(log.since(mark))")
        }
    }

    // MARK: A hop that fails

    /// Review F1: the site of a restored entry is down. WSurf's error document stands in its place: Back goes on to the entry before
    /// it (never forward in time to the page the hop left), and once the site is back the entry loads by GET.
    @Test func aBackHopToAnUnreachableEntryKeepsItsPlaceAndLoadsOnceTheSiteIsBack() async throws {
        try await withRig { rig, log in
            let (dead, reopen) = try await closedPort(log: log)
            let (tab, mark) = try await wake(at: "/c", from: state(back: [rig.server.url("/a"), dead], forward: []), in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/dead"], forward: []), "\(lists(tab))")

            tab.goBack()
            #expect(await showsError(tab, back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(tab.urlString == dead.absoluteString, "the tab's address (saved as its current entry) is the failed one: \(tab.urlString)")
            #expect(tab.page.canGoBack && tab.page.canGoForward)
            tab.goBack()
            #expect(await settles(tab, at: "/a", back: [], forward: ["/dead", "/c"]), "\(lists(tab))")

            let server = try await reopen()
            tab.goForward()
            #expect(await settles(tab, at: "/dead", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /c", "GET /a", "GET /dead"]), "\(log.since(mark))")
            withExtendedLifetime(server) {}
        }
    }

    @Test func aForwardHopToAnUnreachableEntryKeepsTheForwardList() async throws {
        try await withRig { rig, log in
            let (dead, reopen) = try await closedPort(log: log)
            let (tab, mark) = try await wake(at: "/a", from: state(back: [], forward: [dead, rig.server.url("/c")]), in: rig, log: log)
            try #require(await settles(tab, at: "/a", back: [], forward: ["/dead", "/c"]), "\(lists(tab))")

            tab.goForward()
            #expect(await showsError(tab, back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(tab.urlString == dead.absoluteString, "the tab's address (saved as its current entry) is the failed one: \(tab.urlString)")
            tab.goForward()
            #expect(await settles(tab, at: "/c", back: ["/a", "/dead"], forward: []), "\(lists(tab))")

            let server = try await reopen()
            tab.goBack()
            #expect(await settles(tab, at: "/dead", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /a", "GET /c", "GET /dead"]), "\(log.since(mark))")
            withExtendedLifetime(server) {}
        }
    }

    /// Runs `action` once, right after the tab has handled the next failed load: the error document has just started loading, and
    /// what `action` starts replaces it, so it never reports a finish or a failure.
    private func onceAfterFailure(of tab: BrowserTab, _ action: @escaping @MainActor () -> Void) {
        let handled = tab.page.onNavigationFailed
        var fired = false
        tab.page.onNavigationFailed = { navigation, error in
            handled?(navigation, error)
            guard !fired else { return }
            fired = true
            action()
        }
    }

    /// Whether `tab` has finished loading WSurf's error document, titled with its headline. Not the alert branch (which clears the
    /// flag too, and leaves `isShowingError` from the earlier failure) and not the engine's own error page.
    private func showsOwnErrorPage(_ tab: BrowserTab) async -> Bool {
        // WebKit names a refused connection; Chromium's error code reaches WSurf's page as the general headline.
        let headlines = [String(localized: "Can’t reach this website"), String(localized: "This page didn’t load")]
        return await waitUntil(timeout: .seconds(30)) {
            !tab.page.isLoading && tab.isShowingError && !tab.isLoadingErrorPage && tab.page.title.map(headlines.contains) == true
        }
    }

    /// Delta review N5: a page that replaces the error document while it loads reports nothing for it. The flag that waits for it
    /// must not outlive it, or the next failure turns into an alert sheet with a stale address and no error page.
    @Test(arguments: [BrowserEngine.chromium, .webKit])
    func aStoppedErrorDocumentDoesNotTurnTheNextFailureIntoAnAlert(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig, log in
            let (first, _) = try await closedPort(log: log)
            let (second, _) = try await closedPort(log: log)
            let tab = try await rig.open("/a")
            onceAfterFailure(of: tab) { [weak tab] in tab?.load(second) }
            tab.load(first)
            #expect(await showsOwnErrorPage(tab), "\(tab.page.title ?? "-") \(tab.urlString)")
            #expect(tab.urlString == second.absoluteString, "the address of the page that failed: \(tab.urlString)")
            #expect(!tab.isLoadingErrorPage)
        }
    }

    /// The shared rule behind the live test above, whatever the engine: only the error document's own start keeps the flag that
    /// waits for it; any other navigation that starts ends the wait and takes the address.
    @Test func aNavigationThatIsNotTheErrorDocumentEndsTheWaitForIt() {
        let tab = BrowserModel(database: AppDatabase.temporary()).newTab()
        let document = PageNavigation()
        let url = URL(string: "https://example.com/next")
        tab.isShowingError = true
        tab.isLoadingErrorPage = true
        tab.errorDocumentNavigation = document

        tab.navigationStarted(document, url: url)
        #expect(tab.isLoadingErrorPage && tab.isShowingError, "the error document's own start")
        #expect(tab.urlString != url?.absoluteString)

        tab.navigationStarted(PageNavigation(), url: url)
        #expect(!tab.isLoadingErrorPage && !tab.isShowingError)
        #expect(tab.urlString == url?.absoluteString)
    }

    /// A second Back while the error document of a failed Back hop loads (S5): Chromium's error entry for the hop is already in its
    /// list, and Back must not move natively from it back to the page the hop left. It restarts the hop, which fails again; the error
    /// document stands in the failed entry's place once more and the list keeps its order, with no entry twice.
    @Test func aSecondBackWhileTheErrorDocumentLoadsRestartsTheFailedHop() async throws {
        try await withRig { rig, log in
            let (dead, _) = try await closedPort(log: log)
            let (tab, _) = try await wake(at: "/c", from: state(back: [rig.server.url("/a"), dead], forward: []), in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/dead"], forward: []), "\(lists(tab))")

            let mark = log.count
            onceAfterFailure(of: tab) { [weak tab] in tab?.goBack() }
            tab.goBack()
            #expect(await showsError(tab, back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(await showsOwnErrorPage(tab), "\(tab.page.title ?? "-")")
            #expect(tab.urlString == dead.absoluteString, "the tab's address (saved as its current entry) is the failed one: \(tab.urlString)")
            let first = try rig.server.url("/a").absoluteString
            let left = try rig.server.url("/c").absoluteString
            let stored = try #require(tab.sessionState)
            let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
            let saved = try #require(object["chromium"] as? [String: [[String: String]]], "\(object)")
            #expect(saved["back"]?.compactMap { $0["url"] } == [first] && saved["forward"]?.compactMap { $0["url"] } == [left],
                    "saved: the list in its order, no entry twice: \(saved)")
            tab.goBack()
            #expect(await settles(tab, at: "/a", back: [], forward: ["/dead", "/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /a"]), "Back never went to /c: \(log.since(mark))")
        }
    }

    // MARK: Engine switches

    /// Chromium → WebKit → Back: the Chromium page comes back with its list, loading only its own address.
    @Test func backFromWebKitReturnsToTheChromiumPageWithItsList() async throws {
        try await withRig { rig, log in
            let other = try await HTTPFixtureServer.start(routes: ["/w": Self.page("W")], respond: { request in
                log.record(request)
                return nil
            })
            let webKitPage = try other.url("/w")
            let tab = try await history(in: rig)
            tab.engineOverride = nil
            rig.browser.sitePermissions.setEngine(.webKit, for: SitePermissions.origin(for: webKitPage))
            tab.load(webKitPage)
            try #require(await waitUntil(timeout: .seconds(30)) { tab.page.engine == .webKit && tab.page.url == webKitPage && !tab.page.isLoading })

            let mark = log.count
            tab.goBack()
            #expect(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")
            #expect(tab.page.engine == .chromium)
            tab.goBack()
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /c", "GET /b"]), "\(log.since(mark))")
            withExtendedLifetime(other) {}
        }
    }

    /// A Back hop to a restored entry whose site now opens in WebKit: the tab moves there, and the page it left is ahead of the
    /// entry, so it is not kept for Back (Back would go forward in time).
    @Test func aBackHopThatMovesTheTabToWebKitDoesNotKeepThePageItLeft() async throws {
        try await withRig { rig, log in
            let other = try await HTTPFixtureServer.start(routes: ["/w": Self.page("W")], respond: { request in
                log.record(request)
                return nil
            })
            let webKitPage = try other.url("/w")
            let tab = try await rig.open("/a")
            tab.load(webKitPage)
            try #require(await waitUntil(timeout: .seconds(30)) { tab.page.url == webKitPage && !tab.page.isLoading })
            try await visit("/c", in: tab, rig)
            try #require(await settles(tab, at: "/c", back: ["/a", "/w"], forward: []), "\(lists(tab))")
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/w"], forward: []), "\(lists(tab))")

            tab.engineOverride = nil
            rig.browser.sitePermissions.setEngine(.webKit, for: SitePermissions.origin(for: webKitPage))
            let mark = log.count
            tab.goBack()
            #expect(await waitUntil(timeout: .seconds(30)) { tab.page.engine == .webKit && tab.page.url == webKitPage && !tab.page.isLoading })
            #expect(tab.pageBeforeEngineSwitch == nil)
            tab.goBack()
            #expect(await requests(log, since: mark, are: ["GET /w"]), "Back does not return to /c: \(log.since(mark))")
            withExtendedLifetime(other) {}
        }
    }

    // MARK: Other restores

    @Test func theSavedListSurvivesARelaunch() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig, back: 1)
            try #require(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            let url = try rig.server.url("/b")
            let state = try #require(tab.sessionState)
            #expect(BrowserPage.chromiumHistory(in: state)?.back.map(\.url) == [try rig.server.url("/a").absoluteString])

            let database = AppDatabase.temporary()
            let model = BrowserModel(database: database)
            let saved = model.newTab(url: URL(string: "https://saved.example/"), activate: false)
            let active = model.newTab(url: URL(string: "https://active.example/"))
            saved.deferRestore(state: state, url: url)
            model.activeTabID = active.id
            model.saveBlocking()
            let reopened = BrowserModel(database: database)
            reopened.restoreSession()
            let stored = try #require(reopened.tabs.first { $0.id == saved.id }?.sessionState)
            #expect(stored == state)

            // The stored bytes wake a live tab: the same lists, one load.
            _ = try await rig.open("/still")
            rig.coordinator.unloadTab(tab)
            tab.deferRestore(state: stored, url: url)
            let mark = log.count
            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(await requests(log, since: mark, are: ["GET /b"]), "\(log.since(mark))")
        }
    }

    @Test func duplicateAndReopenClosedTabKeepTheLists() async throws {
        try await withRig { rig, _ in
            let tab = try await history(in: rig, back: 1)
            try #require(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            let copy = rig.browser.duplicate(tab)
            #expect(await settles(copy, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(copy))")

            rig.browser.close(copy)
            rig.browser.reopenLastClosedTab()
            let reopened = try #require(rig.browser.activeTab)
            #expect(reopened.id == copy.id)
            #expect(await settles(reopened, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(reopened))")
        }
    }

    /// The agent's Back goes through the same page: it reaches a restored entry, and the entry its grant check reads is that one.
    @Test func theAgentsBackReachesARestoredEntry() async throws {
        try await withRig { rig, log in
            let tab = try await history(in: rig)
            _ = try await sleepAndWake(tab, in: rig, log: log)
            try #require(await settles(tab, at: "/c", back: ["/a", "/b"], forward: []), "\(lists(tab))")
            #expect(tab.page.backForwardList.backList.last?.url == (try rig.server.url("/b")), "what `goBackRefusal` checks")
            let result = await PageDriver.goBack(in: tab.page)
            #expect(result.hasPrefix("Went back."), "\(result)")
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
        }
    }

    @Test func aSiteMovedToWebKitWhileAsleepWakesThereWithItsAddressAlone() async throws {
        try await withRig { rig, _ in
            let tab = try await history(in: rig, back: 1)
            _ = try await rig.open("/still")
            rig.coordinator.unloadTab(tab)
            tab.engineOverride = nil
            rig.browser.sitePermissions.setEngine(.webKit, for: SitePermissions.origin(for: try rig.server.url("/b")))
            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            #expect(await settles(tab, at: "/b", back: [], forward: []), "\(lists(tab))")
            #expect(tab.page.engine == .webKit)
        }
    }

    /// WebKit restores its own state natively, as before, and a state the previous build wrote (`{"engine":"webkit","webKit":…}`,
    /// made here by hand, not by the code under test) keeps its meaning.
    @Test func aWebKitTabStillWakesWithItsListsFromAStateSavedBeforeThisChange() async throws {
        try await withRig(engine: .webKit) { rig, log in
            let tab = try await history(in: rig, back: 1)
            try #require(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            _ = try await sleepAndWake(tab, in: rig, log: log)
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
            #expect(tab.page.engine == .webKit)

            let native = try #require(tab.page.webKit?.interactionState as? Data)
            let older = try JSONSerialization.data(withJSONObject: ["engine": "webkit", "webKit": native.base64EncodedString()])
            _ = try await rig.open("/still")
            rig.coordinator.unloadTab(tab)
            tab.deferRestore(state: older, url: try rig.server.url("/b"))
            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            #expect(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]), "\(lists(tab))")
        }
    }
}
