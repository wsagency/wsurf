// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation

extension ChromiumPage {
    /// Presses the left button at the first point of `path`, moves through the rest and releases at the last, as trusted
    /// pointer input delivered through DevTools. It reaches the renderer directly, so it needs neither the app to be active
    /// nor the window to be key. `path` is in CSS pixels of the main frame's viewport. `allowed` is asked in the same turn
    /// that each event is sent; once the button is down a release is always sent, whatever the answer.
    func dragPointer(path: [CGPoint], allowed: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard let first = path.first, let last = path.last, path.count >= 2 else { throw ChromiumError.unavailable("A drag needs two points.") }
        try await ensureReady()
        let guarded: @MainActor @Sendable () throws -> Void = {
            guard allowed() else {
                throw ChromiumError.staleFrame
            }
        }
        func send(_ type: String, _ point: CGPoint, button: String, buttons: Int, checked: Bool = true) async throws {
            let params: [String: Any] = [
                "type": type, "x": Double(point.x), "y": Double(point.y), "button": button, "buttons": buttons,
                "clickCount": type == "mouseMoved" ? 0 : 1,
            ]
            if checked {
                _ = try await devTools.command("Input.dispatchMouseEvent", params: params, dispatchCheck: guarded)
            } else {
                _ = try await devTools.command("Input.dispatchMouseEvent", params: params)
            }
        }
        try await send("mouseMoved", first, button: "none", buttons: 0)
        try await send("mousePressed", first, button: "left", buttons: 1)
        do {
            for point in path.dropFirst() {
                try await send("mouseMoved", point, button: "left", buttons: 1)
            }
        } catch {
            try? await send("mouseReleased", last, button: "left", buttons: 0, checked: false)
            throw error
        }
        try await send("mouseReleased", last, button: "left", buttons: 0, checked: false)
    }

    // MARK: Background pointer and keyboard input (MCP v2 Phase 2)

    /// CDP's modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8. Control is never in a `PageKeyChord`.
    nonisolated static func cdpModifiers(_ modifiers: PageKeyChord.Modifiers) -> Int {
        (modifiers.contains(.option) ? 1 : 0) | (modifiers.contains(.command) ? 4 : 0) | (modifiers.contains(.shift) ? 8 : 0)
    }

    /// While set, a file chooser the page opens without a planned selection, and the engine's context menu, are refused: input
    /// WSurf dispatched for an agent must never put a native panel or menu in front of the person.
    private static let automatedInputGrace: Duration = .seconds(2)

    var isAutomatedInputRecent: Bool {
        automatedInputUntil.map { ContinuousClock.now < $0 } ?? false
    }

    private func markAutomatedInput() {
        automatedInputUntil = .now + Self.automatedInputGrace
    }

    /// Sends one `Input.dispatchMouseEvent`, asking `allowed` in the turn it is sent.
    private func sendMouse(_ params: [String: Any], allowed: (@MainActor @Sendable () -> Bool)?) async throws {
        markAutomatedInput()
        if let allowed {
            _ = try await devTools.command("Input.dispatchMouseEvent", params: params, dispatchCheck: {
                guard allowed() else { throw ChromiumError.staleFrame }
            })
        } else {
            _ = try await devTools.command("Input.dispatchMouseEvent", params: params)
        }
    }

    /// A trusted pointer move to `point` (CSS pixels of the main frame's viewport). Neither the person's cursor nor focus moves.
    func dispatchPointerMove(
        to point: CGPoint, modifiers: PageKeyChord.Modifiers = [], allowed: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        try await ensureReady()
        try await sendMouse(
            ["type": "mouseMoved", "x": Double(point.x), "y": Double(point.y), "button": "none", "buttons": 0,
             "modifiers": Self.cdpModifiers(modifiers)], allowed: allowed)
    }

    /// A trusted click: move, then press and release `clickCount` times with the click count each press would have. Once a
    /// button is down a release is always sent, whatever `allowed` says.
    func dispatchPointerClick(
        at point: CGPoint, button: PageDriver.PointerButton, clickCount: Int, modifiers: PageKeyChord.Modifiers,
        allowed: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        guard (1...2).contains(clickCount) else { throw ChromiumError.unavailable("A click is single or double.") }
        try await ensureReady()
        let bit = ["left": 1, "right": 2, "middle": 4][button.rawValue] ?? 1
        let base: [String: Any] = ["x": Double(point.x), "y": Double(point.y), "modifiers": Self.cdpModifiers(modifiers)]
        try await sendMouse(base.merging(["type": "mouseMoved", "button": "none", "buttons": 0]) { $1 }, allowed: allowed)
        for count in 1...clickCount {
            try await sendMouse(
                base.merging(["type": "mousePressed", "button": button.rawValue, "buttons": bit, "clickCount": count]) { $1 }, allowed: allowed)
            try await sendMouse(base.merging(["type": "mouseReleased", "button": button.rawValue, "buttons": 0, "clickCount": count]) { $1 }, allowed: nil)
        }
    }

    /// A trusted wheel turn at `point` by `deltaX` and `deltaY` CSS pixels.
    func dispatchWheel(at point: CGPoint, deltaX: Double, deltaY: Double, allowed: @escaping @MainActor @Sendable () -> Bool) async throws {
        try await ensureReady()
        try await sendMouse(
            ["type": "mouseWheel", "x": Double(point.x), "y": Double(point.y), "deltaX": deltaX, "deltaY": deltaY, "button": "none",
             "buttons": 0], allowed: allowed)
    }

    /// Sends `chord` as a trusted key down and up to the page's focused element. Only a `PageKeyChord` can be sent, so the
    /// default-deny boundary decides every key; the page's own handlers run and the app's menus are never asked. A parked
    /// page gets focus emulation first, so it treats the key as focused input without taking the window's first responder.
    func dispatchKey(chord: PageKeyChord, allowed: @escaping @MainActor @Sendable () -> Bool) async throws {
        try await ensureReady()
        guard let key = Self.cdpKey(chord) else { throw ChromiumError.unavailable("This key has no DevTools form.") }
        if !isShownToPerson {
            // ponytail: emulation stays on for the page's life; it only makes an agent-held background page report focus.
            _ = try? await devTools.command("Emulation.setFocusEmulationEnabled", params: ["enabled": true])
        }
        var down: [String: Any] = [
            "type": key.text == nil ? "rawKeyDown" : "keyDown", "key": key.key, "code": key.code,
            "windowsVirtualKeyCode": key.virtualKey, "nativeVirtualKeyCode": Int(chord.keyCode), "modifiers": Self.cdpModifiers(chord.modifiers),
        ]
        if let text = key.text {
            down["text"] = text
            down["unmodifiedText"] = text
        }
        let commands = Self.macEditingCommands(chord)
        if !commands.isEmpty {
            down["commands"] = commands
        }
        markAutomatedInput()
        _ = try await devTools.command("Input.dispatchKeyEvent", params: down, dispatchCheck: {
            guard allowed() else { throw ChromiumError.staleFrame }
        })
        markAutomatedInput()
        _ = try await devTools.command(
            "Input.dispatchKeyEvent",
            params: ["type": "keyUp", "key": key.key, "code": key.code, "windowsVirtualKeyCode": key.virtualKey,
                     "nativeVirtualKeyCode": Int(chord.keyCode), "modifiers": Self.cdpModifiers(chord.modifiers)])
    }

    nonisolated struct CDPKey: Equatable {
        let key: String
        let code: String
        let virtualKey: Int
        /// What the key types; nil for a key that types nothing, and for every Command chord.
        let text: String?
    }

    /// The DOM `key`, `code`, Windows virtual key and text of `chord`'s key.
    nonisolated static func cdpKey(_ chord: PageKeyChord) -> CDPKey? {
        let base = chord.name.split(separator: "+").last.map(String.init) ?? chord.name
        let command = chord.modifiers.contains(.command)
        let named: [String: CDPKey] = [
            "Enter": CDPKey(key: "Enter", code: "Enter", virtualKey: 13, text: "\r"), "Tab": CDPKey(key: "Tab", code: "Tab", virtualKey: 9, text: nil),
            "Escape": CDPKey(key: "Escape", code: "Escape", virtualKey: 27, text: nil), "Space": CDPKey(key: " ", code: "Space", virtualKey: 32, text: " "),
            "ArrowLeft": CDPKey(key: "ArrowLeft", code: "ArrowLeft", virtualKey: 37, text: nil),
            "ArrowUp": CDPKey(key: "ArrowUp", code: "ArrowUp", virtualKey: 38, text: nil),
            "ArrowRight": CDPKey(key: "ArrowRight", code: "ArrowRight", virtualKey: 39, text: nil),
            "ArrowDown": CDPKey(key: "ArrowDown", code: "ArrowDown", virtualKey: 40, text: nil),
            "Home": CDPKey(key: "Home", code: "Home", virtualKey: 36, text: nil), "End": CDPKey(key: "End", code: "End", virtualKey: 35, text: nil),
            "PageUp": CDPKey(key: "PageUp", code: "PageUp", virtualKey: 33, text: nil),
            "PageDown": CDPKey(key: "PageDown", code: "PageDown", virtualKey: 34, text: nil),
            "Backspace": CDPKey(key: "Backspace", code: "Backspace", virtualKey: 8, text: nil),
            "Delete": CDPKey(key: "Delete", code: "Delete", virtualKey: 46, text: nil),
        ]
        if let found = named[base] {
            return CDPKey(key: found.key, code: found.code, virtualKey: found.virtualKey, text: command ? nil : found.text)
        }
        let symbols: [String: (code: String, vk: Int)] = [
            "-": ("Minus", 189), "=": ("Equal", 187), "[": ("BracketLeft", 219), "]": ("BracketRight", 221), "\\": ("Backslash", 220),
            ";": ("Semicolon", 186), "'": ("Quote", 222), ",": ("Comma", 188), ".": ("Period", 190), "/": ("Slash", 191), "`": ("Backquote", 192),
        ]
        let typed = command ? nil : chord.characters
        if base.count == 1, let scalar = base.unicodeScalars.first, scalar.isASCII {
            if ("A"..."Z").contains(base) {
                return CDPKey(key: chord.characters, code: "Key" + base, virtualKey: Int(scalar.value), text: typed)
            }
            if ("0"..."9").contains(base) {
                return CDPKey(key: chord.characters, code: "Digit" + base, virtualKey: Int(scalar.value), text: typed)
            }
            if let symbol = symbols[base] {
                return CDPKey(key: chord.characters, code: symbol.code, virtualKey: symbol.vk, text: typed)
            }
        }
        return nil
    }

    /// The AppKit editing commands a Mac renderer needs for keys that edit or move the caret; `PageKeyChord` already limited
    /// Command to these keys (and to text fields where the menu would act on them).
    nonisolated static func macEditingCommands(_ chord: PageKeyChord) -> [String] {
        let base = chord.name.split(separator: "+").last.map(String.init) ?? chord.name
        let shift = chord.modifiers.contains(.shift), option = chord.modifiers.contains(.option), command = chord.modifiers.contains(.command)
        let select = shift ? "AndModifySelection" : ""
        switch base {
        case "A" where command:
            return ["selectAll"]
        case "Z" where command:
            return [shift ? "redo" : "undo"]
        case "ArrowLeft":
            return [(command ? "moveToLeftEndOfLine" : option ? "moveWordLeft" : "moveLeft") + select]
        case "ArrowRight":
            return [(command ? "moveToRightEndOfLine" : option ? "moveWordRight" : "moveRight") + select]
        case "ArrowUp":
            return [(command ? "moveToBeginningOfDocument" : option ? "moveToBeginningOfParagraph" : "moveUp") + select]
        case "ArrowDown":
            return [(command ? "moveToEndOfDocument" : option ? "moveToEndOfParagraph" : "moveDown") + select]
        case "Backspace":
            return [command ? "deleteToBeginningOfLine" : option ? "deleteWordBackward" : "deleteBackward"]
        case "Delete":
            return [command ? "deleteToEndOfLine" : option ? "deleteWordForward" : "deleteForward"]
        case "Home":
            return [shift ? "moveToBeginningOfDocumentAndModifySelection" : "scrollToBeginningOfDocument"]
        case "End":
            return [shift ? "moveToEndOfDocumentAndModifySelection" : "scrollToEndOfDocument"]
        case "PageUp":
            return [shift ? "pageUpAndModifySelection" : "scrollPageUp"]
        case "PageDown":
            return [shift ? "pageDownAndModifySelection" : "scrollPageDown"]
        default:
            return []
        }
    }

    /// Whether the page is on screen for the person (not hidden, not parked on the shelf): a page that is not does not touch the cursor.
    var isShownToPerson: Bool {
        let visibility = remoteVisibility()
        return !visibility.hidden && !visibility.parked
    }

    // MARK: First responder and keys (moved from `ChromiumPage.swift`, which is at its line limit; `sendKeyEvent` is D4-12's)

    func selectAll() {
        guard let responder = window?.firstResponder, responder !== self, ownsResponder(responder) else { return }
        responder.selectAll(nil)
    }

    func ownsResponder(_ responder: NSResponder?) -> Bool {
        responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }

    /// Gives `event` to the page's first responder. For a page in the service that is its content view, which sends the key to the
    /// service and says whether it did: a key the page never received (the page is hidden, or no service runs) is not "delivered".
    func sendKeyEvent(_ event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder, responder !== self, ownsResponder(responder) else { return false }
        if let view = responder as? ChromiumRemoteContentView {
            return view.deliver(event, fromPerson: false)
        }
        if event.type == .keyUp {
            responder.keyUp(with: event)
        } else {
            responder.keyDown(with: event)
        }
        return true
    }
}
