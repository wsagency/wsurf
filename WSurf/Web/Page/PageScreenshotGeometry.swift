// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CoreGraphics
import Foundation

/// Why a screenshot request produced no image. Each case maps to a distinct MCP error text.
nonisolated enum ScreenshotFailure: Error, Equatable {
    case stale, privacy, invalidGeometry, offscreen, captureFailed, unmappableFrame, needsDevelopment

    var message: String {
        switch self {
        case .stale: "The page or element changed before capture. Use readPage again."
        case .privacy: "Screenshot refused: a filled sensitive field is on the page. Use readPage for redacted text."
        case .invalidGeometry: "The element or region has no usable area."
        case .offscreen: "The element or region is outside the visible viewport. Scroll it into view first."
        case .captureFailed: "Screenshot unavailable; use readPage for redacted text."
        case .unmappableFrame:
            "The element or region sits where its position on the page cannot be measured exactly (a selected frame, or a rotated, flipped or skewed frame or clipping container). Screenshot the viewport instead."
        case .needsDevelopment:
            "Screenshots of elements found with findElements need development access. Use a control ref from readPage, or a viewport or region screenshot."
        }
    }
}

/// What to capture. Element and region are mutually exclusive by construction.
nonisolated enum ScreenshotTarget: Equatable, Sendable {
    case viewport
    case element(ref: Int)
    /// CSS pixels, relative to the viewport's top-left corner.
    case region(CGRect)
}

/// A captured image and the CSS-pixel rectangle it shows. `scale` is bitmap pixels per CSS pixel.
nonisolated struct ScreenshotCapture: Sendable {
    let jpeg: Data
    let bounds: CGRect
    let scale: CGFloat
}

/// One iframe on the path from an element's document up to the top document, as the page measured it.
nonisolated struct ScreenshotFrameBox: Equatable, Sendable {
    /// Border box in the parent document's viewport coordinates (`getBoundingClientRect`, so scale and translation apply).
    let border: CGRect
    /// The same border box in untransformed layout pixels (`offsetWidth/Height`).
    let layout: CGSize
    /// Where the frame's document renders: the content box in layout pixels, relative to the border box's origin.
    let content: CGRect
    /// False when the frame or one of its ancestors is rotated, flipped or skewed, which a rectangle cannot carry.
    let axisAligned: Bool
    /// Padding boxes, in the parent document's viewport coordinates, of the frame's overflow-clipping ancestors there.
    var clips: [CGRect] = []
}

nonisolated enum ScreenshotGeometry {
    /// Subpixel slack for layout rounding of rects measured by the page.
    private static let tolerance: CGFloat = 0.5

    private static func valid(_ rect: CGRect, _ viewport: CGSize) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, viewport.width, viewport.height].allSatisfy(\.isFinite)
            && rect.size.width > 0 && rect.size.height > 0 && viewport.width > 0 && viewport.height > 0
    }

    /// A client-supplied region (CSS px, viewport-relative) must lie fully inside the viewport: a region that is not is
    /// `offscreen`, never cropped into a smaller image the client did not ask for.
    static func region(_ rect: CGRect, inViewportCSS viewport: CGSize) -> Result<CGRect, ScreenshotFailure> {
        guard valid(rect, viewport) else { return .failure(.invalidGeometry) }
        let bounds = CGRect(origin: .zero, size: viewport)
        return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(rect) ? .success(rect.intersection(bounds)) : .failure(.offscreen)
    }

    /// An element's box (CSS px, viewport-relative) reduced to its visible part. The result is the capture's reported
    /// `bounds`; an element with no visible part is `offscreen`. Never scrolls or stitches.
    static func visibleBounds(ofElement rect: CGRect, inViewportCSS viewport: CGSize) -> Result<CGRect, ScreenshotFailure> {
        guard valid(rect, viewport) else { return .failure(.invalidGeometry) }
        let visible = rect.intersection(CGRect(origin: .zero, size: viewport))
        return visible.isNull || visible.isEmpty ? .failure(.offscreen) : .success(visible)
    }

    /// The part of `rect` inside every box of `boxes`; `offscreen` when nothing is left, `invalidGeometry` for a rect or
    /// box that is not a finite, positive area.
    private static func shown(_ rect: CGRect, within boxes: [CGRect]) -> Result<CGRect, ScreenshotFailure> {
        // A clipping container may be empty (it then shows nothing), but never negative or non-finite.
        let usable = boxes.allSatisfy { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height].allSatisfy(\.isFinite) && $0.size.width >= 0 && $0.size.height >= 0 }
        guard valid(rect, CGSize(width: 1, height: 1)), usable else { return .failure(.invalidGeometry) }
        let visible = boxes.reduce(rect) { $0.intersection($1) }
        return visible.isNull || visible.isEmpty ? .failure(.offscreen) : .success(visible)
    }

    /// Carries a rect measured in an element's own document out to the top document's viewport. `clips` are the boxes of
    /// the element's overflow-clipping ancestors in its document; `frames` run innermost first, each with the clips of its
    /// own ancestors in its parent. At every level the rect is first cut to what is actually shown (those clips and the
    /// frame's content box, so neighbouring pixels never pass for the element), then moved through the frame's border,
    /// padding and scale. A frame whose geometry cannot be mapped exactly is refused, never approximated.
    static func translate(
        _ rect: CGRect, clippedBy clips: [CGRect] = [], through frames: [ScreenshotFrameBox]
    ) -> Result<CGRect, ScreenshotFailure> {
        var rect = rect, levelClips = clips
        for frame in frames {
            guard frame.axisAligned else { return .failure(.unmappableFrame) }
            guard valid(frame.border, frame.layout), valid(frame.content, frame.layout) else { return .failure(.invalidGeometry) }
            switch shown(rect, within: levelClips + [CGRect(origin: .zero, size: frame.content.size)]) {
            case .failure(let failure): return .failure(failure)
            case .success(let visible):
                let scaleX = frame.border.width / frame.layout.width, scaleY = frame.border.height / frame.layout.height
                rect = CGRect(
                    x: frame.border.minX + scaleX * (frame.content.minX + visible.minX),
                    y: frame.border.minY + scaleY * (frame.content.minY + visible.minY),
                    width: scaleX * visible.width, height: scaleY * visible.height)
                levelClips = frame.clips
            }
        }
        return shown(rect, within: levelClips)
    }
}
