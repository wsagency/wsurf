// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4 spike: input for a ChromiumPage whose browser lives in the out-of-process service. The page is the first responder;
// AppKit's events become CEF's windowless input calls in the service (ported from CefSwift's `CefMetalHostView`, which does
// the same in process). Nothing here waits on the service: IME geometry (`firstRect`) comes from what the service pushed.
// In process (no `remote`) every override falls through to AppKit's default, as before.

import AppKit
import CCef
import CefKit

struct ChromiumRemoteInputState {
    var scrollResidual = CGPoint.zero
    var trackingArea: NSTrackingArea?
    // cefclient's deferred key model: `interpretKeyEvents` only gathers, the key is sent afterwards.
    var handlingKeyDown = false
    var textToBeInserted = ""
    var hasMarkedText = false
    var oldHasMarkedText = false
    var markedText = ""
    var markedSelection = NSRange(location: NSNotFound, length: 0)
    var markedReplacement: NSRange?
    var unmarkTextCalled = false
    var markedRange = NSRange(location: NSNotFound, length: 0)
    // Pushed by the service.
    var compositionBounds: [CGRect] = []
    var caretRect: CGRect?
    var selectedText = ""
    var selectedRange = NSRange(location: NSNotFound, length: 0)
    var contextMenuOpen = false
    var visibilityUpdatePending = false
}

extension ChromiumPage {
    // MARK: Events from the service

    func receiveRemoteInput(_ message: CefRemoteMessage) {
        switch message.op {
        case CefRemote.Event.imeRange:
            let values = message.doubles(CefRemote.Key.rects)
            remoteInput.compositionBounds = stride(from: 0, to: values.count - 3, by: 4).map {
                CGRect(x: values[$0], y: values[$0 + 1], width: values[$0 + 2], height: values[$0 + 3])
            }
            if let first = remoteInput.compositionBounds.first {
                remoteInput.caretRect = first
            }
            // The bounds arrive a moment after `setMarkedText`, which the input method may already have asked `firstRect`
            // about: tell it to ask again, so the candidate window follows the composition.
            inputContext?.invalidateCharacterCoordinates()
        case CefRemote.Event.textSelection:
            remoteInput.selectedText = message.string(CefRemote.Key.text)
            let from = Int(message.int(CefRemote.Key.rangeFrom))
            let to = Int(message.int(CefRemote.Key.rangeTo))
            remoteInput.selectedRange = NSRange(location: from, length: max(0, to - from))
        case CefRemote.Event.contextMenu:
            showRemoteContextMenu(message)
        case CefRemote.Event.unhandledKey, CefRemote.Event.takeFocus, CefRemote.Event.gotFocus:
            break
        default:
            break
        }
    }

    // MARK: Mouse

    static func remoteModifiers(_ flags: NSEvent.ModifierFlags, buttons: Int = 0) -> Int64 {
        var value: UInt32 = 0
        if flags.contains(.shift) { value |= UInt32(EVENTFLAG_SHIFT_DOWN.rawValue) }
        if flags.contains(.control) { value |= UInt32(EVENTFLAG_CONTROL_DOWN.rawValue) }
        if flags.contains(.option) { value |= UInt32(EVENTFLAG_ALT_DOWN.rawValue) }
        if flags.contains(.command) { value |= UInt32(EVENTFLAG_COMMAND_DOWN.rawValue) }
        if flags.contains(.capsLock) { value |= UInt32(EVENTFLAG_CAPS_LOCK_ON.rawValue) }
        if buttons & 1 != 0 { value |= UInt32(EVENTFLAG_LEFT_MOUSE_BUTTON.rawValue) }
        if buttons & 2 != 0 { value |= UInt32(EVENTFLAG_RIGHT_MOUSE_BUTTON.rawValue) }
        if buttons & 4 != 0 { value |= UInt32(EVENTFLAG_MIDDLE_MOUSE_BUTTON.rawValue) }
        return Int64(value)
    }

    private func sendMouse(_ kind: String, _ event: NSEvent, button: Int64 = 0, deltaX: CGFloat = 0, deltaY: CGFloat = 0) {
        guard let remote else { return }
        let point = convert(event.locationInWindow, from: nil)
        let message = remote.message(CefRemote.Op.mouse)
        message.set(CefRemote.Key.kind, kind)
        message.set(CefRemote.Key.x, Double(point.x))
        message.set(CefRemote.Key.y, Double(point.y))
        message.set(CefRemote.Key.modifiers, Self.remoteModifiers(event.modifierFlags, buttons: NSEvent.pressedMouseButtons))
        message.set(CefRemote.Key.button, button)
        message.set(CefRemote.Key.clickCount, Int64(max(1, event.type == .scrollWheel ? 1 : event.clickCount)))
        message.set(CefRemote.Key.deltaX, Double(deltaX))
        message.set(CefRemote.Key.deltaY, Double(deltaY))
        // K4's input leg starts when WSurf sends (the delay before AppKit delivers the event is the same in process).
        message.set(CefRemote.Key.timestamp, ProcessInfo.processInfo.systemUptime)
        remote.sendInput(message)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard isRemote else { return }
        if let area = remoteInput.trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        remoteInput.trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isRemote || super.acceptsFirstMouse(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard remote != nil else { return super.mouseMoved(with: event) }
        sendMouse("move", event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard remote != nil else { return super.mouseDragged(with: event) }
        sendMouse("move", event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard remote != nil else { return super.rightMouseDragged(with: event) }
        sendMouse("move", event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard remote != nil else { return super.otherMouseDragged(with: event) }
        sendMouse("move", event)
    }

    override func mouseEntered(with event: NSEvent) {
        guard remote != nil else { return super.mouseEntered(with: event) }
        sendMouse("move", event)
    }

    override func mouseExited(with event: NSEvent) {
        guard remote != nil else { return super.mouseExited(with: event) }
        sendMouse("leave", event)
    }

    override func mouseDown(with event: NSEvent) {
        guard remote != nil else { return super.mouseDown(with: event) }
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        sendMouse("down", event, button: 0)
    }

    override func mouseUp(with event: NSEvent) {
        guard remote != nil else { return super.mouseUp(with: event) }
        sendMouse("up", event, button: 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard remote != nil else { return super.rightMouseDown(with: event) }
        sendMouse("down", event, button: 2)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard remote != nil else { return super.rightMouseUp(with: event) }
        sendMouse("up", event, button: 2)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard remote != nil else { return super.otherMouseDown(with: event) }
        switch event.buttonNumber {
        case 3: _ = owner?.goBack()
        case 4: _ = owner?.goForward()
        default: sendMouse("down", event, button: 1)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard remote != nil else { return super.otherMouseUp(with: event) }
        guard event.buttonNumber != 3, event.buttonNumber != 4 else { return }
        sendMouse("up", event, button: 1)
    }

    override func scrollWheel(with event: NSEvent) {
        guard remote != nil else { return super.scrollWheel(with: event) }
        // The pixel deltas of the CGEvent, momentum included, as cefclient uses; a line-based wheel is scaled.
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if let cgEvent = event.cgEvent {
            let pointY = cgEvent.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let pointX = cgEvent.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if pointX != 0 || pointY != 0 {
                dx = CGFloat(pointX)
                dy = CGFloat(pointY)
            } else if !event.hasPreciseScrollingDeltas {
                dx *= 40
                dy *= 40
            }
        } else if !event.hasPreciseScrollingDeltas {
            dx *= 40
            dy *= 40
        }
        let totalX = dx + remoteInput.scrollResidual.x
        let totalY = dy + remoteInput.scrollResidual.y
        let sendX = totalX.rounded(.towardZero)
        let sendY = totalY.rounded(.towardZero)
        remoteInput.scrollResidual = CGPoint(x: totalX - sendX, y: totalY - sendY)
        guard sendX != 0 || sendY != 0 else { return }
        sendMouse("wheel", event, deltaX: sendX, deltaY: sendY)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard remote != nil else { return super.cursorUpdate(with: event) }
        remoteCursor.set()
    }

    override func resetCursorRects() {
        guard remote != nil else { return super.resetCursorRects() }
        addCursorRect(bounds, cursor: remoteCursor)
    }

    // MARK: Keyboard

    override var inputContext: NSTextInputContext? {
        // Only the out-of-process page is a text input client; in process CEF's own view is.
        remote != nil ? super.inputContext : nil
    }

    override func keyDown(with event: NSEvent) {
        guard remote != nil else { return super.keyDown(with: event) }
        remoteInput.oldHasMarkedText = remoteInput.hasMarkedText
        remoteInput.handlingKeyDown = true
        remoteInput.textToBeInserted = ""
        remoteInput.markedReplacement = nil
        remoteInput.unmarkTextCalled = false
        interpretKeyEvents([event])
        remoteInput.handlingKeyDown = false
        sendKeyAfterTextInput(event)
    }

    #if DEBUG
    /// D4 spike: `keyDown` with `interpret` in place of `interpretKeyEvents`, so the driver can play an input method's calls
    /// inside a keystroke, the path real IME typing takes, without driving a system input method.
    func simulateKeyDownForIMECheck(_ event: NSEvent, interpret: () -> Void) {
        guard remote != nil else { return }
        remoteInput.oldHasMarkedText = remoteInput.hasMarkedText
        remoteInput.handlingKeyDown = true
        remoteInput.textToBeInserted = ""
        remoteInput.markedReplacement = nil
        remoteInput.unmarkTextCalled = false
        interpret()
        remoteInput.handlingKeyDown = false
        sendKeyAfterTextInput(event)
    }
    #endif

    override func keyUp(with event: NSEvent) {
        guard remote != nil else { return super.keyUp(with: event) }
        sendKey(event, type: KEYEVENT_KEYUP)
    }

    override func flagsChanged(with event: NSEvent) {
        guard remote != nil else { return super.flagsChanged(with: event) }
        sendKey(event, type: Self.isModifierPressed(event) ? KEYEVENT_KEYDOWN : KEYEVENT_KEYUP)
    }

    override func doCommand(by selector: Selector) {
        // The key itself goes to the renderer (KEYDOWN), which moves the caret or deletes; AppKit's command is not wanted.
        guard remote == nil else { return }
        super.doCommand(by: selector)
    }

    private func sendKey(_ event: NSEvent, type: cef_key_event_type_t, character: UInt16? = nil) {
        guard let remote else { return }
        let message = remote.message(CefRemote.Op.key)
        var modifiers = Self.remoteModifiers(event.modifierFlags)
        if Self.isKeyPad(event) {
            modifiers |= Int64(EVENTFLAG_IS_KEY_PAD.rawValue)
        }
        message.set(CefRemote.Key.keyType, Int64(type.rawValue))
        message.set(CefRemote.Key.modifiers, modifiers)
        message.set(CefRemote.Key.nativeKeyCode, Int64(event.keyCode))
        if event.type == .keyDown || event.type == .keyUp {
            message.set(CefRemote.Key.windowsKeyCode,
                        Int64(ChromiumKeyCodes.windowsKeyCode(forMacKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers)))
            message.set(CefRemote.Key.unmodifiedCharacter, Int64(event.charactersIgnoringModifiers?.utf16.first ?? 0))
            message.set(CefRemote.Key.character, Int64(character ?? event.characters?.utf16.first ?? 0))
        }
        // K4's input leg starts when WSurf sends (the delay before AppKit delivers the event is the same in process).
        message.set(CefRemote.Key.timestamp, ProcessInfo.processInfo.systemUptime)
        remote.sendInput(message)
    }

    /// cefclient's rule: a plain key goes as KEYDOWN and CHAR, so the page sees real key events; text from an input method is
    /// committed; the composition is updated, finished or cancelled.
    private func sendKeyAfterTextInput(_ event: NSEvent) {
        guard let remote else { return }
        let state = remoteInput
        if !state.hasMarkedText, !state.oldHasMarkedText, state.textToBeInserted.utf16.count <= 1 {
            sendKey(event, type: KEYEVENT_KEYDOWN)
            sendKey(event, type: KEYEVENT_CHAR, character: state.textToBeInserted.utf16.first ?? event.characters?.utf16.first)
        }
        let threshold = (state.hasMarkedText || state.oldHasMarkedText) ? 0 : 1
        var textInserted = false
        if state.textToBeInserted.utf16.count > threshold {
            remote.sendInput(imeMessage(CefRemote.Op.imeCommit, text: state.textToBeInserted, replacement: nil))
            remoteInput.textToBeInserted = ""
            textInserted = true
        }
        // As Chromium's own view (RenderWidgetHostViewCocoa): text that was inserted ended the composition, so no cancel follows
        // it (the extra cancel is an empty composition, which deletes a selection that is not collapsed).
        if state.hasMarkedText, !state.markedText.isEmpty {
            let message = imeMessage(CefRemote.Op.imeSetComposition, text: state.markedText, replacement: state.markedReplacement)
            message.set(CefRemote.Key.rangeFrom, Int64(max(0, state.markedSelection.location)))
            message.set(CefRemote.Key.rangeTo, Int64(max(0, state.markedSelection.location + state.markedSelection.length)))
            remote.sendInput(message)
        } else if state.oldHasMarkedText, !state.hasMarkedText, !textInserted {
            if state.unmarkTextCalled {
                let message = imeMessage(CefRemote.Op.imeFinish, text: "", replacement: nil)
                message.set(CefRemote.Key.flag, false)
                remote.sendInput(message)
            } else {
                remote.sendInput(imeMessage(CefRemote.Op.imeCancel, text: "", replacement: nil))
            }
        }
        remoteInput.markedReplacement = nil
    }

    private func imeMessage(_ op: String, text: String, replacement: NSRange?) -> CefRemoteMessage {
        let message = remote?.message(op) ?? CefRemoteMessage(op)
        message.set(CefRemote.Key.text, text)
        if let replacement, replacement.location != NSNotFound {
            message.set(CefRemote.Key.replaceFrom, Int64(replacement.location))
            message.set(CefRemote.Key.replaceTo, Int64(replacement.location + replacement.length))
        }
        message.set(CefRemote.Key.timestamp, ProcessInfo.processInfo.systemUptime)
        return message
    }

    private static func isKeyPad(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.numericPad) { return true }
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

    // MARK: Edit menu

    private func remoteEdit(_ kind: String) {
        remote?.send(CefRemote.Op.edit) { $0.set(CefRemote.Key.kind, kind) }
    }

    /// In process these actions are not this view's: they go on along the chain as before (the app's own Undo Close Tab,
    /// for one).
    private func edit(_ kind: String, _ action: Selector, _ sender: Any?) {
        guard remote != nil else {
            _ = nextResponder?.tryToPerform(action, with: sender)
            return
        }
        remoteEdit(kind)
    }

    @objc func copy(_ sender: Any?) { edit("copy", #selector(copy(_:)), sender) }
    @objc func cut(_ sender: Any?) { edit("cut", #selector(cut(_:)), sender) }
    @objc func paste(_ sender: Any?) { pasteRemote("paste", #selector(paste(_:)), sender) }
    @objc func pasteAsPlainText(_ sender: Any?) { pasteRemote("pasteAndMatchStyle", #selector(pasteAsPlainText(_:)), sender) }

    /// K10's fallback, DEBUG only (`WSURF_OOP_PASTE=host`): WSurf reads the pasteboard itself, on the person's own paste
    /// command, and the service inserts the text, so the service never reads the pasteboard. Plain text only: the page's
    /// `paste` event and rich formats (HTML, images, files) are phase 3.
    private func pasteRemote(_ kind: String, _ action: Selector, _ sender: Any?) {
        if let remote, ChromiumOOP.environment("WSURF_OOP_PASTE") == "host" {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
            let message = remote.message(CefRemote.Op.edit)
            message.set(CefRemote.Key.kind, "pasteText")
            message.set(CefRemote.Key.text, text)
            remote.sendInput(message)
            return
        }
        edit(kind, action, sender)
    }
    @objc func delete(_ sender: Any?) { edit("delete", #selector(delete(_:)), sender) }
    @objc func undo(_ sender: Any?) { edit("undo", #selector(undo(_:)), sender) }
    @objc func redo(_ sender: Any?) { edit("redo", #selector(redo(_:)), sender) }

    override func selectAll(_ sender: Any?) {
        // NSResponder only declares this (an optional key-binding method): in process, pass it along instead of to super.
        guard remote != nil else {
            _ = nextResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: sender)
            return
        }
        remoteEdit("selectAll")
    }

    // MARK: Context menu

    private func showRemoteContextMenu(_ message: CefRemoteMessage) {
        guard let remote else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in message.messages(CefRemote.Key.items) {
            if item.bool(CefRemote.Key.separator) {
                menu.addItem(.separator())
                continue
            }
            let label = item.string(CefRemote.Key.label).replacingOccurrences(of: "&", with: "")
            guard !label.isEmpty else { continue }
            let menuItem = NSMenuItem(title: label, action: #selector(remoteContextMenuItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = Int(item.int(CefRemote.Key.command))
            menuItem.isEnabled = item.bool(CefRemote.Key.enabled)
            menu.addItem(menuItem)
        }
        guard !menu.items.isEmpty else {
            remote.send(CefRemote.Op.contextMenuCommand) { $0.set(CefRemote.Key.command, Int64(-1)) }
            return
        }
        remoteInput.contextMenuOpen = true
        let point = NSPoint(x: message.double(CefRemote.Key.x), y: message.double(CefRemote.Key.y))
        // Modal: returns once the menu is closed. A chosen item answered already; otherwise the menu was dismissed.
        menu.popUp(positioning: nil, at: point, in: self)
        if remoteInput.contextMenuOpen {
            remoteInput.contextMenuOpen = false
            remote.send(CefRemote.Op.contextMenuCommand) { $0.set(CefRemote.Key.command, Int64(-1)) }
        }
    }

    @objc private func remoteContextMenuItem(_ sender: NSMenuItem) {
        guard remoteInput.contextMenuOpen else { return }
        remoteInput.contextMenuOpen = false
        remote?.send(CefRemote.Op.contextMenuCommand) { $0.set(CefRemote.Key.command, Int64(sender.tag)) }
    }
}

// MARK: - IME

extension ChromiumPage: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        if remoteInput.handlingKeyDown {
            remoteInput.textToBeInserted += text
        } else {
            // A candidate picked outside a keystroke (the candidate window, the emoji viewer, press-and-hold).
            remote?.sendInput(imeCommitMessage(text, replacementRange: replacementRange))
        }
        remoteInput.hasMarkedText = false
        remoteInput.markedRange = NSRange(location: NSNotFound, length: 0)
    }

    private func imeCommitMessage(_ text: String, replacementRange: NSRange) -> CefRemoteMessage {
        let message = remote?.message(CefRemote.Op.imeCommit) ?? CefRemoteMessage(CefRemote.Op.imeCommit)
        message.set(CefRemote.Key.text, text)
        if replacementRange.location != NSNotFound {
            message.set(CefRemote.Key.replaceFrom, Int64(replacementRange.location))
            message.set(CefRemote.Key.replaceTo, Int64(replacementRange.location + replacementRange.length))
        }
        return message
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        remoteInput.markedSelection = selectedRange
        remoteInput.markedText = text
        remoteInput.hasMarkedText = !text.isEmpty
        remoteInput.markedRange = text.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: text.utf16.count)
        let replacement = replacementRange.location == NSNotFound ? nil : replacementRange
        if remoteInput.handlingKeyDown {
            remoteInput.markedReplacement = replacement
        } else if let remote {
            if text.isEmpty {
                remote.sendInput(remote.message(CefRemote.Op.imeCancel))
            } else {
                let message = remote.message(CefRemote.Op.imeSetComposition)
                message.set(CefRemote.Key.text, text)
                message.set(CefRemote.Key.rangeFrom, Int64(max(0, selectedRange.location)))
                message.set(CefRemote.Key.rangeTo, Int64(max(0, selectedRange.location + selectedRange.length)))
                if let replacement {
                    message.set(CefRemote.Key.replaceFrom, Int64(replacement.location))
                    message.set(CefRemote.Key.replaceTo, Int64(replacement.location + replacement.length))
                }
                remote.sendInput(message)
            }
        }
    }

    func unmarkText() {
        remoteInput.hasMarkedText = false
        remoteInput.markedText = ""
        remoteInput.markedRange = NSRange(location: NSNotFound, length: 0)
        if remoteInput.handlingKeyDown {
            remoteInput.unmarkTextCalled = true
        } else if let remote {
            // keep_selection false, as inside a keystroke and as Chromium's own view: the caret goes after the finished text.
            let message = remote.message(CefRemote.Op.imeFinish)
            message.set(CefRemote.Key.flag, false)
            remote.sendInput(message)
        }
    }

    func selectedRange() -> NSRange {
        remoteInput.selectedRange
    }

    func markedRange() -> NSRange {
        remoteInput.markedRange
    }

    func hasMarkedText() -> Bool {
        remoteInput.markedRange.location != NSNotFound && remoteInput.markedRange.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Where the candidate window, the emoji viewer and the press-and-hold popup go: the composition's first character, or
    /// the last caret the service reported. Never a wait on the service.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        // The asked character's own box, as native Chromium answers (the input method puts its window below it). The bounds
        // are indexed from the composition's start; past its end, the caret after the last character.
        let bounds = remoteInput.compositionBounds
        let index = range.location == NSNotFound ? 0 : range.location
        let caret: CGRect = if index < bounds.count {
            bounds[index]
        } else if let last = bounds.last {
            CGRect(x: last.maxX, y: last.minY, width: 1, height: last.height)
        } else {
            remoteInput.caretRect ?? CGRect(x: 4, y: 4, width: 1, height: 16)
        }
        actualRange?.pointee = NSRange(location: index, length: index < bounds.count ? min(range.length, bounds.count - index) : 0)
        let rect = NSRect(x: caret.minX, y: caret.minY, width: max(caret.width, 1), height: max(caret.height, 1))
        // The view is flipped: `convert` turns the top-left rectangle into window coordinates.
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}

/// macOS key codes to the Windows (DOM) key codes CEF expects (CefSwift's `CefKeyCodes`, which lives in CefSwiftUI).
enum ChromiumKeyCodes {
    static func windowsKeyCode(forMacKeyCode keyCode: UInt16, characters: String?) -> Int {
        if let mapped = special[keyCode] {
            return mapped
        }
        if let scalar = characters?.uppercased().unicodeScalars.first, scalar.value < 128 {
            return Int(scalar.value)
        }
        return 0
    }

    private static let special: [UInt16: Int] = [
        0x24: 0x0D, 0x4C: 0x0D, 0x30: 0x09, 0x31: 0x20, 0x33: 0x08, 0x75: 0x2E, 0x35: 0x1B, 0x7B: 0x25, 0x7C: 0x27,
        0x7D: 0x28, 0x7E: 0x26, 0x73: 0x24, 0x77: 0x23, 0x74: 0x21, 0x79: 0x22, 0x38: 0x10, 0x3C: 0x10, 0x3B: 0x11,
        0x3E: 0x11, 0x3A: 0x12, 0x3D: 0x12, 0x37: 0x5B, 0x36: 0x5C, 0x39: 0x14, 0x7A: 0x70, 0x78: 0x71, 0x63: 0x72,
        0x76: 0x73, 0x60: 0x74, 0x61: 0x75, 0x62: 0x76, 0x64: 0x77, 0x65: 0x78, 0x6D: 0x79, 0x67: 0x7A, 0x6F: 0x7B,
    ]
}
