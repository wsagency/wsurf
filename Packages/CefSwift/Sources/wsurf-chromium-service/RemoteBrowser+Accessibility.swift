// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-40: CEF's accessibility tree out of process. WSurf turns it on per browser (`ax.enable`, `RemoteBrowser.setAccessibility`);
// CEF then asks the render handler for an accessibility handler and sends the tree to it on the UI thread. The updates leave as JSON
// on the accessibility connection (`ServiceHost.sendAccessibility`), never on the control connection.
//
// The handler follows the rule of `RemoteClientHandlers.swift`: it owns the browser's weak box, never the browser. Each request of
// CEF's makes a handler of its own and gives CEF the only reference: nothing here keeps one, so nothing is left to release.

import CCef
import CefKit
import Foundation

extension RemoteBrowser {
    /// `ax.enable`: CEF's tree-only mode for this browser (a windowless browser creates no platform accessibility objects, only the
    /// tree). Once the browser exists; a request that comes sooner waits for it, in order with the rest.
    func setAccessibility(_ enabled: Bool) {
        withHost { [id] host in
            host.pointee.set_accessibility_state?(host, enabled ? STATE_ENABLED : STATE_DISABLED)
            note("browser \(id): accessibility \(enabled ? "on" : "off")")
        }
    }

    /// An update from CEF's handler (UI thread). With no connection to take it, it is not even converted.
    fileprivate func accessibilityChanged(_ name: String, _ value: UnsafeMutablePointer<cef_value_t>?) {
        guard ServiceHost.shared.hasAccessibilityConnection else { return }
        ServiceHost.shared.sendAccessibility(browser: id, name: name, data: AccessibilityJSON.data(value))
    }
}

extension RemoteClientHandlers {
    /// `render.get_accessibility_handler`: a new handler, whose only reference is CEF's. Nil once the browser's box is gone.
    static func makeAccessibility(_ renderSelf: UnsafeMutablePointer<cef_render_handler_t>?) -> UnsafeMutablePointer<cef_accessibility_handler_t>? {
        guard let box = Native.owner(BrowserBox.self, renderSelf.map(UnsafeMutableRawPointer.init)) else { return nil }
        let handler = Native.allocate(cef_accessibility_handler_t.self, owner: box)
        handler.pointee.on_accessibility_tree_change = { handlerSelf, value in
            defer { Native.release(value.map(UnsafeMutableRawPointer.init)) }
            guard let owner = Native.owner(BrowserBox.self, handlerSelf.map(UnsafeMutableRawPointer.init))?.browser else { return }
            MainActor.assumeIsolated { owner.accessibilityChanged(CefRemote.Event.accessibilityTree, value) }
        }
        handler.pointee.on_accessibility_location_change = { handlerSelf, value in
            defer { Native.release(value.map(UnsafeMutableRawPointer.init)) }
            guard let owner = Native.owner(BrowserBox.self, handlerSelf.map(UnsafeMutableRawPointer.init))?.browser else { return }
            MainActor.assumeIsolated { owner.accessibilityChanged(CefRemote.Event.accessibilityLocation, value) }
        }
        return handler
    }
}
