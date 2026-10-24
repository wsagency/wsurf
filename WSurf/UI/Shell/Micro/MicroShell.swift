// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// How a micro window is sized, placed and stacked. The numbers are tuning knobs.
nonisolated enum MicroWindowMetrics {
    static let minSize = NSSize(width: 420, height: 240)
    static let defaultSize = NSSize(width: 560, height: 420)
    /// Each new window opens this far right of and below the last one, and this far from the corner of the screen.
    static let cascade: CGFloat = 24
    /// Where the last micro window was, as `NSStringFromRect`, so the next one opens beside it.
    static let lastFrameKey = "wsurf.browser.micro.lastFrame"

    /// A micro window never enters full screen (the green button zooms). While it floats it also joins every desktop and
    /// stays over full-screen apps, like a picture-in-picture window.
    static func collectionBehavior(floating: Bool) -> NSWindow.CollectionBehavior {
        floating ? [.fullScreenAuxiliary, .canJoinAllSpaces] : [.fullScreenNone]
    }

    /// Where a new micro window opens inside `visible`: below and right of `last` by `cascade`, else in the top right corner.
    /// Always fits `visible`.
    static func openingFrame(visible: NSRect, last: NSRect?) -> NSRect {
        let size = NSSize(
            width: min(last?.width ?? defaultSize.width, visible.width),
            height: min(last?.height ?? defaultSize.height, visible.height)
        )
        var origin = NSPoint(x: visible.maxX - size.width - cascade, y: visible.maxY - size.height - cascade)
        if let last {
            origin = NSPoint(x: last.minX + cascade, y: last.maxY - size.height - cascade)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}
