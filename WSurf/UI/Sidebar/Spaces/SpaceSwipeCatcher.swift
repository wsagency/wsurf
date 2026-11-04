// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

/// Whether a finished horizontal swipe across the sidebar moves to a neighboring space: a quarter of the sidebar's
/// width, or a flick faster than 300 pt/s, as in Linen. Fingers moving left go forward.
enum SpaceSwipe {
    static func step(travel: CGFloat, velocity: CGFloat, width: CGFloat) -> Int {
        let forward = travel < 0
        let flicked = abs(velocity) > 300 && (velocity < 0) == forward && abs(travel) > 20
        guard abs(travel) > width * 0.25 || flicked else { return 0 }
        return forward ? 1 : -1
    }
}

// ponytail: a jump at the end of the swipe, no tracking glide; Linen's held-event replay comes with SP5's glide.
/// Watches two-finger swipes that start over the sidebar and reports a finished horizontal one. It only reads the
/// scroll events, so the list keeps scrolling as before.
struct SpaceSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> SpaceSwipeView {
        let view = SpaceSwipeView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ view: SpaceSwipeView, context: Context) {
        view.onSwipe = onSwipe
    }

    static func dismantleNSView(_ view: SpaceSwipeView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class SpaceSwipeView: NSView {
    var onSwipe: (Int) -> Void = { _ in }

    private var monitor: Any?
    private var tracking = false
    private var horizontal: Bool?
    private var travel = CGSize.zero
    private var recent: [(time: TimeInterval, delta: CGFloat)] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.note(event)
            return event
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func note(_ event: NSEvent) {
        guard event.window === window, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began:
            tracking = bounds.contains(convert(event.locationInWindow, from: nil))
            horizontal = nil
            travel = .zero
            recent = []
        case .changed where tracking:
            // The fingers' own direction, whether or not natural scrolling inverts the deltas.
            let fingers = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            travel.width += fingers
            travel.height += event.scrollingDeltaY
            if horizontal == nil, hypot(travel.width, travel.height) >= 4 {
                horizontal = abs(travel.width) > abs(travel.height)
            }
            recent.append((event.timestamp, fingers))
            recent = Array(recent.suffix(8))
        case .ended where tracking:
            tracking = false
            guard horizontal == true else { return }
            let step = SpaceSwipe.step(travel: travel.width, velocity: velocity, width: bounds.width)
            if step != 0 {
                onSwipe(step)
            }
        case .cancelled:
            tracking = false
        default:
            break
        }
    }

    private var velocity: CGFloat {
        guard let last = recent.last else { return 0 }
        let latest = recent.filter { last.time - $0.time <= 0.08 }
        guard let first = latest.first, last.time > first.time else { return 0 }
        return latest.dropFirst().reduce(0) { $0 + $1.delta } / CGFloat(last.time - first.time)
    }
}
