// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
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

        func record(_ request: HTTPFixtureServer.Request) {
            guard request.path != "/favicon.ico" else { return }
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
