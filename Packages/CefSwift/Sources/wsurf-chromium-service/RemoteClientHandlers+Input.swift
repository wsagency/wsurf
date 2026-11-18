// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-12: the CEF handlers input needs, apart from the browser's own: keyboard (a key the page did not handle goes back to WSurf),
// focus (Tab leaving the page), and the display callbacks of the pointer (cursor, tooltip, status text). Same lifetime rule as the
// other handlers (`RemoteClientHandlers.swift`): constants of the client, owning a weak box, released only when CEF destroys the
// client; every callback runs on the UI thread, which is the main thread.

import CCef
import CefKit
import Foundation

extension RemoteClientHandlers {
    static func makeKeyboard(_ box: BrowserBox) -> UnsafeMutablePointer<cef_keyboard_handler_t> {
        let keyboard = Native.allocate(cef_keyboard_handler_t.self, owner: box)
        // Asked after the renderer: the keys it did not consume. WSurf's own shortcuts were tried before anything was sent.
        keyboard.pointee.on_key_event = { handlerSelf, browser, event, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let event, let owner = RemoteClientHandlers.browser(handlerSelf) else { return 0 }
            // WSurf acts on a key-down only (a character or a key-up it never matches): the others are not worth an XPC message.
            guard event.pointee.type == KEYEVENT_RAWKEYDOWN || event.pointee.type == KEYEVENT_KEYDOWN else { return 0 }
            let type = Int64(event.pointee.type.rawValue)
            let modifiers = Int64(event.pointee.modifiers)
            let nativeKeyCode = Int64(event.pointee.native_key_code)
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.unhandledKey)
                message.set(CefRemote.Key.keyType, type)
                message.set(CefRemote.Key.modifiers, modifiers)
                message.set(CefRemote.Key.nativeKeyCode, nativeKeyCode)
                owner.send(message)
            }
            return 0
        }
        return keyboard
    }

    /// Until the context menu is WSurf's (D4-15) no menu may appear: CEF's own menu runner would run in the service, a process with no
    /// window and no menu of its own (and a menu tracking loop on the UI thread of every tab). The model is cleared, which shows no
    /// menu, and a menu that is run anyway is cancelled.
    static func makeContextMenu(_ box: BrowserBox) -> UnsafeMutablePointer<cef_context_menu_handler_t> {
        let handler = Native.allocate(cef_context_menu_handler_t.self, owner: box)
        handler.pointee.on_before_context_menu = { handlerSelf, browser, frame, params, model in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            Native.release(params.map(UnsafeMutableRawPointer.init))
            defer { Native.release(model.map(UnsafeMutableRawPointer.init)) }
            var cleared = false
            if let model {
                cleared = model.pointee.clear?(model) == 1
            }
            guard cleared, let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.inputStats.menusCleared += 1 }
        }
        handler.pointee.run_context_menu = { _, browser, frame, params, model, callback in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            Native.release(params.map(UnsafeMutableRawPointer.init))
            Native.release(model.map(UnsafeMutableRawPointer.init))
            if let callback {
                callback.pointee.cancel?(callback)
                Native.release(UnsafeMutableRawPointer(callback))
            }
            return 1
        }
        handler.pointee.on_context_menu_command = { _, browser, frame, params, _, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            Native.release(params.map(UnsafeMutableRawPointer.init))
            return 0
        }
        handler.pointee.on_context_menu_dismissed = { _, browser, frame in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
        }
        return handler
    }

    static func makeFocus(_ box: BrowserBox) -> UnsafeMutablePointer<cef_focus_handler_t> {
        let focus = Native.allocate(cef_focus_handler_t.self, owner: box)
        focus.pointee.on_take_focus = { handlerSelf, browser, next in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.takeFocus)
                message.set(CefRemote.Key.flag, next != 0)
                owner.send(message)
            }
        }
        focus.pointee.on_set_focus = { _, browser, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            return 0
        }
        focus.pointee.on_got_focus = { handlerSelf, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.send(owner.event(CefRemote.Event.gotFocus)) }
        }
        return focus
    }

    /// The render handler's text-input callback: whether an editable field has the focus.
    static func addTextInputCallback(to render: UnsafeMutablePointer<cef_render_handler_t>) {
        render.pointee.on_virtual_keyboard_requested = { handlerSelf, browser, mode in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.textInput)
                message.set(CefRemote.Key.flag, mode != CEF_TEXT_INPUT_MODE_NONE)
                owner.send(message)
            }
        }
    }

    /// The pointer's display callbacks, added to the display handler `makeDisplay` made.
    static func addPointerCallbacks(to display: UnsafeMutablePointer<cef_display_handler_t>) {
        display.pointee.on_cursor_change = { handlerSelf, browser, _, type, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return 1 }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.cursor)
                message.set(CefRemote.Key.cursor, Int64(type.rawValue))
                owner.send(message)
            }
            // WSurf sets the cursor: there is no native window for CEF to set it on.
            return 1
        }
        display.pointee.on_tooltip = { handlerSelf, browser, text in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return 1 }
            let tip = Native.string(text.map { UnsafePointer($0) })
            MainActor.assumeIsolated { owner.sendText(CefRemote.Event.tooltip, tip) }
            return 1
        }
        display.pointee.on_status_message = { handlerSelf, browser, value in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            let text = Native.string(value)
            MainActor.assumeIsolated { owner.sendText(CefRemote.Event.statusMessage, text) }
        }
    }
}

extension RemoteBrowser {
    func sendText(_ name: String, _ text: String) {
        let message = event(name)
        message.set(CefRemote.Key.text, text)
        send(message)
    }
}
