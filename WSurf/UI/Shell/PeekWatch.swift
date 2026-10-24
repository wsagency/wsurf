// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit

/// When a peek, the Standard sidebar floated over the page or the Minimal tab list slid in from the edge, has been left.
/// Window points, top-left origin, like `AppCoordinator.pointerInShell` and SwiftUI's `.global` space.
enum PeekExit {
    /// The grab strip of the resize handle reaches this far past the sidebar. It belongs to the peek.
    static let resizeReach: CGFloat = 12

    static func hasLeft(pointer: CGPoint?, frame: CGRect, trailingReach: CGFloat = 0) -> Bool {
        guard !frame.isEmpty else { return false }
        guard let pointer else { return true }
        var reach = frame
        reach.size.width += trailingReach
        return !reach.contains(pointer)
    }

    /// The Standard sidebar's peek ends once the pointer is off the sidebar and its resize strip. It stays while the
    /// sidebar is being resized (the handle is dragged past the strip), while the profile switcher it opened is up, and
    /// never for a sidebar that is docked. `alsoOn` is another place the pointer may rest, the toggle that opened it.
    static func endsSidebarPeek(
        isPeeking: Bool,
        isSidebarVisible: Bool,
        isResizing: Bool,
        isProfileSwitcherOpen: Bool,
        pointer: CGPoint?,
        frame: CGRect,
        alsoOn: CGRect = .null
    ) -> Bool {
        guard isPeeking, !isSidebarVisible, !isResizing, !isProfileSwitcherOpen else { return false }
        if let pointer, alsoOn.contains(pointer) {
            return false
        }
        return hasLeft(pointer: pointer, frame: frame, trailingReach: resizeReach)
    }

    /// Where the sidebar toggle sits, window points. Pointing at it also opens the peek, deliberately, since it is a
    /// button; an icons-only peek is narrower than the 84 pt the traffic lights take, so the toggle is outside it and has
    /// to count as part of the peek, or the peek would end under the pointer that opened it.
    static func toggleReach(windowControlsInset: CGFloat, titleStrip: CGFloat) -> CGRect {
        CGRect(
            x: SidebarMetrics.permanentToggleLeading(windowControlsInset: windowControlsInset),
            y: titleStrip,
            width: SidebarMetrics.permanentToggleSlot,
            height: Theme.topBarHeight
        )
    }

    /// The Minimal tab list's peek ends once the pointer is off the list. A list that is kept open is not a peek: it
    /// stays wherever the pointer is.
    static func endsTabListPeek(
        isPeeking: Bool,
        isPinned: Bool,
        isProfileSwitcherOpen: Bool,
        pointer: CGPoint?,
        frame: CGRect
    ) -> Bool {
        guard isPeeking, !isPinned, !isProfileSwitcherOpen else { return false }
        return hasLeft(pointer: pointer, frame: frame)
    }
}

/// Watches the pointer while something is peeking, because a hover callback is not enough: it does not fire when the
/// pointer leaves the window, when another app comes forward under it, or after a menu that was open over the peek.
@MainActor
final class PeekWatch {
    private let center: NotificationCenter
    private var monitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// `check` runs on every pointer move, in this app or another, and when the window stops being key. Switching to
    /// another app runs `onSwitchAway` instead when there is one: the peek ends there whatever the pointer is over.
    func start(
        window: NSWindow?,
        check: @escaping @MainActor () -> Void,
        onSwitchAway: (@MainActor () -> Void)? = nil
    ) {
        stop()
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            check()
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in
            check()
        }) {
            monitors.append(global)
        }
        observe(NSApplication.didResignActiveNotification, object: nil, check: onSwitchAway ?? check)
        if let window {
            observe(NSWindow.didResignKeyNotification, object: window, check: check)
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject?, check: @escaping @MainActor () -> Void) {
        observers.append(center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { check() }
        })
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(center.removeObserver)
        observers = []
    }
}

extension AppCoordinator {
    /// The pointer in the shell's space: window points from the top-left of the content view, which is what SwiftUI's
    /// `.global` frames are measured in. Nil while there is no window. It is current even when no event is being handled.
    var pointerInShell: CGPoint? {
        guard let window = nativeWindow, let content = window.contentView else { return nil }
        return PeekEdge.shellPoint(
            fromWindow: window.mouseLocationOutsideOfEventStream,
            contentHeight: content.bounds.height
        )
    }
}
