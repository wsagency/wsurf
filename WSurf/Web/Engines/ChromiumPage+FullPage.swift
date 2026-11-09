// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation

extension ChromiumPage {
    /// The view's current frame cropped to `rect` (view points; the whole view when `nil`) and scaled to `width` points. The crop
    /// is made here, not with a DevTools `clip`: for a clip Chromium emulates an offset viewport and resizes the view for one
    /// frame, and when the frame it copies predates them it returns that frame's top-left corner instead of `rect`.
    /// The decode, crop and scale run off the main actor (`decodeCapture`): on main they cost 65-80 ms per capture of a
    /// loaded page, and a tab switch takes three (the leaving tab's preview, the band colour twice).
    ///
    /// `fastEncoding` asks Chromium's PNG encoder to favour speed over size (`optimizeForSpeed`). PNG is lossless either way, so
    /// the pixels are the same; only the bytes of the file differ. The preview and the band colour ask for it, a capture a person or
    /// an agent asks for does not.
    func capture(rect: CGRect?, width: CGFloat?, fastEncoding: Bool = false) async throws -> NSImage {
        #if DEBUG
        // D4 spike (decision 4, fair arms): count every capture asked for and how it ended, in both modes, so the OOP arm cannot
        // pass K1 or K2 by skipping or losing the switch's captures.
        ChromiumCaptureStats.requested += 1
        do {
            let image = try await captureCounted(rect: rect, width: width, fastEncoding: fastEncoding)
            ChromiumCaptureStats.answered += 1
            return image
        } catch {
            ChromiumCaptureStats.failed += 1
            throw error
        }
        #else
        return try await captureCounted(rect: rect, width: width, fastEncoding: fastEncoding)
        #endif
    }

    private func captureCounted(rect: CGRect?, width: CGFloat?, fastEncoding: Bool) async throws -> NSImage {
        try await ensureReady()
        var params: [String: Any] = ["format": "png", "captureBeyondViewport": false]
        if fastEncoding {
            params["optimizeForSpeed"] = true
        }
        let response = try await command("Page.captureScreenshot", params: params)
        let area = rect ?? bounds
        guard let encoded = response["data"] as? String,
            let image = await Self.decodeCapture(encoded, viewWidth: bounds.width, area: area, width: width)
        else { throw ChromiumError.protocolFailure(String(localized: "Chromium did not return a page image.")) }
        let scale = (width ?? area.width) / area.width
        return NSImage(cgImage: image, size: CGSize(width: area.width * scale, height: area.height * scale))
    }

    /// A base64 PNG of a view `viewWidth` points wide, cropped to `area` (view points) and scaled to `width` points. Scaling
    /// draws the image, so the PNG is decoded here and nothing is left to decode on the main actor.
    @concurrent
    nonisolated static func decodeCapture(_ encoded: String, viewWidth: CGFloat, area: CGRect, width: CGFloat?) async -> CGImage? {
        guard viewWidth > 0, area.width > 0, area.height > 0, let data = Data(base64Encoded: encoded),
            let frame = NSBitmapImageRep(data: data)?.cgImage
        else { return nil }
        // Image pixels per view point: the display's scale factor, or an emulated device's.
        let ratio = CGFloat(frame.width) / viewWidth
        let pixels = CGRect(x: area.minX * ratio, y: area.minY * ratio, width: area.width * ratio, height: area.height * ratio)
        guard let crop = frame.cropping(to: pixels.integral) else { return nil }
        let scale = (width ?? area.width) / area.width
        // ponytail: at a scale of 1 (only `DevModeBadge`, off the switch path) the crop is lazy and decodes where it is first drawn.
        guard scale != 1 else { return crop }
        return PageScreenshotEncoding.scaled(NSBitmapImageRep(cgImage: crop), by: Double(scale))?.cgImage ?? crop
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

#if DEBUG
/// D4 spike: Chromium page captures since launch (preview, band colour, and any other), for the driver and the tour.
enum ChromiumCaptureStats {
    static var requested = 0
    static var answered = 0
    static var failed = 0

    static var summary: String {
        "captures requested \(requested), answered \(answered), failed \(failed), in flight \(requested - answered - failed)"
    }
}
#endif
