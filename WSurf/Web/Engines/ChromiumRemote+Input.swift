// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CefKit
import Foundation

// D4 (out-of-process Chromium), phase 3, PR D4-12: the input of a page that runs in the Chromium service. Pointer, wheel, key and
// focus messages go on the input connection (`ChromiumRemote.sendInput`), in the order the person produced them, and are never
// coalesced; what comes back (the cursor, the tooltip, the status text, a key the page did not handle, focus leaving the page) is
// an event on the control connection, handed to the content view (`ChromiumRemoteContentView`). Nothing here waits on the service.

extension ChromiumRemoteBrowser {
    /// Sends one input message of this browser. False, and nothing sent, when the browser is not made yet or is gone, or when the page
    /// is hidden or parked (a person cannot be using it: an event that still arrives, from a test or a late AppKit delivery, is
    /// dropped rather than given to a page that is not shown). `visibleOnly: false` is for focus, which must reach a page that has
    /// just been hidden (it lost its keys).
    @discardableResult
    func sendInput(_ op: String, visibleOnly: Bool = true, _ fill: (CefRemoteMessage) -> Void) -> Bool {
        guard isCreated, !isClosed else { return false }
        if visibleOnly, let visibility = page?.remoteVisibility(), visibility.hidden || visibility.parked {
            return false
        }
        let message = CefRemoteMessage(op, browser: id)
        fill(message)
        // K4's input leg starts when WSurf sends (the delay before AppKit delivers the event is the same in process).
        message.set(CefRemote.Key.timestamp, ProcessInfo.processInfo.systemUptime)
        if let outgoing {
            return outgoing(message)
        }
        connection.sendInput(message)
        return true
    }

    /// The view became, or stopped being, the window's first responder: Chromium's focus follows. Before the browser is made the
    /// last answer waits for it (`markCreated`).
    func sendFocus(_ focused: Bool) {
        guard isCreated else {
            pendingFocus = focused
            return
        }
        sendInput(CefRemote.Op.focus, visibleOnly: false) { $0.set(CefRemote.Key.flag, focused) }
    }

    /// The service's events about the pointer and focus, for the content view.
    func receiveInput(_ message: CefRemoteMessage) {
        guard let view = contentView else { return }
        switch message.op {
        case CefRemote.Event.cursor:
            view.setRemoteCursor(CefCursorType.fromRemote(message.int(CefRemote.Key.cursor)))
        case CefRemote.Event.tooltip:
            view.toolTip = message.string(CefRemote.Key.text).nilIfEmpty
        case CefRemote.Event.statusMessage:
            page?.didHoverLink(URL(string: message.string(CefRemote.Key.text)))
        case CefRemote.Event.unhandledKey:
            view.redispatchUnhandledKey(nativeKeyCode: UInt16(truncatingIfNeeded: message.int(CefRemote.Key.nativeKeyCode)),
                                        type: message.int(CefRemote.Key.keyType))
        case CefRemote.Event.takeFocus:
            view.passFocusOn(forward: message.bool(CefRemote.Key.flag))
        default:
            break
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
