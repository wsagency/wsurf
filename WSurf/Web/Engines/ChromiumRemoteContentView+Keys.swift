// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CCef
import CefKit
import Foundation

// D4-12: the keys and the focus of a page in the Chromium service. WSurf's own shortcuts come first, because AppKit offers a key
// equivalent to the window's views and the main menu before it is a `keyDown` (this view overrides no `performKeyEquivalent`, so
// nothing is sent to the page for a shortcut the menu takes). A key that reaches `keyDown` goes to the page as a key-down and a
// character (as CEF's own view does in process); a key the page does not handle comes back and goes on in the app, to the
// next responder. Nothing is posted to the system. Text input and IME are D4-13.

extension ChromiumRemoteContentView {
    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        browser?.sendFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        browser?.sendFocus(false)
        return true
    }

    /// `on_take_focus`: Tab left the page's last field (or Shift-Tab its first). The window's key view loop goes on from here.
    func passFocusOn(forward: Bool) {
        guard window?.firstResponder === self else { return }
        if forward {
            window?.selectNextKeyView(self)
        } else {
            window?.selectPreviousKeyView(self)
        }
    }

    // MARK: Keys

    /// A chord that WSurf offers to the page before its menu (`ShortcutPriority.pageFirst`: ⌘←, ⌘A, ⌘F and the rest) goes to the page,
    /// as a web view answers it in process; the page may keep it (⌘← moves the caret) or not, and a chord it does not handle comes
    /// back and goes to the menu once (`redispatchUnhandledKey`). Every other key equivalent is the menu's, and is not claimed.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, ShortcutPriority.pageAnswersFirst(event) else { return false }
        return deliver(event)
    }

    override func keyDown(with event: NSEvent) {
        deliver(event)
    }

    override func keyUp(with event: NSEvent) {
        deliver(event)
    }

    override func flagsChanged(with event: NSEvent) {
        sendKey(event, type: Self.isModifierPressed(event) ? KEYEVENT_KEYDOWN : KEYEVENT_KEYUP)
    }

    /// Sends a key event to the page as `keyDown` and `keyUp` do. False when nothing was sent (no browser, not made yet, gone, or the
    /// page is hidden): a caller that reports "delivered" (the MCP key press) must not when the page never received it. `fromPerson` is
    /// false for an agent's key: if the page does not handle it, it is dropped (`redispatchUnhandledKey`).
    @discardableResult
    func deliver(_ event: NSEvent, fromPerson: Bool = true) -> Bool {
        guard event !== redispatching else { return false }
        let line = lineKey(for: event)
        guard event.type == .keyDown else {
            return sendKey(event, type: KEYEVENT_KEYUP, as: line)
        }
        guard sendKey(event, type: KEYEVENT_KEYDOWN, as: line) else { return false }
        // Home and End are the page's own: it takes them, and they never come back as a key to hand on.
        guard line == nil else { return true }
        sentKeyDowns.append(SentKey(event: event, fromPerson: fromPerson))
        if sentKeyDowns.count > Self.unansweredKeyLimit {
            sentKeyDowns.removeFirst()
        }
        // Not for a key with no text (a dead key, an arrow: its character is a private-use code), and not for a command chord (⌘A is not
        // the letter a): there is no character to type.
        if let character = event.characters?.utf16.first, !(0xF700...0xF8FF).contains(character),
           !event.modifierFlags.contains(.command) {
            sendKey(event, type: KEYEVENT_CHAR)
        }
        return true
    }

    /// A key-down the page never answered is dropped from the queue after this many newer ones (the page handled it).
    private static let unansweredKeyLimit = 16

    /// ⌘← and ⌘→ with an editable field focused are "go to the start / end of the line", which in process the text system does for a
    /// web view. Out of process nothing does until D4-13 (text input), so the page gets the Home or End key, with Shift if it is down
    /// (a selection). Without a field they are the menu's (Back and Forward, `ShortcutPriority`).
    private func lineKey(for event: NSEvent) -> (nativeKeyCode: Int64, windowsKeyCode: Int64)? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard editableFocused, flags == .command || flags == [.command, .shift] else { return nil }
        // By the key, not its character: the left and right arrow keys, whatever the layout says they type.
        switch event.keyCode {
        case 123:
            return (115, 0x24)
        case 124:
            return (119, 0x23)
        default:
            return nil
        }
    }

    @discardableResult
    private func sendKey(_ event: NSEvent, type: cef_key_event_type_t, as line: (nativeKeyCode: Int64, windowsKeyCode: Int64)? = nil) -> Bool {
        browser?.sendInput(CefRemote.Op.key) { message in
            var modifiers = Self.modifiers(event.modifierFlags)
            if line != nil {
                modifiers &= ~Int64(EVENTFLAG_COMMAND_DOWN.rawValue)
            }
            if Self.isKeyPad(event) {
                modifiers |= Int64(EVENTFLAG_IS_KEY_PAD.rawValue)
            }
            if event.type != .flagsChanged, event.isARepeat {
                modifiers |= Int64(EVENTFLAG_IS_REPEAT.rawValue)
            }
            message.set(CefRemote.Key.keyType, Int64(type.rawValue))
            message.set(CefRemote.Key.modifiers, modifiers)
            message.set(CefRemote.Key.nativeKeyCode, line?.nativeKeyCode ?? Int64(event.keyCode))
            if let line {
                message.set(CefRemote.Key.windowsKeyCode, line.windowsKeyCode)
            } else if event.type == .keyDown || event.type == .keyUp {
                message.set(
                    CefRemote.Key.windowsKeyCode,
                    Int64(CefRemote.windowsKeyCode(forMacKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers)))
                message.set(CefRemote.Key.unmodifiedCharacter, Int64(event.charactersIgnoringModifiers?.utf16.first ?? 0))
                message.set(CefRemote.Key.character, Int64(event.characters?.utf16.first ?? 0))
            }
        } ?? false
    }

    /// The four modifier bits a report is matched on (the others, such as caps lock or the key pad, are not what tells two keys apart).
    private static let matchedModifiers = Int64(
        EVENTFLAG_SHIFT_DOWN.rawValue | EVENTFLAG_CONTROL_DOWN.rawValue | EVENTFLAG_ALT_DOWN.rawValue | EVENTFLAG_COMMAND_DOWN.rawValue)

    /// `key.unhandled`: the page did not handle a key-down. The event WSurf made it from goes on in the app exactly as if the view had
    /// not taken it: a chord of `ShortcutPriority.pageFirst` to the menu (once), any other key to the responder after this view.
    /// It is matched by key code and modifiers (Shift-Tab is not Tab). Keys the page handled are never reported, so the ones before
    /// it in the queue were handled (or are not coming back) and are let go of. A report that arrives after the person has gone
    /// elsewhere (a field, the address bar) is dropped: a late Tab or Escape must not drive another field's key loop. Whatever the app
    /// does with the event (`redispatching`) it never reaches the page again.
    func redispatchUnhandledKey(nativeKeyCode: UInt16, type: Int64, modifiers: Int64) {
        guard type == Int64(KEYEVENT_RAWKEYDOWN.rawValue) || type == Int64(KEYEVENT_KEYDOWN.rawValue) else { return }
        let matching = sentKeyDowns.indices.filter {
            sentKeyDowns[$0].event.keyCode == nativeKeyCode
                && Self.modifiers(sentKeyDowns[$0].event.modifierFlags) & Self.matchedModifiers == modifiers & Self.matchedModifiers
        }
        guard let index = matching.first, let last = matching.last else { return }
        let sent = sentKeyDowns[index]
        let event = sent.event
        // The report names a chord, not the key-down it answers. When an agent's key-down of the same chord is queued, the report may be
        // the agent's: it is dropped, so that an agent's key can never run a menu item as a person's (R1). The cost is a person's key
        // lost when it is queued together with an agent's identical one.
        let ambiguous = matching.contains { !sentKeyDowns[$0].fromPerson }
        sentKeyDowns.removeFirst(ambiguous ? last + 1 : index + 1)
        // An agent's key never reaches WSurf's menu or its responders (R1): an MCP ⌘Z must not run Undo, nor ⌘← Back.
        guard !ambiguous, sent.fromPerson, window?.firstResponder === self else { return }
        redispatching = event
        defer { redispatching = nil }
        if ShortcutPriority.pageAnswersFirst(event), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        nextResponder?.keyDown(with: event)
    }

    // MARK: Editing

    /// "Select All" for the first responder of a page in the service: the MCP's select-all reaches the view this way. The rest of
    /// the Edit menu is D4-14's.
    override func selectAll(_ sender: Any?) {
        browser?.sendInput(CefRemote.Op.edit) { $0.set(CefRemote.Key.kind, "selectAll") }
    }

    // MARK: Key classification

    private static func isKeyPad(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.numericPad) {
            return true
        }
        return [71, 81, 75, 67, 78, 69, 76, 65, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92].contains(event.keyCode)
    }

    private static func isModifierPressed(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 56, 60:
            return flags.contains(.shift)
        case 59, 62:
            return flags.contains(.control)
        case 58, 61:
            return flags.contains(.option)
        case 55, 54:
            return flags.contains(.command)
        case 57:
            return flags.contains(.capsLock)
        default:
            return true
        }
    }
}
