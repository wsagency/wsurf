// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A Chromium page image (`ChromiumPage.capture`) arrives as a base64 PNG of the whole viewport. A tab switch takes three of them
/// (the leaving tab's preview, the band colour twice), and decoding them on the main actor held it 65-80 ms each. The decode,
/// crop and scale now run off it, and give the image the main-actor code made before.
@MainActor
@Suite(.serialized)
struct ChromiumCaptureDecodeTests {
    /// A 1200 x 800 pt viewport at 2x: noise, so the PNG is as slow to decode as a busy page.
    private static let viewport = CGSize(width: 1200, height: 800)
    private static let fixture: String = {
        let width = 2400, height = 1600
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        bytes.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in words.indices {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                words[i] = seed
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.base64EncodedString()
    }()

    /// What `capture` made on the main actor before the decode moved off it.
    private static func earlierCapture(_ encoded: String, area: CGRect, width: CGFloat?) -> CGImage? {
        guard let frame = NSBitmapImageRep(data: Data(base64Encoded: encoded)!)?.cgImage else { return nil }
        let ratio = CGFloat(frame.width) / viewport.width
        let pixels = CGRect(x: area.minX * ratio, y: area.minY * ratio, width: area.width * ratio, height: area.height * ratio)
        guard let crop = frame.cropping(to: pixels.integral) else { return nil }
        let scale = (width ?? area.width) / area.width
        let cropped = NSBitmapImageRep(cgImage: crop)
        return (scale == 1 ? cropped : PageScreenshotEncoding.scaled(cropped, by: Double(scale)) ?? cropped).cgImage
    }

    private static func pixels(of image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// The tab preview (480 pt), the band colour's image (48 pt), a crop (`PageInteraction`) and a crop at full size (`DevModeBadge`).
    @Test(arguments: [
        (CGRect?.none, CGFloat?.some(480)), (nil, 48), (CGRect(x: 100, y: 50, width: 600, height: 300), 300),
        (CGRect(x: 0, y: 0, width: 300, height: 200), nil),
    ])
    func theImageIsTheOneMadeOnTheMainActorBefore(rect: CGRect?, width: CGFloat?) async throws {
        let area = rect ?? CGRect(origin: .zero, size: Self.viewport)
        let earlier = try #require(Self.earlierCapture(Self.fixture, area: area, width: width))
        let image = try #require(await ChromiumPage.decodeCapture(Self.fixture, viewWidth: Self.viewport.width, area: area, width: width))
        #expect(image.width == earlier.width && image.height == earlier.height)
        let mine = Self.pixels(of: image), theirs = Self.pixels(of: earlier)
        let worst = zip(mine, theirs).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 1, "the largest channel difference is \(worst)")
    }

    /// The decode leaves the main actor. A capture asked for on it is started; once the main actor has run that and moved on, a
    /// decode on it would be over, and one elsewhere is not (the image takes tens of milliseconds, and its result comes back to
    /// the main actor behind this test). Ordering, not timing, so a busy test host cannot make it pass or fail.
    @Test func theDecodeRunsOffTheMainActor() async throws {
        let probe = DecodeProbe()
        let capture = Task { @MainActor in
            _ = await ChromiumPage.decodeCapture(
                Self.fixture, viewWidth: Self.viewport.width, area: CGRect(origin: .zero, size: Self.viewport), width: 480)
            probe.finished = true
        }
        await Task.yield()
        #expect(!probe.finished, "the page image was decoded on the main actor")
        await capture.value
        #expect(probe.finished)
    }
    /// A clip asks Chromium for a smaller image only when the image is wanted smaller than the area and the page is not zoomed.
    @Test func aClipIsAskedForOnlyWhenTheImageIsSmallerAndTheZoomIsOne() {
        let view = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let preview = ChromiumPage.captureClip(area: view, width: 480, density: 2, zoom: 1)
        #expect(preview?.scale == 0.8)
        #expect(preview?.pixelWidth == 960)
        let band = ChromiumPage.captureClip(area: CGRect(x: 0, y: 0, width: 1200, height: 48), width: 48, density: 2, zoom: 1)
        #expect(band?.scale == 0.08)
        #expect(band?.pixelWidth == 96)
        #expect(band?.parameters["height"] as? CGFloat == 48)
        #expect(ChromiumPage.captureClip(area: view, width: nil, density: 2, zoom: 1) == nil, "full size")
        #expect(ChromiumPage.captureClip(area: view, width: 1200, density: 2, zoom: 1) == nil, "not smaller")
        #expect(ChromiumPage.captureClip(area: view, width: 480, density: 2, zoom: 1.2) == nil, "a zoomed page")
        #expect(ChromiumPage.captureClip(area: .zero, width: 480, density: 2, zoom: 1) == nil)
    }

    /// An image of the clip's width is the area already scaled; any other is not the clip's image.
    @Test func aClippedImageIsUsedAsItIsOnlyAtTheSizeAsked() async throws {
        let area = CGRect(origin: .zero, size: Self.viewport)
        let clipped = try #require(await ChromiumPage.decodeCapture(
            Self.fixture, viewWidth: Self.viewport.width, area: area, width: 2400, clippedPixelWidth: 2400))
        #expect(clipped.width == 2400 && clipped.height == 1600, "returned whole, without a crop or a scale")
        #expect(await ChromiumPage.decodeCapture(
            Self.fixture, viewWidth: Self.viewport.width, area: area, width: 480, clippedPixelWidth: 960) == nil)
        let near = await ChromiumPage.decodeCapture(
            Self.fixture, viewWidth: Self.viewport.width, area: area, width: 1200, clippedPixelWidth: 2401)
        #expect(near?.width == 2400, "a pixel of rounding is allowed")
    }

    @Test func aChromiumTabKeepsItsBandColourForTheAddressItWasMeasuredFor() {
        #expect(BrowserTab.keepsBandColour(isChromium: true, hasColour: true, measuredFor: "https://a.test/", now: "https://a.test/"))
        #expect(!BrowserTab.keepsBandColour(isChromium: true, hasColour: true, measuredFor: "https://a.test/", now: "https://a.test/b"))
        #expect(!BrowserTab.keepsBandColour(isChromium: true, hasColour: false, measuredFor: "https://a.test/", now: "https://a.test/"))
        #expect(!BrowserTab.keepsBandColour(isChromium: true, hasColour: true, measuredFor: nil, now: "https://a.test/"))
        #expect(!BrowserTab.keepsBandColour(isChromium: false, hasColour: true, measuredFor: "https://a.test/", now: "https://a.test/"))
    }
}

@MainActor
private final class DecodeProbe {
    var finished = false
}
