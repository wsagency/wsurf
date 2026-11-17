// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CCef
import Foundation

// D4-12 (out-of-process Chromium, phase 3): the vocabulary of input. Pointer, wheel, key and focus messages go from WSurf to the
// service on the input connection (`inputHello`), in the order the person produced them; nothing is coalesced. What comes back (the
// cursor, the tooltip, the status text, a key the page did not handle, focus leaving the page) goes on the control connection, so it
// stays in order with the service's other events.

extension CefRemote.Op {
    /// A pointer event of one browser. Keys: `bid`, ``CefRemote/Key/kind`` (a ``CefRemote/MouseKind``), ``CefRemote/Key/x`` and
    /// ``CefRemote/Key/y`` (view points, top-left origin), ``CefRemote/Key/modifiers``, and for a click ``CefRemote/Key/button``
    /// (0 left, 1 middle, 2 right) and ``CefRemote/Key/clickCount``, for a wheel ``CefRemote/Key/deltaX`` and ``CefRemote/Key/deltaY``.
    public static let mouse = "input.mouse"
    /// A key event of one browser, as `cef_key_event_t` (see ``CefRemote/Key/keyType`` and its neighbours).
    public static let key = "input.key"
    /// The page's view became (``CefRemote/Key/flag`` true) or stopped being the window's first responder: `set_focus`.
    public static let focus = "input.focus"
    /// An editing command of the focused frame, named by ``CefRemote/Key/kind``. Phase 3 has `selectAll` only; the Edit menu is D4-14.
    public static let edit = "input.edit"
}

extension CefRemote.Event {
    /// The cursor the page wants, as `cef_cursor_type_t` in ``CefRemote/Key/cursor``.
    public static let cursor = "display.cursor"
    /// The tooltip under the pointer in ``CefRemote/Key/text`` (empty: none).
    public static let tooltip = "display.tooltip"
    /// The status text (the address of the link under the pointer) in ``CefRemote/Key/text``; empty when there is none.
    public static let statusMessage = "display.status"
    /// A key the page did not handle (`on_key_event`): ``CefRemote/Key/keyType``, ``CefRemote/Key/nativeKeyCode``,
    /// ``CefRemote/Key/modifiers``. WSurf re-dispatches the matching `NSEvent` in the app.
    public static let unhandledKey = "key.unhandled"
    /// Focus leaves the page (Tab from its last field, or Shift-Tab from its first): ``CefRemote/Key/flag`` is true for "next".
    public static let takeFocus = "focus.take"
    /// An editable field took or lost the focus (`on_virtual_keyboard_requested`): ``CefRemote/Key/flag`` is true while one has it. WSurf
    /// sends ⌘← and ⌘→ to the page as Home and End then, and does not let an unhandled one go to the menu as Back or Forward.
    public static let textInput = "text.input"
    /// The page took focus (`on_got_focus`).
    public static let gotFocus = "focus.got"
}

extension CefRemote.Key {
    public static let modifiers = "mods"
    public static let x = "x"
    public static let y = "y"
    public static let kind = "kind"
    public static let button = "button"
    public static let clickCount = "clicks"
    public static let deltaX = "dx"
    public static let deltaY = "dy"
    /// `cef_key_event_type_t`.
    public static let keyType = "ktype"
    public static let nativeKeyCode = "nkc"
    public static let windowsKeyCode = "wkc"
    public static let character = "ch"
    public static let unmodifiedCharacter = "uch"
    public static let cursor = "cursor"
    /// `debug.stats` with a browser (D4-12): the input messages the browser handled, the sum and the maximum of the leg from WSurf's
    /// send to the service's receipt in milliseconds (K4's input leg; reported, never asserted).
    public static let inputEvents = "inevents"
    public static let inputLegSumMs = "inlegsum"
    public static let inputLegMaxMs = "inlegmax"
    /// `debug.stats` with a browser (D4-12): the last `set_focus` the browser was given (0 or 1), and -1 before any.
    public static let inputFocus = "infocus"
    /// `debug.stats` with a browser (D4-12, review F4): the context menus the service emptied instead of showing.
    public static let inputMenusCleared = "inmenus"
}

extension CefRemote {
    /// What a ``Op/mouse`` message is.
    public enum MouseKind {
        public static let move = "move"
        public static let leave = "leave"
        public static let down = "down"
        public static let up = "up"
        public static let wheel = "wheel"
    }

    /// The Windows (DOM) virtual key code CEF expects in `cef_key_event_t.windows_key_code`, from a macOS key code
    /// (`NSEvent.keyCode`). The table covers the keys whose code is not their character (CefSwift's `CefKeyCodes`, which lives in
    /// CefSwiftUI and cannot be imported) and the punctuation keys, whose VK_OEM codes are not their ASCII (`.` is 0x2E, which is
    /// VK_DELETE); a letter or a digit is its upper-cased ASCII code.
    public static func windowsKeyCode(forMacKeyCode keyCode: UInt16, characters: String?) -> Int {
        if let mapped = windowsKeyCodes[keyCode] {
            return mapped
        }
        if let scalar = characters?.uppercased().unicodeScalars.first, scalar.value < 128 {
            return Int(scalar.value)
        }
        return 0
    }

    private static let windowsKeyCodes: [UInt16: Int] = [
        0x24: 0x0D, 0x4C: 0x0D, 0x30: 0x09, 0x31: 0x20, 0x33: 0x08, 0x75: 0x2E, 0x35: 0x1B, 0x7B: 0x25, 0x7C: 0x27,
        0x7D: 0x28, 0x7E: 0x26, 0x73: 0x24, 0x77: 0x23, 0x74: 0x21, 0x79: 0x22, 0x38: 0x10, 0x3C: 0x10, 0x3B: 0x11,
        0x3E: 0x11, 0x3A: 0x12, 0x3D: 0x12, 0x37: 0x5B, 0x36: 0x5C, 0x39: 0x14, 0x7A: 0x70, 0x78: 0x71, 0x63: 0x72,
        0x76: 0x73, 0x60: 0x74, 0x61: 0x75, 0x62: 0x76, 0x64: 0x77, 0x65: 0x78, 0x6D: 0x79, 0x67: 0x7A, 0x6F: 0x7B,
        // Punctuation, by the key's place on an ANSI layout: ; = , - . / ` [ \ ] '
        0x29: 0xBA, 0x18: 0xBB, 0x2B: 0xBC, 0x1B: 0xBD, 0x2F: 0xBE, 0x2C: 0xBF, 0x32: 0xC0, 0x21: 0xDB, 0x2A: 0xDC, 0x1E: 0xDD, 0x27: 0xDE,
    ]
}

extension CefCursorType {
    /// The cursor a remote browser asked for, from the raw `cef_cursor_type_t` value the service sends.
    public static func fromRemote(_ value: Int64) -> CefCursorType {
        CefCursorType(cefValue: cef_cursor_type_t(rawValue: UInt32(truncatingIfNeeded: value)))
    }
}
