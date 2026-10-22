// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The byte limit decides what is returned; the minimum edge only stops further shrinking.
struct PageScreenshotEncodingTests {
    /// Pseudo-random pixels from a fixed seed: they compress badly, and every run sees the same bytes.
    private func noise(width: Int, height: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var state: UInt32 = 0x2545_F491
        for offset in 0..<(bitmap.bytesPerRow * height) {
            state = state &* 1_664_525 &+ 1_013_904_223
            bitmap.bitmapData![offset] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return bitmap
    }

    @Test func aSmallImageThatFitsIsReturnedAsIs() throws {
        let encoded = try #require(PageScreenshotEncoding.jpeg(noise(width: 80, height: 30), fitting: 150_000))
        #expect(encoded.pixelsWide == 80)
        let decoded = try #require(NSBitmapImageRep(data: encoded.data))
        #expect(decoded.pixelsWide == 80 && decoded.pixelsHigh == 30)
        #expect(encoded.data.count <= 150_000)
    }

    @Test func aLargeImageShrinksUntilItFits() throws {
        let limit = 8_000
        let encoded = try #require(PageScreenshotEncoding.jpeg(noise(width: 200, height: 200), fitting: limit))
        #expect(encoded.data.count <= limit)
        #expect(encoded.pixelsWide < 200)
        #expect(try #require(NSBitmapImageRep(data: encoded.data)).pixelsWide == encoded.pixelsWide)
    }

    @Test func nothingIsReturnedWhenFittingWouldNeedAnEdgeBelowTheMinimum() {
        // No JPEG fits in 10 bytes, so a fit would need smaller and smaller images: 40 -> 30 pixels is below 32.
        #expect(PageScreenshotEncoding.jpeg(noise(width: 40, height: 40), fitting: 10) == nil)
        #expect(PageScreenshotEncoding.jpeg(noise(width: 80, height: 30), fitting: 10) == nil)
    }
}
