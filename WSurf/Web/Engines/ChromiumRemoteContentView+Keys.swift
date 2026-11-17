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
    /// page is hidden): a caller that reports "delivered" (the MCP key press) must not when the page never received it.
    @discardableResult
    func deliver(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return sendKey(event, type: KEYEVENT_KEYUP)
        }
        guard sendKey(event, type: KEYEVENT_KEYDOWN) else { return false }
        sentKeyDowns.append(event)
        if sentKeyDowns.count > Self.unansweredKeyLimit {
            sentKeyDowns.removeFirst()
        }
        sendKey(event, type: KEYEVENT_CHAR)
        return true
    }

    /// A key-down the page never answered is dropped from the queue after this many newer ones (the page handled it).
    private static let unansweredKeyLimit = 16

    @discardableResult
    private func sendKey(_ event: NSEvent, type: cef_key_event_type_t) -> Bool {
        browser?.sendInput(CefRemote.Op.key) { message in
            var modifiers = Self.modifiers(event.modifierFlags)
            if Self.isKeyPad(event) {
                modifiers |= Int64(EVENTFLAG_IS_KEY_PAD.rawValue)
            }
            message.set(CefRemote.Key.keyType, Int64(type.rawValue))
            message.set(CefRemote.Key.modifiers, modifiers)
            message.set(CefRemote.Key.nativeKeyCode, Int64(event.keyCode))
            if event.type == .keyDown || event.type == .keyUp {
                message.set(
                    CefRemote.Key.windowsKeyCode,
                    Int64(CefRemote.windowsKeyCode(forMacKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers)))
                message.set(CefRemote.Key.unmodifiedCharacter, Int64(event.charactersIgnoringModifiers?.utf16.first ?? 0))
                message.set(CefRemote.Key.character, Int64(event.characters?.utf16.first ?? 0))
            }
        } ?? false
    }

    /// `key.unhandled`: the page did not handle a key-down. The event WSurf made it from goes on in the app, to the responder after
    /// this view, exactly as if the view had not taken it. Keys it handled are never reported, so the ones before it in the queue
    /// were handled (or are not coming back) and are let go of.
    func redispatchUnhandledKey(nativeKeyCode: UInt16, type: Int64) {
        guard type == Int64(KEYEVENT_RAWKEYDOWN.rawValue) || type == Int64(KEYEVENT_KEYDOWN.rawValue),
              let index = sentKeyDowns.firstIndex(where: { $0.keyCode == nativeKeyCode }) else { return }
        let event = sentKeyDowns[index]
        sentKeyDowns.removeFirst(index + 1)
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
        case 56, 60: return flags.contains(.shift)
        case 59, 62: return flags.contains(.control)
        case 58, 61: return flags.contains(.option)
        case 55, 54: return flags.contains(.command)
        case 57: return flags.contains(.capsLock)
        default: return true
        }
    }
}
