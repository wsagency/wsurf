// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CoreGraphics
import Testing

@testable import WSurf

/// The page-side measurement (`R.screenshotGeometry`, run by the real `PageRuntime.script` in a real WKWebView) through the
/// Swift mapping, against rects worked out by hand from the CSS. Native pixels stay a DevOps check; this proves the
/// boxes, transforms and clips WebKit reports are carried exactly, for padded, scaled, flipped, rotated, skewed and clipped frames.
@MainActor
struct PageScreenshotWebKitFixtureTests {
    /// A 300 x 200 content box, 5 px border and 10 px padding (a 330 x 230 border box at (100, 50), centre (265, 165)),
    /// holding a 60 x 40 element at (20, 30) in its own document: layout (35, 45)-(95, 85) from the border box's origin.
    private func page(
        frameStyle: String = "", wrapperStyle: String = "",
        inner: String = "<style>body{margin:0}#t{position:absolute;left:20px;top:30px;width:60px;height:40px}</style><div id=t>x</div>"
    ) async -> RuntimeHarness {
        await RuntimeHarness(html: """
            <style>body { margin: 0 } #wrap { position: absolute; left: 0; top: 0; \(wrapperStyle) }
            iframe { position: absolute; left: 100px; top: 50px; width: 300px; height: 200px; border: 5px solid; padding: 10px; \(frameStyle) }</style>
            <div id=wrap><iframe srcdoc='\(inner)'></iframe></div>
            """)
    }

    private func mapped(_ page: RuntimeHarness) async throws -> Result<CGRect, ScreenshotFailure> {
        let items = try #require(try await page.find("#t")["items"] as? [[String: Any]])
        let ref = try #require(items.first?["r"] as? Int)
        let measured = try await page.run("return JSON.stringify(R.screenshotGeometry(\(ref)));").object
        return ScreenshotGeometry.topViewportRect(measured: measured)
    }

    private func expectMapped(_ page: RuntimeHarness, _ expected: CGRect, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        guard case .success(let rect) = try await mapped(page) else { Issue.record("not mapped", sourceLocation: sourceLocation); return }
        let delta = [rect.minX - expected.minX, rect.minY - expected.minY, rect.width - expected.width, rect.height - expected.height]
        #expect(delta.allSatisfy { abs($0) <= 1 }, "\(rect) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test func aPaddedFrameIsMovedPastItsBorderAndPadding() async throws {
        try await expectMapped(await page(), CGRect(x: 135, y: 95, width: 60, height: 40))
    }

    @Test func aScaledFrameScalesAboutItsCentre() async throws {
        try await expectMapped(await page(frameStyle: "transform: scale(0.5)"), CGRect(x: 200, y: 130, width: 30, height: 20))
    }

    @Test func aFlippedFrameMirrorsAboutItsCentre() async throws {
        try await expectMapped(await page(frameStyle: "transform: scaleX(-1)"), CGRect(x: 335, y: 95, width: 60, height: 40))
    }

    @Test func aRotatedFrameTurnsAboutItsCentre() async throws {
        try await expectMapped(await page(frameStyle: "transform: rotate(90deg)"), CGRect(x: 295, y: 35, width: 40, height: 60))
    }

    @Test func theIndividualRotateAndScalePropertiesCompose() async throws {
        try await expectMapped(await page(frameStyle: "scale: 0.5; rotate: 90deg"), CGRect(x: 280, y: 100, width: 20, height: 30))
    }

    @Test func aSkewedFrameKeepsEveryCornerNotTheBoundingBoxWidth() async throws {
        try await expectMapped(await page(frameStyle: "transform: matrix(1, 0, 0.5, 1, 0, 0)"), CGRect(x: 100, y: 95, width: 80, height: 40))
    }

    @Test func aClippingContainerAroundTheFrameCutsTheElement() async throws {
        try await expectMapped(await page(wrapperStyle: "width: 160px; height: 600px; overflow: hidden"), CGRect(x: 135, y: 95, width: 25, height: 40))
    }

    @Test func aFrameUnderAThreeDimensionalTransformIsRefused() async throws {
        #expect(try await mapped(await page(frameStyle: "transform: rotateY(40deg)")) == .failure(.unmappableFrame))
    }

    @Test func aFrameTranslatedInZUnderPerspectiveIsRefused() async throws {
        #expect(try await mapped(await page(frameStyle: "translate: 0 0 50px", wrapperStyle: "perspective: 200px")) == .failure(.unmappableFrame))
    }

    // CSS `zoom` scales layout, not through a transform: the box WebKit reports is zoomed while its layout sizes are not.
    @Test(arguments: [
        ("zoom: 1.5", CGRect(x: 202.5, y: 142.5, width: 90, height: 60)),
        ("zoom: 0.5", CGRect(x: 67.5, y: 47.5, width: 30, height: 20)),
    ])
    func aZoomedFrameIsScaledAboutTheDocumentOrigin(style: String, expected: CGRect) async throws {
        try await expectMapped(await page(frameStyle: style), expected)
    }

    @Test(arguments: [
        ("zoom: 2", CGRect(x: 270, y: 190, width: 120, height: 80)),
        ("zoom: 0.5", CGRect(x: 67.5, y: 47.5, width: 30, height: 20)),
    ])
    func aZoomedAncestorOfTheFrameIsScaledAboutTheDocumentOrigin(style: String, expected: CGRect) async throws {
        try await expectMapped(await page(wrapperStyle: style), expected)
    }

    /// A 50 x 100 clipping container zoomed 1.5 (75 x 150 on screen) inside the frame's document, holding the 60 x 40 element
    /// at (20, 30) layout (zoomed: 90 x 60 at (30, 45)): the container cuts it to 45 wide. The frame's content origin is (115, 65).
    @Test func aZoomedClippingContainerInsideTheFrameCutsTheElement() async throws {
        let inner = "<style>body{margin:0}#c{position:absolute;left:0;top:0;width:50px;height:100px;overflow:hidden;zoom:1.5}"
            + "#t{position:absolute;left:20px;top:30px;width:60px;height:40px}</style><div id=c><div id=t>x</div></div>"
        try await expectMapped(await page(inner: inner), CGRect(x: 145, y: 110, width: 45, height: 60))
    }

    // SVG nodes have no layout box to measure from: the frame is reported as not measurable, not as a changed document.
    @Test func aFrameInsideSVGContentIsNotMeasurableNotStale() async throws {
        let page = await RuntimeHarness(html: """
            <svg width=500 height=400><g transform='translate(5 5)'><foreignObject x=10 y=10 width=400 height=300>
            <iframe style='width:300px;height:200px' srcdoc='<div id=t style="width:60px;height:40px">x</div>'></iframe>
            </foreignObject></g></svg>
            """)
        #expect(try await mapped(page) == .failure(.unmappableFrame))
    }
}
