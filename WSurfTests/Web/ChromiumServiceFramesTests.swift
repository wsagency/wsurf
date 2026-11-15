// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import IOSurface
import Testing
import XPC

@testable import CefKit
@testable import WSurf

/// D4-7: the frames of a windowless browser in the Chromium service, as a test connection (standing in for WSurf's frames
/// connection) receives them: copies of CEF's IOSurfaces from a ring of `CefRemote.frameRingSize`, on the frames connection, with
/// the entry timestamp. Raw XPC (`ChromiumServiceClient`), pages from a fixture server on 127.0.0.1. Every test needs
/// `WSurf Chromium.xpc` (the OOP lane: `Tools/run-chromium-oop-tests.sh ChromiumServiceFramesTests`), is serialized, and ends by
/// waiting for its service instance to leave. WSurf's own side of the connection is D4-3 (the sink) and D4-5 (the client).
@Suite(.serialized)
struct ChromiumServiceFramesTests {
    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/red": .html("<!doctype html><title>Red</title><body style=\"margin:0;background:#f00\"></body>"),
        "/blue": .html("<!doctype html><title>Blue</title><body style=\"margin:0;background:#00f\"></body>"),
        // Repaints on every animation frame, so frames keep coming and the ring is reused.
        "/animated": .html("""
            <!doctype html><title>Animated</title><body style="margin:0;background:#f00"></body>
            <script>let n = 0; (function tick() { document.body.style.background = n++ % 2 ? "#f00" : "#00f"; requestAnimationFrame(tick) })()</script>
            """),
        "/select": .html("""
            <!doctype html><title>Select</title><body style="margin:0;background:#fff">
            <select style="position:absolute;left:20px;top:20px;width:200px;height:30px"><option>A</option><option>B</option><option>C</option></select>
            </body>
            """),
    ]

    /// A started service with a request context, a fixture server, and a second connection that stands in for WSurf's frames
    /// connection (not attached until `attachFrames`).
    private struct Rig {
        let client: ChromiumServiceClient
        let frames: ChromiumServiceClient
        let server: HTTPFixtureServer

        func url(_ path: String) throws -> String {
            try server.url(path).absoluteString
        }

        /// The frames hello, answered by the service: true when it attached this connection.
        @discardableResult
        func attachFrames() throws -> Bool {
            try frames.call(CefRemoteMessage(CefRemote.Op.framesHello)).bool(CefRemote.Key.success)
        }

        func finish() {
            frames.close()
            client.finish()
        }
    }

    private static func rig() async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: routes, waitsForBody: true)
        let client = try ChromiumServiceClient()
        client.hostAnswersQuestions = true
        let reply = try client.hello()
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        try client.context("profile")
        // The host's process makes the frames connection, as WSurf does; it has its own queue, so it never touches the control one.
        let frames = try ChromiumServiceClient(root: client.root)
        return Rig(client: client, frames: frames, server: server)
    }

    @discardableResult
    private static func open(_ rig: Rig, _ id: Int64, _ path: String, debug: String? = nil) throws -> CefRemoteMessage {
        let reply = try rig.client.createBrowser(id, url: rig.url(path), context: "profile", debug: debug)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        #expect(rig.client.waitEvent(CefRemote.Event.browserReady) { $0.browser == id } != nil, "browser.ready")
        #expect(rig.client.waitEvent(CefRemote.Event.loadEnd) { $0.browser == id } != nil, "load.end")
        return reply
    }

    // MARK: Reading what arrived

    /// The `frame` events for `browser` that came on the frames connection, popup frames or the page's.
    private static func frames(_ rig: Rig, _ browser: Int64, popup: Bool = false) -> [CefRemoteMessage] {
        rig.frames.events(CefRemote.Event.frame).filter { $0.browser == browser && $0.bool(CefRemote.Key.flag) == popup }
    }

    /// A pixel's colour by dominance, not by exact value: the page's `#f00` and `#00f` may come out of the compositor with a
    /// colour-space conversion, and what the tests ask is only which of the two the centre of the frame is.
    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        func matches(_ colour: Colour) -> Bool {
            switch colour {
            case .red:
                red > 200 && green < 80 && blue < 80
            case .blue:
                blue > 200 && red < 80 && green < 80
            }
        }
    }

    private enum Colour {
        case red, blue
    }

    /// The surface a `frame` event carries, and its pixel at the centre (BGRA or RGBA, as its pixel format says).
    private static func surface(of frame: CefRemoteMessage) -> IOSurfaceRef? {
        xpc_dictionary_get_value(frame.object, CefRemote.Key.surface).flatMap { IOSurfaceLookupFromXPCObject($0) }
    }

    private static func centre(of surface: IOSurfaceRef) -> Pixel? {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let bytes = base + (height / 2) * IOSurfaceGetBytesPerRow(surface) + (width / 2) * 4
        switch IOSurfaceGetPixelFormat(surface) {
        case 0x4247_5241:  // 'BGRA'
            return Pixel(red: bytes[2], green: bytes[1], blue: bytes[0])
        case 0x5247_4241:  // 'RGBA'
            return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2])
        default:
            return nil
        }
    }

    /// The first frame of `browser`, after the first `after` of them, whose centre pixel is `colour`, received now or within `timeout`.
    private static func waitFrame(_ rig: Rig, _ browser: Int64, after: Int = 0, colour: Colour, timeout: TimeInterval = 15) -> CefRemoteMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        func found() -> CefRemoteMessage? {
            frames(rig, browser).dropFirst(after).first { frame in
                surface(of: frame).flatMap(centre(of:))?.matches(colour) == true
            }
        }
        repeat {
            if let frame = found() {
                return frame
            }
            usleep(20_000)
        } while Date() < deadline
        return found()
    }

    /// The browser's own `debug.stats` (the ring, the paths, the counts), from the instance this client said hello to.
    private static func stats(_ client: ChromiumServiceClient, _ browser: Int64) throws -> CefRemoteMessage {
        let reply = try client.call(CefRemoteMessage(CefRemote.Op.debugStats, browser: browser))
        #expect(pid_t(reply.int(CefRemote.Key.pid)) == client.pid, "the stats came from another service instance")
        return reply
    }

    private static func ringSurfaces(_ rig: Rig, _ browser: Int64, until done: (Int64) -> Bool, timeout: TimeInterval = 10) throws -> Int64 {
        let deadline = Date().addingTimeInterval(timeout)
        var count = try stats(rig.client, browser).int(CefRemote.Key.ringSurfaces)
        while !done(count), Date() < deadline {
            usleep(100_000)
            count = try stats(rig.client, browser).int(CefRemote.Key.ringSurfaces)
        }
        return count
    }

    private static func machSeconds() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)) / 1e9
    }

    // MARK: Frames

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aRedPageGivesFramesWhoseCentrePixelIsRedAndThatCarryTheEntryTimestamp() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        #expect(try rig.attachFrames(), "the host's own process may attach a frames connection")
        try Self.open(rig, 1, "/red")
        let frame = try #require(Self.waitFrame(rig, 1, colour: .red), "a frame whose centre is red")
        let surface = try #require(Self.surface(of: frame))
        // The 800 x 600 view at scale 1 (`ChromiumServiceClient.createBrowser`).
        #expect(IOSurfaceGetWidth(surface) == 800)
        #expect(IOSurfaceGetHeight(surface) == 600)
        // The timestamp is CEF's callback entry on the mach clock the two processes share: in the past, and not long ago.
        let stamp = frame.double(CefRemote.Key.timestamp)
        let now = Self.machSeconds()
        #expect(stamp > 0 && stamp <= now && now - stamp < 60, "timestamp \(stamp) against now \(now)")
        let stats = try Self.stats(rig.client, 1)
        #expect(stats.int(CefRemote.Key.acceleratedFrames) >= 1, "the shared-texture path ran")
        #expect(stats.int(CefRemote.Key.cpuFrames) == 0)
        #expect(stats.int(CefRemote.Key.framesSent) >= 1)
        let ring = stats.int(CefRemote.Key.ringSurfaces)
        #expect(ring >= 1 && ring <= CefRemote.frameRingSize, "ring \(ring)")
        // Review S1: every accelerated frame either carries CEF's colour-space tag to its copy or is counted as untagged. What CEF's
        // surface really carries is recorded in the log, not asserted.
        let tagged = stats.int(CefRemote.Key.colourTagged)
        let untagged = stats.int(CefRemote.Key.colourUntagged)
        print("ChromiumServiceFramesTests colour tag: tagged \(tagged), untagged \(untagged)")
        #expect(tagged + untagged >= 1, "no frame was counted for its colour space")
        #expect((IOSurfaceCopyValue(surface, kIOSurfaceColorSpace) != nil) == (untagged == 0), "the copy's tag does not follow the source's")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theRingNeverHoldsMoreThanItsSizeWhileAnAnimatedPageKeepsPainting() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        try Self.open(rig, 1, "/animated")
        let first = try #require(Self.waitFrame(rig, 1, colour: .blue), "a blue frame")
        #expect(Self.surface(of: first) != nil)
        // Frames keep coming, and they are copies from a ring that is reused: more frames than surfaces.
        var sent = 0
        let deadline = Date().addingTimeInterval(15)
        while sent < 12, Date() < deadline {
            sent = Self.frames(rig, 1).count
            usleep(50_000)
        }
        #expect(sent >= 12, "\(sent) frames")
        let stats = try Self.stats(rig.client, 1)
        print("ChromiumServiceFramesTests ring overwrites: \(stats.int(CefRemote.Key.ringOverwrites)) in \(stats.int(CefRemote.Key.framesSent)) frames")
        let ring = stats.int(CefRemote.Key.ringSurfaces)
        #expect(ring >= 1 && ring <= CefRemote.frameRingSize, "ring \(ring) of at most \(CefRemote.frameRingSize)")
        // The surfaces that arrived are few and distinct from CEF's pool: the service never sends CEF's own surface.
        let distinct = Set(Self.frames(rig, 1).compactMap { Self.surface(of: $0).map(IOSurfaceGetID) })
        #expect(distinct.count <= CefRemote.frameRingSize, "\(distinct.count) distinct surfaces were sent")
    }

    // MARK: Hidden

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHiddenBrowserFreesItsRingAndTheFirstFrameAfterItIsShownBuildsItAgain() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        try Self.open(rig, 1, "/animated")
        _ = try #require(Self.waitFrame(rig, 1, colour: .blue))
        #expect(try Self.stats(rig.client, 1).int(CefRemote.Key.ringSurfaces) >= 1, "frames built the ring")
        // was_hidden: the ring goes, every surface of it.
        let hidden = try rig.client.command(CefRemote.Op.visibility, browser: 1) { $0.set(CefRemote.Key.hidden, true) }
        #expect(hidden.bool(CefRemote.Key.success))
        let freed = try Self.ringSurfaces(rig, 1, until: { $0 == 0 })
        #expect(freed == 0, "a hidden browser holds \(freed) surfaces")
        // No frames while hidden: the count stops growing.
        usleep(500_000)
        let whileHidden = Self.frames(rig, 1).count
        usleep(1_000_000)
        #expect(Self.frames(rig, 1).count == whileHidden, "frames kept coming while hidden")
        #expect(try Self.stats(rig.client, 1).int(CefRemote.Key.ringSurfaces) == 0)
        // Chromium itself stopped painting (`was_hidden`): the presenter drops frames while hidden, so only Chromium's own paint
        // count, which is taken before that drop, tells. A page that animates at 30 fps would paint about 30 times here; a few
        // paints already in flight are allowed (review M1).
        let paintsBefore = try Self.stats(rig.client, 1).int(CefRemote.Key.acceleratedFrames)
        usleep(1_000_000)
        let paintsAfter = try Self.stats(rig.client, 1).int(CefRemote.Key.acceleratedFrames)
        #expect(paintsAfter - paintsBefore <= 3, "Chromium kept painting while hidden: \(paintsAfter - paintsBefore) paints in 1 s")
        // Shown again: frames resume, and the ring is built by the first of them.
        let shown = try rig.client.command(CefRemote.Op.visibility, browser: 1) { $0.set(CefRemote.Key.hidden, false) }
        #expect(shown.bool(CefRemote.Key.success))
        let after = Self.frames(rig, 1).count
        #expect(Self.waitFrame(rig, 1, after: after, colour: .blue) != nil || Self.waitFrame(rig, 1, after: after, colour: .red) != nil,
                "frames did not resume after the browser was shown")
        let rebuilt = try Self.ringSurfaces(rig, 1, until: { $0 >= 1 })
        #expect(rebuilt >= 1 && rebuilt <= CefRemote.frameRingSize, "rebuilt ring \(rebuilt)")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aStillPageShownAgainSendsAFrameAtOnceBecauseTheServiceInvalidatesIt() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        try Self.open(rig, 1, "/red")
        _ = try #require(Self.waitFrame(rig, 1, colour: .red))
        _ = try rig.client.command(CefRemote.Op.visibility, browser: 1) { $0.set(CefRemote.Key.hidden, true) }
        #expect(try Self.ringSurfaces(rig, 1, until: { $0 == 0 }) == 0)
        let before = Self.frames(rig, 1).count
        _ = try rig.client.command(CefRemote.Op.visibility, browser: 1) { $0.set(CefRemote.Key.hidden, false) }
        // A page that does not change paints nothing of its own: the frame is the service's invalidate.
        #expect(Self.waitFrame(rig, 1, after: before, colour: .red, timeout: 5) != nil, "no frame after the page was shown")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserCreatedHiddenBuildsNoRingUntilItIsShown() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        let message = CefRemoteMessage(CefRemote.Op.createBrowser, browser: 1)
        // An animated page: Chromium would paint it about 30 times a second if `was_hidden(1)` did not reach it.
        message.set(CefRemote.Key.url, try rig.url("/animated"))
        message.set(CefRemote.Key.context, "profile")
        message.set(CefRemote.Key.width, 800.0)
        message.set(CefRemote.Key.height, 600.0)
        message.set(CefRemote.Key.scale, 1.0)
        message.set(CefRemote.Key.hidden, true)
        #expect(try rig.client.call(message).bool(CefRemote.Key.success))
        #expect(rig.client.waitEvent(CefRemote.Event.browserReady) { $0.browser == 1 } != nil)
        usleep(1_500_000)
        #expect(Self.frames(rig, 1).isEmpty, "a hidden browser sent frames")
        // `was_hidden(1)` at creation: Chromium made no (or hardly any) paint, not just a presenter that dropped them (review M1).
        let paints = try Self.stats(rig.client, 1).int(CefRemote.Key.acceleratedFrames)
        #expect(paints <= 3, "a browser created hidden painted \(paints) times")
        #expect(try Self.stats(rig.client, 1).int(CefRemote.Key.ringSurfaces) == 0)
        _ = try rig.client.command(CefRemote.Op.visibility, browser: 1) { $0.set(CefRemote.Key.hidden, false) }
        #expect(Self.waitFrame(rig, 1, colour: .red) != nil || Self.waitFrame(rig, 1, colour: .blue) != nil, "no frame once shown")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aParkedBrowserDropsItsFramesAndSendsOneWhenItComesBack() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        try Self.open(rig, 1, "/animated")
        _ = try #require(Self.waitFrame(rig, 1, colour: .blue))
        _ = try rig.client.command(CefRemote.Op.visibility, browser: 1) { $0.set(CefRemote.Key.parked, true) }
        usleep(500_000)
        let whileParked = Self.frames(rig, 1).count
        let paintsBefore = try Self.stats(rig.client, 1).int(CefRemote.Key.acceleratedFrames)
        usleep(1_000_000)
        #expect(Self.frames(rig, 1).count == whileParked, "frames kept coming while parked")
        // The contrast to the hidden test: a parked page is still visible to Chromium, which keeps painting (the presenter drops
        // those), so the counter the hidden test bounds is live.
        let paintsAfter = try Self.stats(rig.client, 1).int(CefRemote.Key.acceleratedFrames)
        #expect(paintsAfter - paintsBefore >= 5, "a parked page painted only \(paintsAfter - paintsBefore) times in 1 s")
        #expect(try Self.stats(rig.client, 1).int(CefRemote.Key.framesDropped) >= 1)
        _ = try rig.client.command(CefRemote.Op.visibility, browser: 1) { $0.set(CefRemote.Key.parked, false) }
        #expect(Self.waitFrame(rig, 1, after: whileParked, colour: .blue) != nil || Self.waitFrame(rig, 1, after: whileParked, colour: .red) != nil)
    }

    // MARK: CPU fallback

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserWithoutASharedTexturePaintsIntoMemoryAndItsFramesGoThroughTheSameRing() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        try Self.open(rig, 1, "/red", debug: CefRemote.DebugCreate.cpuPaint)
        let frame = try #require(Self.waitFrame(rig, 1, colour: .red), "a CPU frame whose centre is red")
        #expect(IOSurfaceGetWidth(try #require(Self.surface(of: frame))) == 800)
        let stats = try Self.stats(rig.client, 1)
        #expect(stats.int(CefRemote.Key.cpuFrames) >= 1, "on_paint ran")
        #expect(stats.int(CefRemote.Key.acceleratedFrames) == 0)
        let ring = stats.int(CefRemote.Key.ringSurfaces)
        #expect(ring >= 1 && ring <= CefRemote.frameRingSize, "ring \(ring)")
    }

    // MARK: Popup

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aSelectsPopupIsShownWithItsRectangleAndItsOwnFramesAndHiddenAgainOnTheFramesConnection() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        try Self.open(rig, 1, "/select")
        // A mouse click through DevTools (the renderer's input, not the system's) opens the list.
        func mouse(_ type: String, _ x: Int, _ y: Int, id: Int64) {
            _ = rig.client.devTools(
                "Input.dispatchMouseEvent",
                params: #"{"type":"\#(type)","x":\#(x),"y":\#(y),"button":"left","clickCount":1}"#,
                id: id, browser: 1
            )
        }
        mouse("mousePressed", 100, 35, id: 30)
        mouse("mouseReleased", 100, 35, id: 31)
        // CEF shows the popup first (`on_popup_show`, no rectangle yet) and then sizes it (`on_popup_size`): the event that says
        // visible with a size is the second one, and both ride the frames connection.
        let shown = rig.frames.waitEvent(CefRemote.Event.popup, timeout: 10) {
            $0.bool(CefRemote.Key.flag) && $0.double(CefRemote.Key.width) > 0 && $0.double(CefRemote.Key.height) > 0
        }
        #expect(shown != nil, "the popup was shown, with a rectangle")
        #expect(rig.frames.events(CefRemote.Event.popup).first?.bool(CefRemote.Key.flag) == true, "the first popup event is the show")
        // Its own frames, flagged as the popup's, and not the page's.
        let deadline = Date().addingTimeInterval(10)
        while Self.frames(rig, 1, popup: true).isEmpty, Date() < deadline {
            usleep(50_000)
        }
        #expect(!Self.frames(rig, 1, popup: true).isEmpty, "the popup's own frames arrived")
        let ring = try Self.stats(rig.client, 1).int(CefRemote.Key.ringSurfaces)
        #expect(ring >= 2 && ring <= 2 * CefRemote.frameRingSize, "the popup has its own ring: \(ring)")
        let popupRing = try Self.stats(rig.client, 1).int(CefRemote.Key.popupRingSurfaces)
        #expect(popupRing >= 1 && popupRing <= CefRemote.frameRingSize, "the popup's ring: \(popupRing)")
        // A click elsewhere closes it, and the service says so on the same connection; its ring goes with it.
        mouse("mousePressed", 700, 500, id: 32)
        mouse("mouseReleased", 700, 500, id: 33)
        let hidden = rig.frames.waitEvent(CefRemote.Event.popup, timeout: 10) { !$0.bool(CefRemote.Key.flag) }
        #expect(hidden != nil, "the popup was hidden")
        // Its ring was freed before the event was sent, and a late popup paint does not build it again (review S4).
        #expect(try Self.stats(rig.client, 1).int(CefRemote.Key.popupRingSurfaces) == 0, "the popup's ring outlived the popup")
        usleep(500_000)
        #expect(try Self.stats(rig.client, 1).int(CefRemote.Key.popupRingSurfaces) == 0, "the popup's ring was built again after it was hidden")
    }

    // MARK: Which connection frames go to

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserWithNoFramesConnectionBuildsNoRingAndSendsNothingUntilOneAttachesAndThenGetsAFrameAtOnce() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try Self.open(rig, 1, "/red")
        usleep(1_000_000)
        let before = try Self.stats(rig.client, 1)
        #expect(before.int(CefRemote.Key.framesSent) == 0)
        #expect(before.int(CefRemote.Key.ringSurfaces) == 0, "nothing was copied with nobody to send to")
        #expect(before.int(CefRemote.Key.framesDropped) >= 1, "frames were painted and dropped")
        // The connection attaches after the page painted: a still page paints nothing more, so the service asks for a frame.
        try rig.attachFrames()
        #expect(Self.waitFrame(rig, 1, colour: .red) != nil, "the frame the attach asked for")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aSecondFramesConnectionReplacesTheFirstAndOnlyItGetsFramesAfterwards() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachFrames()
        try Self.open(rig, 1, "/animated")
        _ = try #require(Self.waitFrame(rig, 1, colour: .blue))
        let second = try ChromiumServiceClient(root: rig.client.root)
        defer { second.close() }
        #expect(try second.call(CefRemoteMessage(CefRemote.Op.framesHello)).bool(CefRemote.Key.success))
        let deadline = Date().addingTimeInterval(10)
        while second.events(CefRemote.Event.frame).isEmpty, Date() < deadline {
            usleep(50_000)
        }
        #expect(!second.events(CefRemote.Event.frame).isEmpty, "the new connection gets frames")
        // The first one was cancelled by the service: what it had is all it will ever have.
        usleep(300_000)
        let firstCount = rig.frames.events(CefRemote.Event.frame).count
        usleep(1_000_000)
        #expect(rig.frames.events(CefRemote.Event.frame).count == firstCount, "the replaced connection kept getting frames")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aFramesConnectionIsRefusedAfterAHelloThatDidNotStartCEFAndBeforeAnyHello() async throws {
        // A hello whose root is not canonical is refused (CEF does not start) but leaves a control connection behind: it must not
        // be a host for the frames connection (review F8b: accepted only after a successful hello).
        let alias = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: alias) }
        let client = try ChromiumServiceClient(root: alias)
        defer { client.finish(expectExit: false) }
        let early = try ChromiumServiceClient(root: alias)
        defer { early.close() }
        let before = try early.call(CefRemoteMessage(CefRemote.Op.framesHello))
        #expect(!before.bool(CefRemote.Key.success), "no hello yet")
        let hello = try client.hello()
        #expect(!hello.bool(CefRemote.Key.success), "the alias root is refused")
        let side = try ChromiumServiceClient(root: alias)
        defer { side.close() }
        let reply = try side.call(CefRemoteMessage(CefRemote.Op.framesHello))
        #expect(!reply.bool(CefRemote.Key.success), "a frames connection attached to a host whose CEF never started")
        #expect(!(try side.call(CefRemoteMessage(CefRemote.Op.inputHello)).bool(CefRemote.Key.success)), "and the input connection too")
    }
}
