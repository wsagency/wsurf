// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

extension ChromiumPage {
    /// Presses the left button at the first point of `path`, moves through the rest and releases at the last, as trusted
    /// pointer input delivered through DevTools. It reaches the renderer directly, so it needs neither the app to be active
    /// nor the window to be key. `path` is in CSS pixels of the main frame's viewport. `allowed` is asked in the same turn
    /// that each event is sent; once the button is down a release is always sent, whatever the answer.
    func dragPointer(path: [CGPoint], allowed: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard let first = path.first, let last = path.last, path.count >= 2 else { throw ChromiumError.unavailable("A drag needs two points.") }
        try await ensureReady()
        let guarded: @MainActor @Sendable () throws -> Void = {
            guard allowed() else {
                throw ChromiumError.staleFrame
            }
        }
        func send(_ type: String, _ point: CGPoint, button: String, buttons: Int, checked: Bool = true) async throws {
            let params: [String: Any] = [
                "type": type, "x": Double(point.x), "y": Double(point.y), "button": button, "buttons": buttons,
                "clickCount": type == "mouseMoved" ? 0 : 1,
            ]
            if checked {
                _ = try await devTools.command("Input.dispatchMouseEvent", params: params, dispatchCheck: guarded)
            } else {
                _ = try await devTools.command("Input.dispatchMouseEvent", params: params)
            }
        }
        try await send("mouseMoved", first, button: "none", buttons: 0)
        try await send("mousePressed", first, button: "left", buttons: 1)
        do {
            for point in path.dropFirst() {
                try await send("mouseMoved", point, button: "left", buttons: 1)
            }
        } catch {
            try? await send("mouseReleased", last, button: "left", buttons: 0, checked: false)
            throw error
        }
        try await send("mouseReleased", last, button: "left", buttons: 0, checked: false)
    }
}
