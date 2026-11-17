// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

/// D4-11: the transparent view over a `ChromiumPage` that runs in the Chromium service (`ChromiumRemoteContentView`). It is the first
/// responder of such a page, is made with the page's browser and goes with it, and never exists for a page in process.
///
/// Three groups. The in-process page needs no service and runs in the default lane only (the OOP lane refuses in-process Chromium).
/// The rig group gives a page a browser whose messages go nowhere (no service, no CEF) and runs in both lanes. The last group drives
/// real pages through the service (gated per test; the OOP lane: `Tools/run-chromium-oop-tests.sh ChromiumOOPContentViewTests`).
@MainActor
@Suite(.serialized)
struct ChromiumOOPContentViewTests {
    init() {
        #if DEBUG
        // As `ChromiumOOPPageTests`: before any Chromium start of this host. Without the service the override changes nothing.
        ChromiumOOP.testOverride = true
        #endif
    }

    private static func window(_ page: BrowserPage, width: CGFloat = 800, height: CGFloat = 600) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        return window
    }

    private static func contentViews(of page: ChromiumPage) -> [ChromiumRemoteContentView] {
        page.subviews.compactMap { $0 as? ChromiumRemoteContentView }
    }

    // MARK: A page in process

    /// The default lane's proof of the plan's C1: nothing of the OOP view exists in process, and the page takes focus as it did.
    @Test(.enabled(if: !ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aPageInProcessNeverHasAContentViewAndTakesFocusAsBefore() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = Self.window(page)
        #expect(native.remote == nil)
        #expect(Self.contentViews(of: native).isEmpty)
        #expect(window.makeFirstResponder(page))
        #expect(window.firstResponder === page, "the page is the first responder, as it was before the content view existed")
        #expect(native.becomeFirstResponder(), "an in-process page still accepts focus itself")
        #expect(Self.contentViews(of: native).isEmpty)
        window.contentView = nil
        window.close()
        await page.close()
        await context.endPrivateSession()
    }

    // MARK: A page with a recorded browser (no service)

    private struct Rig {
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow
        let connection: ChromiumRemote
        /// The page's first browser (the page's own `remote` is nil once the service has ended).
        let remote: ChromiumRemoteBrowser

        func end() async {
            window.contentView = nil
            window.close()
            connection.disconnect()
            await page.close()
            await context.endPrivateSession()
        }
    }

    /// A page in a window with a browser that is not the service's: nothing is sent anywhere, and no CEF starts. Its frame layer is
    /// attached as `materializeRemote` does (the page has its window before it).
    private func makeRig() -> Rig {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-view-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        remote.outgoing = { _ in true }
        native.remote = remote
        native.preparation = Task<Void, Error> {}
        native.hasAppliedInitialSettings = true
        remote.markCreated()
        let window = Self.window(page)
        native.attachRemoteFrameLayer(to: remote)
        return Rig(context: context, native: native, page: page, window: window, connection: connection, remote: remote)
    }

    @Test func aPageThatRunsInTheServiceHasExactlyOneContentViewAtItsBoundsAndItFollowsTheResize() async {
        let rig = makeRig()
        #expect(Self.contentViews(of: rig.native).count == 1)
        #expect(rig.remote.contentView === Self.contentViews(of: rig.native).first)
        #expect(rig.remote.contentView?.frame == rig.native.bounds)
        #expect(rig.remote.contentView?.isFlipped == true)
        for size in [CGSize(width: 900, height: 640), CGSize(width: 500, height: 300)] {
            rig.window.setContentSize(size)
            rig.window.contentView?.layoutSubtreeIfNeeded()
            #expect(rig.native.bounds.size == size)
            #expect(rig.remote.contentView?.frame == rig.native.bounds, "the view follows the page's bounds at \(size)")
            #expect(Self.contentViews(of: rig.native).count == 1)
        }
        await rig.end()
    }

    /// The plan's mutation: `BrowserPage` focuses the content view, never the page. The page itself declines focus out of process.
    @Test func focusingTheTabMakesTheContentViewTheFirstResponder() async {
        let rig = makeRig()
        let view = rig.remote.contentView
        #expect(view != nil)
        #expect(rig.window.makeFirstResponder(rig.page))
        #expect(rig.window.firstResponder === view, "the first responder is \(String(describing: rig.window.firstResponder))")
        #expect(rig.page.ownsResponder(rig.window.firstResponder), "the page still owns its content view's keys")
        #expect(!rig.native.becomeFirstResponder(), "the page itself is not what takes focus out of process")
        await rig.end()
    }

    @Test func theContentViewGoesWithTheBrowserAndComesBackWithTheNextOne() async throws {
        let rig = makeRig()
        let first = try #require(rig.remote.contentView)
        #expect(rig.window.makeFirstResponder(rig.page))
        #expect(rig.window.firstResponder === first)
        // The service ended: the browser, and the view with it. Nothing is left in the tree for a dead browser.
        rig.remote.remoteServiceEnded()
        #expect(rig.native.remote == nil)
        #expect(Self.contentViews(of: rig.native).isEmpty)
        #expect(first.superview == nil)
        #expect(rig.window.firstResponder !== first)
        // The next browser: a new view, at the page's size.
        let next = ChromiumRemoteBrowser(page: rig.native, connection: rig.connection)
        next.outgoing = { _ in true }
        rig.native.remote = next
        rig.native.attachRemoteFrameLayer(to: next)
        #expect(Self.contentViews(of: rig.native).count == 1)
        #expect(next.contentView !== first && next.contentView?.frame == rig.native.bounds)
        #expect(rig.window.makeFirstResponder(rig.page))
        #expect(rig.window.firstResponder === next.contentView)
        await rig.end()
        #expect(Self.contentViews(of: rig.native).isEmpty, "a closed page has no view")
    }

    // MARK: Real pages through the service

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/page": .html("<!doctype html><title>View</title><body style='margin:0'><p>view</p>")
    ]

    private func withLive(_ body: (ChromiumPage, BrowserPage, NSWindow) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = Self.window(page)
        do {
            let url = try server.url("/page")
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try await body(native, page, window)
        } catch {
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        window.contentView = nil
        window.close()
        await page.close()
        await context.endPrivateSession()
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aRealPageHasOneContentViewAtItsBoundsAfterAResizeAndFocusGoesToIt() async throws {
        try await withLive { native, page, window in
            let remote = try #require(native.remote)
            #expect(Self.contentViews(of: native).count == 1)
            #expect(remote.contentView?.frame == native.bounds)
            window.setContentSize(CGSize(width: 1000, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(native.bounds.size == CGSize(width: 1000, height: 700))
            #expect(remote.contentView?.frame == native.bounds)
            #expect(Self.contentViews(of: native).count == 1)
            #expect(window.makeFirstResponder(page))
            #expect(window.firstResponder === remote.contentView)
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func theViewGoesWhenARealPageClosesAndNoPageInTheServiceRunsInProcess() async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = Self.window(page)
        let url = try server.url("/page")
        page.load(URLRequest(url: url))
        try #require(await waitUntil { page.url == url && !page.isLoading })
        let view = try #require(native.remote?.contentView)
        #expect(view.superview === native)
        window.contentView = nil
        window.close()
        await page.close()
        #expect(view.superview == nil, "the closed page let go of its view")
        #expect(native.remote == nil)
        await context.endPrivateSession()
    }
}
