// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import CefKit
@testable import WSurf

/// D4-8's service-side behaviours, over raw XPC like `ChromiumServiceBrowserTests` (and gated and serialized like it): what the
/// service asks and tells WSurf about a navigation, and how it keeps its history list honest. `ChromiumOOPPageTests` drives the same
/// through a real page. Run: `Tools/run-chromium-oop-tests.sh ChromiumServiceNavigationTests`.
@Suite(.serialized)
struct ChromiumServiceNavigationTests {
    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/one": .html("<!doctype html><title>One</title><p>one</p>"),
        "/two": .html("<!doctype html><title>Two</title><p>two</p>"),
        "/three": .html("<!doctype html><title>Three</title><p>three</p>"),
        "/form": .html("""
            <!doctype html><title>Form</title><form method="post" action="/posted"><input name="a" value="1"></form>
            <script>addEventListener("load", () => setTimeout(() => document.forms[0].submit(), 50))</script>
            """),
        "/posted": .html("<!doctype html><title>Posted</title><p>posted</p>"),
        "/same": .html("<!doctype html><title>Same</title><p>same</p>"),
    ]

    private struct Rig {
        let client: ChromiumServiceClient
        let server: HTTPFixtureServer

        func url(_ path: String) throws -> String {
            try server.url(path).absoluteString
        }
    }

    private static func rig() async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: routes, waitsForBody: true)
        let client = try ChromiumServiceClient()
        client.hostAnswersQuestions = true
        let reply = try client.hello(linger: nil)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        try client.context("profile")
        return Rig(client: client, server: server)
    }

    private static func open(_ rig: Rig, _ id: Int64, _ path: String) throws {
        let reply = try rig.client.createBrowser(id, url: rig.url(path), context: "profile")
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        #expect(rig.client.waitEvent(CefRemote.Event.browserReady) { $0.browser == id } != nil, "browser.ready")
        #expect(rig.client.waitEvent(CefRemote.Event.loadEnd) { $0.browser == id } != nil, "load.end")
    }

    private func holdHistory(_ rig: Rig, count: Int, delay: Double? = nil) throws {
        let message = CefRemoteMessage(CefRemote.Op.debugHoldHistory, browser: 1)
        message.set(CefRemote.Key.count, count)
        if let delay {
            message.set(CefRemote.Key.value, delay)
        }
        #expect(try rig.client.call(message).bool(CefRemote.Key.success))
    }

    // MARK: What the service asks

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theQuestionCarriesTheMethodTheBodyAndTheTransitionOfTheNavigation() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let posted = try rig.url("/posted")
        try Self.open(rig, 1, "/one")
        try rig.client.load(rig.url("/form"), browser: 1)
        let question = try #require(
            rig.client.waitEvent(CefRemote.Event.beforeBrowse) { $0.string(CefRemote.Key.url) == posted },
            "the form's POST is asked about")
        #expect(question.string(CefRemote.Key.method) == "POST")
        // WSurf's gate stops a replay in another engine on the method alone (and the page proxy counts any method but GET as a body),
        // so the flag is only passed on as CEF reports it: measured, a form's POST reaches `on_before_browse` with no body element.
        #expect(question.has(CefRemote.Key.hasPostData))
        print("ChromiumServiceNavigationTests observed: a form's POST in on_before_browse: post flag \(question.bool(CefRemote.Key.hasPostData))")
        #expect(question.int(CefRemote.Key.transition) & 0xFF == 7, "TT_FORM_SUBMIT")
        #expect(question.string(CefRemote.Key.sourceURL).hasSuffix("/form"), "the page that submitted it")
        let first = try #require(rig.client.events(CefRemote.Event.beforeBrowse).first)
        #expect(first.string(CefRemote.Key.method) == "GET" && !first.bool(CefRemote.Key.hasPostData))
    }

    // MARK: What the service tells (review D1)

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aMailtoNavigationIsCancelledAndWSurfIsToldOnceAtMostThreeTimesInAWindow() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let one = try rig.url("/one")
        try Self.open(rig, 1, "/one")
        try rig.client.load("mailto:first@example.com", browser: 1)
        let told = try #require(rig.client.waitEvent(CefRemote.Event.externalScheme) { $0.browser == 1 })
        #expect(told.string(CefRemote.Key.url) == "mailto:first@example.com")
        #expect(told.bool(CefRemote.Key.isMain))
        #expect(!rig.client.questionURLs.contains("mailto:first@example.com"), "the cancel is the service's own: WSurf is not asked")
        // A page can do this as often as it likes: the rest of a burst is held back.
        for number in 2...9 {
            try rig.client.load("mailto:burst\(number)@example.com", browser: 1)
        }
        let stats = try rig.client.waitStats { $0.int(CefRemote.Key.droppedExternal) >= 6 }
        #expect(stats.int(CefRemote.Key.droppedExternal) == 6, "nine tries, three let through")
        #expect(rig.client.events(CefRemote.Event.externalScheme).count == 3)
        // The page is where it was.
        let cdp = try #require(rig.client.devTools("Page.getNavigationHistory", id: 9, browser: 1))
        let json = try #require(try JSONSerialization.jsonObject(with: cdp.data(CefRemote.Key.data)) as? [String: Any])
        #expect((json["entries"] as? [[String: Any]])?.compactMap { $0["url"] as? String } == [one])
    }

    // MARK: The history list stays honest

    /// Review F5, the case the cache cannot tell apart: the list is unchanged (a reload), the read its commit asked for is slow, and a
    /// collapse arrives meanwhile. Decided on the cache it would be answered at once; the list may be one whose ids moved, so it waits
    /// for the read.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCollapseThatArrivesWhileAReadOfAnUnchangedListIsInFlightWaitsForItsResult() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        try rig.client.load(rig.url("/two"), browser: 1)
        let known = try #require(rig.client.waitHistory { $0.count == 2 && $0[1].isCurrent && $0[1].title == "Two" })
        let ids = known.map(\.id)
        try holdHistory(rig, count: 1, delay: 1.5)
        #expect(try rig.client.command(CefRemote.Op.reload, browser: 1).bool(CefRemote.Key.success))
        // The loading state that starts the reload asks for a read; its result is held back.
        #expect(rig.client.waitEvent(CefRemote.Event.loadingState) { $0.bool(CefRemote.Key.loading) } != nil)
        let started = Date()
        rig.client.send(CefRemoteMessage.collapseHistory(browser: 1, request: 7, keeping: ids[1], ifEntriesAre: ids))
        let outcome = try #require(
            rig.client.waitEvent(CefRemote.Event.historyCollapsed, timeout: 15) { $0.int(CefRemote.Key.identifier) == 7 }?.collapseOutcome)
        #expect(Date().timeIntervalSince(started) > 0.8, "it waited for the slow read (answered after \(Date().timeIntervalSince(started)) s)")
        #expect(outcome == .landed || outcome == .refused, "decided on the fresh list: the same one")
    }

    /// Review F8: a read that never answers (a renderer that went away) must not stop `historyChanged` for good.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHistoryReadThatNeverAnswersEndsAndHistoryChangedGoesOn() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let two = try rig.url("/two")
        try Self.open(rig, 1, "/one")
        _ = try #require(rig.client.waitHistory { $0.count == 1 })
        try holdHistory(rig, count: 1)
        let before = rig.client.historyCount
        try rig.client.load(two, browser: 1)
        let list = try #require(
            rig.client.waitHistory(after: before, timeout: 12) { $0.count == 2 && $0[1].isCurrent && $0[1].url == two },
            "the list reaches WSurf after the held read was given up")
        #expect(list.count == 2)
        let stats = try rig.client.stats()
        #expect(stats.int(CefRemote.Key.historyTimeouts) >= 1, "the service gave up on the read")
    }

    /// Review F5: a collapse that arrives while the cached list may be stale waits for the fresh one and is decided on it. Decided on
    /// the cache it would pass (the cache is [one, two] and `two` is current) and drop real entries.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCollapseThatArrivesWhileTheListIsBeingReadWaitsForTheFreshListAndIsDecidedOnIt() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let three = try rig.url("/three")
        try Self.open(rig, 1, "/one")
        try rig.client.load(rig.url("/two"), browser: 1)
        let known = try #require(rig.client.waitHistory { $0.count == 2 && $0[1].isCurrent && $0[1].title == "Two" })
        let ids = known.map(\.id)
        // The read the next commit asks for is answered a second and a half late.
        try holdHistory(rig, count: 1, delay: 1.5)
        try rig.client.load(three, browser: 1)
        // The commit is out, so a read of the list is in flight (its result held back).
        #expect(rig.client.waitEvent(CefRemote.Event.address) { $0.string(CefRemote.Key.url) == three } != nil)
        rig.client.send(CefRemoteMessage.collapseHistory(browser: 1, request: 5, keeping: ids[1], ifEntriesAre: ids))
        let started = Date()
        let outcome = try #require(
            rig.client.waitEvent(CefRemote.Event.historyCollapsed, timeout: 12) { $0.int(CefRemote.Key.identifier) == 5 }?.collapseOutcome)
        #expect(outcome == .skipped, "the list has grown past [one, two]: decided on the fresh list, not on the stale one")
        #expect(Date().timeIntervalSince(started) > 0.3, "it waited for the read, it was not answered at once")
        let cdp = try #require(rig.client.devTools("Page.getNavigationHistory", id: 9, browser: 1))
        let json = try #require(try JSONSerialization.jsonObject(with: cdp.data(CefRemote.Key.data)) as? [String: Any])
        #expect((json["entries"] as? [[String: Any]])?.count == 3, "nothing was dropped")
    }

    /// A parked collapse whose read never comes is answered `refused` when the service gives the read up, so that its caller can
    /// ask again; it is not held for ever, and it is not answered before the read has had its time.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCollapseParkedBehindAReadThatNeverAnswersIsRefusedWhenTheReadIsGivenUp() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        try rig.client.load(rig.url("/two"), browser: 1)
        let known = try #require(rig.client.waitHistory { $0.count == 2 && $0[1].isCurrent && $0[1].title == "Two" })
        let ids = known.map(\.id)
        try holdHistory(rig, count: 1)
        try rig.client.load(rig.url("/three"), browser: 1)
        #expect(rig.client.waitEvent(CefRemote.Event.address) { $0.string(CefRemote.Key.url).hasSuffix("/three") } != nil)
        rig.client.send(CefRemoteMessage.collapseHistory(browser: 1, request: 6, keeping: ids[1], ifEntriesAre: ids))
        #expect(rig.client.waitEvent(CefRemote.Event.historyCollapsed, timeout: 1) { $0.int(CefRemote.Key.identifier) == 6 } == nil,
                "not refused at once: it waits for the read")
        let outcome = rig.client.waitEvent(CefRemote.Event.historyCollapsed, timeout: 12) { $0.int(CefRemote.Key.identifier) == 6 }?.collapseOutcome
        #expect(outcome == .refused)
    }

    /// Review F9: Back from one entry to another of the same address, where both Back and Forward stay possible, changes neither the
    /// loading state nor the address.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBackBetweenEntriesOfOneAddressRefreshesTheList() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let same = try rig.url("/same")
        try Self.open(rig, 1, "/same")
        // Three entries made by the page, each with a user activation (the history-manipulation intervention would otherwise make Back
        // skip them): `userGesture` is DevTools', not synthetic system input.
        for step in 0..<3 {
            let pushed = try #require(rig.client.devTools(
                "Runtime.evaluate", params: #"{"expression":"history.pushState({n:\#(step)}, '', location.href)","userGesture":true}"#,
                id: 30 + Int64(step), browser: 1))
            #expect(pushed.bool(CefRemote.Key.success))
        }
        let list = try #require(rig.client.waitHistory { $0.count == 4 && $0[3].isCurrent }, "three pushState entries after the page's own")
        #expect(Set(list.map(\.url)) == [same], "one address in every entry")
        for expectedCurrent in [2, 1] {
            let before = rig.client.historyCount
            let back = try rig.client.command(CefRemote.Op.goBack, browser: 1)
            #expect(back.bool(CefRemote.Key.success), "\(back.string(CefRemote.Key.error))")
            let moved = rig.client.waitHistory(after: before, timeout: 6) { $0.count == 4 && $0[expectedCurrent].isCurrent }
            #expect(moved != nil, "the list says the current entry is \(expectedCurrent) after Back")
        }
    }
}
