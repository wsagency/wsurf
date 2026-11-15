// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

/// The second group of `ChromiumOOPPageTests`: real pages through the real service, fixtures on 127.0.0.1. Each test needs
/// `WSurf Chromium.xpc` (the OOP lane: `Tools/run-chromium-oop-tests.sh ChromiumOOPPageTests`) and is skipped without it. The lane's
/// invocation holds no in-process Chromium suite: the process is latched out of process by the first page here, for good.
extension ChromiumOOPPageTests {
    /// A page that runs in the service, shown in a window, and the fixture server it loads from.
    struct Live {
        let server: HTTPFixtureServer
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow

        func url(_ path: String) throws -> URL {
            try server.url(path)
        }

        func finish() async {
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
        }
    }

    static let routes: [String: HTTPFixtureServer.Response] = [
        "/one": .html("<!doctype html><title>One</title><body style='margin:0;background:#ff0000'><p>one</p>"),
        "/two": .html("<!doctype html><title>Two</title><body style='margin:0;background:#0000ff'><p>two</p>"),
        "/cross": .html("""
            <!doctype html><title>Cross</title><body><script>
            const f = document.createElement('iframe'); f.src = 'http://localhost:' + location.port + '/frame'; document.body.append(f);
            </script></body>
            """),
        "/frame": .html("<!doctype html><title>Frame</title><body id=\"inner\">frame</body>"),
    ]

    func live() async throws -> Live {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        return Live(server: server, context: context, native: native, page: page, window: window)
    }

    /// `body` with a live page, which is closed afterwards whatever happens.
    func withLive(_ body: (Live) async throws -> Void) async throws {
        let live = try await live()
        do {
            try await body(live)
        } catch {
            await live.finish()
            throw error
        }
        await live.finish()
    }

    private func loaded(_ live: Live, _ path: String) async throws -> URL {
        let url = try live.url(path)
        live.page.load(URLRequest(url: url))
        try #require(await waitUntil { live.page.url == url && !live.page.isLoading })
        return url
    }

    // MARK: Load, mirror, startup

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aPageInTheServiceLoadsAFixtureAndMirrorsItsStateWithoutEverStartingCEFHere() async throws {
        let calls = ChromiumRuntime.shared.ensureInitializedCalls
        try await withLive { live in
            let one = try await loaded(live, "/one")
            #expect(await waitUntil { live.page.title == "One" })
            #expect(ChromiumOOP.latch.mode == .outOfProcess)
            #expect(live.native.remote != nil && live.native.client == nil, "the browser is the service's, and there is no client in process")
            #expect(ChromiumRemote.shared.isRunning)
            #expect(!CefRuntime.shared.isInitialized, "CEF never started in WSurf")
            #expect(ChromiumRuntime.shared.ensureInitializedCalls == calls, "the page never reached the in-process start")
            // The startup sequence, as it is measured: the load replaces the startup page, the list has one entry, and nothing
            // was dropped by a collapse. WSurf's list has the page and no Back.
            #expect(await waitUntil { live.native.history.currentItem?.url == one })
            #expect(await waitUntil { live.native.startupEntry == .dropped })
            #expect(live.native.history.backList.isEmpty && live.native.history.forwardList.isEmpty)
            #expect(!live.page.canGoBack && !live.page.canGoForward)
            print("ChromiumOOPPageTests observed: a load right after the browser was made: collapses sent \(live.native.remote?.collapsesSent ?? -1)")
            #expect(live.native.remote?.isCreated == true && live.native.remote?.isReady == true)
        }
    }

    /// The startup page finishes loading before the first real load: whatever Chromium keeps (one entry or two), Back never goes to it.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aLoadMadeAfterTheStartupPageFinishedStillLeavesNoStartupPageToGoBackTo() async throws {
        try await withLive { live in
            try await live.native.ensureReady()
            let remote = try #require(live.native.remote)
            #expect(await waitUntil { remote.isReady })
            #expect(await waitUntil { remote.history?.first?.url == "about:blank" }, "the startup page is in the list")
            try await Task.sleep(for: .milliseconds(800))
            let one = try await loaded(live, "/one")
            #expect(await waitUntil { live.native.startupEntry == .dropped })
            #expect(await waitUntil { live.native.history.currentItem?.url == one })
            #expect(live.native.history.backList.isEmpty, "no startup page in WSurf's list")
            #expect(!live.page.canGoBack)
            print("ChromiumOOPPageTests observed: a load after about:blank finished: native entries \(remote.history?.map(\.url) ?? []), collapses sent \(remote.collapsesSent)")
            // Back is on once there is a real entry to go back to.
            _ = try await loaded(live, "/two")
            #expect(await waitUntil { live.page.canGoBack })
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func backForwardAndReloadWorkThroughTheService() async throws {
        try await withLive { live in
            let one = try await loaded(live, "/one")
            let two = try await loaded(live, "/two")
            #expect(await waitUntil { live.page.canGoBack && !live.page.canGoForward })
            #expect(live.page.goBack() != nil)
            #expect(await waitUntil { live.page.url == one && !live.page.isLoading && live.page.title == "One" })
            #expect(await waitUntil { live.page.canGoForward && !live.page.canGoBack })
            #expect(live.page.goForward() != nil)
            #expect(await waitUntil { live.page.url == two && !live.page.isLoading && live.page.title == "Two" })
            // A reload makes a new document: a variable set on the old one is gone.
            _ = try await live.page.evaluateJavaScript("window.__marker = 41")
            #expect(try await live.page.evaluateJavaScript("window.__marker") as? Int == 41)
            live.page.reload()
            #expect(await waitUntil {
                let kind = try? await live.page.evaluateJavaScript("typeof window.__marker")
                return kind as? String == "undefined"
            })
            #expect(await waitUntil { live.page.url == two && !live.page.isLoading })
        }
    }

    // MARK: CDP, capture, setters

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func cdpGoesThroughChromiumDevToolsAndCapturesStayFair() async throws {
        try await withLive { live in
            _ = try await loaded(live, "/one")
            let sum = try await live.page.evaluateJavaScript("1 + 2")
            #expect((sum as? NSNumber)?.intValue == 3)
            let direct = try await live.native.command("Runtime.evaluate", params: ["expression": "6 * 7", "returnByValue": true])
            #expect(((direct["result"] as? [String: Any])?["value"] as? NSNumber)?.intValue == 42)
            // `Page.captureScreenshot` is what the preview and the band colour use: it works on a windowless browser, and the page is
            // red from edge to edge.
            func isRed(_ image: NSImage) -> Bool {
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let colour = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.sRGB)
                else { return false }
                return colour.redComponent > 0.9 && colour.blueComponent < 0.3 && colour.greenComponent < 0.3
            }
            var image = try await live.page.capture(rect: nil, width: 200)
            #expect(image.size.width == 200)
            for _ in 0..<40 where !isRed(image) {
                try await Task.sleep(for: .milliseconds(100))
                image = try await live.page.capture(rect: nil, width: 200)
            }
            #expect(isRed(image), "the capture shows the page")
            // The setters reach the service and nothing breaks: a mute, a zoom, and the page still answers.
            live.native.setAudioMuted(true)
            live.native.pageZoom = 1.2
            #expect(live.native.isAudioMuted)
            #expect(try await live.page.evaluateJavaScript("2 + 2") as? Int == 4)
            #expect(await waitUntil { live.native.remote?.isMuted == true })
        }
    }

    // MARK: Review carries

    /// Review F7: a message of a cross-site frame's own session is forwarded whole. The page's evaluation inside that frame is
    /// answered by such a message, so it cannot return unless the service forwarded it (and did not hand it to CEF's parsed callbacks,
    /// which drop the session ID).
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aMessageOfACrossSiteFramesSessionIsForwardedAndAnsweredThroughTheService() async throws {
        try await withLive { live in
            _ = try await loaded(live, "/cross")
            let devTools = live.native.devTools
            #expect(await waitUntil { devTools.sessions.count == 1 }, "the cross-site frame has a session of its own")
            // The cross-site frame is not in the page's own frame tree (it is in another process): its session has it.
            let session = try #require(devTools.sessions.values.first)
            #expect(await waitUntil { session.frameSnapshot().contains { !$0.isMainFrame } })
            let child = try #require(session.frameSnapshot().first { !$0.isMainFrame })
            #expect(child.request.url?.host == "localhost" && live.page.url?.host == "127.0.0.1", "another site than the page")
            let value = try await live.page.evaluateJavaScript("document.body.id", in: child, contentWorld: .page)
            #expect(value as? String == "inner", "an evaluation in the frame, answered by a message of its session")
            #expect(devTools.loadStatistics.sessionMessagesParsed > 0, "session messages were parsed whole")
        }
    }

    /// Review D1: a link to `mailto:` is cancelled in the service, and the tab still gets to offer the app.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aMailtoLinkIsOfferedToTheTabThoughTheServiceCancelledIt() async throws {
        try await withLive { live in
            let one = try await loaded(live, "/one")
            var offered: [String] = []
            live.native.navigationDecision = { request, _, _, _, _, _, _ in
                offered.append(request.url?.absoluteString ?? "")
                return request.url?.scheme != "mailto"
            }
            _ = try await live.page.evaluateJavaScript("location.href = 'mailto:oop-test@example.com'", in: nil, contentWorld: .page, userGesture: true)
            #expect(await waitUntil { offered.contains("mailto:oop-test@example.com") }, "offered: \(offered)")
            #expect(live.page.url == one, "the page did not move")
        }
    }

    // MARK: Letting go of a browser

    /// Review M1: a page that lost its browser (here closed under it) keeps the scripts and message handlers WSurf installed, and its
    /// next browser runs them again.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func theScriptsAndHandlersWSurfInstalledSurviveTheBrowserGoingAway() async throws {
        try await withLive { live in
            let world = WKContentWorld.world(name: "WSurfOOPKept")
            var messages: [String] = []
            live.page.installScript("globalThis.__kept = location.pathname", in: world, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            live.page.addScriptMessageHandler(name: "kept", in: world) { messages.append($0.body as? String ?? "") }
            _ = try await loaded(live, "/one")
            #expect(try await live.page.evaluateJavaScript("globalThis.__kept", in: nil, contentWorld: world) as? String == "/one")
            let first = try #require(live.native.remote)
            first.requestClose()
            #expect(await waitUntil { live.native.remote == nil }, "the page let go of the browser the service closed")
            _ = try await loaded(live, "/two")
            #expect(live.native.remote != nil && live.native.remote !== first)
            #expect(try await live.page.evaluateJavaScript("globalThis.__kept", in: nil, contentWorld: world) as? String == "/two",
                    "the installed script ran in the new browser")
            _ = try await live.page.evaluateJavaScript("__wsurfSend('kept', 'again')", in: nil, contentWorld: world)
            #expect(await waitUntil { messages.contains("again") }, "the message handler is still there: \(messages)")
        }
    }

    /// Review M2: a browser the service could not make reports through the load that waited for it. The tab does not keep loading.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aBrowserThatCouldNotBeMadeFailsTheLoadAndTheNextLoadMakesANewOne() async throws {
        ChromiumRemoteBrowser.debugCreate = CefRemote.DebugCreate.fail
        defer { ChromiumRemoteBrowser.debugCreate = nil }
        try await withLive { live in
            var failures: [Error] = []
            live.page.onNavigationFailed = { _, error in failures.append(error) }
            live.page.load(URLRequest(url: try live.url("/one")))
            #expect(await waitUntil { !failures.isEmpty }, "the load reports why")
            #expect((failures.first as? ChromiumError)?.errorDescription == String(localized: "Chromium could not open this tab."))
            #expect(!live.page.isLoading, "the tab is not left loading")
            #expect(live.native.remote == nil)
            ChromiumRemoteBrowser.debugCreate = nil
            _ = try await loaded(live, "/one")
            #expect(live.native.remote != nil)
        }
    }

    // MARK: The latch and the close

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func closingAPageClosesItsBrowserInTheServiceAndAnInProcessStartIsRefusedAfterTheLatch() async throws {
        let live = try await live()
        _ = try await loaded(live, "/one")
        #expect(ChromiumRemote.shared.browserCount >= 1)
        await live.finish()
        #expect(live.native.isClosed && live.native.remote == nil)
        #expect(await waitUntil { ChromiumRemote.shared.browserCount == 0 }, "the service's browser is closed and WSurf lets go of it")
        // The process went out of process at the first start: in-process Chromium is refused with the tab's own error, and CEF is not
        // started here.
        #expect(ChromiumOOP.latch.mode == .outOfProcess)
        let error = #expect(throws: ChromiumError.self) { try ChromiumRuntime.shared.ensureInitialized() }
        #expect(error?.errorDescription == String(localized: "Chromium could not open this tab."))
        #expect(!CefRuntime.shared.isInitialized)
    }
}
