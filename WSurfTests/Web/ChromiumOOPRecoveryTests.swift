// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import IOSurface
import QuartzCore
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

/// D4-10: what a `ChromiumPage` in the Chromium service does when its browser is gone. The service ends (a crash, a kill, its own
/// exit): every page resets through `didTerminate`, which the tab answers by loading its committed address again. A page that is
/// shown does that at once (the load waits, in order, for the relaunched service's hello); a hidden one waits until it is shown; a
/// service that keeps dying leaves the tab in its crash state until the person reloads. The last tab closed lets the service
/// leave after its linger, and the next one launches it again.
///
/// The tests that make a page load again need `WSurf Chromium.xpc` (the OOP lane: `Tools/run-chromium-oop-tests.sh
/// ChromiumOOPRecoveryTests`) and are skipped without it: a page that lost its browser asks the process's latch where its next one is
/// made, which must never be "in process" in the default lane. The first group (this file) drives a page with a recorded browser
/// and a connection that has no service; the second (`+Service`) kills and idles the real one.
@MainActor
@Suite(.serialized)
struct ChromiumOOPRecoveryTests {
    init() {
        #if DEBUG
        // Before any Chromium start of this host, as `ChromiumOOPPageTests`.
        ChromiumOOP.testOverride = true
        #endif
    }

    static let address = URL(string: "https://recovery.example/page")!

    final class Recorder {
        var messages: [CefRemoteMessage] = []

        func sent(_ op: String) -> [CefRemoteMessage] {
            messages.filter { $0.op == op }
        }
    }

    final class Flag {
        var raised = false
    }

    struct Rig {
        let native: ChromiumPage
        let page: BrowserPage
        let remote: ChromiumRemoteBrowser
        let recorder: Recorder
        let connection: ChromiumRemote
        let window: NSWindow

        /// What the tab does when its page's content is gone (`BrowserTab.contentProcessDidTerminate`): it loads the address again.
        func reloadLikeTheTab() {
            page.onContentProcessTerminated = { [weak page] in
                page?.load(URLRequest(url: ChromiumOOPRecoveryTests.address))
            }
        }

        func end() async {
            page.onContentProcessTerminated = nil
            window.contentView = nil
            window.close()
            connection.disconnect()
            await page.close()
        }
    }

    /// A page with a made browser whose messages go to a recorder, in a window of its own, on a connection that has no service.
    func makeRig() async -> Rig {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-recovery-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        native.remoteConnection = connection
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        let recorder = Recorder()
        remote.outgoing = { message in
            recorder.messages.append(message)
            return true
        }
        native.remote = remote
        native.preparation = Task<Void, Error> {}
        native.hasAppliedInitialSettings = true
        remote.markCreated()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        let rig = Rig(native: native, page: page, remote: remote, recorder: recorder, connection: connection, window: window)
        await settle()
        return rig
    }

    /// Long enough for the end of a run-loop turn (where visibility and the recovery check are made) to have come.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    // MARK: Which pages load again, and when

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aPageThatIsShownLoadsItsAddressAgainAsSoonAsTheServiceEnds() async {
        let rig = await makeRig()
        rig.reloadLikeTheTab()
        rig.remote.remoteServiceEnded()
        // Checked in the turn of the end, not later: a connection that has no service ends the browser it is asked for again.
        #expect(rig.native.heldReload == nil)
        #expect(rig.native.pendingLoad != nil, "the tab's reload was not held: the load began")
        #expect(rig.native.requestedURL == Self.address)
        await rig.end()
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHiddenPageLoadsItsAddressAgainOnlyWhenItIsShown() async {
        let rig = await makeRig()
        rig.page.isHidden = true
        await settle()
        rig.reloadLikeTheTab()
        rig.remote.remoteServiceEnded()
        #expect(rig.native.recovery == .waitingForActivation)
        #expect(rig.native.heldReload?.url == Self.address, "the tab's reload is held, not dropped")
        await settle()
        #expect(rig.native.remote == nil, "no browser is made for a page nobody sees")
        #expect(rig.native.pendingLoad == nil)
        rig.page.isHidden = false
        #expect(await waitUntil { rig.native.pendingLoad != nil }, "shown: the held load began")
        #expect(rig.native.heldReload == nil)
        #expect(rig.native.requestedURL == Self.address)
        await rig.end()
    }

    /// The exit gate's carry (review of #130, F3): a page on the shelf is visible to itself but not to the person, so it waits like a
    /// hidden one. Twenty recently visited tabs on the shelf do not relaunch twenty pages at once.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aParkedPageLoadsItsAddressAgainOnlyWhenItComesBackOffTheShelf() async {
        let rig = await makeRig()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.addSubview(WebViewParkingShelf(frame: .zero))
        rig.window.contentView = root
        WebViewParking.park(rig.page, in: rig.window)
        await settle()
        #expect(rig.native.remoteVisibility() == (hidden: false, parked: true), "the page is parked, not hidden")
        rig.reloadLikeTheTab()
        rig.remote.remoteServiceEnded()
        #expect(rig.native.recovery == .waitingForActivation, "parked counts as unseen")
        #expect(rig.native.heldReload?.url == Self.address, "the tab's reload is held, not dropped")
        await settle()
        #expect(rig.native.remote == nil, "no browser is made for a page nobody sees")
        #expect(rig.native.pendingLoad == nil)
        // A move onto the shelf again (a tab switch) does not make one either.
        WebViewParking.park(rig.page, in: rig.window)
        await settle()
        #expect(rig.native.remote == nil && rig.native.pendingLoad == nil, "a move between shelf and window is not an activation")
        // Back in the window: shown, the held load begins.
        rig.page.removeFromSuperview()
        rig.page.frame = root.bounds
        root.addSubview(rig.page)
        #expect(await waitUntil { rig.native.pendingLoad != nil }, "shown: the held load began")
        #expect(rig.native.heldReload == nil)
        #expect(rig.native.requestedURL == Self.address)
        await rig.end()
    }

    // MARK: A page waits for its replacement with its last frame, and loading (the 10 s launchd throttle)

    private func frameSurface() throws -> IOSurface {
        try #require(IOSurface(properties: [.width: 16, .height: 16, .bytesPerElement: 4, .pixelFormat: 0x4247_5241]))
    }

    /// A page of the rig with its frame layer registered and a frame in it.
    private func showFrame(_ rig: Rig) throws -> IOSurface {
        rig.native.attachRemoteFrameLayer(to: rig.remote)
        let frame = try frameSurface()
        rig.connection.sink.framesQueue.sync { rig.connection.sink.apply(surface: frame, browser: rig.remote.id, popup: false) }
        return frame
    }

    /// The service ended and the tab loads the page again: the page keeps the layer with its last frame, in its tree, and the tab
    /// loads. The replacement browser takes the same layer (its first frame is the first thing that changes it).
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aShownPageKeepsItsLastFrameAndLoadsWhileItsServiceIsReplaced() async throws {
        let rig = await makeRig()
        let frame = try showFrame(rig)
        let layer = try #require(rig.remote.pageLayer)
        rig.reloadLikeTheTab()
        rig.remote.remoteServiceEnded()
        // Read in the turn of the end: a connection that has no service ends the browser it is asked for again.
        #expect(rig.native.retainedPreview === layer, "the page kept the layer")
        #expect(layer.contents as AnyObject? === frame, "with its last frame")
        #expect(layer.superlayer === rig.native.layer, "in the tree, so the person still sees it")
        #expect(rig.page.isLoading && rig.native.pendingLoad != nil, "and the tab is loading")
        try rig.native.materializeRemote()
        let next = try #require(rig.native.remote)
        #expect(next.pageLayer === layer && rig.native.retainedPreview == nil, "the replacement browser shows in the same layer")
        #expect(layer.contents as AnyObject? === frame, "which shows the old frame until the replacement's first")
        let first = try frameSurface()
        rig.connection.sink.framesQueue.sync { rig.connection.sink.apply(surface: first, browser: next.id, popup: false) }
        #expect(layer.contents as AnyObject? === first, "its first frame replaces it")
        await rig.end()
    }

    /// A page the tab does not load again (it died twice within 5 s), a crash loop and a closed page show no frame of a page that is
    /// not coming.
    @Test
    func aPageThatIsNotLoadedAgainLetsGoOfItsLastFrame() async throws {
        let rig = await makeRig()
        _ = try showFrame(rig)
        let layer = try #require(rig.remote.pageLayer)
        rig.page.onContentProcessTerminated = nil
        rig.remote.remoteServiceEnded()
        #expect(rig.native.retainedPreview == nil, "nothing replaces it")
        #expect(layer.superlayer == nil && layer.contents == nil, "so it is gone")
        await rig.end()
    }

    /// A hidden page keeps its frame through the service's end, as it does while the service lives, and waits for its activation. If
    /// the service is given up before that (a crash loop that other tabs ran into), the crash state shows no frame of a page that is not
    /// coming: the held load that begins when the page is shown lets go of it, and no browser is asked for.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHiddenPageKeepsItsFrameUntilTheServiceIsGivenUpAndThenShowsNone() async throws {
        let rig = await makeRig()
        let frame = try showFrame(rig)
        let layer = try #require(rig.remote.pageLayer)
        rig.page.isHidden = true
        await settle()
        rig.reloadLikeTheTab()
        rig.remote.remoteServiceEnded()
        #expect(rig.native.recovery == .waitingForActivation)
        #expect(rig.native.retainedPreview === layer && layer.superlayer === rig.native.layer, "the hidden page keeps its frame")
        #expect(layer.contents as AnyObject? === frame)
        let other = RealTab(rig.connection, withBrowser: true)
        crashLoop(rig.connection, with: [other])
        #expect(rig.connection.state == .crashLooping)
        #expect(rig.native.retainedPreview === layer, "the loop's deaths do not touch a page that has no browser")
        rig.page.isHidden = false
        await settle()
        #expect(rig.native.retainedPreview == nil && layer.superlayer == nil && layer.contents == nil, "the crash state shows no frame")
        #expect(rig.native.remote == nil && rig.native.pendingLoad == nil, "and nothing asked for the service")
        await other.end()
        await rig.end()
    }

    /// The tab covers a page whose content is gone until the new document is presented; a page that kept its frame stays uncovered, or
    /// the cover would hide that frame behind the window's background for the whole wait.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aTabDoesNotCoverAPageThatKeptItsFrame() async throws {
        let connection = makeConnection()
        let framed = RealTab(connection, withBrowser: true), bare = RealTab(connection, withBrowser: true)
        framed.native.attachRemoteFrameLayer(to: try #require(framed.native.remote))
        let id = try #require(framed.native.remote).id
        let frame = try frameSurface()
        connection.sink.framesQueue.sync { connection.sink.apply(surface: frame, browser: id, popup: false) }
        framed.tab.hasPresentedContent = true
        bare.tab.hasPresentedContent = true
        // One death of the service (the first of the loop's three), with both tabs in it.
        connection.receive(.interrupted, generation: connection.generation)
        #expect(framed.native.retainedPreview != nil)
        #expect(framed.tab.hasPresentedContent, "the page's frame is not covered")
        #expect(!bare.tab.hasPresentedContent, "a page with no frame to keep is covered until its new document is presented, as before")
        connection.disconnect()
        await framed.end()
        await bare.end()
    }

    /// The crash state of a page in a stand-in tab (no `BrowserTab`: see `aTabInACrashLoop...` for the real path): the tab's reload
    /// is held, so nothing fails, nothing is shown and nothing launches the service, until a person reloads.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aServiceThatKeepsDyingHoldsTheTabsReloadUntilThePersonReloads() async {
        let rig = await makeRig()
        var failures: [Error] = []
        rig.page.onNavigationFailed = { _, error in failures.append(error) }
        let connection = rig.connection
        // Three deaths in a row, with no await between them: the third trips the cap, and the page hears of it after the state is
        // set. The tab (its stand-in) reloads when the page says its content is gone, as it does at the third.
        for death in 0..<3 {
            if rig.native.remote == nil {
                rig.native.remote = ChromiumRemoteBrowser(page: rig.native, connection: connection)
            }
            if death == 2 {
                rig.reloadLikeTheTab()
            }
            connection.receive(.interrupted, generation: connection.generation)
        }
        #expect(connection.state == .crashLooping)
        #expect(rig.native.recovery == .waitingForPerson)
        let hellos = connection.helloCount
        await settle()
        #expect(failures.isEmpty, "the tab's reload is held: nothing fails into an error page")
        #expect(!rig.page.isLoading)
        #expect(connection.helloCount == hellos && connection.state == .crashLooping, "nothing launched the service again")
        // Not a person's: a load of the page, a reload.
        rig.page.load(URLRequest(url: Self.address))
        rig.page.reload()
        #expect(connection.helloCount == hellos && connection.state == .crashLooping, "an automatic load does not end the loop")
        // The person reloads: the loop is given up, the service is asked for, and the page loads.
        rig.page.reload(byPerson: true)
        #expect(rig.native.recovery == .none)
        #expect(connection.state != .crashLooping)
        #expect(connection.helloCount == hellos + 1)
        await rig.end()
    }

    // MARK: A crash loop with real tabs (review of #130, F1 and F2)

    /// A real `BrowserTab` around a Chromium page on `connection`, in a window of its own.
    @MainActor
    final class RealTab {
        let tab: BrowserTab
        let native: ChromiumPage
        let window: NSWindow
        /// Finished loads (the tab's `onNavigationFinished`).
        private(set) var finished = 0

        /// `withBrowser`: a page that was already in the service (a recorded browser, as `makeRig`); without it the page has none, as a
        /// new tab, or one that was not open when a crash loop began.
        init(_ connection: ChromiumRemote, withBrowser: Bool = false, address: URL = ChromiumOOPRecoveryTests.address) {
            tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .privateBrowsing()))
            tab.engineOverride = .chromium
            native = ChromiumPage(context: tab.context)
            native.remoteConnection = connection
            tab.adopt(BrowserPage(chromium: native))
            tab.urlString = address.absoluteString
            if withBrowser {
                let remote = ChromiumRemoteBrowser(page: native, connection: connection)
                remote.outgoing = { _ in true }
                native.remote = remote
                native.preparation = Task<Void, Error> {}
                native.hasAppliedInitialSettings = true
                remote.markCreated()
            }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = tab.page
            window.orderBack(nil)
            tab.onNavigationFinished = { [weak self] _ in self?.finished += 1 }
        }

        func end() async {
            tab.detach()
            window.contentView = nil
            window.close()
            await tab.waitForRetirement()
        }
    }

    func makeConnection() -> ChromiumRemote {
        ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-recovery-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
    }

    /// Three deaths of the service with a browser of each tab in it, with no await between them (so that nothing made in between
    /// reaches a service): the third trips the cap.
    func crashLoop(_ connection: ChromiumRemote, with tabs: [RealTab]) {
        for _ in 0..<3 {
            for tab in tabs where tab.native.remote == nil {
                tab.native.remote = ChromiumRemoteBrowser(page: tab.native, connection: connection)
            }
            connection.receive(.interrupted, generation: connection.generation)
        }
    }

    /// F1: in a crash loop the tab's own error page used to call `userReload()` (through the document's load) and relaunch the
    /// service every launchd throttle. Nothing automatic ends the loop: not the tab's reload, not its error path, not an error
    /// document, not a hidden tab being shown; a tab with no window raises no alert.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aTabInACrashLoopShowsNoErrorPageAndNothingAutomaticLaunchesTheService() async {
        let connection = makeConnection()
        let shown = RealTab(connection, withBrowser: true), hidden = RealTab(connection, withBrowser: true)
        hidden.tab.page.isHidden = true
        await settle()
        crashLoop(connection, with: [shown, hidden])
        #expect(connection.state == .crashLooping)
        #expect(shown.native.recovery == .waitingForPerson && hidden.native.recovery == .waitingForPerson)
        let hellos = connection.helloCount
        let failure = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: Self.address])
        // The tab's real error path, twice (the second would raise an alert if the first had started an error document), and the
        // loads the tab and its error page make by themselves.
        for tab in [shown, hidden] {
            tab.tab.navigationFailed(nil, error: failure)
            tab.tab.navigationFailed(nil, error: failure)
            tab.tab.page.loadHTMLString("<p>error</p>", baseURL: Self.address)
            tab.tab.page.load(URLRequest(url: Self.address))
            #expect(!tab.tab.isShowingError && !tab.tab.isLoadingErrorPage, "no error document was started")
        }
        hidden.tab.page.isHidden = false
        await settle()
        for tab in [shown, hidden] {
            #expect(tab.native.remote == nil && !tab.tab.page.isLoading, "no browser was asked for, nothing is loading")
            #expect(tab.native.requestedURL == Self.address, "the address a person's reload loads is kept")
        }
        #expect(connection.helloCount == hellos && connection.state == .crashLooping, "nothing launched the service again")
        // Longer than two launchd pacings (10 s each) and the 15 s a hello may take: a relaunch that came later than the loads
        // above (a timer, a deferred error page) would show here as a hello, or as a state that is no longer the crash loop.
        try? await Task.sleep(for: .seconds(26))
        #expect(connection.helloCount == hellos && connection.state == .crashLooping, "still no launch after 26 s")
        #expect(shown.native.remote == nil && hidden.native.remote == nil && !shown.tab.page.isLoading && !hidden.tab.page.isLoading)
        await shown.end()
        await hidden.end()
        connection.disconnect()
    }

    /// The same for a hello that failed for good (no answer in time): the pages wait for a person, and the tab's error path does not
    /// send a new hello; a person's load does.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHelloThatFailedForGoodIsNotSentAgainByTheTabsErrorPage() async {
        let connection = makeConnection()
        let tab = RealTab(connection, withBrowser: true)
        connection.connect()
        // The hello's timer, run by hand: the connection has no service to be silent.
        connection.helloEnded(.timedOut, sentAt: 0, generation: connection.generation)
        #expect(connection.state == .failed(.noAnswer))
        #expect(tab.native.recovery == .waitingForPerson)
        let hellos = connection.helloCount
        let failure = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: Self.address])
        tab.tab.navigationFailed(nil, error: failure)
        tab.tab.page.loadHTMLString("<p>error</p>", baseURL: Self.address)
        tab.tab.page.load(URLRequest(url: Self.address))
        try? await Task.sleep(for: .seconds(1))
        #expect(connection.helloCount == hellos && connection.isGivenUp, "no hello was sent again")
        tab.tab.load(Self.address, byPerson: true)
        #expect(connection.helloCount == hellos + 1, "a person's load sends one")
        connection.disconnect()
        await tab.end()
    }

    /// F2: a new tab, made while the loop is going, is ended by a person's load in it, not by an agent's.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anAgentsLoadInANewTabDuringACrashLoopDoesNotEndIt() async {
        let connection = makeConnection()
        let old = RealTab(connection, withBrowser: true)
        crashLoop(connection, with: [old])
        #expect(connection.state == .crashLooping)
        let hellos = connection.helloCount
        let fresh = RealTab(connection)
        // As `MCPBrowserSession` and the agent load a page: `transition: .agent`, with `startedByUser` left at its default (true).
        fresh.tab.load(Self.address, transition: .agent)
        fresh.tab.load(Self.address, transition: .agent, startedByUser: true)
        fresh.tab.reload()
        #expect(connection.state == .crashLooping && connection.helloCount == hellos, "an agent's load, or an automatic reload, does not end the loop")
        #expect(fresh.native.remote == nil && !fresh.tab.page.isLoading)
        connection.disconnect()
        await fresh.end()
        await old.end()
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aPersonsLoadInANewTabDuringACrashLoopEndsItAndLoads() async {
        let connection = makeConnection()
        let old = RealTab(connection, withBrowser: true)
        crashLoop(connection, with: [old])
        #expect(connection.state == .crashLooping)
        let hellos = connection.helloCount
        let fresh = RealTab(connection)
        fresh.tab.load(Self.address, byPerson: true)
        // Read before anything else runs, then ended before a service that is not there answers (the connection has none).
        #expect(connection.state != .crashLooping, "the person's load gave the loop up")
        #expect(connection.helloCount == hellos + 1, "and asked for the service")
        #expect(fresh.tab.page.isLoading, "and the page loads")
        connection.disconnect()
        await fresh.end()
        await old.end()
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aPersonsReloadOfATabThatWasNotOpenWhenTheLoopBeganEndsIt() async {
        let connection = makeConnection()
        let old = RealTab(connection, withBrowser: true)
        crashLoop(connection, with: [old])
        #expect(connection.state == .crashLooping)
        let hellos = connection.helloCount
        let late = RealTab(connection)
        late.tab.reload()
        #expect(connection.state == .crashLooping && connection.helloCount == hellos, "an automatic reload does not end the loop")
        late.tab.reload(byPerson: true)
        #expect(connection.state != .crashLooping && connection.helloCount == hellos + 1, "the person's Reload does")
        connection.disconnect()
        await late.end()
        await old.end()
    }

    /// A page that is not in the service is not touched by any of it (the WebKit and in-process paths ignore `byPerson`).
    @Test
    func aPersonsLoadChangesNothingForAPageWhoseServiceIsNotGivenUp() async {
        let connection = makeConnection()
        let native = ChromiumPage(context: BrowserProfileContext(profile: .privateBrowsing()))
        native.remoteConnection = connection
        #expect(!connection.isGivenUp)
        #expect(!native.holdsForRecovery(URLRequest(url: Self.address), byPerson: true))
        #expect(!native.holdsForRecovery(URLRequest(url: Self.address)))
        #expect(connection.helloCount == 0 && connection.state == .stopped && native.recovery == .none)
        // A process that took the other path is not "given up": no action of a person changes its choice.
        let refused = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory }, latch: ChromiumOOP.Latch(), isEnabled: { false })
        refused.connect()
        #expect(refused.state == .failed(.notEnabled) && !refused.isGivenUp)
        await BrowserPage(chromium: native).close()
    }

    /// Review of #129, F1: a browser made again for a page that is already in its window is told the screen it is on.
    @Test
    func aBrowserMadeAgainForAPageInItsWindowIsToldTheScreen() async throws {
        let rig = await makeRig()
        guard rig.window.screen != nil else { await rig.end(); return }
        rig.remote.remoteServiceEnded()
        #expect(rig.native.remote == nil)
        try rig.native.materializeRemote()
        let made = try #require(rig.native.remote)
        // Sent at the end of the turn (one `browser.resize` for whatever changed in it), held in order until the browser is made.
        await settle()
        #expect(made.sentScreen == rig.window.screen?.frame.size, "the screen is sent (held until the browser is made), not left unknown")
        #expect(made.sentScreen != .zero)
        await rig.end()
    }

    // MARK: A cancelled load does not leave the tab loading (carried from the D4-8 delta review)

    /// The tab does not reload a page that died twice in five seconds ("leaving the tab alone"): nothing else ends its loading.
    @Test
    func aLoadCancelledByTheServiceEndingLeavesNoLoadingWhenTheTabLeavesThePageAlone() async {
        let rig = await makeRig()
        rig.page.load(URLRequest(url: Self.address))
        #expect(await waitUntil { !rig.recorder.sent(CefRemote.Op.load).isEmpty })
        #expect(rig.page.isLoading)
        rig.remote.remoteServiceEnded()
        #expect(!rig.page.isLoading, "the cancelled load is not left loading")
        await rig.end()
    }

    @Test
    func aLoadCancelledByTheBrowserClosingLeavesNoLoadingWhenTheTabLeavesThePageAlone() async {
        let rig = await makeRig()
        rig.page.load(URLRequest(url: Self.address))
        #expect(await waitUntil { !rig.recorder.sent(CefRemote.Op.load).isEmpty })
        #expect(rig.page.isLoading)
        rig.remote.remoteEvent(CefRemoteMessage(CefRemote.Event.browserClosed, browser: rig.remote.id))
        #expect(!rig.page.isLoading)
        await rig.end()
    }

    // MARK: Late events of a browser the page let go of

    /// A browser's events after the page made a new one are not the page's (carried from the same review).
    @Test
    func anEventOfABrowserThePageLetGoOfDoesNotReachThePage() async throws {
        let rig = await makeRig()
        var terminated = 0
        rig.page.onContentProcessTerminated = { terminated += 1 }
        let old = rig.remote
        old.remoteServiceEnded()
        #expect(terminated == 1)
        let next = ChromiumRemoteBrowser(page: rig.native, connection: rig.connection)
        rig.native.remote = next
        old.remoteEvent(CefRemoteMessage(CefRemote.Event.renderTerminated, browser: old.id))
        #expect(terminated == 1, "the late event of the old browser is dropped")
        next.remoteEvent(CefRemoteMessage(CefRemote.Event.renderTerminated, browser: next.id))
        #expect(terminated == 2, "the page's own browser still reaches it")
        await rig.end()
    }

    /// The case that mattered: command ids restart in the page's next DevTools, so a late reply of the old browser could answer a
    /// command of the new one.
    @Test
    func aLateReplyOfAnAbandonedBrowserDoesNotAnswerACommandOfTheNewOne() async throws {
        let rig = await makeRig()
        let old = rig.remote
        old.remoteServiceEnded()
        let next = ChromiumRemoteBrowser(page: rig.native, connection: rig.connection)
        let recorder = Recorder()
        next.outgoing = { message in
            recorder.messages.append(message)
            return true
        }
        rig.native.remote = next
        try rig.native.devTools.attach(remote: next)
        next.markCreated()
        let answered = Flag()
        let command = Task { [native = rig.native] in
            _ = try? await native.devTools.command("Browser.getVersion")
            answered.raised = true
        }
        #expect(await waitUntil { !recorder.sent(CefRemote.Op.devTools).isEmpty })
        let sent = try #require(recorder.sent(CefRemote.Op.devTools).first)
        var id = -1
        sent.withBytes(CefRemote.Key.data) { pointer, size in
            guard let pointer else { return }
            let object = try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: size)) as? [String: Any]
            id = (object?["id"] as? Int) ?? -1
        }
        #expect(id > 0)
        func reply(from browser: ChromiumRemoteBrowser) -> CefRemoteMessage {
            let message = CefRemoteMessage(CefRemote.Event.devToolsResult, browser: browser.id)
            message.set(CefRemote.Key.identifier, id)
            message.set(CefRemote.Key.success, true)
            message.set(CefRemote.Key.data, data: Data("{}".utf8))
            return message
        }
        old.remoteEvent(reply(from: old))
        await settle()
        #expect(!answered.raised, "the old browser's reply does not match the new browser's command")
        next.remoteEvent(reply(from: next))
        #expect(await waitUntil { answered.raised })
        _ = await command.value
        await rig.end()
    }
}
