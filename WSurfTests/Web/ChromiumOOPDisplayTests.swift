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

/// D4-9: what a `ChromiumPage` in the Chromium service needs to be seen. Its size and scale reach the service (`browser.resize`), its
/// frames land in its layer (the frame sink), and where it is (a window, the shelf, hidden) reaches the service as one
/// `browser.visibility` per run-loop turn. Real pages through the real service, fixtures on 127.0.0.1: every test needs
/// `WSurf Chromium.xpc` (the OOP lane: `Tools/run-chromium-oop-tests.sh ChromiumOOPDisplayTests`) and is skipped without it. The
/// lane's invocation holds no in-process Chromium suite: the process latches out of process at the first page here, for good.
@MainActor
@Suite(.serialized)
struct ChromiumOOPDisplayTests {
    init() {
        #if DEBUG
        // As `ChromiumOOPPageTests`: before any Chromium start of this host.
        ChromiumOOP.testOverride = true
        #endif
    }

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/red": .html("<!doctype html><title>Red</title><body style='margin:0;background:#ff0000'><p>red</p>"),
        // The top half red, the bottom half blue: which way up the frame is.
        // Repaints on every animation frame: the ring is reused, and the overwrite counters mean something.
        "/animated": .html("""
            <!doctype html><title>Animated</title><body style="margin:0;background:#f00"></body>
            <script>let n = 0; (function tick() { document.body.style.background = n++ % 2 ? "#f00" : "#00f"; requestAnimationFrame(tick) })()</script>
            """),
        "/split": .html("""
            <!doctype html><title>Split</title><body style='margin:0'>
            <div style='height:50vh;background:#f00'></div><div style='height:50vh;background:#00f'></div>
            """),
    ]

    private struct Live {
        let server: HTTPFixtureServer
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow

        var browser: Int64 {
            native.remote?.id ?? -1
        }

        func url(_ path: String) throws -> URL {
            try server.url(path)
        }

        /// The service's own view of this browser (`debug.stats` with the browser), or nil when it does not answer.
        func stats() async -> CefRemoteMessage? {
            guard case let .value(reply) = await ChromiumRemote.shared.request(CefRemoteMessage(CefRemote.Op.debugStats, browser: browser))
            else { return nil }
            return reply
        }

        func finish() async {
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
        }
    }

    private func live(width: CGFloat = 800, height: CGFloat = 600) async throws -> Live {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        return Live(server: server, context: context, native: native, page: page, window: window)
    }

    private func withLive(_ path: String? = nil, _ body: (Live) async throws -> Void) async throws {
        let live = try await live()
        do {
            if let path {
                let url = try live.url(path)
                live.page.load(URLRequest(url: url))
                try #require(await waitUntil { live.page.url == url && !live.page.isLoading })
            }
            try await body(live)
        } catch {
            await live.finish()
            throw error
        }
        await live.finish()
    }

    /// The IOSurface a layer shows, if its contents are one.
    private static func surface(of layer: CALayer?) -> IOSurfaceRef? {
        guard let contents = layer?.contents, CFGetTypeID(contents as AnyObject) == IOSurfaceGetTypeID() else { return nil }
        return unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
    }

    /// A pixel of a BGRA or RGBA surface, `fraction` of the way down its middle column (0 = top row).
    private static func pixel(of surface: IOSurfaceRef, fractionDown fraction: Double) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let bytes = base + Int(Double(height) * fraction) * IOSurfaceGetBytesPerRow(surface) + (width / 2) * 4
        switch IOSurfaceGetPixelFormat(surface) {
        case 0x4247_5241:  // 'BGRA'
            return (bytes[2], bytes[1], bytes[0])
        case 0x5247_4241:  // 'RGBA'
            return (bytes[0], bytes[1], bytes[2])
        default:
            return nil
        }
    }

    // MARK: Geometry

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func resizingThePageMakesTheServicesViewRectAndItsFramesFollow() async throws {
        try await withLive("/red") { live in
            let scale = live.window.backingScaleFactor
            let remote = try #require(live.native.remote)
            for size in [CGSize(width: 900, height: 640), CGSize(width: 1300, height: 860)] {
                live.window.setContentSize(size)
                #expect(await waitUntil(timeout: .seconds(10)) {
                    let stats = await live.stats()
                    return stats?.double(CefRemote.Key.width) == size.width && stats?.double(CefRemote.Key.height) == size.height
                }, "the service's view rect did not become \(size)")
                let stats = try #require(await live.stats())
                #expect(stats.double(CefRemote.Key.scale) == scale, "the service's scale follows the window's backing scale")
                // The frames follow: CEF paints the new size in pixels, and the layer shows such a frame.
                #expect(await waitUntil(timeout: .seconds(10)) {
                    Self.surface(of: remote.pageLayer).map { IOSurfaceGetWidth($0) == Int(size.width * scale) && IOSurfaceGetHeight($0) == Int(size.height * scale) } == true
                }, "the page layer never showed a \(size) frame at scale \(scale)")
                #expect(remote.pageLayer?.frame.size == live.native.bounds.size, "the layer is the view's size")
            }
            // One resize per size: a page whose size did not change sends nothing.
            let sent = remote.resizesSent
            live.native.updateRemoteGeometry()
            live.native.updateRemoteGeometry()
            #expect(remote.resizesSent == sent)
        }
    }

    // MARK: Frames in the layer

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func thePageLayerShowsASurfaceAfterALoadWhoseRowsAreTopFirstAndWhoseColourTagIsTheServices() async throws {
        let sink = ChromiumRemote.shared.sink
        let shownBefore = sink.framesShown
        try await withLive("/split") { live in
            let remote = try #require(live.native.remote)
            #expect(await waitUntil(timeout: .seconds(10)) { sink.framesShown > shownBefore && Self.surface(of: remote.pageLayer) != nil }, "the sink counted no frame of this page")
            #expect(sink.isRegistered(browser: live.browser))
            let surface = try #require(Self.surface(of: remote.pageLayer))
            // The surface's rows are top-first (the first row is the top of the page). How the layer displays them inside the flipped
            // view is the spike's layout (a plain sublayer at the view's bounds) and is not checked on screen: the render below is
            // information only.
            #expect(await waitUntil(timeout: .seconds(10)) {
                guard let top = Self.surface(of: remote.pageLayer).flatMap({ Self.pixel(of: $0, fractionDown: 0.25) }),
                      let bottom = Self.surface(of: remote.pageLayer).flatMap({ Self.pixel(of: $0, fractionDown: 0.75) })
                else { return false }
                return top.red > 200 && top.blue < 80 && bottom.blue > 200 && bottom.red < 80
            }, "the surface rows are not top-first")
            // P3 / colour: the layer shows the service's surface untouched. The surface carries Chromium's colour-space tag (the
            // service copies it, `colourTagged`), the layer sets none of its own, and the compositor matches the surface by its tag.
            let stats = try #require(await live.stats())
            let tagged = stats.int(CefRemote.Key.colourTagged), untagged = stats.int(CefRemote.Key.colourUntagged)
            print("ChromiumOOPDisplayTests observed: colour tag on frames shown: tagged \(tagged), untagged \(untagged)")
            #expect(tagged + untagged >= 1)
            #expect((IOSurfaceCopyValue(surface, kIOSurfaceColorSpace) != nil) == (untagged == 0), "the layer's surface does not carry the service's tag")
            // What the compositor draws, as far as a layer render shows it (information only: a render of a layer outside the window
            // server is not the screen).
            if let layer = live.window.contentView?.layer {
                let width = Int(layer.bounds.width), height = Int(layer.bounds.height)
                if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                   let data = context.data {
                    layer.render(in: context)
                    let bytes = data.assumingMemoryBound(to: UInt8.self)
                    func rgb(_ row: Int) -> String {
                        let at = bytes + row * width * 4 + (width / 2) * 4
                        return "\(at[0]),\(at[1]),\(at[2])"
                    }
                    print("ChromiumOOPDisplayTests observed: layer render, first bitmap row \(rgb(0)), last row \(rgb(height - 1))")
                }
            }
        }
    }

    // MARK: Exit-gate measurement

    /// D4-9 exit gate input (not a threshold): with WSurf's real frame sink attached, how often the service's ring falls back to
    /// overwriting a copy that may be in use, on a page that repaints on every frame. Near 0 against many frames means the 10 of 13 that
    /// D4-7 measured with a raw test client was that client's artefact; about frames minus 3 means the service keeps surfaces in use.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func ringOverwritesAgainstFramesSentWithTheRealSinkAttachedAreMeasured() async throws {
        let sink = ChromiumRemote.shared.sink
        let shownBefore = sink.framesShown
        try await withLive("/animated") { live in
            try await Task.sleep(for: .seconds(3))
            let stats = try #require(await live.stats())
            let sent = stats.int(CefRemote.Key.framesSent), overwrites = stats.int(CefRemote.Key.ringOverwrites)
            let slots = stats.int(CefRemote.Key.overwrittenSlots), ring = stats.int(CefRemote.Key.ringSurfaces)
            print("ChromiumOOPDisplayTests observed: real sink, animated page, 3 s: frames sent \(sent), ring overwrites \(overwrites),"
                + " distinct copies overwritten \(slots), ring \(ring), sink frames shown \(sink.framesShown), scale \(live.window.backingScaleFactor)")
            #expect(sent >= 10, "the animated page sent \(sent) frames in 3 s")
            #expect(sink.framesShown - shownBefore >= 10)
        }
    }

    // MARK: Visibility

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func threeWindowMovesInOneTurnReachTheServiceAsExactlyOneVisibilityMessage() async throws {
        try await withLive("/red") { live in
            let remote = try #require(live.native.remote)
            #expect(await waitUntil { remote.isReady })
            try await Task.sleep(for: .milliseconds(300))
            let beforeSent = remote.visibilityMessagesSent
            let beforeService = try #require(await live.stats()).int(CefRemote.Key.visibilityMessages)
            // Out of the window, back in, out again: three moves in one turn, ending hidden.
            live.window.contentView = nil
            live.window.contentView = live.page
            live.window.contentView = nil
            try await Task.sleep(for: .milliseconds(500))
            #expect(remote.visibilityMessagesSent == beforeSent + 1, "one message for the turn, not one for each move")
            #expect(await waitUntil(timeout: .seconds(5)) {
                await live.stats()?.int(CefRemote.Key.visibilityMessages) == beforeService + 1
            }, "the service received exactly one")
            #expect(remote.sentHidden && !remote.sentParked, "the message carried the final state")
            // Out and in again within one turn ends where it began: nothing is sent.
            live.window.contentView = live.page
            try await Task.sleep(for: .milliseconds(300))
            let shown = remote.visibilityMessagesSent
            live.window.contentView = nil
            live.window.contentView = live.page
            try await Task.sleep(for: .milliseconds(300))
            #expect(remote.visibilityMessagesSent == shown, "a page that ends where it was sends nothing")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aHiddenPageFreesTheServicesRingAndAShownOneGetsAFrameWithinASecond() async throws {
        let sink = ChromiumRemote.shared.sink
        try await withLive("/red") { live in
            let remote = try #require(live.native.remote)
            #expect(await waitUntil(timeout: .seconds(10)) { (await live.stats())?.int(CefRemote.Key.ringSurfaces) ?? 0 > 0 && Self.surface(of: remote.pageLayer) != nil }, "no ring while shown")
            // The last frame of the shown page, once it has stopped changing (a late load frame must not move it under the check).
            var last = Self.surface(of: remote.pageLayer)
            #expect(await waitUntil(timeout: .seconds(5)) {
                try? await Task.sleep(for: .milliseconds(300))
                let now = Self.surface(of: remote.pageLayer)
                defer { last = now }
                return now != nil && now === last
            })
            live.window.contentView = nil
            #expect(await waitUntil(timeout: .seconds(5)) { await live.stats()?.int(CefRemote.Key.ringSurfaces) == 0 }, "the ring is not freed while hidden")
            // The tab's last frame stays in its layer: it shows until a new one arrives.
            #expect(last != nil && Self.surface(of: remote.pageLayer) === last)
            let frames = sink.framesShown
            live.window.contentView = live.page
            #expect(await waitUntil(timeout: .seconds(1)) { sink.framesShown > frames }, "no frame within a second of the page being shown")
            #expect(try #require(await live.stats()).int(CefRemote.Key.ringSurfaces) > 0, "the ring is built again")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aPageOnTheShelfIsParkedAndItsFramesAreDroppedUntilItComesBack() async throws {
        let sink = ChromiumRemote.shared.sink
        try await withLive("/red") { live in
            let remote = try #require(live.native.remote)
            #expect(await waitUntil(timeout: .seconds(10)) { Self.surface(of: remote.pageLayer) != nil })
            // The shelf: a view of the window's content that holds the page out of sight (`WebViewParking`).
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let shelf = WebViewParkingShelf(frame: .zero)
            root.addSubview(shelf)
            live.window.contentView = root
            WebViewParking.park(live.page, in: live.window)
            #expect(await waitUntil(timeout: .seconds(5)) { remote.sentParked && !remote.sentHidden }, "parked is not hidden")
            let stats = try #require(await live.stats())
            #expect(stats.int(CefRemote.Key.visibilityMessages) >= 1)
            // Back in the window: shown, a frame follows.
            let frames = sink.framesShown
            live.page.removeFromSuperview()
            live.page.frame = root.bounds
            root.addSubview(live.page)
            #expect(await waitUntil(timeout: .seconds(5)) { !remote.sentParked && !remote.sentHidden })
            #expect(await waitUntil(timeout: .seconds(5)) { sink.framesShown > frames })
            live.window.contentView = nil
        }
    }
}
