// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// What the Minimal window feels without drawing anything: the page scrolling (to slide the bar away and back), the
/// pointer at the bar's edge (to bring it back while the pointer stays there), clicks (to close the tab list), and it keeps
/// the traffic lights hidden unless the tab list is open or the window is in full screen.
struct MinimalShellSensor: NSViewRepresentable {
    let onScroll: (Bool) -> Void
    /// The edge the bar floats at, and how far in from it the pointer counts as being there.
    var edge: MinimalBarEdge = .bottom
    var zoneHeight: CGFloat = MicroShell.revealBand
    var onPointerInZone: (Bool) -> Void = { _ in }
    let onPointerDown: (CGPoint) -> Void
    var pinsWindowControls = false

    func makeNSView(context: Context) -> SensorView {
        SensorView()
    }

    func updateNSView(_ view: SensorView, context: Context) {
        view.onScroll = onScroll
        view.onPointerInZone = onPointerInZone
        view.onPointerDown = onPointerDown
        view.zone = (edge, zoneHeight)
        view.pinsWindowControls = pinsWindowControls
    }

    static func dismantleNSView(_ view: SensorView, coordinator: ()) {
        view.stop()
    }

    /// Scrolling has to travel `threshold` points one way before it counts, so a trackpad's jitter moves nothing.
    nonisolated struct ScrollTravel {
        static let threshold: CGFloat = 14

        private var distance: CGFloat = 0

        /// `true` toward the top of the page, `false` toward the bottom, `nil` while it has not travelled far enough.
        mutating func add(_ deltaY: CGFloat, beginsGesture: Bool) -> Bool? {
            if beginsGesture || (distance < 0) != (deltaY < 0) {
                distance = 0
            }
            distance += deltaY
            guard abs(distance) > Self.threshold else { return nil }
            defer { distance = 0 }
            return distance > 0
        }
    }

    final class SensorView: NSView {
        var onScroll: ((Bool) -> Void)?
        var onPointerInZone: ((Bool) -> Void)?
        var onPointerDown: ((CGPoint) -> Void)?
        var zone: (edge: MinimalBarEdge, height: CGFloat) = (.bottom, MicroShell.revealBand) {
            didSet {
                if zone != oldValue {
                    updateTrackingAreas()
                }
            }
        }
        var pinsWindowControls = false {
            didSet {
                if pinsWindowControls != oldValue {
                    setWindowControlsHidden(!pinsWindowControls)
                }
            }
        }

        private var monitor: Any?
        private var fullScreenObservers: [any NSObjectProtocol] = []
        private var travel = ScrollTravel()
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                stop()
                return
            }
            setWindowControlsHidden(true)
            if fullScreenObservers.isEmpty {
                // Full screen shows the traffic lights in its own title bar; leaving it hides them again.
                fullScreenObservers = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map {
                    NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.setWindowControlsHidden(true) }
                    }
                }
            }
            guard monitor == nil else { return }
            let watched: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: watched) { [weak self] event in
                self?.note(event)
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                stop()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        /// Gives the window its traffic lights back and stops listening; called when the Minimal window style ends.
        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            for observer in fullScreenObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            fullScreenObservers = []
            setWindowControlsHidden(false)
        }

        /// One zone at the bar's edge, as the micro window's: thin while the bar is away, as deep as the bar while it shows,
        /// so the pointer can move onto the bar without it leaving. It reports leaving too, so the bar goes again.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area {
                removeTrackingArea(area)
            }
            let rect = Self.zoneRect(edge: zone.edge, height: zone.height, in: bounds)
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
            // A zone rebuilt under a pointer that is already in it never sees an enter, so it has to be told to expect the exit.
            if let window, rect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                options.insert(.assumeInside)
            }
            let rebuilt = NSTrackingArea(rect: rect, options: options, owner: self, userInfo: nil)
            addTrackingArea(rebuilt)
            area = rebuilt
        }

        static func zoneRect(edge: MinimalBarEdge, height: CGFloat, in bounds: NSRect) -> NSRect {
            let height = min(max(height, 0), bounds.height)
            return NSRect(x: 0, y: edge == .top ? bounds.maxY - height : bounds.minY, width: bounds.width, height: height)
        }

        override func mouseEntered(with event: NSEvent) {
            onPointerInZone?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onPointerInZone?(false)
        }

        private func note(_ event: NSEvent) {
            guard event.window === window else { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                onPointerDown?(event.locationInWindow)
            }
            if event.type == .scrollWheel {
                noteScroll(event)
            }
        }

        private func noteScroll(_ event: NSEvent) {
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
            // ponytail: a text view as first responder means the address (or another chrome field) is being edited, so its
            // results scroll, not the page. A page's own fields live inside the web view, which is not a text view.
            guard !(window?.firstResponder is NSTextView) else { return }
            if let towardTop = travel.add(event.scrollingDeltaY, beginsGesture: event.phase == .began) {
                onScroll?(towardTop)
            }
        }

        private func setWindowControlsHidden(_ hidden: Bool) {
            guard let window else { return }
            let hides = hidden && !pinsWindowControls && !window.styleMask.contains(.fullScreen)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = hides
            }
        }
    }
}
