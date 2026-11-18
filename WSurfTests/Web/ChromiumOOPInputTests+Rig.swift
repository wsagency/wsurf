// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

// The rig of `ChromiumOOPInputTests`, moved here unchanged (only `private` is dropped) so that the suites of the later phase-3 PRs use it
// instead of copying it: the in-app events (`window`, `mouse`, `key`, `wheel`, `thumbButton`), a page with a browser whose messages go to
// a recorder and no service (`makeRig`, `Rig`, `Sent`), a test main menu (`withMenu`) and a real page through the service on a loopback
// fixture (`withLive`, `Live`, with the suite's `routes`). Same shape as `ChromiumOOPDisplayTests+Rig.swift`.
extension ChromiumOOPInputTests {
    // MARK: Events

    static func window(_ content: NSView, width: CGFloat = 800, height: CGFloat = 600) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderBack(nil)
        return window
    }

    /// A mouse event at (`x`, `y`) of the PAGE (CSS pixels, top-left origin). The window point is worked out here by hand (the window's
    /// y runs up from its bottom), not by asking the view, so a view that gets its flip wrong fails the tests that check the point.
    static func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, in window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: (window.contentView?.bounds.height ?? 0) - y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: 1))
    }

    static func key(
        _ characters: String, code: UInt16, type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }

    /// A wheel event of `pixels` (a CGEvent that is never posted).
    static func wheel(pixels: Int32) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    static func thumbButton(_ number: Int64) throws -> NSEvent {
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

    struct Rig {
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

    func makeRig() throws -> Rig {
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
        // A shown tab's page has the keys (the attach gave them already when the window had none; made sure of here).
        _ = window.makeFirstResponder(view)
        sent.messages.removeAll()
        return Rig(context: context, native: native, page: page, window: window, connection: connection, remote: remote, sent: sent, view: view)
    }

    /// A responder that offers the event back to the view, as the window does (`NSWindow.keyDown` offers it as a key equivalent) and as
    /// a menu action may: first as a key equivalent, then as a key.
    final class ReenteringResponder: NSResponder {
        weak var view: ChromiumRemoteContentView?
        var received = 0

        override func keyDown(with event: NSEvent) {
            received += 1
            _ = view?.performKeyEquivalent(with: event)
            view?.keyDown(with: event)
        }
    }

    func unhandled(_ rig: Rig, code: Int64, modifiers: Int64 = 0) -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Event.unhandledKey, browser: rig.remote.id)
        message.set(CefRemote.Key.keyType, Int64(1))
        message.set(CefRemote.Key.nativeKeyCode, code)
        message.set(CefRemote.Key.modifiers, modifiers)
        return message
    }

    final class MenuHits: NSObject {
        var hits: [String] = []

        @objc func find(_ sender: Any?) {
            hits.append("find")
        }

        @objc func back(_ sender: Any?) {
            hits.append("back")
        }

        @objc func undo(_ sender: Any?) {
            hits.append("undo")
        }
    }

    /// Runs `body` with a main menu of a Find item (⌘F), a Back item (⌘←) and an Undo item (⌘Z) that record their hits.
    func withMenu(_ body: (MenuHits) async throws -> Void) async throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let hits = MenuHits()
        let root = NSMenu()
        let submenu = NSMenu()
        let find = NSMenuItem(title: "Find", action: #selector(MenuHits.find(_:)), keyEquivalent: "f")
        find.target = hits
        let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let back = NSMenuItem(title: "Back", action: #selector(MenuHits.back(_:)), keyEquivalent: leftArrow)
        back.target = hits
        let undo = NSMenuItem(title: "Undo", action: #selector(MenuHits.undo(_:)), keyEquivalent: "z")
        undo.target = hits
        submenu.addItem(find)
        submenu.addItem(back)
        submenu.addItem(undo)
        let item = NSMenuItem()
        item.submenu = submenu
        root.addItem(item)
        NSApp.mainMenu = root
        try await body(hits)
    }

    struct Live {
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

    func withLive(_ path: String, container: Bool = false, _ body: (Live) async throws -> Void) async throws {
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
}
