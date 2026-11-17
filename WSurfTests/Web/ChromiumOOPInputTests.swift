// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

/// D4-12: pointer, wheel, keys, focus, cursor, tooltips and status text of a `ChromiumPage` that runs in the Chromium service. Events
/// are in-app `NSEvent`s handed to the content view (nothing is posted to the system). Two groups. The rig group gives a page a browser
/// whose messages go to a recorder (no service, no CEF) and shows WSurf's half; it runs in both lanes. The live group drives real
/// pages through the service, on fixtures at 127.0.0.1 (gated per test; the OOP lane:
/// `Tools/run-chromium-oop-tests.sh ChromiumOOPInputTests`).
@MainActor
@Suite(.serialized)
struct ChromiumOOPInputTests {
    init() {
        #if DEBUG
        // As `ChromiumOOPPageTests`: before any Chromium start of this host. Without the service the override changes nothing.
        ChromiumOOP.testOverride = true
        #endif
    }

    // MARK: Events

    private static func window(_ content: NSView, width: CGFloat = 800, height: CGFloat = 600) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderBack(nil)
        return window
    }

    /// A mouse event at (`x`, `y`) of the PAGE (CSS pixels, top-left origin). The window point is worked out here by hand (the window's
    /// y runs up from its bottom), not by asking the view, so a view that gets its flip wrong fails the tests that check the point.
    private static func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, in window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: (window.contentView?.bounds.height ?? 0) - y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: 1))
    }

    private static func key(
        _ characters: String, code: UInt16, type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }

    /// A wheel event of `pixels` (a CGEvent that is never posted).
    private static func wheel(pixels: Int32) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private static func thumbButton(_ number: Int64) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: number)
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// The responder after the content view in a test: records the key-downs that reach it.
    final class KeyRecorder: NSResponder {
        var keyCodes: [UInt16] = []

        override func keyDown(with event: NSEvent) {
            keyCodes.append(event.keyCode)
        }
    }

    final class Sent {
        var messages: [CefRemoteMessage] = []

        func sent(_ op: String) -> [CefRemoteMessage] {
            messages.filter { $0.op == op }
        }

        var mouse: [CefRemoteMessage] {
            sent(CefRemote.Op.mouse)
        }

        var keys: [CefRemoteMessage] {
            sent(CefRemote.Op.key)
        }

        var focus: [Bool] {
            sent(CefRemote.Op.focus).map { $0.bool(CefRemote.Key.flag) }
        }
    }

    // MARK: A page with a recorded browser (no service)

    private struct Rig {
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow
        let connection: ChromiumRemote
        let remote: ChromiumRemoteBrowser
        let sent: Sent
        let view: ChromiumRemoteContentView

        func end() async {
            window.contentView = nil
            window.close()
            connection.disconnect()
            await page.close()
            await context.endPrivateSession()
        }
    }

    private func makeRig() throws -> Rig {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-input-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        let sent = Sent()
        remote.outgoing = { message in
            sent.messages.append(message)
            return true
        }
        native.remote = remote
        native.preparation = Task<Void, Error> {}
        native.hasAppliedInitialSettings = true
        remote.markCreated()
        let window = Self.window(page)
        native.attachRemoteFrameLayer(to: remote)
        let view = try #require(remote.contentView)
        sent.messages.removeAll()
        return Rig(context: context, native: native, page: page, window: window, connection: connection, remote: remote, sent: sent, view: view)
    }

    @Test func aClickGoesToTheServiceAtThePointOfThePageWithItsTopLeftOrigin() async throws {
        let rig = try makeRig()
        rig.view.mouseDown(with: try Self.mouse(.leftMouseDown, 350, 120, in: rig.window))
        rig.view.mouseUp(with: try Self.mouse(.leftMouseUp, 350, 120, in: rig.window))
        let messages = rig.sent.mouse
        #expect(messages.map { $0.string(CefRemote.Key.kind) } == [CefRemote.MouseKind.down, CefRemote.MouseKind.up])
        for message in messages {
            #expect(message.double(CefRemote.Key.x) == 350)
            #expect(message.double(CefRemote.Key.y) == 120, "the point is the page's, with its origin at the top left")
            #expect(message.int(CefRemote.Key.button) == 0)
            #expect(message.double(CefRemote.Key.timestamp) > 0, "the input leg starts at the send")
        }
        #expect(rig.window.firstResponder === rig.view, "a click takes the keys")
        await rig.end()
    }

    @Test func aWheelStepGoesAsItsPixelDeltaAndASlowOneIsCarried() async throws {
        let rig = try makeRig()
        rig.view.eventPoint = { _ in CGPoint(x: 100, y: 100) }
        for _ in 0..<10 {
            rig.view.scrollWheel(with: try Self.wheel(pixels: -40))
        }
        let wheels = rig.sent.mouse.filter { $0.string(CefRemote.Key.kind) == CefRemote.MouseKind.wheel }
        #expect(wheels.count == 10)
        #expect(wheels.allSatisfy { $0.double(CefRemote.Key.deltaY) == -40 && $0.double(CefRemote.Key.deltaX) == 0 })
        #expect(wheels.allSatisfy { $0.double(CefRemote.Key.x) == 100 && $0.double(CefRemote.Key.y) == 100 })
        await rig.end()
    }

    /// WSurf's menus keep precedence: AppKit offers a key equivalent to the views, then to the menu, before it is a `keyDown`. The view
    /// takes none, so the menu does, and the page never sees the key (plan mutation: send key equivalents to the page first).
    @Test func aMenuShortcutIsNotGivenToThePage() async throws {
        let rig = try makeRig()
        let event = try Self.key("t", code: 17, flags: .command, in: rig.window)
        #expect(!rig.view.performKeyEquivalent(with: event), "the view does not take a key equivalent: the menu does")
        #expect(rig.sent.keys.isEmpty, "the page saw no key for a shortcut")
        let menu = NSMenu()
        let recorder = MenuRecorder()
        let item = NSMenuItem(title: "New Tab", action: #selector(MenuRecorder.fire(_:)), keyEquivalent: "t")
        item.target = recorder
        menu.addItem(item)
        #expect(menu.performKeyEquivalent(with: event))
        #expect(recorder.fired == 1)
        #expect(rig.sent.keys.isEmpty)
        await rig.end()
    }

    final class MenuRecorder: NSObject {
        var fired = 0

        @objc func fire(_ sender: Any?) {
            fired += 1
        }
    }

    @Test func aKeyIsSentAsKeyDownThenCharacterAndItsKeyUpFollows() async throws {
        let rig = try makeRig()
        rig.view.keyDown(with: try Self.key("w", code: 13, in: rig.window))
        rig.view.keyUp(with: try Self.key("w", code: 13, type: .keyUp, in: rig.window))
        let keys = rig.sent.keys
        #expect(keys.map { $0.int(CefRemote.Key.keyType) } == [1, 3, 2], "KEYDOWN, CHAR, KEYUP")
        #expect(keys.allSatisfy { $0.int(CefRemote.Key.nativeKeyCode) == 13 && $0.int(CefRemote.Key.windowsKeyCode) == 0x57 })
        #expect(keys[1].int(CefRemote.Key.character) == Int64("w".utf16.first ?? 0))
        await rig.end()
    }

    @Test func aKeyThePageDidNotHandleGoesOnToTheNextResponderAndAHandledOneDoesNot() async throws {
        let rig = try makeRig()
        let recorder = KeyRecorder()
        rig.view.nextResponder = recorder
        rig.view.keyDown(with: try Self.key("w", code: 13, in: rig.window))
        rig.view.keyDown(with: try Self.key("\u{F70C}", code: 101, in: rig.window))
        // The page reports the key it did not handle, by its key code. The one before it (handled) never comes back.
        let unhandled = CefRemoteMessage(CefRemote.Event.unhandledKey, browser: rig.remote.id)
        unhandled.set(CefRemote.Key.keyType, Int64(1))
        unhandled.set(CefRemote.Key.nativeKeyCode, Int64(101))
        unhandled.set(CefRemote.Key.modifiers, Int64(0))
        rig.remote.remoteEvent(unhandled)
        #expect(recorder.keyCodes == [101], "the unhandled key reached the next responder, and the handled one did not")
        rig.remote.remoteEvent(unhandled)
        #expect(recorder.keyCodes == [101], "a report with no key waiting does nothing")
        // A key-up or a character is not a key-down.
        let other = CefRemoteMessage(CefRemote.Event.unhandledKey, browser: rig.remote.id)
        other.set(CefRemote.Key.keyType, Int64(2))
        other.set(CefRemote.Key.nativeKeyCode, Int64(13))
        rig.remote.remoteEvent(other)
        #expect(recorder.keyCodes == [101])
        await rig.end()
    }

    @Test func focusLeavingThePageMovesTheKeyViewOnOrBack() async throws {
        let rig = try makeRig()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        rig.page.addSubview(field)
        rig.view.nextKeyView = field
        field.nextKeyView = rig.view
        #expect(rig.window.makeFirstResponder(rig.view))
        let take = CefRemoteMessage(CefRemote.Event.takeFocus, browser: rig.remote.id)
        take.set(CefRemote.Key.flag, true)
        rig.remote.remoteEvent(take)
        #expect(rig.window.firstResponder !== rig.view, "Tab out of the page's last field leaves the page")
        #expect(rig.window.firstResponder === field || (rig.window.firstResponder as? NSText)?.delegate === field, "the field has the keys")
        // A report that arrives when the page no longer has the keys does not take them from where they are.
        let before = rig.window.firstResponder
        rig.remote.remoteEvent(take)
        #expect(rig.window.firstResponder === before)
        await rig.end()
    }

    @Test func theServiceIsToldOfFocusAsTheViewTakesAndLosesIt() async throws {
        let rig = try makeRig()
        // The view has the keys from its attach (the page was the first responder). Let go of them, then take them again.
        #expect(rig.window.makeFirstResponder(nil))
        #expect(rig.sent.focus.last == false)
        rig.sent.messages.removeAll()
        #expect(rig.window.makeFirstResponder(rig.page))
        #expect(rig.sent.focus == [true])
        #expect(rig.window.makeFirstResponder(nil))
        #expect(rig.sent.focus == [true, false])
        await rig.end()
    }

    @Test func nothingIsSentForAHiddenPageAndTheKeyPressIsNotDelivered() async throws {
        let rig = try makeRig()
        #expect(rig.window.makeFirstResponder(rig.page))
        rig.sent.messages.removeAll()
        rig.page.isHidden = true
        rig.view.mouseDown(with: try Self.mouse(.leftMouseDown, 10, 10, in: rig.window))
        rig.view.keyDown(with: try Self.key("a", code: 0, in: rig.window))
        rig.view.scrollWheel(with: try Self.wheel(pixels: -40))
        #expect(rig.sent.mouse.isEmpty && rig.sent.keys.isEmpty, "nothing reaches a page that is not shown")
        // F2 of the D4-11 review: the MCP's key press says so when the page never received it.
        #expect(!rig.view.deliver(try Self.key("a", code: 0, in: rig.window)), "the view reports that nothing was sent")
        #expect(!rig.native.sendKeyEvent(try Self.key("a", code: 0, in: rig.window)))
        rig.page.isHidden = false
        rig.view.mouseDown(with: try Self.mouse(.leftMouseDown, 10, 10, in: rig.window))
        #expect(rig.sent.mouse.count == 1, "shown again, it is sent")
        await rig.end()
    }

    /// F2 of the D4-11 review: an MCP key press or select-all on a page in the service goes through the input path, and is reported
    /// delivered only when it was sent.
    @Test func anMCPKeyPressAndSelectAllReachThePageThroughTheInputPath() async throws {
        let rig = try makeRig()
        #expect(rig.window.makeFirstResponder(rig.page))
        rig.sent.messages.removeAll()
        #expect(rig.native.sendKeyEvent(try Self.key("a", code: 0, in: rig.window)))
        #expect(rig.sent.keys.map { $0.int(CefRemote.Key.keyType) } == [1, 3], "the page got the key, not only the report")
        #expect(rig.native.sendKeyEvent(try Self.key("a", code: 0, type: .keyUp, in: rig.window)))
        #expect(rig.sent.keys.last?.int(CefRemote.Key.keyType) == 2)
        rig.native.selectAll()
        let edits = rig.sent.sent(CefRemote.Op.edit)
        #expect(edits.map { $0.string(CefRemote.Key.kind) } == ["selectAll"], "the view implements select-all and sends it")
        // With no browser behind the view nothing is delivered, and nothing is claimed.
        rig.remote.remoteServiceEnded()
        #expect(!rig.native.sendKeyEvent(try Self.key("a", code: 0, in: rig.window)))
        await rig.end()
    }

    @Test func theThumbButtonsAreBackAndForwardAndAreNotSentAsMiddleClicks() async throws {
        let rig = try makeRig()
        rig.page.canGoBack = true
        rig.view.eventPoint = { _ in CGPoint(x: 5, y: 5) }
        rig.view.otherMouseDown(with: try Self.thumbButton(3))
        rig.view.otherMouseUp(with: try Self.thumbButton(3))
        #expect(rig.sent.sent(CefRemote.Op.goBack).count == 1, "button 4 (number 3) goes Back")
        #expect(rig.sent.mouse.isEmpty, "and is not a click on the page")
        await rig.end()
    }

    // MARK: Real pages through the service

    private static let routes: [String: HTTPFixtureServer.Response] = [
        // Fixed positions, no margin: a point of the page is a point of the viewport.
        "/input": .html("""
            <!doctype html><title>Input</title><body style="margin:0;height:3000px">
            <input id="f" style="position:absolute;left:20px;top:20px;width:200px;height:30px;font:16px sans-serif">
            <button id="b" style="position:absolute;left:20px;top:120px;width:120px;height:40px" onclick="window.clicks=(window.clicks||0)+1">Go</button>
            <a id="l" href="/other" style="position:absolute;left:20px;top:180px;display:block;width:150px;height:30px">link</a>
            <div id="t" title="a tip" style="position:absolute;left:20px;top:230px;width:150px;height:30px;background:#ddd">tip</div>
            <div id="m" style="position:absolute;left:300px;top:300px;width:100px;height:100px;background:#f00"
                 onclick="window.hit=[event.clientX,event.clientY]"></div>
            """),
        "/tab": .html("""
            <!doctype html><title>Tab</title><body style="margin:0">
            <input id="a" style="position:absolute;left:20px;top:20px;width:200px;height:30px">
            <input id="z" style="position:absolute;left:20px;top:70px;width:200px;height:30px">
            """),
        "/other": .html("<!doctype html><title>Other</title><p>other"),
    ]

    private struct Live {
        let server: HTTPFixtureServer
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow
        var view: ChromiumRemoteContentView? {
            native.remote?.contentView
        }

        func js(_ script: String) async -> Any? {
            try? await page.evaluateJavaScript(script)
        }

        func number(_ script: String) async -> Double? {
            await js(script) as? Double
        }

        func stats() async -> CefRemoteMessage? {
            guard case let .value(reply) = await ChromiumRemote.shared.request(
                CefRemoteMessage(CefRemote.Op.debugStats, browser: native.remote?.id ?? -1)) else { return nil }
            return reply
        }

        func click(_ x: CGFloat, _ y: CGFloat) throws {
            let view = try #require(view)
            view.mouseMoved(with: try ChromiumOOPInputTests.mouse(.mouseMoved, x, y, in: window))
            view.mouseDown(with: try ChromiumOOPInputTests.mouse(.leftMouseDown, x, y, in: window))
            view.mouseUp(with: try ChromiumOOPInputTests.mouse(.leftMouseUp, x, y, in: window))
        }

        func finish() async {
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
        }
    }

    private func withLive(_ path: String, container: Bool = false, _ body: (Live) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window: NSWindow
        if container {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            page.frame = root.bounds
            root.addSubview(page)
            window = Self.window(root)
        } else {
            window = Self.window(page)
        }
        let live = Live(server: server, context: context, native: native, page: page, window: window)
        do {
            let url = try server.url(path)
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(live.view != nil)
            try await body(live)
        } catch {
            await live.finish()
            throw error
        }
        await live.finish()
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func typingWsurfIntoAFieldGivesItsValueAndTheServiceHasTheInputStats() async throws {
        try await withLive("/input") { live in
            try #require(live.window.makeFirstResponder(live.page))
            try live.click(60, 35)
            for (character, code) in [("w", UInt16(13)), ("s", 1), ("u", 32), ("r", 15), ("f", 3)] {
                live.view?.keyDown(with: try Self.key(character, code: code, in: live.window))
                live.view?.keyUp(with: try Self.key(character, code: code, type: .keyUp, in: live.window))
            }
            #expect(await waitUntil { await live.js("document.getElementById('f').value") as? String == "wsurf" })
            let stats = try #require(await live.stats())
            #expect(stats.int(CefRemote.Key.inputEvents) >= 15, "every input message was counted by the browser")
            #expect(stats.int(CefRemote.Key.inputFocus) == 1, "the page's Chromium has the focus")
            print("D4-12 input leg: events \(stats.int(CefRemote.Key.inputEvents)) max \(stats.double(CefRemote.Key.inputLegMaxMs)) ms")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aClickOnAButtonCountsOnceAndAClickAtAKnownPointLandsThere() async throws {
        try await withLive("/input") { live in
            try live.click(80, 140)
            #expect(await waitUntil { await live.number("window.clicks || 0") == 1 })
            try live.click(350, 350)
            #expect(await waitUntil { (await live.js("JSON.stringify(window.hit || null)") as? String) == "[350,350]" },
                    "the click lands where it was made: the y-flip and the scale are right")
            #expect(await live.number("window.clicks || 0") == 1, "the first click was one click")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func tenWheelStepsOf40PointsScrollThePageBy400() async throws {
        try await withLive("/input") { live in
            let view = try #require(live.view)
            view.eventPoint = { _ in CGPoint(x: 500, y: 400) }
            for _ in 0..<10 {
                view.scrollWheel(with: try Self.wheel(pixels: -40))
            }
            let scrolled = await waitUntil { (await live.number("Math.round(window.scrollY)")) == 400 }
            let scrollY = await live.number("window.scrollY")
            #expect(scrolled, "scrollY is \(String(describing: scrollY))")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func theCursorIsAnIBeamOverTheFieldAndAnArrowOffIt() async throws {
        try await withLive("/input") { live in
            let view = try #require(live.view)
            view.mouseMoved(with: try Self.mouse(.mouseMoved, 60, 35, in: live.window))
            #expect(await waitUntil { view.remoteCursor == NSCursor.iBeam })
            view.mouseMoved(with: try Self.mouse(.mouseMoved, 600, 500, in: live.window))
            #expect(await waitUntil { view.remoteCursor == NSCursor.arrow })
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aTitleGivesATooltipAndHoveringALinkGivesStatusText() async throws {
        try await withLive("/input") { live in
            let view = try #require(live.view)
            let hovered = HoverBox()
            live.page.onLinkHovered = { hovered.urls.append($0) }
            view.mouseMoved(with: try Self.mouse(.mouseMoved, 60, 245, in: live.window))
            #expect(await waitUntil { view.toolTip == "a tip" }, "the tooltip is \(String(describing: view.toolTip))")
            view.mouseMoved(with: try Self.mouse(.mouseMoved, 60, 195, in: live.window))
            #expect(await waitUntil { hovered.urls.contains { $0?.path == "/other" } }, "hovered: \(hovered.urls)")
            view.mouseMoved(with: try Self.mouse(.mouseMoved, 600, 500, in: live.window))
            #expect(await waitUntil { hovered.urls.last.map { $0 == nil } == true }, "the status text goes when the pointer leaves the link")
        }
    }

    final class HoverBox {
        var urls: [URL?] = []
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aKeyThePageDoesNotHandleReachesTheNextResponder() async throws {
        try await withLive("/input") { live in
            let view = try #require(live.view)
            let recorder = KeyRecorder()
            view.nextResponder = recorder
            try #require(live.window.makeFirstResponder(live.page))
            // No field has the focus and nothing listens for keys: the page leaves F9 unhandled, and it goes on in the app.
            view.keyDown(with: try Self.key("\u{F70C}", code: 101, in: live.window))
            view.keyUp(with: try Self.key("\u{F70C}", code: 101, type: .keyUp, in: live.window))
            #expect(await waitUntil { recorder.keyCodes.contains(101) }, "F9 reached the next responder: \(recorder.keyCodes)")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func tabFromThePagesLastFieldMovesTheFirstResponderOutOfThePage() async throws {
        try await withLive("/tab", container: true) { live in
            let view = try #require(live.view)
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            live.window.contentView?.addSubview(field)
            view.nextKeyView = field
            field.nextKeyView = view
            try #require(live.window.makeFirstResponder(live.page))
            try live.click(60, 85)
            #expect(await live.js("document.activeElement.id") as? String == "z")
            view.keyDown(with: try Self.key("\t", code: 48, in: live.window))
            view.keyUp(with: try Self.key("\t", code: 48, type: .keyUp, in: live.window))
            #expect(await waitUntil { live.window.firstResponder !== view }, "the first responder is still the page's view")
        }
    }
}
