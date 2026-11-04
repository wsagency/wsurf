// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

extension View {
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        onMiddleClick(on: { _ in true }) { _ in action() }
    }

    /// One catcher for many targets, such as the rows of a list: `target` names what is at a point of this view (origin top
    /// left), or nil where there is nothing to click. A click goes to what was under both the press and the release.
    func onMiddleClick<Target: Hashable>(
        on target: @escaping (CGPoint) -> Target?,
        perform action: @escaping (Target) -> Void
    ) -> some View {
        overlay(MiddleClickCatcher(
            target: { target($0).map(AnyHashable.init) },
            action: { if let hit = $0.base as? Target { action(hit) } }
        ))
    }
}

private struct MiddleClickCatcher: NSViewRepresentable {
    let target: (CGPoint) -> AnyHashable?
    let action: (AnyHashable) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.target = target
        nsView.action = action
    }

    final class CatcherView: NSView {
        var target: ((CGPoint) -> AnyHashable?)?
        var action: ((AnyHashable) -> Void)?
        private var pressed: AnyHashable?

        override var isFlipped: Bool {
            true
        }

        override var mouseDownCanMoveWindow: Bool {
            false
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil,
                  let event = window?.currentEvent ?? NSApp.currentEvent,
                  event.buttonNumber == 2
            else { return nil }
            switch event.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return target?(convert(point, from: superview)) == nil ? nil : self
            default:
                return nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = event.buttonNumber == 2 ? target?(convert(event.locationInWindow, from: nil)) : nil
        }

        override func otherMouseUp(with event: NSEvent) {
            defer { pressed = nil }
            let point = convert(event.locationInWindow, from: nil)
            guard event.buttonNumber == 2, let pressed, bounds.contains(point), target?(point) == pressed else { return }
            action?(pressed)
        }
    }
}
