// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Tells a tab's dialog queue when the user clicks or types in its page, so a dialog that follows is the user's and no
/// connection's claim on the tab survives it. Events a tool sends the page never pass through the application, so only
/// the user's own input arrives here.
@MainActor
enum PageUserGesture {
    private static var monitor: Any?

    static func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated { page(receiving: event)?.dialogs?.userInteracted() }
            return event
        }
    }

    /// The page the event is for: the one under the pointer, or for a key the one that has the keyboard.
    static func page(receiving event: NSEvent) -> BrowserPage? {
        guard let window = event.window else { return nil }
        var view: NSView?
        if event.type == .keyDown {
            view = window.firstResponder as? NSView
        } else if let content = window.contentView {
            // hitTest takes the point in the superview's coordinates.
            view = content.hitTest((content.superview ?? content).convert(event.locationInWindow, from: nil))
        }
        while let current = view {
            if let page = current as? BrowserPage {
                return page
            }
            view = current.superview
        }
        return nil
    }
}
