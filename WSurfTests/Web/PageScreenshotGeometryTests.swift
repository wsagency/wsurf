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

    private func frame(
        border: CGRect, layout: CGSize? = nil, content: CGRect, axisAligned: Bool = true
    ) -> ScreenshotFrameBox {
        ScreenshotFrameBox(border: border, layout: layout ?? border.size, content: content, axisAligned: axisAligned)
    }

    @Test func anElementInAFrameIsMovedThroughItsBorderAndPadding() {
        // 1 px border and 10 px padding: the document starts 11 px inside the border box.
        let box = frame(border: CGRect(x: 100, y: 50, width: 320, height: 240), content: CGRect(x: 11, y: 11, width: 298, height: 218))
        #expect(ScreenshotGeometry.translate(CGRect(x: 5, y: 5, width: 50, height: 20), through: [box]) == .success(CGRect(x: 116, y: 66, width: 50, height: 20)))
    }

    @Test func aScaledFrameScalesTheRect() {
        let box = frame(border: CGRect(x: 0, y: 0, width: 160, height: 120), layout: CGSize(width: 320, height: 240), content: CGRect(x: 0, y: 0, width: 320, height: 240))
        #expect(ScreenshotGeometry.translate(CGRect(x: 100, y: 60, width: 40, height: 20), through: [box]) == .success(CGRect(x: 50, y: 30, width: 20, height: 10)))
    }

    @Test func onlyThePartTheFrameShowsIsKept() {
        let box = frame(border: CGRect(x: 10, y: 10, width: 200, height: 100), content: CGRect(x: 0, y: 0, width: 200, height: 100))
        // The part past the frame's edge would be the page's neighbouring pixels, so it is cut, not reported.
        #expect(ScreenshotGeometry.translate(CGRect(x: 150, y: 80, width: 100, height: 100), through: [box]) == .success(CGRect(x: 160, y: 90, width: 50, height: 20)))
        #expect(ScreenshotGeometry.translate(CGRect(x: 210, y: 0, width: 10, height: 10), through: [box]) == .failure(.offscreen))
        #expect(ScreenshotGeometry.translate(CGRect(x: -30, y: 0, width: 10, height: 10), through: [box]) == .failure(.offscreen))
    }

    @Test func nestedFramesComposeInnermostFirst() {
        let inner = frame(border: CGRect(x: 20, y: 30, width: 200, height: 100), content: CGRect(x: 0, y: 0, width: 200, height: 100))
        let outer = frame(border: CGRect(x: 100, y: 100, width: 400, height: 300), content: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(ScreenshotGeometry.translate(CGRect(x: 10, y: 10, width: 50, height: 20), through: [inner, outer]) == .success(CGRect(x: 130, y: 140, width: 50, height: 20)))
    }

    @Test func noFramesLeavesTheRectUnchanged() {
        let rect = CGRect(x: 3, y: 4, width: 5, height: 6)
        #expect(ScreenshotGeometry.translate(rect, through: []) == .success(rect))
    }

    @Test func aFrameThatCannotBeMappedExactlyIsRefused() {
        let rect = CGRect(x: 5, y: 5, width: 10, height: 10)
        let content = CGRect(x: 0, y: 0, width: 200, height: 100)
        let border = CGRect(x: 10, y: 10, width: 200, height: 100)
        #expect(ScreenshotGeometry.translate(rect, through: [frame(border: border, content: content, axisAligned: false)]) == .failure(.unmappableFrame))
        // An unmeasurable layout size would make the scale meaningless.
        #expect(ScreenshotGeometry.translate(rect, through: [frame(border: border, layout: .zero, content: content)]) == .failure(.invalidGeometry))
        #expect(ScreenshotGeometry.translate(rect, through: [frame(border: CGRect(x: CGFloat.nan, y: 0, width: 200, height: 100), content: content)]) == .failure(.invalidGeometry))
    }

    @Test func anOverflowClippedElementKeepsOnlyWhatItsContainerShows() {
        let container = [CGRect(x: 0, y: 0, width: 100, height: 40)]
        #expect(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 100, height: 100), clippedBy: container, through: []) == .success(CGRect(x: 0, y: 0, width: 100, height: 40)))
        #expect(ScreenshotGeometry.translate(CGRect(x: 0, y: 50, width: 10, height: 10), clippedBy: container, through: []) == .failure(.offscreen))
        #expect(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 10, height: 10), clippedBy: [CGRect(x: 0, y: 0, width: 100, height: 0)], through: []) == .failure(.offscreen))
        #expect(ScreenshotGeometry.translate(CGRect(x: 0, y: 0, width: 10, height: 10), clippedBy: [CGRect(x: 0, y: 0, width: -5, height: 10)], through: []) == .failure(.invalidGeometry))
    }

    @Test func aClipAroundTheFrameCutsTheMappedRect() {
        // The frame's own container, in the parent document, shows only the left 150 px.
        let box = ScreenshotFrameBox(
            border: CGRect(x: 100, y: 100, width: 400, height: 300), layout: CGSize(width: 400, height: 300),
            content: CGRect(x: 0, y: 0, width: 400, height: 300), axisAligned: true, clips: [CGRect(x: 0, y: 0, width: 150, height: 300)])
        #expect(ScreenshotGeometry.translate(CGRect(x: 10, y: 10, width: 200, height: 20), through: [box]) == .success(CGRect(x: 110, y: 110, width: 40, height: 20)))
        #expect(ScreenshotGeometry.translate(CGRect(x: 100, y: 10, width: 200, height: 20), through: [box]) == .failure(.offscreen))
    }

    @Test func aPaddedScaledAndClippedFrameComposes() {
        // 1 px border + 9 px padding, drawn at half size; the document is 400 x 300 and the element runs 40 px past its edge.
        let box = frame(border: CGRect(x: 10, y: 20, width: 210, height: 160), layout: CGSize(width: 420, height: 320), content: CGRect(x: 10, y: 10, width: 400, height: 300))
        #expect(ScreenshotGeometry.translate(CGRect(x: 390, y: 290, width: 50, height: 50), through: [box]) == .success(CGRect(x: 210, y: 170, width: 5, height: 5)))
    }
}
