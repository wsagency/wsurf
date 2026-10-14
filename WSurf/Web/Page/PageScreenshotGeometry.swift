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
            "The element or region sits where its position on the page cannot be measured exactly (a selected frame, a frame or clipping container under a 3D transform or perspective, or SVG content). Screenshot the viewport instead."
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
    /// The element was registered only by `findElements`: the image may be returned only while development access still holds,
    /// which the caller asks once more after any further await.
    let requiresDevelopment: Bool
}

/// One box the page measured in a document: where its border box lands in that document's viewport and which 2D linear
/// map (rotation, reflection, skew, scale: the composed transforms of the box and its ancestors in that document) its
/// layout pixels went through. The translation is not measured but derived: a bounding box of a transformed rectangle is
/// centred on the image of the rectangle's centre, so `border`'s centre fixes it exactly.
nonisolated struct ScreenshotPlacement: Equatable, Sendable {
    /// Bounding box of the transformed border box in the document's viewport (`getBoundingClientRect`).
    let border: CGRect
    /// The border box in untransformed layout pixels (`offsetWidth/Height`).
    let layout: CGSize
    /// Composed linear part of the transforms, as `CGAffineTransform` (a, b, c, d; no translation).
    let linear: CGAffineTransform
    /// The region of interest in layout pixels, relative to the border box's origin (a frame's content box, or the padding
    /// box of an overflow-clipping container).
    let local: CGRect
}

/// One iframe on the path from an element's document up to the top document, as the page measured it.
nonisolated struct ScreenshotFrameBox: Equatable, Sendable {
    /// The frame's border box; `local` is where its document renders (the content box, border and padding excluded).
    let placement: ScreenshotPlacement
    /// The frame's overflow-clipping ancestors in the parent document (`local` is each one's padding box).
    var clips: [ScreenshotPlacement] = []
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

    private typealias Polygon = [CGPoint]

    private static func finite(_ points: Polygon) -> Bool { points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }

    private static func corners(_ rect: CGRect) -> Polygon {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func area(_ polygon: Polygon) -> CGFloat {
        var sum: CGFloat = 0
        for (i, p) in polygon.enumerated() {
            let q = polygon[(i + 1) % polygon.count]
            sum += p.x * q.y - q.x * p.y
        }
        return sum / 2
    }

    /// Below this a polygon shows nothing (CSS px squared).
    private static let minimumArea: CGFloat = 1e-6

    /// Layout pixels of a box to its document's viewport: the measured linear map, and the translation that puts the
    /// centre of the layout border box on the centre of the measured bounding box.
    private static func matrix(_ box: ScreenshotPlacement) -> CGAffineTransform {
        var m = box.linear
        let centre = CGPoint(x: box.layout.width / 2, y: box.layout.height / 2)
        m.tx = box.border.midX - (m.a * centre.x + m.c * centre.y)
        m.ty = box.border.midY - (m.b * centre.x + m.d * centre.y)
        return m
    }

    /// False when a measured number is not finite or a size is negative: such a box cannot be mapped.
    private static func usable(_ box: ScreenshotPlacement) -> Bool {
        let numbers = [box.border.origin.x, box.border.origin.y, box.border.width, box.border.height, box.layout.width, box.layout.height,
            box.linear.a, box.linear.b, box.linear.c, box.linear.d, box.local.origin.x, box.local.origin.y, box.local.width, box.local.height]
        return numbers.allSatisfy(\.isFinite) && box.layout.width >= 0 && box.layout.height >= 0
    }

    /// The box's `local` region in its document's viewport, as a convex polygon (any rotation, reflection or skew).
    private static func polygon(of box: ScreenshotPlacement) -> Polygon? {
        guard usable(box) else { return nil }
        let m = matrix(box)
        let points = corners(box.local).map { $0.applying(m) }
        return finite(points) ? points : nil
    }

    /// Sutherland-Hodgman against a convex `clip`; empty when nothing of `subject` is inside.
    private static func cut(_ subject: Polygon, to clip: Polygon) -> Polygon {
        let clipArea = area(clip)
        guard abs(clipArea) > minimumArea else { return [] }
        let orientation: CGFloat = clipArea > 0 ? 1 : -1
        var result = subject
        for i in clip.indices where !result.isEmpty {
            let a = clip[i], b = clip[(i + 1) % clip.count]
            func side(_ p: CGPoint) -> CGFloat { orientation * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) }
            let input = result
            result = []
            var previous = input[input.count - 1]
            for current in input {
                let now = side(current), before = side(previous)
                func crossing() -> CGPoint {
                    let t = before / (before - now)
                    return CGPoint(x: previous.x + t * (current.x - previous.x), y: previous.y + t * (current.y - previous.y))
                }
                if now >= 0 {
                    if before < 0 { result.append(crossing()) }
                    result.append(current)
                } else if before >= 0 {
                    result.append(crossing())
                }
                previous = current
            }
        }
        return result
    }

    /// Cuts `polygon` to every clip of one document level. `nil`: a clip was not measurable; empty: nothing is shown.
    private static func shown(_ polygon: Polygon, within clips: [ScreenshotPlacement]) -> Polygon? {
        var result = polygon
        for clip in clips {
            guard let box = Self.polygon(of: clip) else { return nil }
            result = cut(result, to: box)
            if result.count < 3 || abs(area(result)) <= minimumArea { return [] }
        }
        return result
    }

    /// Carries a rect measured in an element's own document out to the top document's viewport. `clips` are the
    /// overflow-clipping ancestors of the element in its document; `frames` run innermost first, each with the clips of its
    /// own ancestors in its parent. Every level's transform is a general 2D affine map (rotation, reflection, skew, scale),
    /// so the visible part is cut as a polygon, at each level to what is actually shown (the clips and the frame's content
    /// box, so neighbouring pixels never pass for the element), then moved through the frame's border, padding and
    /// transform once. The result is the bounding rect of that polygon in the top viewport.
    static func translate(
        _ rect: CGRect, clippedBy clips: [ScreenshotPlacement] = [], through frames: [ScreenshotFrameBox]
    ) -> Result<CGRect, ScreenshotFailure> {
        guard valid(rect, CGSize(width: 1, height: 1)) else { return .failure(.invalidGeometry) }
        var polygon = corners(rect), levelClips = clips
        for frame in frames {
            guard let visible = shown(polygon, within: levelClips) else { return .failure(.invalidGeometry) }
            guard !visible.isEmpty else { return .failure(.offscreen) }
            let box = frame.placement
            guard usable(box) else { return .failure(.invalidGeometry) }
            // The frame's document starts at the content box's origin and shows `local.size` of it.
            let shownInFrame = cut(visible, to: corners(CGRect(origin: .zero, size: box.local.size)))
            guard shownInFrame.count >= 3, abs(area(shownInFrame)) > minimumArea else { return .failure(.offscreen) }
            let inner = CGAffineTransform(translationX: box.local.minX, y: box.local.minY).concatenating(matrix(box))
            polygon = shownInFrame.map { $0.applying(inner) }
            guard finite(polygon) else { return .failure(.invalidGeometry) }
            levelClips = frame.clips
        }
        guard let visible = shown(polygon, within: levelClips) else { return .failure(.invalidGeometry) }
        guard visible.count >= 3, abs(area(visible)) > minimumArea else { return .failure(.offscreen) }
        let xs = visible.map(\.x), ys = visible.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return .success(bounds)
    }

    private static func number(_ object: [String: Any]?, _ key: String) -> CGFloat? {
        (object?[key] as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private static func rect(_ object: Any?) -> CGRect? {
        let box = object as? [String: Any]
        guard let x = number(box, "x"), let y = number(box, "y"), let w = number(box, "width"), let h = number(box, "height") else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func placement(_ object: Any?) -> ScreenshotPlacement? {
        guard let box = object as? [String: Any], let border = rect(box["border"]), let layout = rect(box["layout"]), let local = rect(box["local"]),
            let l = box["linear"] as? [NSNumber], l.count == 4
        else { return nil }
        let m = l.map { CGFloat($0.doubleValue) }
        return ScreenshotPlacement(border: border, layout: layout.size, linear: CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: 0, ty: 0), local: local)
    }

    /// The element's rect in the top viewport from what `R.screenshotGeometry` measured: an element inside same-origin
    /// iframes is measured in its own frame's viewport and carried out through every frame on its path.
    static func topViewportRect(measured probe: [String: Any]) -> Result<CGRect, ScreenshotFailure> {
        guard probe["unmappable"] as? Bool != true else { return .failure(.unmappableFrame) }
        func placements(_ list: Any?) -> [ScreenshotPlacement]? {
            let boxes = (list as? [Any] ?? []).map(placement)
            return boxes.contains { $0 == nil } ? nil : boxes.compactMap { $0 }
        }
        guard let own = rect(probe["rect"]), let clips = placements(probe["clips"]) else { return .failure(.stale) }
        var frames: [ScreenshotFrameBox] = []
        for entry in probe["frames"] as? [[String: Any]] ?? [] {
            guard let box = placement(entry), let frameClips = placements(entry["clips"]) else { return .failure(.stale) }
            frames.append(ScreenshotFrameBox(placement: box, clips: frameClips))
        }
        return translate(own, clippedBy: clips, through: frames)
    }
}
