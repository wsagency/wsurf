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

    /// F1 of the review of #145: the thumb buttons are the window's (`BrowserWindow.sendEvent`, on when the person left
    /// `sideButtonsNavigate` on). The view never navigates itself, which with the setting off would override the person's choice, and
    /// the page cannot be given buttons 3 and 4 (`cef_mouse_button_type_t` has no such button): both edges are swallowed.
    @Test func theThumbButtonsAreSwallowedByTheViewItNeitherNavigatesNorSendsThem() async throws {
        let rig = try makeRig()
        rig.page.canGoBack = true
        rig.page.canGoForward = true
        rig.view.eventPoint = { _ in CGPoint(x: 5, y: 5) }
        for number: Int64 in [3, 4] {
            rig.view.otherMouseDown(with: try Self.thumbButton(number))
            rig.view.otherMouseUp(with: try Self.thumbButton(number))
        }
        #expect(rig.sent.sent(CefRemote.Op.goBack).isEmpty && rig.sent.sent(CefRemote.Op.goForward).isEmpty, "no navigation of its own")
        #expect(rig.sent.mouse.isEmpty, "and nothing for the page, not even as a middle click")
        // Any other button is a middle click, as before.
        let middle = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        rig.view.otherMouseDown(with: try #require(NSEvent(cgEvent: middle)))
        #expect(rig.sent.mouse.map { $0.int(CefRemote.Key.button) } == [1])
        await rig.end()
    }

    // MARK: Re-entry, modifiers, page-first chords (review of #145: F3, N1, F2)

    /// F3: an unhandled key that climbs to the window and is offered back to the view (as a key equivalent, or as a key) is never sent to
    /// the page again, so a page that reports every key-down unhandled cannot make an endless exchange. The route that stormed under
    /// the M2 mutation of the first run: the count is exactly one key-down and one character.
    @Test func anUnhandledKeyOfferedBackToTheViewIsNotSentAgain() async throws {
        let rig = try makeRig()
        let responder = ReenteringResponder()
        responder.view = rig.view
        rig.view.nextResponder = responder
        rig.view.keyDown(with: try Self.key("w", code: 13, in: rig.window))
        #expect(rig.sent.keys.map { $0.int(CefRemote.Key.keyType) } == [1, 3])
        rig.remote.remoteEvent(unhandled(rig, code: 13))
        #expect(responder.received == 1, "the key went on in the app once")
        #expect(rig.sent.keys.map { $0.int(CefRemote.Key.keyType) } == [1, 3], "and was not sent to the page again")
        rig.remote.remoteEvent(unhandled(rig, code: 13))
        #expect(responder.received == 1 && rig.sent.keys.count == 2, "a second report finds nothing waiting")
        await rig.end()
    }

    /// F3: a report that arrives after the person went to another field is dropped: a late Tab must not drive that field's key loop.
    @Test func anUnhandledKeyReportedAfterTheFocusMovedOnIsDropped() async throws {
        let rig = try makeRig()
        let recorder = KeyRecorder()
        rig.view.nextResponder = recorder
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        rig.page.addSubview(field)
        rig.view.keyDown(with: try Self.key("\u{F70C}", code: 101, in: rig.window))
        #expect(rig.window.makeFirstResponder(field))
        rig.remote.remoteEvent(unhandled(rig, code: 101))
        #expect(recorder.keyCodes.isEmpty)
        await rig.end()
    }

    /// N1: the report is matched by key code and modifiers: a handled Tab followed by an unhandled Shift-Tab hands Shift-Tab on.
    @Test func anUnhandledKeyIsMatchedByItsModifiersAsWellAsItsKeyCode() async throws {
        let rig = try makeRig()
        let recorder = KeyRecorder()
        rig.view.nextResponder = recorder
        rig.view.keyDown(with: try Self.key("\t", code: 48, in: rig.window))
        let shifted = try Self.key("\t", code: 48, flags: .shift, in: rig.window)
        rig.view.keyDown(with: shifted)
        rig.remote.remoteEvent(unhandled(rig, code: 48, modifiers: ChromiumRemoteContentView.modifiers(.shift)))
        #expect(recorder.keyCodes == [48])
        #expect(rig.view.sentKeyDowns.isEmpty, "the plain Tab before it was handled, and is let go of")
        await rig.end()
    }

    @Test func aRepeatIsMarkedAndAnArrowOrACommandChordSendsNoCharacter() async throws {
        let rig = try makeRig()
        let again = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rig.window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: true, keyCode: 13))
        rig.view.keyDown(with: again)
        #expect(rig.sent.keys.first.map { $0.int(CefRemote.Key.modifiers) & (1 << 13) != 0 } == true, "EVENTFLAG_IS_REPEAT")
        rig.sent.messages.removeAll()
        rig.view.keyDown(with: try Self.key("\u{F702}", code: 123, in: rig.window))
        rig.view.keyDown(with: try Self.key("a", code: 0, flags: .command, in: rig.window))
        #expect(rig.sent.keys.map { $0.int(CefRemote.Key.keyType) } == [1, 1], "key-downs only: no character for an arrow or ⌘A")
        await rig.end()
    }

    /// F2: a chord of `ShortcutPriority.pageFirst` (⌘F here) is offered to the page before the menu, when the view has the keys; one the
    /// page does not handle goes to the menu once. A chord that is the menu's (⌘T) is never claimed.
    @Test func aPageFirstChordGoesToThePageAndComesBackToTheMenuOnceWhenTheyDoNotHandleIt() async throws {
        let rig = try makeRig()
        try await withMenu { hits in
            let responder = ReenteringResponder()
            responder.view = rig.view
            rig.view.nextResponder = responder
            let find = try Self.key("f", code: 3, flags: .command, in: rig.window)
            #expect(rig.view.performKeyEquivalent(with: find), "the page is offered ⌘F first")
            #expect(rig.sent.keys.map { $0.int(CefRemote.Key.keyType) } == [1], "as a key-down, with no character")
            #expect(hits.hits.isEmpty, "the menu has not seen it yet")
            rig.remote.remoteEvent(unhandled(rig, code: 3, modifiers: ChromiumRemoteContentView.modifiers(.command)))
            #expect(hits.hits == ["find"], "the page did not handle it: the menu gets it, once")
            #expect(responder.received == 0 && rig.sent.keys.count == 1, "and not the responder chain, nor the page again")
            #expect(!rig.view.performKeyEquivalent(with: try Self.key("t", code: 17, flags: .command, in: rig.window)), "⌘T is the menu's")
            #expect(rig.sent.keys.count == 1)
            // Not the first responder: not its key.
            #expect(rig.window.makeFirstResponder(nil))
            #expect(!rig.view.performKeyEquivalent(with: find))
        }
        await rig.end()
    }

    /// R1: an agent's key (the MCP key press) is the page's and no one else's. In process it goes to the web view and never to WSurf's
    /// menu; here an agent's ⌘Z or ⌘← that the page does not handle must not run Undo or Back either, nor go on to any responder. A
    /// person's ⌘← on the same page still goes Back.
    @Test func anAgentsKeyThePageDoesNotHandleNeverReachesTheMenuOrTheResponders() async throws {
        let rig = try makeRig()
        try await withMenu { hits in
            let responder = ReenteringResponder()
            responder.view = rig.view
            rig.view.nextResponder = responder
            let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            let agentZ = try Self.key("z", code: 6, flags: .command, in: rig.window)
            let agentLeft = try Self.key(left, code: 123, flags: .command, in: rig.window)
            #expect(rig.native.sendKeyEvent(agentZ), "the page got the agent's ⌘Z")
            #expect(rig.native.sendKeyEvent(agentLeft), "and ⌘←")
            #expect(rig.sent.keys.map { $0.int(CefRemote.Key.nativeKeyCode) } == [6, 123])
            rig.remote.remoteEvent(unhandled(rig, code: 6, modifiers: ChromiumRemoteContentView.modifiers(.command)))
            rig.remote.remoteEvent(unhandled(rig, code: 123, modifiers: ChromiumRemoteContentView.modifiers(.command)))
            #expect(hits.hits.isEmpty, "no menu item ran for an agent's keys: \(hits.hits)")
            #expect(responder.received == 0, "and no responder saw them")
            #expect(rig.view.sentKeyDowns.isEmpty)
            // A person's ⌘← on the same page, left unhandled, is Back.
            #expect(rig.view.performKeyEquivalent(with: try Self.key(left, code: 123, flags: .command, in: rig.window)))
            rig.remote.remoteEvent(unhandled(rig, code: 123, modifiers: ChromiumRemoteContentView.modifiers(.command)))
            #expect(hits.hits == ["back"], "a person's ⌘← goes Back: \(hits.hits)")
        }
        await rig.end()
    }

    /// F2: with an editable field focused (`text.input`), ⌘← is "start of the line": the page gets Home (and End for ⌘→), with Shift if
    /// it is down, and it is never handed on to the menu as Back. Without a field it goes as it is, and an unhandled one is Back.
    @Test func commandLeftInAnEditableFieldIsHomeAndNeverGoesBackWhileWithoutAFieldItDoes() async throws {
        let rig = try makeRig()
        try await withMenu { hits in
            let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            let chord = try Self.key(left, code: 123, flags: .command, in: rig.window)
            // With no field: the chord itself, and an unhandled one comes back to the menu: Back.
            #expect(rig.view.performKeyEquivalent(with: chord))
            #expect(rig.sent.keys.first?.int(CefRemote.Key.nativeKeyCode) == 123)
            rig.remote.remoteEvent(unhandled(rig, code: 123, modifiers: ChromiumRemoteContentView.modifiers(.command)))
            #expect(hits.hits == ["back"], "no field focused: ⌘← still goes Back")
            // With a field.
            rig.sent.messages.removeAll()
            let editable = CefRemoteMessage(CefRemote.Event.textInput, browser: rig.remote.id)
            editable.set(CefRemote.Key.flag, true)
            rig.remote.remoteEvent(editable)
            #expect(rig.view.editableFocused)
            let again = try Self.key(left, code: 123, flags: [.command, .shift], in: rig.window)
            #expect(rig.view.performKeyEquivalent(with: again))
            rig.view.keyUp(with: try Self.key(left, code: 123, type: .keyUp, flags: [.command, .shift], in: rig.window))
            let keys = rig.sent.keys
            #expect(keys.map { $0.int(CefRemote.Key.keyType) } == [1, 2], "Home down and up, no character")
            #expect(keys.allSatisfy { $0.int(CefRemote.Key.nativeKeyCode) == 115 && $0.int(CefRemote.Key.windowsKeyCode) == 0x24 })
            let shiftOnly = ChromiumRemoteContentView.modifiers(.shift)
            #expect(keys.allSatisfy { $0.int(CefRemote.Key.modifiers) & ChromiumRemoteContentView.modifiers([.shift, .command]) == shiftOnly },
                    "Shift kept, Command dropped")
            rig.remote.remoteEvent(unhandled(rig, code: 115, modifiers: shiftOnly))
            #expect(hits.hits == ["back"], "a Home the page leaves unhandled is not Back")
            let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            rig.sent.messages.removeAll()
            #expect(rig.view.performKeyEquivalent(with: try Self.key(right, code: 124, flags: .command, in: rig.window)))
            #expect(rig.sent.keys.first?.int(CefRemote.Key.nativeKeyCode) == 119, "⌘→ is End")
            // The field loses the focus: the chord is itself again.
            editable.set(CefRemote.Key.flag, false)
            rig.remote.remoteEvent(editable)
            #expect(!rig.view.editableFocused)
        }
        await rig.end()
    }

    // MARK: Real pages through the service

    static let routes: [String: HTTPFixtureServer.Response] = [
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
        "/step1": .html("<!doctype html><title>One</title><a id=\"next\" href=\"/step2\">next</a>"),
        "/step2": .html("<!doctype html><title>Two</title><a id=\"next\" href=\"/step3\">next</a>"),
        "/step3": .html("<!doctype html><title>Three</title><p>three"),
    ]

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

    /// N5: a punctuation key has its own virtual-key code (`.` is VK_OEM_PERIOD, not VK_DELETE, which is what its ASCII value is): typed
    /// into the middle of text it inserts, and does not delete the character after the caret.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aPeriodTypedIntoTheMiddleOfTextInsertsAndDoesNotDelete() async throws {
        try await withLive("/input") { live in
            let view = try #require(live.view)
            try #require(live.window.makeFirstResponder(live.page))
            try live.click(60, 35)
            for (character, code) in [("a", UInt16(0)), ("b", 11)] {
                view.keyDown(with: try Self.key(character, code: code, in: live.window))
                view.keyUp(with: try Self.key(character, code: code, type: .keyUp, in: live.window))
            }
            #expect(await waitUntil { await live.js("document.getElementById('f').value") as? String == "ab" })
            view.keyDown(with: try Self.key("\u{F702}", code: 123, in: live.window))
            view.keyUp(with: try Self.key("\u{F702}", code: 123, type: .keyUp, in: live.window))
            view.keyDown(with: try Self.key(".", code: 47, in: live.window))
            view.keyUp(with: try Self.key(".", code: 47, type: .keyUp, in: live.window))
            let value = await waitUntil { await live.js("document.getElementById('f').value") as? String == "a.b" }
            let shown = await live.js("document.getElementById('f').value") as? String
            #expect(value, "the field holds \(String(describing: shown))")
        }
    }

    /// F4: a right-click reaches a service that has no context menu of WSurf's yet (D4-15). CEF's own menu must not appear, and the
    /// service must stay responsive: it emptied the menu (`debug.stats` counts it), still answers, and the page still takes clicks.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aRightClickShowsNoMenuAndLeavesTheServiceAndThePageWorking() async throws {
        try await withLive("/input") { live in
            let view = try #require(live.view)
            let before = try #require(await live.stats()).int(CefRemote.Key.inputMenusCleared)
            view.mouseMoved(with: try Self.mouse(.mouseMoved, 80, 140, in: live.window))
            view.rightMouseDown(with: try Self.mouse(.rightMouseDown, 80, 140, in: live.window))
            view.rightMouseUp(with: try Self.mouse(.rightMouseUp, 80, 140, in: live.window))
            #expect(await waitUntil { await live.stats()?.int(CefRemote.Key.inputMenusCleared) ?? 0 > before },
                    "the service emptied the menu CEF offered")
            #expect(await live.stats() != nil, "the service still answers")
            try live.click(80, 140)
            #expect(await waitUntil { await live.number("window.clicks || 0") == 1 }, "and the page still takes clicks")
        }
    }

    /// F2: ⌘← is WSurf's Back (a hidden menu item), but a page answers it first: in a text field it is "start of the line", and the tab
    /// does not go Back (the typed text is not lost). With no field focused the page leaves it unhandled and it is Back.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func commandLeftInATextFieldMovesTheCaretAndDoesNotGoBack() async throws {
        try await withMenu { hits in
            try await withLive("/input") { live in
                let view = try #require(live.view)
                try #require(live.window.makeFirstResponder(live.page))
                try live.click(60, 35)
                for (character, code) in [("w", UInt16(13)), ("s", 1), ("u", 32)] {
                    view.keyDown(with: try Self.key(character, code: code, in: live.window))
                    view.keyUp(with: try Self.key(character, code: code, type: .keyUp, in: live.window))
                }
                #expect(await waitUntil { await live.js("document.getElementById('f').value") as? String == "wsu" })
                #expect(await waitUntil { view.editableFocused }, "the page told WSurf that a field has the focus")
                let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
                try #require(view.performKeyEquivalent(with: try Self.key(left, code: 123, flags: .command, in: live.window)))
                view.keyUp(with: try Self.key(left, code: 123, type: .keyUp, flags: .command, in: live.window))
                #expect(await waitUntil { await live.number("document.getElementById('f').selectionStart") == 0 }, "the caret is at the start")
                try await Task.sleep(for: .milliseconds(500))
                #expect(hits.hits.isEmpty, "and the tab did not go Back: \(hits.hits)")
            }
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func commandLeftOnAPageWithNoFieldFocusedStillGoesBack() async throws {
        try await withMenu { hits in
            try await withLive("/other") { live in
                let view = try #require(live.view)
                try #require(live.window.makeFirstResponder(live.page))
                try live.click(300, 300)
                try #require(await waitUntil { live.window.firstResponder === view })
                let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
                try #require(view.performKeyEquivalent(with: try Self.key(left, code: 123, flags: .command, in: live.window)))
                #expect(await waitUntil { hits.hits == ["back"] }, "the page left ⌘← unhandled and the menu got it once: \(hits.hits)")
            }
        }
    }

    // MARK: The thumb buttons, through a real browser window

    /// Presses mouse button `number` over the middle of the window, as the system makes the event (a `CGEvent`, converted and never
    /// posted), and sends it through the window as AppKit does.
    private static func press(button number: UInt32, in window: NSWindow) throws {
        let point = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let button = try #require(CGMouseButton(rawValue: number))
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let made = try #require(CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: point.x, y: primary - point.y), mouseButton: button))
            made.setIntegerValueField(.mouseEventClickState, value: 1)
            let event = try #require(NSEvent(cgEvent: made))
            try #require(event.buttonNumber == Int(number))
            window.sendEvent(event)
        }
    }

    /// F1 of the review of #145: with the setting on, the window takes the thumb button and the tab goes Back once (not twice: the view
    /// never sees it); with it off the person left the buttons to websites, which an out-of-process page cannot be given, so the tab
    /// stays and the page gets no input at all.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func theThumbButtonGoesBackOnceThroughTheWindowAndNotAtAllWithTheSettingOff() async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Input thumb")
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let main = app.newWindow(profile: profile, show: false)
        let first = try server.url("/step1")
        main.context.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: first))
        main.showBrowser(activate: false)
        let settings = main.context.settings
        var failure: (any Error)?
        do {
            let window = try #require(main.nativeWindow)
            let tab = main.browser.newTab(url: first)
            func at(_ path: String) async -> Bool {
                let url = try? server.url(path)
                return await waitUntil(timeout: .seconds(15)) { tab.isMaterialised && tab.page.url == url && !tab.page.isLoading }
            }
            try #require(await at("/step1"))
            for (link, path) in [("next", "/step2"), ("next", "/step3")] {
                _ = try? await tab.page.callAsyncJavaScript(
                    "document.getElementById(id).click(); return true;", arguments: ["id": link], in: nil, contentWorld: .page, userGesture: true)
                try #require(await at(path))
            }
            try #require(tab.page.chromium?.remote?.contentView != nil, "the tab's page runs in the service")
            let browser = try #require(tab.page.chromium?.remote?.id)
            func inputEvents() async -> Int64? {
                guard case let .value(reply) = await ChromiumRemote.shared.request(CefRemoteMessage(CefRemote.Op.debugStats, browser: browser))
                else { return nil }
                return reply.int(CefRemote.Key.inputEvents)
            }
            try #require(await waitUntil { tab.canGoBack })
            // On (the default): the window takes the button, once.
            settings.sideButtonsNavigate = true
            try Self.press(button: 3, in: window)
            #expect(await at("/step2"), "button 3 went Back: \(tab.urlString)")
            try await Task.sleep(for: .seconds(1))
            #expect(tab.page.url == (try server.url("/step2")), "once, not twice: \(tab.urlString)")
            // Off: nothing moves, and nothing reaches the page.
            settings.sideButtonsNavigate = false
            let events = await inputEvents()
            try Self.press(button: 3, in: window)
            try Self.press(button: 4, in: window)
            try await Task.sleep(for: .seconds(1))
            #expect(tab.page.url == (try server.url("/step2")), "off, neither button navigated: \(tab.urlString)")
            #expect(await inputEvents() == events, "and the page was sent nothing")
        } catch {
            failure = error
        }
        settings.sideButtonsNavigate = true
        StageMode.defaults.removeObject(forKey: BrowserSettings.Key.mouseSideButtons)
        let tabs = main.browser.tabs
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        withExtendedLifetime(server) {}
        if let failure {
            throw failure
        }
    }
}
