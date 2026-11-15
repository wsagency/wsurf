// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

/// D4-8: a `ChromiumPage` whose browser lives in the Chromium service (`ChromiumRemoteBrowser`): the mirrored state, the setters as
/// messages, CDP over the control connection, and the page's own sequences (startup, close, the service ending).
///
/// The first group needs no service: the page is given a browser whose messages go to a recorder (`outgoing`), and the test plays
/// the service's events (`remoteEvent`). It runs in the default lane. The second group (gated per test on
/// `ChromiumServiceBundle.isPresent`) drives real pages through the service, in the OOP lane:
/// `Tools/run-chromium-oop-tests.sh ChromiumOOPPageTests`. That invocation must hold no in-process Chromium suite: the process
/// latches out of process at its first Chromium start (`ChromiumOOP.Latch`), and in-process Chromium is refused from then on.
@MainActor
@Suite(.serialized)
struct ChromiumOOPPageTests {
    init() {
        #if DEBUG
        // Before any Chromium start of this host: the process latches out of process when the service is present (the OOP lane),
        // and no test that happens to run first can latch it in process. Without the service the override changes nothing.
        ChromiumOOP.testOverride = true
        #endif
    }

    // MARK: A page with a recorded browser (no service)

    /// What the page sent to its browser, in order.
    final class Recorder {
        var messages: [CefRemoteMessage] = []

        var ops: [String] {
            messages.map(\.op)
        }

        func sent(_ op: String) -> [CefRemoteMessage] {
            messages.filter { $0.op == op }
        }
    }

    struct Rig {
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let remote: ChromiumRemoteBrowser
        let recorder: Recorder
        /// A client of its own: its connection is never opened (nothing is sent through it).
        let connection: ChromiumRemote

        /// The service's side of the conversation: an event of this browser.
        func event(_ op: String, _ fill: (CefRemoteMessage) -> Void = { _ in }) {
            let message = CefRemoteMessage(op, browser: remote.id)
            fill(message)
            remote.remoteEvent(message)
        }

        func end() async {
            connection.disconnect()
            await page.close()
            await context.endPrivateSession()
        }
    }

    private func makeRig(created: Bool = true) -> Rig {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-page-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        let recorder = Recorder()
        remote.outgoing = { message in
            recorder.messages.append(message)
            return true
        }
        native.remote = remote
        // A page whose browser is made: nothing to prepare, and the settings were applied (they need a DevTools session).
        native.preparation = Task<Void, Error> {}
        native.hasAppliedInitialSettings = true
        if created {
            remote.markCreated()
        }
        return Rig(context: context, native: native, page: page, remote: remote, recorder: recorder, connection: connection)
    }

    // MARK: The mirror

    /// The plan's mutation: the title the page reports is the one the service pushed. A page that stops updating it keeps the old one.
    @Test func theMirroredTitleIsWhatThePageReports() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://one.example/")!), isRedirect: false)
        rig.event(CefRemote.Event.title) { $0.set(CefRemote.Key.title, "One") }
        #expect(rig.page.title == "One")
        rig.event(CefRemote.Event.title) { $0.set(CefRemote.Key.title, "Two") }
        #expect(rig.page.title == "Two")
        rig.event(CefRemote.Event.loadEnd) {
            $0.set(CefRemote.Key.url, "https://one.example/")
            $0.set(CefRemote.Key.title, "Three")
            $0.set(CefRemote.Key.status, 200)
        }
        #expect(rig.page.title == "Three", "the end of a load carries the title too")
        // An untitled document has an empty entry title, as in process: the display's substitute is not WSurf's title.
        rig.event(CefRemote.Event.title) { $0.set(CefRemote.Key.title, "") }
        #expect(rig.page.title == "")
        await rig.end()
    }

    @Test func theMirroredAddressLoadingStateAndProgressReachTheOwner() async {
        let rig = makeRig()
        let url = URL(string: "https://one.example/a")!
        rig.native.willNavigate(URLRequest(url: url), isRedirect: false)
        #expect(rig.page.isLoading)
        rig.event(CefRemote.Event.address) { $0.set(CefRemote.Key.url, url.absoluteString) }
        #expect(rig.page.url == url)
        rig.event(CefRemote.Event.progress) { $0.set(CefRemote.Key.progress, 0.5) }
        #expect(rig.page.estimatedProgress == 0.5)
        rig.event(CefRemote.Event.loadingState) {
            $0.set(CefRemote.Key.loading, false)
            $0.set(CefRemote.Key.canGoBack, false)
            $0.set(CefRemote.Key.canGoForward, false)
        }
        #expect(!rig.page.isLoading)
        #expect(rig.page.estimatedProgress == 1)
        await rig.end()
    }

    @Test func theMirroredSecurityOfTheVisibleEntryFollowsTheSameRuleAsInProcess() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://login.example/")!), isRedirect: false)
        rig.event(CefRemote.Event.address) {
            $0.set(CefRemote.Key.url, "https://login.example/")
            $0.set(CefRemote.Key.securityURL, "https://login.example/")
            $0.set(CefRemote.Key.secureConnection, true)
            $0.set(CefRemote.Key.certStatus, 0)
            $0.set(CefRemote.Key.contentStatus, 0)
        }
        rig.native.updateNativeSecurity()
        #expect(rig.page.hasOnlySecureContent)
        // A certificate error bit, or content flags, make it not secure: the one rule of `ChromiumPage.hasOnlySecureContent`.
        rig.event(CefRemote.Event.loadEnd) {
            $0.set(CefRemote.Key.url, "https://login.example/")
            $0.set(CefRemote.Key.securityURL, "https://login.example/")
            $0.set(CefRemote.Key.secureConnection, true)
            $0.set(CefRemote.Key.certStatus, 1 << 2)
            $0.set(CefRemote.Key.contentStatus, 0)
        }
        rig.native.updateNativeSecurity()
        #expect(!rig.page.hasOnlySecureContent)
        await rig.end()
    }

    @Test func theMuteIsMirroredAndSentAndAnEventOverridesIt() async {
        let rig = makeRig()
        #expect(!rig.native.isAudioMuted)
        rig.native.setAudioMuted(true)
        #expect(rig.native.isAudioMuted, "read at once, from the mirror")
        #expect(rig.recorder.sent(CefRemote.Op.mute).map { $0.bool(CefRemote.Key.flag) } == [true])
        rig.event(CefRemote.Event.muteChanged) { $0.set(CefRemote.Key.muted, false) }
        #expect(!rig.native.isAudioMuted, "the service has the last word")
        #expect(!rig.native.hasDevTools, "no DevTools window of the service yet (phase 4)")
        await rig.end()
    }

    // MARK: Setters are messages

    @Test func theSettersAreMessagesForTheBrowser() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://one.example/")!), isRedirect: false)
        rig.native.stopLoading()
        rig.native.pageZoom = 1.2
        rig.native.reload()
        rig.native.reload(ignoreCache: true)
        #expect(rig.recorder.ops == [CefRemote.Op.stop, CefRemote.Op.zoom, CefRemote.Op.reload, CefRemote.Op.reload])
        #expect(abs((rig.recorder.sent(CefRemote.Op.zoom).first?.double(CefRemote.Key.value) ?? 0) - 1) < 0.001, "zoom 1.2 is one step of 1.2")
        #expect(rig.recorder.sent(CefRemote.Op.reload).map { $0.bool(CefRemote.Key.flag) } == [false, true])
        #expect(rig.recorder.messages.allSatisfy { $0.browser == rig.remote.id })
        await rig.end()
    }

    @Test func messagesSentBeforeTheBrowserExistsWaitInOrderAndGoRightAfterIt() async {
        let rig = makeRig(created: false)
        rig.native.setAudioMuted(true)
        rig.native.pageZoom = 1.2
        #expect(rig.recorder.messages.isEmpty, "the service has no browser to give them to yet")
        #expect(rig.native.isAudioMuted, "but the mirror already has the mute")
        rig.remote.markCreated()
        #expect(rig.recorder.ops == [CefRemote.Op.mute, CefRemote.Op.zoom])
        rig.native.stopLoading()
        #expect(rig.recorder.ops == [CefRemote.Op.mute, CefRemote.Op.zoom, CefRemote.Op.stop])
        await rig.end()
    }

    // MARK: Native history (the mirror)

    private func entries(_ urls: [String], current: Int) -> (CefRemoteMessage) -> Void {
        { message in
            message.set(CefRemote.Key.entries, messages: urls.enumerated().map { index, url in
                let item = CefRemoteMessage("history.entry")
                item.set(CefRemote.Key.entryID, Int64(10 + index))
                item.set(CefRemote.Key.url, url)
                item.set(CefRemote.Key.title, "T\(index)")
                item.set(CefRemote.Key.isCurrent, index == current)
                return item
            })
        }
    }

    @Test func historyChangedBuildsWSurfsListAndBackAndForward() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://a.example/")!), isRedirect: false)
        var told = 0
        rig.page.onHistoryChanged = { told += 1 }
        rig.native.startupEntry = .dropped
        rig.event(CefRemote.Event.historyChanged, entries(["https://a.example/", "https://b.example/", "https://c.example/"], current: 1))
        #expect(told >= 1)
        #expect(rig.native.history.backList.map(\.url.absoluteString) == ["https://a.example/"])
        #expect(rig.native.history.forwardList.map(\.url.absoluteString) == ["https://c.example/"])
        #expect(rig.native.history.currentItem?.url.absoluteString == "https://b.example/")
        #expect(rig.native.history.currentItem?.chromiumIndex == 11, "the entry's id is Chromium's own, as `Page.navigateToHistoryEntry` takes it")
        #expect(rig.page.canGoBack && rig.page.canGoForward)
        // Back to the first entry: no Back, Forward twice. (No loading state or address came with it: the list alone says so.)
        rig.event(CefRemote.Event.historyChanged, entries(["https://a.example/", "https://b.example/", "https://c.example/"], current: 0))
        #expect(!rig.page.canGoBack && rig.page.canGoForward)
        #expect(rig.native.history.forwardList.count == 2)
        await rig.end()
    }

    @Test func theStartupPageIsNeverReachedByBackWhileTheListKeepsIt() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://a.example/")!), isRedirect: false)
        rig.event(CefRemote.Event.historyChanged, entries(["about:blank", "https://a.example/"], current: 1))
        #expect(rig.native.startupEntry == .inHistory)
        #expect(!rig.page.canGoBack, "Back would only go to the startup page")
        #expect(rig.native.history.backList.isEmpty)
        await rig.end()
    }

    // MARK: The startup sequence

    /// The windowless browser starts on about:blank. Measured in D4-4b: a load right after `browser.ready` leaves ONE entry, and the
    /// same check then finds nothing to drop. A load that comes after about:blank has finished keeps two, and the one-turn collapse
    /// of the service drops the first. Both end with no startup page in WSurf's list and Back off.
    @Test func aListOfOneEntryNeedsNoCollapseAndEndsDropped() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://a.example/")!), isRedirect: false)
        rig.event(CefRemote.Event.historyChanged, entries(["https://a.example/"], current: 0))
        rig.native.dropStartupEntry()
        #expect(await waitUntil { rig.native.startupEntry == .dropped })
        #expect(rig.remote.collapsesSent == 0, "nothing to drop: the first entry is not the startup page")
        #expect(!rig.page.canGoBack)
        await rig.end()
    }

    @Test func aListOfTheStartupPageAndTheCommittedEntryIsCollapsedByTheServiceInOneTurn() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://a.example/")!), isRedirect: false)
        rig.event(CefRemote.Event.historyChanged, entries(["about:blank", "https://a.example/"], current: 1))
        // As `didNavigate` starts it.
        rig.native.startupEntry = .resetting
        rig.native.dropStartupEntry()
        #expect(await waitUntil { !rig.recorder.sent(CefRemote.Op.collapseHistory).isEmpty })
        let request = rig.recorder.sent(CefRemote.Op.collapseHistory).first
        #expect(request?.collapseKeep == 11, "the committed entry is kept")
        #expect(request?.collapseExpected == [10, 11], "if the list is exactly this one")
        #expect(rig.native.startupEntry == .resetting, "Back stays off the startup page until the reset has landed")
        rig.event(CefRemote.Event.historyCollapsed) {
            $0.set(CefRemote.Key.identifier, request?.int(CefRemote.Key.identifier) ?? 0)
            $0.set(CefRemote.Key.outcome, CefRemote.CollapseOutcome.landed.rawValue)
        }
        #expect(await waitUntil { rig.native.startupEntry == .dropped })
        await rig.end()
    }

    @Test func aRefusedCollapseIsTriedAgainAndAnAnswerThatNeverComesIsRefused() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://a.example/")!), isRedirect: false)
        rig.event(CefRemote.Event.historyChanged, entries(["about:blank", "https://a.example/"], current: 1))
        rig.native.dropStartupEntry()
        // The first two are refused (the service's list was being read); the third lands.
        for round in 0..<3 {
            #expect(await waitUntil { rig.recorder.sent(CefRemote.Op.collapseHistory).count == round + 1 })
            let request = rig.recorder.sent(CefRemote.Op.collapseHistory)[round]
            rig.event(CefRemote.Event.historyCollapsed) {
                $0.set(CefRemote.Key.identifier, request.int(CefRemote.Key.identifier))
                $0.set(CefRemote.Key.outcome, (round < 2 ? CefRemote.CollapseOutcome.refused : .landed).rawValue)
            }
        }
        #expect(await waitUntil { rig.native.startupEntry == .dropped })
        // A browser that closes while one waits ends it as refused, never for ever.
        let waiting = Task { await rig.remote.collapseHistory(keeping: 11, ifEntriesAre: [10, 11]) }
        #expect(await waitUntil { rig.recorder.sent(CefRemote.Op.collapseHistory).count == 4 })
        rig.remote.remoteServiceEnded()
        #expect(await waiting.value == .refused)
        await rig.end()
    }

    // MARK: Closing, and the service ending

    @Test func closingAsksTheServiceAndTheBrowsersClosedEventEndsTheClose() async {
        let rig = makeRig()
        var asked = 0
        rig.remote.closeSeam = { asked += 1 }
        let closing = Task { await rig.native.close() }
        #expect(await waitUntil { rig.native.closing })
        #expect(asked == 1, "the service is asked once")
        #expect(!rig.native.isClosed, "and the page waits for its answer")
        rig.event(CefRemote.Event.browserClosed)
        await closing.value
        #expect(rig.native.isClosed)
        #expect(rig.native.remote == nil)
        await rig.end()
    }

    /// With no service running the client lets go of the browser itself, and the page hears `browser.closed` from it.
    @Test func aCloseWithNoServiceRunningEndsWithoutWaiting() async {
        let rig = makeRig()
        await rig.native.close()
        #expect(rig.native.isClosed)
        await rig.end()
    }

    /// "A connection that drops means every browser closed": a page that is closing when the service ends is closed, and does not
    /// wait for an event the service can no longer send.
    @Test func aServiceThatEndsWhileAPageIsClosingClosesIt() async {
        let rig = makeRig()
        rig.native.willNavigate(URLRequest(url: URL(string: "https://a.example/")!), isRedirect: false)
        var terminated = 0
        rig.page.onContentProcessTerminated = { terminated += 1 }
        // A page that is not closing is left as after a renderer crash.
        rig.remote.remoteServiceEnded()
        #expect(terminated == 1)
        #expect(rig.native.remote == nil, "no browser: the next load asks the service for a new one")
        #expect(!rig.native.isClosed)
        // One that is closing is closed.
        let second = makeRig()
        second.remote.closeSeam = {}
        let closing = Task { await second.native.close() }
        #expect(await waitUntil { second.native.closing })
        second.remote.remoteServiceEnded()
        await closing.value
        #expect(second.native.isClosed)
        await second.end()
        await rig.end()
    }

    // MARK: The service asks and tells

    private func question(
        _ url: String, method: String = "GET", post: Bool = false, transition: Int64 = 0, source: String = "", redirect: Bool = false
    ) -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Event.beforeBrowse, browser: 1)
        message.set(CefRemote.Key.url, url)
        message.set(CefRemote.Key.method, method)
        message.set(CefRemote.Key.hasPostData, post)
        message.set(CefRemote.Key.transition, transition)
        message.set(CefRemote.Key.sourceURL, source)
        message.set(CefRemote.Key.isRedirect, redirect)
        message.set(CefRemote.Key.userGesture, true)
        return message
    }

    /// What the tab's decision was asked, as the page built it from the question.
    struct Asked {
        let url: String
        let method: String?
        let hasBody: Bool
        let isMain: Bool
        let type: WKNavigationType
        let source: String?
    }

    /// `cef_transition_type_t`: TT_LINK 0, TT_FORM_SUBMIT 7.
    private static let transitionLink: Int64 = 0
    private static let transitionFormSubmit: Int64 = 7

    @Test func theNavigationQuestionReachesTheTabsDecisionWithTheMethodTheBodyAndTheTransition() async {
        let rig = makeRig()
        var seen: [Asked] = []
        rig.native.navigationDecision = { request, main, _, _, type, source, _ in
            seen.append(Asked(
                url: request.url?.absoluteString ?? "", method: request.httpMethod, hasBody: request.httpBody != nil, isMain: main,
                type: type, source: source?.absoluteString))
            return true
        }
        // A form submitted with POST: the tab must see the method and that it has a body, or it could replay it as a GET elsewhere.
        #expect(rig.remote.remoteAllowsNavigation(question: question(
            "https://shop.example/pay", method: "POST", post: true, transition: Self.transitionFormSubmit, source: "https://shop.example/cart")))
        #expect(seen.count == 1)
        #expect(seen[0].url == "https://shop.example/pay" && seen[0].method == "POST" && seen[0].hasBody)
        #expect(seen[0].isMain, "only main frames are asked")
        #expect(seen[0].type == .formSubmitted)
        #expect(seen[0].source == "https://shop.example/cart")
        // CEF may report no body element for a form's POST: any method but GET still counts as a body for the gate.
        #expect(rig.remote.remoteAllowsNavigation(question: question("https://shop.example/pay2", method: "POST", post: false)))
        #expect(seen[1].method == "POST" && seen[1].hasBody)
        // A plain link is a GET with no body.
        #expect(rig.remote.remoteAllowsNavigation(question: question("https://a.example/x", transition: Self.transitionLink)))
        #expect(seen[2].method == "GET" && !seen[2].hasBody && seen[2].type == .linkActivated)
        // The tab says no: the service cancels, and the page does not start a navigation.
        rig.native.navigationDecision = { _, _, _, _, _, _, _ in false }
        #expect(!rig.remote.remoteAllowsNavigation(question: question("https://a.example/blocked")))
        await rig.end()
    }

    @Test func aNavigationThatPassesStartsTheNavigationAndOneThatIsRefusedHereDoesNot() async {
        let rig = makeRig()
        rig.native.navigationDecision = { _, _, _, _, _, _, _ in true }
        var started: [URL?] = []
        rig.page.onNavigationStarted = { _, url in started.append(url) }
        #expect(rig.remote.remoteAllowsNavigation(question: question("https://a.example/")))
        #expect(started.map { $0?.absoluteString } == ["https://a.example/"])
        // `file:` is held to its folder in process by a handler the service does not have: it is refused, not loaded without it.
        #expect(!rig.remote.remoteAllowsNavigation(question: question("file:///tmp/x.html")))
        // A scheme outside the list is the service's own refusal too, whatever the tab says.
        #expect(!rig.remote.remoteAllowsNavigation(question: question("javascript:alert(1)")))
        #expect(started.count == 1)
        // A closed browser asks nobody.
        rig.remote.remoteServiceEnded()
        #expect(!rig.remote.remoteAllowsNavigation(question: question("https://a.example/again")))
        await rig.end()
    }

    struct Offered {
        let url: String
        let isMain: Bool
        let gesture: Bool
    }

    @Test func aRefusedSchemeIsOfferedToTheTabSoTheAppCanBeOffered() async {
        let rig = makeRig()
        var offered: [Offered] = []
        rig.native.navigationDecision = { request, main, gesture, _, _, _, _ in
            offered.append(Offered(url: request.url?.absoluteString ?? "", isMain: main, gesture: gesture))
            return false
        }
        rig.event(CefRemote.Event.externalScheme) {
            $0.set(CefRemote.Key.url, "mailto:someone@example.com")
            $0.set(CefRemote.Key.isMain, true)
            $0.set(CefRemote.Key.userGesture, true)
        }
        #expect(offered.count == 1 && offered[0].url == "mailto:someone@example.com" && offered[0].isMain && offered[0].gesture)
        // What WSurf loads itself never goes this way, however it arrives.
        rig.event(CefRemote.Event.externalScheme) { $0.set(CefRemote.Key.url, "https://a.example/") }
        rig.event(CefRemote.Event.externalScheme) { $0.set(CefRemote.Key.url, "") }
        #expect(offered.count == 1)
        await rig.end()
    }

    // MARK: Loading

    @Test func aLoadIsAMessageAndARequestWithABodyIsRefusedNotTurnedIntoAGet() async {
        let rig = makeRig()
        let url = URL(string: "https://a.example/start")!
        rig.page.load(URLRequest(url: url))
        #expect(await waitUntil { !rig.recorder.sent(CefRemote.Op.load).isEmpty })
        #expect(rig.recorder.sent(CefRemote.Op.load).first?.string(CefRemote.Key.url) == url.absoluteString)
        var failed: [Error] = []
        rig.page.onNavigationFailed = { _, error in failed.append(error) }
        var post = URLRequest(url: URL(string: "https://a.example/pay")!)
        post.httpMethod = "POST"
        post.httpBody = Data("a=1".utf8)
        rig.page.load(post)
        #expect(await waitUntil { !failed.isEmpty })
        #expect(rig.recorder.sent(CefRemote.Op.load).count == 1, "nothing was sent for it: a body is never replaced by a plain GET")
        #expect((failed.first as? ChromiumError).map { "\($0)" }?.contains("unavailable") == true)
        await rig.end()
    }

    /// Review S3: a `file:` load is refused where it starts, with the tab's error (the service has no file scope yet).
    @Test func aFileLoadIsRefusedWithAnErrorTheTabShows() async {
        let rig = makeRig()
        var failed: [Error] = []
        rig.page.onNavigationFailed = { _, error in failed.append(error) }
        rig.page.load(URLRequest(url: URL(fileURLWithPath: "/tmp/x.html")))
        #expect(await waitUntil { !failed.isEmpty })
        #expect(!rig.page.isLoading)
        #expect(rig.recorder.sent(CefRemote.Op.load).isEmpty, "nothing was sent")
        await rig.end()
    }

    // MARK: The pieces that need no page

    @Test func theRateLimitLetsABurstThroughAndThenOneAsTheWindowMoves() {
        var limit = CefRemoteRateLimit(maxEvents: 3, window: 10)
        let first = limit.allow(at: 0), second = limit.allow(at: 1), third = limit.allow(at: 2)
        #expect(first && second && third)
        let fourth = limit.allow(at: 3), stillHeld = limit.allow(at: 9.9)
        #expect(!fourth, "a fourth inside the window is held back")
        #expect(!stillHeld)
        let later = limit.allow(at: 10)
        #expect(later, "the first one has left the window")
        let refused = limit.allow(at: 10.5)
        #expect(!refused, "a refused one is not counted against the others")
        let next = limit.allow(at: 11)
        #expect(next)
        // A clock that went backwards forgets the future, instead of locking the limit for good.
        let backwards = limit.allow(at: 0)
        #expect(backwards)
        var none = CefRemoteRateLimit(maxEvents: 0, window: 10)
        let never = none.allow(at: 0)
        #expect(!never)
    }
}
