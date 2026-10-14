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
}
