// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// A full-page capture is bounded by WSurf, not by the size the page reports.
@MainActor
@Suite(.boundedWebViews)
struct MCPFullPageBoundsTests {
    private typealias Rig = MCPFeedbackRig

    @Test func aPageReportingAHugeDocumentWidthYieldsABoundedImage() async throws {
        let html = "<!doctype html><title>Wide</title><div style='width:5000000px;height:300px;background:#06c'>Wide</div>"
        let rig = try await Rig.make(engine: .chromium, html: html, access: .development)
        defer { rig.close() }
        rig.session.feedback.sleep = { _ in }
        _ = try await rig.start(development: true)
        let result = try await rig.call("screenshotPage", ["fullPage": true])
        #expect(result.isError == false, "\(Rig.text(result))")
        let content = Rig.content(result)
        #expect(content.range(of: #"4096 by \d+"#, options: .regularExpression) != nil, "the area is clamped to 4,096 CSS pixels: \(content.prefix(200))")
        let data = try #require(Rig.images(result).first)
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide <= ScreenshotTarget.fullPagePixelWidth, "\(image.pixelsWide) px wide")
        #expect(image.pixelsHigh <= Int(ScreenshotTarget.fullPageHeight))
        // The cap holds for a caller who asks for more, too.
        let wider = try await rig.call("screenshotPage", ["fullPage": true, "maxWidth": 2_048])
        let widerData = try #require(Rig.images(wider).first)
        let widerImage = try #require(NSBitmapImageRep(data: widerData))
        #expect(widerImage.pixelsWide <= ScreenshotTarget.fullPagePixelWidth)
    }
}
