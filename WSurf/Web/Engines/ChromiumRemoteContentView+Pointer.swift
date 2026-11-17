// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CCef
import CefKit
import Foundation

// D4-12: the pointer of a page in the Chromium service: moves, buttons, the wheel, the cursor and the tooltip. A page in process has
// CEF's own view for this; here the transparent content view takes the events and sends them on the input connection. Points are the
// view's own (it is flipped, so a point is top-left origin: CSS pixels at zoom 1).

extension ChromiumRemoteContentView {
    /// The `cef_mouse_event_t` modifier bits: keyboard modifiers, and the buttons that are down (bit 0 left, 1 right, 2 middle, as
    /// `NSEvent.pressedMouseButtons`).
    static func modifiers(_ flags: NSEvent.ModifierFlags, buttons: Int = 0) -> Int64 {
        var value: UInt32 = 0
        if flags.contains(.shift) {
            value |= UInt32(EVENTFLAG_SHIFT_DOWN.rawValue)
        }
        if flags.contains(.control) {
            value |= UInt32(EVENTFLAG_CONTROL_DOWN.rawValue)
        }
        if flags.contains(.option) {
            value |= UInt32(EVENTFLAG_ALT_DOWN.rawValue)
        }
        if flags.contains(.command) {
            value |= UInt32(EVENTFLAG_COMMAND_DOWN.rawValue)
        }
        if flags.contains(.capsLock) {
            value |= UInt32(EVENTFLAG_CAPS_LOCK_ON.rawValue)
        }
        if buttons & 1 != 0 {
            value |= UInt32(EVENTFLAG_LEFT_MOUSE_BUTTON.rawValue)
        }
        if buttons & 2 != 0 {
            value |= UInt32(EVENTFLAG_RIGHT_MOUSE_BUTTON.rawValue)
        }
        if buttons & 4 != 0 {
            value |= UInt32(EVENTFLAG_MIDDLE_MOUSE_BUTTON.rawValue)
        }
        return Int64(value)
    }

    @discardableResult
    private func sendMouse(
        _ kind: String, _ event: NSEvent, button: Int64 = 0, deltaX: CGFloat = 0, deltaY: CGFloat = 0
    ) -> Bool {
        let point = eventPoint?(event) ?? convert(event.locationInWindow, from: nil)
        let down = NSEvent.pressedMouseButtons
        return browser?.sendInput(CefRemote.Op.mouse) { message in
            message.set(CefRemote.Key.kind, kind)
            message.set(CefRemote.Key.x, Double(point.x))
            message.set(CefRemote.Key.y, Double(point.y))
            message.set(CefRemote.Key.modifiers, Self.modifiers(event.modifierFlags, buttons: down))
            message.set(CefRemote.Key.button, button)
            message.set(CefRemote.Key.clickCount, Int64(max(1, event.type == .scrollWheel ? 1 : event.clickCount)))
            message.set(CefRemote.Key.deltaX, Double(deltaX))
            message.set(CefRemote.Key.deltaY, Double(deltaY))
        } ?? false
    }

    // MARK: Tracking and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func cursorUpdate(with event: NSEvent) {
        remoteCursor.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: remoteCursor)
    }

    /// The page asked for a cursor (`display.cursor`). It is set at once only while the pointer is over the page: a change that
    /// arrives as the pointer leaves must not change the cursor over the sidebar.
    func setRemoteCursor(_ type: CefCursorType) {
        remoteCursor = type.nsCursor ?? .arrow
        window?.invalidateCursorRects(for: self)
        guard let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        remoteCursor.set()
    }

    // MARK: Moves

    override func mouseMoved(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.move, event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.move, event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.move, event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.move, event)
    }

    override func mouseEntered(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.move, event)
    }

    override func mouseExited(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.leave, event)
    }

    // MARK: Buttons

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        sendMouse(CefRemote.MouseKind.down, event, button: 0)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.up, event, button: 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.down, event, button: 2)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(CefRemote.MouseKind.up, event, button: 2)
    }

    /// The thumb buttons (3 and 4) are Back and Forward, as for a page in process (`CefMetalHostView.otherMouseDown`); the press is
    /// the edge and the release is swallowed. Any other button is a middle click. (The window takes the thumb buttons first when the
    /// setting `sideButtonsNavigate` is on: `BrowserWindow.sendEvent`.)
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3:
            _ = owningPage?.owner?.goBack()
        case 4:
            _ = owningPage?.owner?.goForward()
        default:
            sendMouse(CefRemote.MouseKind.down, event, button: 1)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber != 3, event.buttonNumber != 4 else { return }
        sendMouse(CefRemote.MouseKind.up, event, button: 1)
    }

    // MARK: Wheel

    /// The pixel deltas of the CGEvent, momentum included, as cefclient uses; a line-based wheel is scaled. The part of a delta that
    /// is not a whole pixel is carried to the next event, so a slow scroll is not rounded to nothing. (Scroll phases and momentum
    /// have no field in `cef_mouse_event_t`: elastic overscroll is not available windowless.)
    override func scrollWheel(with event: NSEvent) {
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
        let totalX = dx + scrollResidual.x
        let totalY = dy + scrollResidual.y
        let sendX = totalX.rounded(.towardZero)
        let sendY = totalY.rounded(.towardZero)
        scrollResidual = CGPoint(x: totalX - sendX, y: totalY - sendY)
        guard sendX != 0 || sendY != 0 else { return }
        sendMouse(CefRemote.MouseKind.wheel, event, deltaX: sendX, deltaY: sendY)
    }
}
