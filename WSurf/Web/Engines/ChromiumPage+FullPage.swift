// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation

extension ChromiumPage {
    /// The view's current frame cropped to `rect` (view points; the whole view when `nil`) and scaled to `width` points.
    ///
    /// When the image is wanted smaller than the view (the 480 pt preview, the 48 pt band colour), Chromium renders only that:
    /// a DevTools `clip` with a `scale` makes it capture `rect` at the size asked for, instead of the whole viewport as a PNG at
    /// the display's resolution. That image was most of the 160-175 ms of main-thread work a switch onto a Chromium tab cost: the
    /// UI-thread half of Chromium's capture runs on this thread. `optimizeForSpeed` trades PNG size for encode time.
    ///
    /// A clip makes Chromium emulate an offset viewport and resize the view for one frame, and when the frame it copies predates
    /// them it returns another region's pixels. So the image is used only when it has the size asked for, and any other
    /// size is read as a full frame and cropped here, as before. Page zoom changes what a clip's units mean, so a zoomed page
    /// takes the full frame too.
    /// The decode, crop and scale run off the main actor (`decodeCapture`): on main they cost 65-80 ms per capture of a
    /// loaded page.
    func capture(rect: CGRect?, width: CGFloat?) async throws -> NSImage {
        try await ensureReady()
        let area = rect ?? bounds
        let scale = (width ?? area.width) / area.width
        let size = CGSize(width: area.width * scale, height: area.height * scale)
        if let clip = Self.captureClip(area: area, width: width, density: window?.backingScaleFactor ?? 1, zoom: pageZoom) {
            let response = try await command(
                "Page.captureScreenshot",
                params: ["format": "png", "captureBeyondViewport": false, "optimizeForSpeed": true, "clip": clip.parameters])
            let encoded = response["data"] as? String
            if let encoded,
                let image = await Self.decodeCapture(
                    encoded, viewWidth: bounds.width, area: area, width: width, clippedPixelWidth: clip.pixelWidth) {
                return NSImage(cgImage: image, size: size)
            }
            // The clip did not give the size asked for: read the whole frame.
        }
        let response = try await command(
            "Page.captureScreenshot", params: ["format": "png", "captureBeyondViewport": false, "optimizeForSpeed": true])
        guard let encoded = response["data"] as? String,
            let image = await Self.decodeCapture(encoded, viewWidth: bounds.width, area: area, width: width)
        else { throw ChromiumError.protocolFailure(String(localized: "Chromium did not return a page image.")) }
        return NSImage(cgImage: image, size: size)
    }

    /// The region Chromium is asked to render for a capture of `area` at `width` points: only when that is smaller than `area` and
    /// the page is not zoomed.
    struct CaptureClip: Equatable {
        let area: CGRect
        /// Image pixels per CSS pixel.
        let scale: Double
        /// The width in pixels of the image Chromium returns for the clip.
        let pixelWidth: Int

        var parameters: [String: Any] {
            ["x": area.minX, "y": area.minY, "width": area.width, "height": area.height, "scale": scale]
        }
    }

    nonisolated static func captureClip(area: CGRect, width: CGFloat?, density: CGFloat, zoom: CGFloat) -> CaptureClip? {
        guard let width, width > 0, area.width > 0, area.height > 0, width < area.width, zoom == 1, density > 0 else { return nil }
        let scale = Double(width / area.width * density)
        return CaptureClip(area: area, scale: scale, pixelWidth: Int((Double(area.width) * scale).rounded()))
    }

    /// A base64 PNG of a view `viewWidth` points wide, cropped to `area` (view points) and scaled to `width` points. Scaling
    /// draws the image, so the PNG is decoded here and nothing is left to decode on the main actor.
    /// `clippedPixelWidth` is the width of the image a clip should have made: an image of that width, give or take a pixel, is
    /// `area` already scaled and is returned as it is; any other width is not the clip's image, and `nil` comes back.
    @concurrent
    nonisolated static func decodeCapture(
        _ encoded: String, viewWidth: CGFloat, area: CGRect, width: CGFloat?, clippedPixelWidth: Int? = nil
    ) async -> CGImage? {
        guard viewWidth > 0, area.width > 0, area.height > 0, let data = Data(base64Encoded: encoded),
            let frame = NSBitmapImageRep(data: data)?.cgImage
        else { return nil }
        if let clippedPixelWidth {
            return abs(frame.width - clippedPixelWidth) <= 1 ? frame : nil
        }
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
