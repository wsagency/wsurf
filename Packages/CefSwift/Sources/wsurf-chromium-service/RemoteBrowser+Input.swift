// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-12: what a browser does with the input WSurf sends (pointer, wheel, key, focus). The messages come on the input connection
// (`ServiceHost.handle` routes them here), in the order the person produced them. They are given to CEF in that order, once the
// browser exists (`withHost`); nothing is coalesced or dropped here.

import CCef
import CefKit
import Foundation

/// What `debug.stats` reports of a browser's input: K4's input leg is the time from WSurf's send to this receipt.
struct InputStatistics {
    var events = 0
    var legSumMs = 0.0
    var legMaxMs = 0.0
    /// The last `set_focus` given to the browser; -1 before any.
    var focus = -1
}

extension RemoteBrowser {
    func handleInput(_ message: CefRemoteMessage) {
        recordInputLeg(message)
        switch message.op {
        case CefRemote.Op.mouse:
            let event = cef_mouse_event_t(
                x: Int32(clamping: Int(message.double(CefRemote.Key.x).clamped(to: -1e6 ... 1e6).rounded())),
                y: Int32(clamping: Int(message.double(CefRemote.Key.y).clamped(to: -1e6 ... 1e6).rounded())),
                modifiers: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.modifiers)))
            let kind = message.string(CefRemote.Key.kind)
            let button = message.int(CefRemote.Key.button)
            let clicks = Int32(clamping: max(1, message.int(CefRemote.Key.clickCount)))
            let deltaX = Int32(clamping: Int(message.double(CefRemote.Key.deltaX).clamped(to: -1e6 ... 1e6).rounded()))
            let deltaY = Int32(clamping: Int(message.double(CefRemote.Key.deltaY).clamped(to: -1e6 ... 1e6).rounded()))
            withHost { host in
                Self.sendMouse(kind, event, button: button, clicks: clicks, deltaX: deltaX, deltaY: deltaY, to: host)
            }
        case CefRemote.Op.key:
            var event = cef_key_event_t()
            event.size = MemoryLayout<cef_key_event_t>.stride
            event.type = cef_key_event_type_t(rawValue: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.keyType)))
            event.modifiers = UInt32(truncatingIfNeeded: message.int(CefRemote.Key.modifiers))
            event.windows_key_code = Int32(truncatingIfNeeded: message.int(CefRemote.Key.windowsKeyCode))
            event.native_key_code = Int32(truncatingIfNeeded: message.int(CefRemote.Key.nativeKeyCode))
            event.character = UInt16(truncatingIfNeeded: message.int(CefRemote.Key.character))
            event.unmodified_character = UInt16(truncatingIfNeeded: message.int(CefRemote.Key.unmodifiedCharacter))
            withHost { host in host.pointee.send_key_event?(host, &event) }
        case CefRemote.Op.focus:
            let focused = message.bool(CefRemote.Key.flag)
            inputStats.focus = focused ? 1 : 0
            withHost { host in host.pointee.set_focus?(host, focused ? 1 : 0) }
        case CefRemote.Op.edit:
            // Phase 3 has one command (F2 of the D4-11 review: the page's MCP select-all); the Edit menu is D4-14's.
            guard message.string(CefRemote.Key.kind) == "selectAll" else { return }
            withBrowserLater { browser in
                guard let frame = browser.pointee.get_focused_frame?(browser) else { return }
                frame.pointee.select_all?(frame)
                Native.release(UnsafeMutableRawPointer(frame))
            }
        default:
            note("browser \(id): unknown input op \(message.op)")
        }
    }

    private static func sendMouse(
        _ kind: String, _ event: cef_mouse_event_t, button: Int64, clicks: Int32, deltaX: Int32, deltaY: Int32,
        to host: UnsafeMutablePointer<cef_browser_host_t>
    ) {
        var event = event
        switch kind {
        case CefRemote.MouseKind.move:
            host.pointee.send_mouse_move_event?(host, &event, 0)
        case CefRemote.MouseKind.leave:
            host.pointee.send_mouse_move_event?(host, &event, 1)
        case CefRemote.MouseKind.down, CefRemote.MouseKind.up:
            let type: cef_mouse_button_type_t = switch button {
            case 1: MBT_MIDDLE
            case 2: MBT_RIGHT
            default: MBT_LEFT
            }
            host.pointee.send_mouse_click_event?(host, &event, type, kind == CefRemote.MouseKind.up ? 1 : 0, clicks)
        case CefRemote.MouseKind.wheel:
            host.pointee.send_mouse_wheel_event?(host, &event, deltaX, deltaY)
        default:
            break
        }
    }

    private func recordInputLeg(_ message: CefRemoteMessage) {
        inputStats.events += 1
        let stamp = message.double(CefRemote.Key.timestamp)
        guard stamp > 0 else { return }
        let leg = max(0, Double(Clock.nowNanoseconds) / 1e9 - stamp) * 1000
        inputStats.legSumMs += leg
        inputStats.legMaxMs = max(inputStats.legMaxMs, leg)
    }

    func inputStatistics(into message: CefRemoteMessage) {
        message.set(CefRemote.Key.inputEvents, inputStats.events)
        message.set(CefRemote.Key.inputLegSumMs, inputStats.legSumMs)
        message.set(CefRemote.Key.inputLegMaxMs, inputStats.legMaxMs)
        message.set(CefRemote.Key.inputFocus, inputStats.focus)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
