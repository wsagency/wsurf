// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CoreGraphics

/// Why a screenshot request produced no image. Each case maps to a distinct MCP error text.
nonisolated enum ScreenshotFailure: Error, Equatable {
    case stale, privacy, invalidGeometry, offscreen, captureFailed
}

nonisolated enum ScreenshotGeometry {
    /// Validates a CSS-pixel crop target and clips it to the visible viewport. Never scrolls or stitches: a target that
    /// does not intersect the viewport is `offscreen`, and a partly visible one is cropped to the visible part.
    static func clip(_ rect: CGRect, toViewport viewport: CGSize) -> Result<CGRect, ScreenshotFailure> {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, viewport.width, viewport.height]
        guard values.allSatisfy(\.isFinite), rect.size.width > 0, rect.size.height > 0, viewport.width > 0, viewport.height > 0 else {
            return .failure(.invalidGeometry)
        }
        let visible = rect.intersection(CGRect(origin: .zero, size: viewport))
        return visible.isNull || visible.isEmpty ? .failure(.offscreen) : .success(visible)
    }
}
