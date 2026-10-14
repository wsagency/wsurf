// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CoreGraphics
import Testing

@testable import WSurf

struct PageScreenshotGeometryTests {
    private let viewport = CGSize(width: 800, height: 600)

    private func clip(_ rect: CGRect) -> Result<CGRect, ScreenshotFailure> {
        ScreenshotGeometry.clip(rect, toViewport: viewport)
    }

    @Test func aFullyVisibleRegionIsUnchanged() {
        #expect(clip(CGRect(x: 10, y: 20, width: 100, height: 50)) == .success(CGRect(x: 10, y: 20, width: 100, height: 50)))
    }

    @Test func aPartlyVisibleRegionIsCroppedToTheViewport() {
        #expect(clip(CGRect(x: 700, y: -40, width: 300, height: 100)) == .success(CGRect(x: 700, y: 0, width: 100, height: 60)))
    }

    @Test func aRegionCoveringTheViewportIsClippedNotGrown() {
        #expect(clip(CGRect(x: -5_000, y: -5_000, width: 50_000, height: 50_000)) == .success(CGRect(origin: .zero, size: viewport)))
    }

    @Test(arguments: [
        CGRect(x: 800, y: 0, width: 10, height: 10),  // touches the right edge only
        CGRect(x: 0, y: 600, width: 10, height: 10),
        CGRect(x: -100, y: -100, width: 50, height: 50),
        CGRect(x: 2_000, y: 2_000, width: 5, height: 5),
    ])
    func aRegionOutsideTheViewportIsOffscreen(rect: CGRect) {
        #expect(clip(rect) == .failure(.offscreen))
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 0, height: 10),
        CGRect(x: 0, y: 0, width: 10, height: 0),
        CGRect(x: 0, y: 0, width: -10, height: 10),
        CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
        CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10),
    ])
    func zeroNegativeOrNonFiniteRegionsAreInvalid(rect: CGRect) {
        #expect(clip(rect) == .failure(.invalidGeometry))
    }

    @Test func anUnusableViewportIsInvalid() {
        #expect(ScreenshotGeometry.clip(CGRect(x: 0, y: 0, width: 10, height: 10), toViewport: .zero) == .failure(.invalidGeometry))
    }
}
