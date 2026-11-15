// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import CefKit
@testable import WSurf

/// D4-4b: windowless browsers in the Chromium service, driven over raw XPC (`ChromiumServiceClient`; WSurf's own client is D4-5).
/// Pages come from a fixture server on 127.0.0.1. Like `ChromiumServiceHostTests`, every test needs `WSurf Chromium.xpc` (the OOP
/// lane: `Tools/run-chromium-oop-tests.sh ChromiumServiceBrowserTests`), is serialized, and ends by waiting for its service
/// instance to leave. No frames are checked (D4-7), no input (phase 3), no geometry change (D4-9).
@Suite(.serialized)
struct ChromiumServiceBrowserTests {
    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/one": .html("<!doctype html><title>One</title><p>one</p>"),
        "/two": .html("<!doctype html><title>Two</title><p>two</p>"),
        "/three": .html("<!doctype html><title>Three</title><p>three</p>"),
        "/form": .html("""
            <!doctype html><title>Form</title><form method="post" action="/posted"><input name="a" value="1"></form>
            <script>addEventListener("load", () => setTimeout(() => document.forms[0].submit(), 50))</script>
            """),
        "/posted": .html("<!doctype html><title>Posted</title><p>posted</p>"),
        "/find": .html("<!doctype html><title>Find</title><p>needle one, needle two</p>"),
        "/frame": .html("<!doctype html><title>Frame</title><p>frame</p>"),
        "/parent": .html("<!doctype html><title>Parent</title><iframe src=\"/frame\"></iframe>"),
    ]

    /// A started service with one request context, and a fixture server. `answers`: whether this host lets navigations go ahead.
    private struct Rig {
        let client: ChromiumServiceClient
        let server: HTTPFixtureServer

        func url(_ path: String) throws -> String {
            try server.url(path).absoluteString
        }
    }

    private static func rig(answers: Bool = true, linger: Double? = nil) async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: routes, waitsForBody: true)
        let client = try ChromiumServiceClient()
        client.hostAnswersQuestions = answers
        let reply = try client.hello(linger: linger)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        try client.context("profile")
        return Rig(client: client, server: server)
    }

    /// A browser opened on `path`, ready and finished loading it.
    private static func open(_ rig: Rig, _ id: Int64, _ path: String) throws {
        let reply = try rig.client.createBrowser(id, url: rig.url(path), context: "profile")
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        #expect(rig.client.waitEvent(CefRemote.Event.browserReady) { $0.browser == id } != nil, "browser.ready")
        #expect(rig.client.waitEvent(CefRemote.Event.loadEnd) { $0.browser == id } != nil, "load.end")
    }

    // MARK: Create, load, state

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserCreatedWithAURLLoadsItAndLoadEndCarriesTheURLAndTheTitle() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let one = try rig.url("/one")
        try Self.open(rig, 1, "/one")
        let end = try #require(rig.client.waitEvent(CefRemote.Event.loadEnd) { $0.browser == 1 })
        #expect(end.string(CefRemote.Key.url) == one)
        #expect(end.string(CefRemote.Key.title) == "One")
        #expect(end.int(CefRemote.Key.status) == 200)
        // The state is pushed with the events (plan §1.5): the address, the title, and a loading state that ended.
        #expect(rig.client.waitEvent(CefRemote.Event.address) { $0.browser == 1 && $0.string(CefRemote.Key.url) == one } != nil)
        #expect(rig.client.waitEvent(CefRemote.Event.title) { $0.browser == 1 && $0.string(CefRemote.Key.title) == "One" } != nil)
        #expect(rig.client.waitEvent(CefRemote.Event.loadingState) { $0.browser == 1 && !$0.bool(CefRemote.Key.loading) } != nil)
        // WSurf was asked about the navigation before it went ahead (on_before_browse).
        #expect(rig.client.questionURLs.contains(one))
        let stats = try rig.client.stats()
        #expect(stats.int(CefRemote.Key.count) == 1)
        #expect(stats.int(CefRemote.Key.browserObjects) == 1)
        #expect(stats.int(CefRemote.Key.handlerSets) == 1)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCDPRuntimeEvaluateRoundTripIsForwardedAndItsEventsToo() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        let result = try #require(rig.client.devTools("Runtime.evaluate", params: #"{"expression":"1 + 2","returnByValue":true}"#, id: 7, browser: 1))
        #expect(result.bool(CefRemote.Key.success))
        let json = try #require(try JSONSerialization.jsonObject(with: result.data(CefRemote.Key.data)) as? [String: Any])
        let value = try #require((json["result"] as? [String: Any])?["value"] as? Int)
        #expect(value == 3)
        // A CDP event arrives on the same stream, with its method and parameters.
        let enable = try #require(rig.client.devTools("Runtime.enable", id: 8, browser: 1))
        #expect(enable.bool(CefRemote.Key.success))
        let event = rig.client.waitEvent(CefRemote.Event.devToolsEvent) { $0.string(CefRemote.Key.method) == "Runtime.executionContextCreated" }
        #expect(event != nil, "a CDP event is forwarded")
        // A page controls what its scripts return: a value that contains the word `sessionId` unescaped (a nested object) must
        // not make the service take the message as a cross-site frame session's. It is the page's own result, so it arrives as one.
        let nested = try #require(rig.client.devTools("Runtime.evaluate", params: #"{"expression":"({sessionId: 'x'})","returnByValue":true}"#, id: 9, browser: 1))
        #expect(nested.bool(CefRemote.Key.success))
        let nestedJSON = try #require(try JSONSerialization.jsonObject(with: nested.data(CefRemote.Key.data)) as? [String: Any])
        #expect(((nestedJSON["result"] as? [String: Any])?["value"] as? [String: Any])?["sessionId"] as? String == "x")
        #expect(rig.client.events(CefRemote.Event.devToolsMessage).isEmpty, "a page's own message is not diverted as a session's")
        // The service's own commands are not WSurf's: an id from the service's range is never answered as WSurf's.
        let ids = rig.client.events(CefRemote.Event.devToolsResult).map { $0.int(CefRemote.Key.identifier) }
        #expect(ids.allSatisfy { $0 < CefRemote.serviceCommandBase }, "the service's history reads stay inside the service: \(ids)")
    }

    // MARK: Scheme allowlist (review F1)

    @Test
    func theServiceAndWSurfApplyOneSchemeAllowlist() throws {
        for scheme in ["http", "https", "file", "about", "data", "blob", "chrome-extension", "HTTPS"] {
            #expect(CefRemote.allowsNavigation(to: try #require(URL(string: "\(scheme)://x/y"))), "\(scheme)")
        }
        for url in ["chrome://version", "ftp://127.0.0.1/x", "view-source:https://x/", "javascript:alert(1)", "mailto:a@b", "x-wsurf://x"] {
            #expect(!CefRemote.allowsNavigation(to: try #require(URL(string: url))), "\(url)")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aNavigationToASchemeOutsideTheAllowlistIsCancelledInTheServiceEvenWhenTheHostAnswersYes() async throws {
        let rig = try await Self.rig(answers: true)
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        let one = try rig.url("/one")
        let loadEnds = rig.client.events(CefRemote.Event.loadEnd).count
        let refused = try rig.client.stats().int(CefRemote.Key.refusedNavigations)
        // Main frame: the host would say yes to anything, and is not even asked.
        try rig.client.load("chrome://version", browser: 1)
        let afterMain = try rig.client.waitStats { $0.int(CefRemote.Key.refusedNavigations) > refused }
        #expect(afterMain.int(CefRemote.Key.refusedNavigations) > refused, "the service cancelled the chrome:// navigation itself")
        #expect(!rig.client.questionURLs.contains("chrome://version"), "a disallowed scheme costs no round trip")
        // Sub-frames: the page's iframe is navigated by the browser (CDP `Page.navigate` with the frame's id) to a scheme outside the list.
        let parent = try rig.url("/parent")
        try rig.client.load(parent, browser: 1)
        #expect(rig.client.waitEvent(CefRemote.Event.loadEnd) { $0.browser == 1 && $0.string(CefRemote.Key.url) == parent } != nil)
        let frameTree = try #require(rig.client.devTools("Page.getFrameTree", id: 20, browser: 1))
        let tree = try #require(try JSONSerialization.jsonObject(with: frameTree.data(CefRemote.Key.data)) as? [String: Any])
        let children = (tree["frameTree"] as? [String: Any])?["childFrames"] as? [[String: Any]]
        let childID = try #require((children?.first?["frame"] as? [String: Any])?["id"] as? String, "the parent page has an iframe")
        // The iframe's own load (an allowed scheme) was not asked about: sub-frames with an allowed scheme are unchanged (D4-8 decides).
        #expect(rig.server.lastRequestHead(for: "/frame") != nil, "a sub-frame with an allowed scheme still loads")
        #expect(!rig.client.questionURLs.contains(try rig.url("/frame")), "and is not asked about")
        let beforeFrame = try rig.client.stats().int(CefRemote.Key.refusedNavigations)
        #expect(beforeFrame == afterMain.int(CefRemote.Key.refusedNavigations), "nothing else was refused so far")
        // Chromium decides by itself which of these it hands to the browser's navigation gate; every one that gets there is refused.
        for (offset, target) in ["ftp://127.0.0.1:9/blocked-frame", "chrome://version"].enumerated() {
            _ = rig.client.devTools("Page.navigate", params: #"{"url":"\#(target)","frameId":"\#(childID)"}"#, id: 21 + Int64(offset), browser: 1)
        }
        let afterFrame = try rig.client.waitStats { $0.int(CefRemote.Key.refusedNavigations) > beforeFrame }
        #expect(afterFrame.int(CefRemote.Key.refusedNavigations) > beforeFrame, "a sub-frame's navigation to a scheme outside the list was cancelled in the service")
        #expect(!rig.client.questionURLs.contains { $0.hasPrefix("ftp:") || $0.hasPrefix("chrome:") }, "and not asked about, though the host answers yes")
        // Nothing of the cancelled main-frame navigation loaded: every load.end since is the parent's.
        let ends = rig.client.events(CefRemote.Event.loadEnd).dropFirst(loadEnds).map { $0.string(CefRemote.Key.url) }
        #expect(ends.allSatisfy { $0 == parent }, "load.end for \(ends) (the page before was \(one))")
    }

    // MARK: History

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func twoNavigationsGiveHistoryChangedWithTwoEntriesAndStableIDsThatBackAndForwardKeep() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let one = try rig.url("/one")
        let two = try rig.url("/two")
        try Self.open(rig, 1, "/one")
        try rig.client.load(two, browser: 1)
        let list = try #require(
            rig.client.waitHistory { $0.count == 2 && $0[1].isCurrent && $0[1].url == two && !$0[1].title.isEmpty && !$0[0].title.isEmpty },
            "historyChanged with both entries, the second current")
        #expect(list.map(\.url) == [one, two])
        #expect(list.map(\.title) == ["One", "Two"])
        #expect(list.map(\.isCurrent) == [false, true])
        #expect(list.allSatisfy { !$0.hasPostData })
        #expect(list[0].id != list[1].id && list[0].id > 0 && list[1].id > 0)
        // The ids are Chromium's own: the ones CDP gives the same list (what `Page.navigateToHistoryEntry` takes).
        let cdp = try #require(rig.client.devTools("Page.getNavigationHistory", id: 9, browser: 1))
        let json = try #require(try JSONSerialization.jsonObject(with: cdp.data(CefRemote.Key.data)) as? [String: Any])
        let cdpIDs = (json["entries"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }
        #expect(cdpIDs == list.map { Int($0.id) })
        // WSurf's mirror says what native history can do.
        #expect(rig.client.waitEvent(CefRemote.Event.loadingState) { $0.bool(CefRemote.Key.canGoBack) && !$0.bool(CefRemote.Key.canGoForward) } != nil)
        // Back and forward keep the ids. At the first entry there is no native Back: the reply says so (WSurf makes its own hop).
        let before = rig.client.events(CefRemote.Event.historyChanged).count
        let back = try rig.client.command(CefRemote.Op.goBack, browser: 1)
        #expect(back.bool(CefRemote.Key.success), "\(back.string(CefRemote.Key.error))")
        let moved = try #require(rig.client.waitHistory(after: before) { $0.count == 2 && $0[0].isCurrent })
        #expect(moved.map(\.id) == list.map(\.id), "the ids survive Back")
        let none = try rig.client.command(CefRemote.Op.goBack, browser: 1)
        #expect(!none.bool(CefRemote.Key.success))
        #expect(none.string(CefRemote.Key.error) == CefRemote.noNativeEntry)
        let beforeForward = rig.client.historyCount
        let forward = try rig.client.command(CefRemote.Op.goForward, browser: 1)
        #expect(forward.bool(CefRemote.Key.success))
        // Only a list that arrives after the Forward can answer for it (the list from before Back is the same one).
        let again = try #require(rig.client.waitHistory(after: beforeForward) { $0.count == 2 && $0[1].isCurrent })
        #expect(again.map(\.id) == list.map(\.id), "the ids survive Forward")
        let end = try rig.client.command(CefRemote.Op.goForward, browser: 1)
        #expect(end.string(CefRemote.Key.error) == CefRemote.noNativeEntry)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anEntryMadeByAPostIsMarkedAndTheOthersAreNot() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let posted = try rig.url("/posted")
        try Self.open(rig, 1, "/one")
        try rig.client.load(rig.url("/form"), browser: 1)
        let list = try #require(rig.client.waitHistory { $0.count == 3 && $0[2].url == posted && $0[2].isCurrent }, "the form's POST is an entry")
        #expect(list.map(\.hasPostData) == [false, false, true], "has_post_data comes from CEF's visitor, entry by entry")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func collapseHistoryIsLandedWhenTheListMatchesAndRefusedOrSkippedWhenItDoesNot() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        // Three real pages: [one, two, three]. (What a browser made on about:blank holds is `aPageLoadedOverAboutBlank...`.)
        let three = try rig.url("/three")
        try Self.open(rig, 1, "/one")
        try rig.client.load(rig.url("/two"), browser: 1)
        _ = try #require(rig.client.waitHistory { $0.count == 2 && $0[1].isCurrent && $0[1].title == "Two" })
        try rig.client.load(three, browser: 1)
        let list = try #require(rig.client.waitHistory { $0.count == 3 && $0[2].isCurrent && $0[2].url == three })
        let ids = list.map(\.id)

        func collapse(_ request: Int64, keeping: Int64, expected: [Int64]) throws -> CefRemote.CollapseOutcome? {
            rig.client.send(CefRemoteMessage.collapseHistory(browser: 1, request: request, keeping: keeping, ifEntriesAre: expected))
            return rig.client.waitEvent(CefRemote.Event.historyCollapsed) { $0.int(CefRemote.Key.identifier) == request }?.collapseOutcome
        }
        // Not the list the caller expects: nothing changes. (The ids the caller expects include one Chromium never had.)
        #expect(try collapse(1, keeping: ids[2], expected: ids + [ids[2] + 1_000_000]) == .refused)
        // The list has grown past what the caller expected: skipped, nothing to retry.
        #expect(try collapse(2, keeping: ids[1], expected: [ids[0], ids[1]]) == .skipped)
        let cdp = try #require(rig.client.devTools("Page.getNavigationHistory", id: 9, browser: 1))
        let unchanged = try #require(try JSONSerialization.jsonObject(with: cdp.data(CefRemote.Key.data)) as? [String: Any])
        #expect((unchanged["entries"] as? [[String: Any]])?.compactMap { $0["id"] as? Int } == ids.map(Int.init), "a refused or skipped collapse changes nothing")
        // The list is the expected one and the kept entry is current: the reset goes through. Chromium may refuse it while the
        // first commit still swaps renderers, which is the caller's retry (as `ChromiumPage` does today).
        var outcome: CefRemote.CollapseOutcome?
        let beforeLanding = rig.client.historyCount
        for attempt in 0..<8 where outcome != .landed {
            outcome = try collapse(10 + Int64(attempt), keeping: ids[2], expected: ids)
            if outcome != .landed {
                usleep(300_000)
            }
        }
        #expect(outcome == .landed)
        let collapsed = try #require(rig.client.waitHistory(after: beforeLanding) { $0.count == 1 })
        #expect(collapsed[0].id == ids[2] && collapsed[0].isCurrent && collapsed[0].url == three, "only the kept entry is left")
        // With nothing left to drop, the same request is answered `landed` without a reset.
        #expect(try collapse(99, keeping: ids[2], expected: ids) == .landed)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aPageLoadedOverAboutBlankIsTheCurrentEntryOfTheHistory() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        // WSurf's tabs start on about:blank. Whether Chromium keeps that entry or replaces it is Chromium's to say (D4-8 meets it
        // as the startup entry): this records what it does, and checks only what holds either way.
        let one = try rig.url("/one")
        #expect(try rig.client.createBrowser(1, url: "about:blank", context: "profile").bool(CefRemote.Key.success))
        #expect(rig.client.waitEvent(CefRemote.Event.browserReady) { $0.browser == 1 } != nil)
        try rig.client.load(one, browser: 1)
        let list = try #require(rig.client.waitHistory { $0.last?.url == one && $0.last?.isCurrent == true && $0.last?.title == "One" })
        #expect(list.filter(\.isCurrent).count == 1)
        #expect(Set(list.map(\.id)).count == list.count, "the ids are distinct")
        print("ChromiumServiceBrowserTests observed: about:blank then /one gives \(list.count) entries: \(list.map(\.url))")
    }

    // MARK: Mute and find

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func muteReportsTheStateCEFHasAndFindReportsItsMatches() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/find")
        let muted = try rig.client.command(CefRemote.Op.mute, browser: 1) { $0.set(CefRemote.Key.flag, true) }
        #expect(muted.bool(CefRemote.Key.success))
        let change = try #require(rig.client.waitEvent(CefRemote.Event.muteChanged) { $0.browser == 1 })
        #expect(change.bool(CefRemote.Key.muted), "the event carries what CEF reports after the change")
        let found = try rig.client.command(CefRemote.Op.find, browser: 1) {
            $0.set(CefRemote.Key.text, "needle")
            $0.set(CefRemote.Key.forward, true)
            $0.set(CefRemote.Key.matchCase, false)
            $0.set(CefRemote.Key.findNext, false)
        }
        #expect(found.bool(CefRemote.Key.success))
        let result = rig.client.waitEvent(CefRemote.Event.findResult) { $0.browser == 1 && $0.bool(CefRemote.Key.final) && $0.int(CefRemote.Key.count) == 2 }
        #expect(result != nil, "find.result with both matches")
        #expect(try rig.client.command(CefRemote.Op.stopFinding, browser: 1) { $0.set(CefRemote.Key.flag, true) }.bool(CefRemote.Key.success))
    }

    // MARK: Handler lifetime

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aClosedBrowserFreesItsObjectAndItsHandlers() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        #expect(try rig.client.stats().int(CefRemote.Key.handlerSets) == 1)
        try rig.client.closeBrowser(1)
        let stats = try rig.client.waitStats { $0.int(CefRemote.Key.browserObjects) == 0 && $0.int(CefRemote.Key.handlerSets) == 0 }
        #expect(stats.int(CefRemote.Key.count) == 0)
        #expect(stats.int(CefRemote.Key.browserObjects) == 0, "the browser object is freed after a normal close")
        #expect(stats.int(CefRemote.Key.handlerSets) == 0, "the client's handlers are freed once CEF has destroyed the client")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserClosedBeforeCEFMadeItFreesEverything() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        // CEF is never asked (the DEBUG `hold`): the browser cannot reach on_after_created, so only the close frees it.
        let held = try rig.client.createBrowser(1, url: rig.url("/one"), context: "profile", debug: CefRemote.DebugCreate.hold)
        #expect(held.bool(CefRemote.Key.success))
        let alive = try rig.client.stats()
        #expect(alive.int(CefRemote.Key.browserObjects) == 1 && alive.int(CefRemote.Key.handlerSets) == 1)
        try rig.client.closeBrowser(1)
        let stats = try rig.client.waitStats { $0.int(CefRemote.Key.browserObjects) == 0 && $0.int(CefRemote.Key.handlerSets) == 0 }
        #expect(stats.int(CefRemote.Key.count) == 0)
        #expect(stats.int(CefRemote.Key.browserObjects) == 0, "a close before creation frees the browser")
        #expect(stats.int(CefRemote.Key.handlerSets) == 0, "and its handlers")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aRealBrowserClosedRightAfterItWasAskedForIsClosedWhenCEFHasMadeIt() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let created = try rig.client.createBrowser(1, url: rig.url("/one"), context: "profile")
        #expect(created.bool(CefRemote.Key.success))
        rig.client.send(CefRemoteMessage(CefRemote.Op.close, browser: 1))
        #expect(rig.client.waitEvent(CefRemote.Event.browserClosed) { $0.browser == 1 } != nil, "browser.closed")
        let stats = try rig.client.waitStats { $0.int(CefRemote.Key.browserObjects) == 0 && $0.int(CefRemote.Key.handlerSets) == 0 }
        #expect(stats.int(CefRemote.Key.count) == 0)
        #expect(stats.int(CefRemote.Key.browserObjects) == 0)
        #expect(stats.int(CefRemote.Key.handlerSets) == 0)
    }

    /// The test above with its race always lost: the close is taken before CEF has made the browser (the DEBUG `closeFirst`), as
    /// happens to the first browser of a fresh disk context. CEF goes on using the browser after `on_after_created` returns, so
    /// a close made inside that callback crashed the service (`AlloyBrowserHostImpl::CreateInternal`, a null platform
    /// delegate); the service then ends, and `stats` says so. Three in a row, in one instance.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserWhoseCloseCameBeforeCEFMadeItIsClosedWithoutCrashingTheService() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        for id in Int64(1) ... 3 {
            let created = try rig.client.createBrowser(id, url: rig.url("/one"), context: "profile", debug: CefRemote.DebugCreate.closeFirst)
            #expect(created.bool(CefRemote.Key.success))
            #expect(rig.client.waitEvent(CefRemote.Event.browserClosed) { $0.browser == id } != nil, "browser.closed \(id)")
            let stats = try rig.client.waitStats { $0.int(CefRemote.Key.browserObjects) == 0 && $0.int(CefRemote.Key.handlerSets) == 0 }
            #expect(stats.int(CefRemote.Key.count) == 0)
            #expect(stats.int(CefRemote.Key.browserObjects) == 0)
            #expect(stats.int(CefRemote.Key.handlerSets) == 0)
        }
        // The service still makes browsers.
        try Self.open(rig, 4, "/one")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCreationThatFailsFreesEverythingAndTellsWSurf() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        // The DEBUG `fail` runs the real failure path (CEF refusing the request) without calling CEF.
        let failed = try rig.client.createBrowser(1, url: rig.url("/one"), context: "profile", debug: CefRemote.DebugCreate.fail)
        #expect(!failed.bool(CefRemote.Key.success))
        #expect(!failed.string(CefRemote.Key.error).isEmpty)
        #expect(rig.client.waitEvent(CefRemote.Event.browserClosed) { $0.browser == 1 } != nil, "WSurf hears that there will be no browser")
        let stats = try rig.client.waitStats { $0.int(CefRemote.Key.browserObjects) == 0 && $0.int(CefRemote.Key.handlerSets) == 0 }
        #expect(stats.int(CefRemote.Key.count) == 0, "the failed browser is not left open")
        #expect(stats.int(CefRemote.Key.browserObjects) == 0, "the browser of a failed creation is freed")
        #expect(stats.int(CefRemote.Key.handlerSets) == 0, "and so are its handlers")
        // The id is free again, and the service still makes browsers.
        try Self.open(rig, 1, "/one")
    }

    // MARK: Create and CDP refusals (review F2, F3)

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCreateWithAnIdThatIsOpenIsRefusedAndTheOpenBrowserIsUntouched() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        let two = try rig.url("/two")
        let refused = try rig.client.createBrowser(1, url: two, context: "profile")
        #expect(!refused.bool(CefRemote.Key.success))
        #expect(refused.string(CefRemote.Key.error) == "a browser with this id is open")
        // Events and the reply travel in order on one connection: a `browser.closed` the refusal had sent is here already.
        #expect(rig.client.events(CefRemote.Event.browserClosed).isEmpty, "WSurf is not told that the open browser closed")
        let stats = try rig.client.stats()
        #expect(stats.int(CefRemote.Key.count) == 1 && stats.int(CefRemote.Key.browserObjects) == 1 && stats.int(CefRemote.Key.handlerSets) == 1)
        // It is the same browser, still working: a load goes through and is its own.
        try rig.client.load(two, browser: 1)
        #expect(rig.client.waitEvent(CefRemote.Event.loadEnd) { $0.browser == 1 && $0.string(CefRemote.Key.url) == two } != nil)
        #expect(rig.client.events(CefRemote.Event.browserClosed).isEmpty)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHostCDPCommandInTheServicesOwnIdRangeIsRefusedAndTheServicesHistoryReadsStillWork() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        // The service's first command id is exactly the base: a host command with it would be taken for the history read.
        for id in [CefRemote.serviceCommandBase, CefRemote.serviceCommandBase + 7] {
            let before = rig.client.events(CefRemote.Event.devToolsResult).count
            let result = try #require(rig.client.devTools("Runtime.evaluate", params: #"{"expression":"1 + 2"}"#, id: id, browser: 1), "an answer for \(id)")
            #expect(!result.bool(CefRemote.Key.success), "id \(id) is the service's")
            #expect(rig.client.events(CefRemote.Event.devToolsResult).count == before + 1, "one refusal, and nothing else for id \(id)")
        }
        // The history read is intact: a navigation still produces its list.
        let two = try rig.url("/two")
        try rig.client.load(two, browser: 1)
        #expect(rig.client.waitHistory { $0.count == 2 && $0[1].isCurrent && $0[1].url == two } != nil)
        // An id below the range is the host's as before.
        let fine = try #require(rig.client.devTools("Runtime.evaluate", params: #"{"expression":"1 + 2","returnByValue":true}"#, id: CefRemote.serviceCommandBase - 1, browser: 1))
        #expect(fine.bool(CefRemote.Key.success))
    }

    // MARK: Ask the host

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anOnBeforeBrowseThatWSurfDoesNotAnswerCancelsTheNavigationWithinOneAndAHalfSeconds() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        // A browser made on about:blank, with a host that answers; then it stops answering.
        #expect(try rig.client.createBrowser(1, url: "about:blank", context: "profile").bool(CefRemote.Key.success))
        #expect(rig.client.waitEvent(CefRemote.Event.browserReady) { $0.browser == 1 } != nil)
        _ = try rig.client.waitStats { $0.int(CefRemote.Key.count) == 1 }
        rig.client.hostAnswersQuestions = false
        let asked = rig.client.questionsAsked
        let load = CefRemoteMessage(CefRemote.Op.load, browser: 1)
        load.set(CefRemote.Key.url, try rig.url("/one"))
        rig.client.send(load)
        let deadline = Date().addingTimeInterval(10)
        while rig.client.questionsAsked == asked, Date() < deadline {
            usleep(10_000)
        }
        #expect(rig.client.questionsAsked > asked, "the service asks WSurf before it navigates")
        // The service's main thread waits for the answer, so a request sent now is served only when the wait ends: its round
        // trip is the length of the wait, which the plan caps at one second.
        let began = Date()
        _ = try rig.client.stats()
        let waited = Date().timeIntervalSince(began)
        #expect(waited <= 1.5, "the wait on a host that never answers took \(waited) s")
        // The navigation was cancelled: the page was never requested, and the browser is still the blank page's.
        usleep(1_500_000)
        #expect(rig.server.lastRequestHead(for: "/one") == nil, "a cancelled navigation must not reach the network")
        #expect(rig.client.events(CefRemote.Event.loadEnd).allSatisfy { $0.string(CefRemote.Key.url) != (try? rig.url("/one")) })
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theQuestionGoesToTheControlConnectionAndNotToAnotherOne() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        let observer = try ChromiumServiceClient(root: rig.client.root)
        defer { observer.close() }
        observer.hostAnswersQuestions = true
        _ = try observer.stats()
        try Self.open(rig, 1, "/one")
        #expect(rig.client.questionsAsked >= 1)
        #expect(observer.questionsAsked == 0, "the control connection is the one asked (F8)")
        #expect(observer.events(CefRemote.Event.loadEnd).isEmpty, "events go to the control connection only")
    }

    // MARK: One host, leaving, side connections

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aSecondConnectionCannotCreateOrDriveBrowsers() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        let intruder = try ChromiumServiceClient(root: rig.client.root)
        defer { intruder.close() }
        let refused = try intruder.createBrowser(2, url: rig.url("/two"))
        #expect(!refused.bool(CefRemote.Key.success))
        let load = try intruder.command(CefRemote.Op.load, browser: 1) { $0.set(CefRemote.Key.url, "about:blank") }
        #expect(load.string(CefRemote.Key.error) == "not the host")
        let script = try intruder.command(CefRemote.Op.devTools, browser: 1) { $0.set(CefRemote.Key.data, data: Data(#"{"id":1,"method":"Browser.close"}"#.utf8)) }
        #expect(script.string(CefRemote.Key.error) == "not the host")
        let stats = try rig.client.stats()
        #expect(stats.int(CefRemote.Key.count) == 1)
        #expect(rig.client.events(CefRemote.Event.browserClosed).isEmpty, "the first host's browser is untouched")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserOpIsRefusedWhileTheServiceIsLeaving() async throws {
        // A linger of 1 s and a context (so the exit waits half a second for the cookie flush): the window in which the service has
        // begun to leave and still answers is about half a second wide, and the probe asks every 50 ms.
        let rig = try await Self.rig(linger: 1)
        defer { rig.client.finish() }
        let pid = try #require(rig.client.pid)
        var refusal: String?
        let deadline = Date().addingTimeInterval(4)
        // The probe stops at the first failure: a message sent to a service that has gone would start a new, un-helloed instance.
        while refusal == nil, Date() < deadline, kill(pid, 0) == 0 {
            guard let reply = try? rig.client.command(CefRemote.Op.load, browser: 99, { $0.set(CefRemote.Key.url, "about:blank") }) else { break }
            if reply.string(CefRemote.Key.error).contains("leaving") {
                refusal = reply.string(CefRemote.Key.error)
            }
            usleep(50_000)
        }
        #expect(refusal != nil, "an op sent while the service is leaving is refused, not served")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theInputAndFramesConnectionsAreAcceptedOnlyAfterAHelloAndOnlyFromTheHostsProcess() async throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        let early = try ChromiumServiceClient(root: client.root)
        defer { early.close() }
        // Before any hello there is no host for them to belong to.
        let before = try early.call(CefRemoteMessage(CefRemote.Op.inputHello))
        #expect(!before.bool(CefRemote.Key.success))
        #expect(try early.call(CefRemoteMessage(CefRemote.Op.framesHello)).bool(CefRemote.Key.success) == false)
        #expect(try client.hello().bool(CefRemote.Key.success))
        // The host's own process (this test host, for every connection here) may attach them; the control connection itself may not.
        let side = try ChromiumServiceClient(root: client.root)
        defer { side.close() }
        #expect(try side.call(CefRemoteMessage(CefRemote.Op.inputHello)).bool(CefRemote.Key.success))
        #expect(try side.call(CefRemoteMessage(CefRemote.Op.framesHello)).bool(CefRemote.Key.success))
        #expect(try client.call(CefRemoteMessage(CefRemote.Op.inputHello)).bool(CefRemote.Key.success) == false)
    }

    // MARK: Closing everything

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func closingTheControlConnectionClosesRealBrowsersAndTheServiceLeavesWithinFourSeconds() async throws {
        let rig = try await Self.rig()
        defer { rig.client.finish() }
        try Self.open(rig, 1, "/one")
        try Self.open(rig, 2, "/two")
        let pid = try #require(rig.client.pid)
        let closed = Date()
        rig.client.close()
        let took = try #require(ChromiumServiceClient.secondsUntilGone(pid, within: 4), "open browsers kept the service up past its cap")
        print("ChromiumServiceBrowserTests observed: two real browsers, control closed, service gone after \(Date().timeIntervalSince(closed)) s (\(took) s polling)")
    }
}
