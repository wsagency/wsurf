// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

extension ChromiumPage {
    /// The view's current frame cropped to `rect` (view points; the whole view when `nil`) and scaled to `width` points. The crop
    /// is made here, not with a DevTools `clip`: for a clip Chromium emulates an offset viewport and resizes the view for one
    /// frame, and when the frame it copies predates them it returns that frame's top-left corner instead of `rect`.
    func capture(rect: CGRect?, width: CGFloat?) async throws -> NSImage {
        try await ensureReady()
        let response = try await command("Page.captureScreenshot", params: ["format": "png", "captureBeyondViewport": false])
        let area = rect ?? bounds
        let failure = ChromiumError.protocolFailure(String(localized: "Chromium did not return a page image."))
        guard let encoded = response["data"] as? String, let data = Data(base64Encoded: encoded),
            let frame = NSBitmapImageRep(data: data)?.cgImage, bounds.width > 0, area.width > 0, area.height > 0
        else { throw failure }
        // Image pixels per view point: the display's scale factor, or an emulated device's.
        let ratio = CGFloat(frame.width) / bounds.width
        let pixels = CGRect(x: area.minX * ratio, y: area.minY * ratio, width: area.width * ratio, height: area.height * ratio)
        guard let crop = frame.cropping(to: pixels.integral) else { throw failure }
        let scale = (width ?? area.width) / area.width
        let cropped = NSBitmapImageRep(cgImage: crop)
        let image = NSImage(size: CGSize(width: area.width * scale, height: area.height * scale))
        image.addRepresentation(scale == 1 ? cropped : PageScreenshotEncoding.scaled(cropped, by: Double(scale)) ?? cropped)
        return image
    }

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
