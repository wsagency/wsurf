// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

extension ChromiumPage {
    /// The document area `area` (CSS pixels from the document's top-left corner), including the part below the viewport.
    /// `scale` is image pixels per CSS pixel, so the page is rendered at the size the caller wants and never larger.
    func captureFullPage(_ area: CGRect, scale: Double) async throws -> NSImage {
        // The caller bounds these, and so does this: the engine allocates what it is asked for.
        let width = min(max(1, area.width), ScreenshotTarget.fullPageWidth)
        let height = min(max(1, area.height), ScreenshotTarget.fullPageHeight)
        let bounded = min(max(scale, 0.05), Double(ScreenshotTarget.fullPagePixelWidth) / width, 1)
        try await ensureReady()
        let response = try await command(
            "Page.captureScreenshot",
            params: [
                "format": "png", "captureBeyondViewport": true,
                "clip": ["x": 0, "y": 0, "width": width, "height": height, "scale": bounded],
            ])
        guard let encoded = response["data"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) else {
            throw ChromiumError.protocolFailure(String(localized: "Chromium did not return a page image."))
        }
        return image
    }
}
