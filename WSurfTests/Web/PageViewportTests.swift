// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

struct PageViewportTests {
    @Test(arguments: [
        (63, 800, PageViewport.Failure.axisOutOfRange(.width, 63)),
        (64, 63, PageViewport.Failure.axisOutOfRange(.height, 63)),
        (4097, 800, PageViewport.Failure.axisOutOfRange(.width, 4097)),
        (800, 4097, PageViewport.Failure.axisOutOfRange(.height, 4097)),
        (0, 0, PageViewport.Failure.axisOutOfRange(.width, 0)),
        (-1, 800, PageViewport.Failure.axisOutOfRange(.width, -1)),
        (4096, 2049, PageViewport.Failure.areaTooLarge),
    ])
    func rejectsOutOfRange(width: Int, height: Int, failure: PageViewport.Failure) {
        #expect(PageViewport.validate(width: width, height: height, zoom: 1, scale: 1) == .failure(failure))
    }

    @Test(arguments: [(64, 64), (4096, 64), (64, 4096), (4096, 2048), (390, 844)])
    func acceptsBoundaries(width: Int, height: Int) {
        #expect(PageViewport.validate(width: width, height: height, zoom: 1, scale: 1)
            == .success(PageViewport.Request(width: width, height: height)))
    }

    @Test func backingBudgetUsesZoomAndScale() {
        // 4096×2048 CSS px is exactly 8,388,608; ×4 backing is exactly 33,554,432.
        #expect(PageViewport.validate(width: 4096, height: 2048, zoom: 1, scale: 2) != .failure(.backingTooLarge))
        #expect(PageViewport.validate(width: 4096, height: 2048, zoom: 1, scale: 2.01) == .failure(.backingTooLarge))
        #expect(PageViewport.validate(width: 4096, height: 2048, zoom: 1.25, scale: 2) == .failure(.backingTooLarge))
        // Zoom shrinks the backing area; a small viewport at high zoom stays inside the budget.
        #expect(PageViewport.validate(width: 1000, height: 1000, zoom: 0.5, scale: 2) == .success(.init(width: 1000, height: 1000)))
    }

    @Test(arguments: [0.0, -1.0, .nan, .infinity])
    func rejectsNonPositiveOrNonFiniteScale(value: Double) {
        #expect(PageViewport.validate(width: 390, height: 844, zoom: value, scale: 1) == .failure(.invalidScale))
        #expect(PageViewport.validate(width: 390, height: 844, zoom: 1, scale: value) == .failure(.invalidScale))
    }

    @Test func axisFailuresAreReportedBeforeBudgets() {
        // Both the axis and the area are wrong; the axis rule is reported first and deterministically.
        #expect(PageViewport.validate(width: 5000, height: 5000, zoom: 1, scale: 1) == .failure(.axisOutOfRange(.width, 5000)))
    }

    @Test func landscapeSwapsTheProfileAxes() throws {
        for name in ["phone", "tablet", "responsive-desktop"] {
            let profile = try #require(PageViewport.profile(named: name))
            let portrait = profile.dimensions(.portrait), landscape = profile.dimensions(.landscape)
            #expect(landscape.width == portrait.height && landscape.height == portrait.width, "\(name)")
        }
    }

    @Test func unknownProfileAndOrientationAreRejected() {
        #expect(PageViewport.profile(named: "Phone") == nil)
        #expect(PageViewport.profile(named: "") == nil)
        #expect(PageViewport.profile(named: "watch") == nil)
        #expect(PageViewport.Orientation(rawValue: "portrait") == .portrait)
        #expect(PageViewport.Orientation(rawValue: "sideways") == nil)
    }

    @Test func profileRequestIsBudgetChecked() throws {
        let phone = try #require(PageViewport.profile(named: "phone"))
        #expect(PageViewport.request(phone, orientation: .landscape, zoom: 1) == .success(.init(width: 844, height: 390)))
        #expect(PageViewport.request(phone, orientation: .portrait, zoom: .nan) == .failure(.invalidScale))
    }
}
