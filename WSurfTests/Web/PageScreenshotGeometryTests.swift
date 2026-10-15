// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CoreGraphics
import Testing

@testable import WSurf

struct PageScreenshotGeometryTests {
    private let viewport = CGSize(width: 800, height: 600)

    private func region(_ rect: CGRect) -> Result<CGRect, ScreenshotFailure> {
        ScreenshotGeometry.region(rect, inViewportCSS: viewport)
    }

    private func element(_ rect: CGRect) -> Result<CGRect, ScreenshotFailure> {
        ScreenshotGeometry.visibleBounds(ofElement: rect, inViewportCSS: viewport)
    }

    @Test func aRegionFullyInsideIsUnchangedAndMayTouchTheEdges() {
        #expect(region(CGRect(x: 10, y: 20, width: 100, height: 50)) == .success(CGRect(x: 10, y: 20, width: 100, height: 50)))
        #expect(region(CGRect(origin: .zero, size: viewport)) == .success(CGRect(origin: .zero, size: viewport)))
    }

    @Test(arguments: [
        CGRect(x: 700, y: -40, width: 300, height: 100),  // straddles two edges
        CGRect(x: 790, y: 0, width: 20, height: 10),  // straddles the right edge
        CGRect(x: -5_000, y: -5_000, width: 50_000, height: 50_000),  // covers the viewport
        CGRect(x: 800, y: 0, width: 10, height: 10),
        CGRect(x: 0, y: 600, width: 10, height: 10),
        CGRect(x: -100, y: -100, width: 50, height: 50),
        CGRect(x: 2_000, y: 2_000, width: 5, height: 5),
    ])
    func aRegionNotFullyInsideIsRejectedNeverCropped(rect: CGRect) {
        #expect(region(rect) == .failure(.offscreen))
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 0, height: 10),
        CGRect(x: 0, y: 0, width: 10, height: 0),
        CGRect(x: 0, y: 0, width: -10, height: 10),
        CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
        CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10),
    ])
    func zeroNegativeOrNonFiniteGeometryIsInvalid(rect: CGRect) {
        #expect(region(rect) == .failure(.invalidGeometry))
        #expect(element(rect) == .failure(.invalidGeometry))
    }

    @Test func anElementReportsOnlyItsVisiblePart() {
        #expect(element(CGRect(x: 700, y: -40, width: 300, height: 100)) == .success(CGRect(x: 700, y: 0, width: 100, height: 60)))
        #expect(element(CGRect(x: -5_000, y: -5_000, width: 50_000, height: 50_000)) == .success(CGRect(origin: .zero, size: viewport)))
    }

    @Test(arguments: [CGRect(x: 800, y: 0, width: 10, height: 10), CGRect(x: -100, y: -100, width: 50, height: 50)])
    func anElementWithNoVisiblePartIsOffscreen(rect: CGRect) {
        #expect(element(rect) == .failure(.offscreen))
    }

    @Test func anUnusableViewportIsInvalid() {
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(ScreenshotGeometry.region(box, inViewportCSS: .zero) == .failure(.invalidGeometry))
    }

    /// A measured box: `border` is its bounding box in its viewport, `layout` its untransformed size, `local` the region of
    /// interest in layout pixels from the border box's origin (the whole box unless given).
    private func place(
        border: CGRect, layout: CGSize? = nil, linear: CGAffineTransform = .identity, local: CGRect? = nil
    ) -> ScreenshotPlacement {
        let size = layout ?? border.size
        return ScreenshotPlacement(border: border, layout: size, linear: linear, local: local ?? CGRect(origin: .zero, size: size))
    }

    private func frame(
        border: CGRect, layout: CGSize? = nil, linear: CGAffineTransform = .identity, content: CGRect? = nil, clips: [ScreenshotPlacement] = []
    ) -> ScreenshotFrameBox {
        ScreenshotFrameBox(placement: place(border: border, layout: layout, linear: linear, local: content), clips: clips)
    }

    private func expectClose(_ result: Result<CGRect, ScreenshotFailure>, _ expected: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .success(let rect) = result else { Issue.record("expected \(expected), got \(result)", sourceLocation: sourceLocation); return }
        let delta = [rect.minX - expected.minX, rect.minY - expected.minY, rect.width - expected.width, rect.height - expected.height]
        #expect(delta.allSatisfy { abs($0) < 1e-6 }, "\(rect) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test func anElementInAFrameIsMovedThroughItsBorderAndPadding() {
        // 1 px border and 10 px padding: the document starts 11 px inside the border box.
        let box = frame(border: CGRect(x: 100, y: 50, width: 320, height: 240), content: CGRect(x: 11, y: 11, width: 298, height: 218))
        expectClose(ScreenshotGeometry.translate(CGRect(x: 5, y: 5, width: 50, height: 20), through: [box]), CGRect(x: 116, y: 66, width: 50, height: 20))
    }

    @Test func aScaledFrameScalesTheRect() {
        let box = frame(border: CGRect(x: 0, y: 0, width: 160, height: 120), layout: CGSize(width: 320, height: 240), linear: CGAffineTransform(scaleX: 0.5, y: 0.5))
        expectClose(ScreenshotGeometry.translate(CGRect(x: 100, y: 60, width: 40, height: 20), through: [box]), CGRect(x: 50, y: 30, width: 20, height: 10))
    }

    @Test func onlyThePartTheFrameShowsIsKept() {
        let box = frame(border: CGRect(x: 10, y: 10, width: 200, height: 100))
        // The part past the frame's edge would be the page's neighbouring pixels, so it is cut, not reported.
        expectClose(ScreenshotGeometry.translate(CGRect(x: 150, y: 80, width: 100, height: 100), through: [box]), CGRect(x: 160, y: 90, width: 50, height: 20))
        #expect(ScreenshotGeometry.translate(CGRect(x: 210, y: 0, width: 10, height: 10), through: [box]) == .failure(.offscreen))
        #expect(ScreenshotGeometry.translate(CGRect(x: -30, y: 0, width: 10, height: 10), through: [box]) == .failure(.offscreen))
    }

    @Test func nestedFramesComposeInnermostFirst() {
        let inner = frame(border: CGRect(x: 20, y: 30, width: 200, height: 100))
        let outer = frame(border: CGRect(x: 100, y: 100, width: 400, height: 300))
        expectClose(ScreenshotGeometry.translate(CGRect(x: 10, y: 10, width: 50, height: 20), through: [inner, outer]), CGRect(x: 130, y: 140, width: 50, height: 20))
    }

    @Test func noFramesLeavesTheRectUnchanged() {
        let rect = CGRect(x: 3, y: 4, width: 5, height: 6)
        #expect(ScreenshotGeometry.translate(rect, through: []) == .success(rect))
    }

    @Test func aFrameRotatedAQuarterTurnMapsTheRectAndKeepsOnlyWhatItShows() {
        // 200 x 100 frame turned 90 degrees about its centre (200, 200): a 100 x 200 box. Layout (0, 0) lands at (250, 100).
        let box = frame(border: CGRect(x: 150, y: 100, width: 100, height: 200), layout: CGSize(width: 200, height: 100), linear: CGAffineTransform(rotationAngle: .pi / 2))
        expectClose(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 50, height: 20), through: [box]), CGRect(x: 230, y: 100, width: 20, height: 50))
        // 50 px of the 100 wide element run past the frame's right edge; they are cut, not mapped onto neighbouring pixels.
        expectClose(ScreenshotGeometry.translate(CGRect(x: 150, y: 0, width: 100, height: 50), through: [box]), CGRect(x: 200, y: 250, width: 50, height: 50))
    }

    @Test func aFlippedFrameMirrorsTheRect() {
        let box = frame(border: CGRect(x: 100, y: 50, width: 200, height: 100), linear: CGAffineTransform(scaleX: -1, y: 1))
        expectClose(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 50, height: 20), through: [box]), CGRect(x: 250, y: 50, width: 50, height: 20))
    }

    @Test func aSkewedFrameMapsEveryCornerNotTheBoundingBoxWidth() {
        // x' = x + y: a 100 x 100 frame whose bounding box is 200 wide.
        let box = frame(border: CGRect(x: 0, y: 0, width: 200, height: 100), layout: CGSize(width: 100, height: 100), linear: CGAffineTransform(a: 1, b: 0, c: 1, d: 1, tx: 0, ty: 0))
        expectClose(ScreenshotGeometry.translate(CGRect(x: 0, y: 90, width: 10, height: 10), through: [box]), CGRect(x: 90, y: 90, width: 20, height: 10))
        // Right of the skewed frame's content box (x > 100 in its own pixels) is not part of the frame.
        #expect(ScreenshotGeometry.translate(CGRect(x: 100, y: 0, width: 10, height: 10), through: [box]) == .failure(.offscreen))
    }

    @Test func aRotatedFrameKeepsItsPaddingAndScale() {
        // 1 px border + 9 px padding, drawn at half size and turned 90 degrees: 420 x 320 layout becomes a 160 x 210 box.
        let box = frame(
            border: CGRect(x: 100, y: 100, width: 160, height: 210), layout: CGSize(width: 420, height: 320),
            linear: CGAffineTransform(rotationAngle: .pi / 2).scaledBy(x: 0.5, y: 0.5), content: CGRect(x: 10, y: 10, width: 400, height: 300))
        // Layout (x, y) -> (260 - y / 2, 100 + x / 2); the document's (0, 0) is layout (10, 10), so (0..20, 0..40) is layout (10..30, 10..50).
        expectClose(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 20, height: 40), through: [box]), CGRect(x: 235, y: 105, width: 20, height: 10))
    }

    @Test func anOverflowClippedElementKeepsOnlyWhatItsContainerShows() {
        let container = [place(border: CGRect(x: 0, y: 0, width: 100, height: 40))]
        expectClose(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 100, height: 100), clippedBy: container, through: []), CGRect(x: 0, y: 0, width: 100, height: 40))
        #expect(ScreenshotGeometry.translate(CGRect(x: 0, y: 50, width: 10, height: 10), clippedBy: container, through: []) == .failure(.offscreen))
        #expect(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 10, height: 10), clippedBy: [place(border: CGRect(x: 0, y: 0, width: 100, height: 0))], through: []) == .failure(.offscreen))
    }

    @Test func aRotatedClipContainerCutsTheCornersOfItsBoundingBox() {
        // A 100 x 100 container turned 45 degrees about (200, 200) shows a diamond; its bounding box is 141.42 wide.
        let side = 100 * 2.0.squareRoot()
        let diamond = place(
            border: CGRect(x: 200 - side / 2, y: 200 - side / 2, width: side, height: side), layout: CGSize(width: 100, height: 100),
            linear: CGAffineTransform(rotationAngle: .pi / 4))
        // The top-left corner of the bounding box is outside the diamond.
        #expect(ScreenshotGeometry.translate(CGRect(x: 130, y: 130, width: 10, height: 10), clippedBy: [diamond], through: []) == .failure(.offscreen))
        expectClose(ScreenshotGeometry.translate(CGRect(x: 190, y: 190, width: 20, height: 20), clippedBy: [diamond], through: []), CGRect(x: 190, y: 190, width: 20, height: 20))
        // The upper-right quarter: a triangle (200, 129.29), (270.71, 200), (200, 200).
        expectClose(
            ScreenshotGeometry.translate(CGRect(x: 200, y: 100, width: 100, height: 100), clippedBy: [diamond], through: []),
            CGRect(x: 200, y: 200 - side / 2, width: side / 2, height: side / 2))
    }

    @Test func aClipAroundTheFrameCutsTheMappedRect() {
        // The frame's own container, in the parent document, shows only the left 150 px.
        let cut = place(border: CGRect(x: 0, y: 0, width: 150, height: 300))
        let box = frame(border: CGRect(x: 100, y: 100, width: 400, height: 300), clips: [cut])
        expectClose(ScreenshotGeometry.translate(CGRect(x: 10, y: 10, width: 200, height: 20), through: [box]), CGRect(x: 110, y: 110, width: 40, height: 20))
        #expect(ScreenshotGeometry.translate(CGRect(x: 100, y: 10, width: 200, height: 20), through: [box]) == .failure(.offscreen))
    }

    @Test func aSingularOrNonFiniteFrameCannotBeMapped() {
        let rect = CGRect(x: 5, y: 5, width: 10, height: 10)
        let border = CGRect(x: 10, y: 10, width: 200, height: 100)
        #expect(ScreenshotGeometry.translate(rect, through: [frame(border: border, linear: CGAffineTransform(scaleX: 0, y: 1))]) == .failure(.offscreen))
        #expect(ScreenshotGeometry.translate(rect, through: [frame(border: CGRect(x: CGFloat.nan, y: 0, width: 200, height: 100))]) == .failure(.invalidGeometry))
        #expect(ScreenshotGeometry.translate(rect, through: [frame(border: border, linear: CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0))]) == .failure(.invalidGeometry))
    }

    @Test func measuredNumbersAreCarriedThroughEveryFrameAndAThreeDimensionalPageIsRefused() {
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Any] { ["x": x, "y": y, "width": w, "height": h] }
        let frame: [String: Any] = ["border": box(150, 100, 100, 200), "layout": box(0, 0, 200, 100), "local": box(0, 0, 200, 100), "linear": [0.0, 1.0, -1.0, 0.0], "clips": []]
        let measured: [String: Any] = ["rect": box(0, 0, 50, 20), "clips": [], "frames": [frame]]
        expectClose(ScreenshotGeometry.topViewportRect(measured: measured), CGRect(x: 230, y: 100, width: 20, height: 50))
        #expect(ScreenshotGeometry.topViewportRect(measured: measured.merging(["unmappable": true]) { $1 }) == .failure(.unmappableFrame))
        #expect(ScreenshotGeometry.topViewportRect(measured: ["clips": [], "frames": []]) == .failure(.stale))
    }
}
