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
                    return stats?.double(CefRemote.Key.width) == Double(size.width) && stats?.double(CefRemote.Key.height) == Double(size.height)
                }, "the service's view rect did not become \(size)")
                let stats = try #require(await live.stats())
                #expect(stats.double(CefRemote.Key.scale) == Double(scale), "the service's scale follows the window's backing scale")
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

    /// The exit gate's F4: 120 sizes, one every 16 ms (programmatic `setFrame`s, the closest a test gets to a drag), on a page that
    /// repaints on every frame. Before the service held a new size back until it was stable (or 100 ms old), every size that
    /// painted allocated a ring surface: 106 new IOSurfaces for 120 sizes. The count is `slotsMade` of `debug.stats`.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aLiveResizeOf120SizesAllocatesAFewSurfacesAndThePageEndsAtItsFinalSize() async throws {
        try await withLive("/animated") { live in
            let scale = live.window.backingScaleFactor
            let remote = try #require(live.native.remote)
            #expect(await waitUntil(timeout: .seconds(10)) { Self.surface(of: remote.pageLayer) != nil })
            try await Task.sleep(for: .milliseconds(500))
            let before = try #require(await live.stats())
            let start = live.window.contentView?.frame.size ?? CGSize(width: 800, height: 600)
            // Down by 4 points a step to 240 points narrower, and back: 120 sizes.
            var widths: [CGFloat] = (1...60).map { start.width - 4 * CGFloat($0) }
            widths += (0..<60).map { start.width - 240 + 4 * CGFloat($0 + 1) }
            let sent = remote.resizesSent
            let began = ContinuousClock.now
            for width in widths {
                live.window.setContentSize(CGSize(width: width, height: start.height))
                try await Task.sleep(for: .milliseconds(16))
            }
            let seconds = Double((ContinuousClock.now - began).components.seconds) + Double((ContinuousClock.now - began).components.attoseconds) / 1e18
            let final = CGSize(width: widths.last ?? start.width, height: start.height)
            #expect(await waitUntil(timeout: .seconds(10)) {
                Self.surface(of: remote.pageLayer).map { IOSurfaceGetWidth($0) == Int(final.width * scale) && IOSurfaceGetHeight($0) == Int(final.height * scale) } == true
            }, "the page layer never showed a \(final) frame: the final size gets its frame")
            let after = try #require(await live.stats())
            let made = after.int(CefRemote.Key.slotsMade) - before.int(CefRemote.Key.slotsMade)
            let frames = after.int(CefRemote.Key.framesSent) - before.int(CefRemote.Key.framesSent)
            let dropped = after.int(CefRemote.Key.framesDropped) - before.int(CefRemote.Key.framesDropped)
            print("ChromiumOOPDisplayTests observed: 120 sizes in a live resize: \(made) new ring surfaces, \(frames) frames sent, \(dropped) dropped,"
                + " \(remote.resizesSent - sent) resize messages (the exit gate measured 106 new surfaces before the service held sizes back)")
            // The service takes a changing size at most every 100 ms (`FramePresenter.maxWait`), and the final one fills its ring: the budget
            // follows the drag's duration, not the number of sizes (26-32 measured over about 2 s). A service that paints every size made
            // 69-70 (106 at the exit gate), so a fixed cap of 60 keeps that regression visible however long a loaded machine takes.
            let budget = 60
            #expect(made <= budget, "\(made) new ring surfaces for 120 sizes over \(seconds) s (budget \(budget))")
            #expect(frames >= 5, "the page still repainted during the drag: \(frames) frames")
            #expect(remote.pageLayer?.frame.size == live.native.bounds.size)
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
            // The surface's rows are top-first (the first row is the top of the page).
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
            // Which way up the layer shows the surface, against what AppKit itself shows: a flipped view of the same size and parent
            // that draws the same two halves (top red, bottom blue). Both are rendered the same way into a bitmap, so whatever the
            // render does to a flipped hierarchy (it does not undo the flip as the window server does) happens to both.
            let reference = UprightReference(frame: live.native.frame)
            live.page.addSubview(reference)
            reference.wantsLayer = true
            reference.display()
            let shown = Self.halves(of: live.native.layer), expected = Self.halves(of: reference.layer)
            print("ChromiumOOPDisplayTests observed: layer render (top, bottom): page \(shown?.top ?? "-"), \(shown?.bottom ?? "-");"
                + " reference view \(expected?.top ?? "-"), \(expected?.bottom ?? "-")")
            #expect(expected != nil && expected?.top != expected?.bottom, "the reference view did not render")
            #expect(shown?.top == expected?.top && shown?.bottom == expected?.bottom, "the page layer shows the frame the other way up than a flipped AppKit view shows it")
            reference.removeFromSuperview()
        }
    }

    /// A flipped view that draws the `/split` page's two halves: red on top, blue below.
    private final class UprightReference: NSView {
        override var isFlipped: Bool {
            true
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2).fill()
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
            NSRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2).fill()
        }
    }

    /// The colour (by dominance) a layer renders at a quarter and three quarters of the way down the bitmap rows, or nil.
    private static func halves(of layer: CALayer?) -> (top: String, bottom: String)? {
        guard let layer, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = Int(layer.bounds.width), height = Int(layer.bounds.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        layer.render(in: context)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        func name(_ row: Int) -> String {
            let at = bytes + row * width * 4 + (width / 2) * 4
            if at[0] > 200, at[2] < 80 { return "red" }
            if at[2] > 200, at[0] < 80 { return "blue" }
            return "other(\(at[0]),\(at[1]),\(at[2]))"
        }
        return (name(height / 4), name(height * 3 / 4))
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
