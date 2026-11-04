// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// What the micro window feels without drawing anything: whether the pointer is at the top of the window, and the traffic
/// lights, which show only with the bar. `MinimalShellSensor` is not reused: it tracks only the key window, so a floating
/// micro window would not answer the pointer while another app is in front, it reports no exits, and it carries scroll
/// and click monitors this window does not need.
struct MicroRevealSensor: NSViewRepresentable {
    /// How far down from the top edge the pointer counts as "at the top".
    let zoneHeight: CGFloat
    let showsWindowControls: Bool
    let onPointerInZone: (Bool) -> Void

    func makeNSView(context: Context) -> SensorView {
        SensorView()
    }

    func updateNSView(_ view: SensorView, context: Context) {
        view.onPointerInZone = onPointerInZone
        view.zoneHeight = zoneHeight
        view.showsWindowControls = showsWindowControls
    }

    static func dismantleNSView(_ view: SensorView, coordinator: ()) {
        view.stop()
    }

    final class SensorView: NSView {
        var onPointerInZone: ((Bool) -> Void)?
        var zoneHeight: CGFloat = MicroShell.revealBand {
            didSet {
                if zoneHeight != oldValue {
                    updateTrackingAreas()
                }
            }
        }
        var showsWindowControls = false {
            didSet {
                if showsWindowControls != oldValue {
                    applyWindowControls()
                }
            }
        }

        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowControls()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                stop()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        /// Gives the window its traffic lights back; called while the view is leaving the window.
        func stop() {
            for kind in Self.buttons {
                window?.standardWindowButton(kind)?.isHidden = false
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area {
                removeTrackingArea(area)
            }
            let zone = NSRect(x: 0, y: bounds.maxY - zoneHeight, width: bounds.width, height: zoneHeight)
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
            // A zone rebuilt under a pointer that is already in it never sees an enter, so it has to be told to expect the exit.
            if let window, zone.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                options.insert(.assumeInside)
            }
            let rebuilt = NSTrackingArea(rect: zone, options: options, owner: self, userInfo: nil)
            addTrackingArea(rebuilt)
            area = rebuilt
        }

        override func mouseEntered(with event: NSEvent) {
            onPointerInZone?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onPointerInZone?(false)
        }

        private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        private func applyWindowControls() {
            guard let window else { return }
            for kind in Self.buttons {
                window.standardWindowButton(kind)?.isHidden = !showsWindowControls
            }
        }
    }
}
