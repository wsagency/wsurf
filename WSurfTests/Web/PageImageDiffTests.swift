// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics
import Testing

@testable import WSurf

/// The pixel comparison of two screenshots, on synthetic grids: no page, no engine.
struct PageImageDiffTests {
    private typealias Luma = PageImageDiff.Luma

    /// A white grid with `boxes` painted in, each `(x, y, width, height, level)`.
    private func grid(_ width: Int = 320, _ height: Int = 200, boxes: [[Int]] = []) -> Luma {
        var image = Luma(width: width, height: height)
        for box in boxes {
            for y in box[1]..<min(height, box[1] + box[3]) {
                for x in box[0]..<min(width, box[0] + box[2]) {
                    image.pixels[y * width + x] = UInt8(box[4])
                }
            }
        }
        return image
    }

    @Test func identicalImagesHaveNoDifference() {
        let page = grid(boxes: [[20, 20, 100, 40, 30], [150, 90, 120, 60, 120]])
        let diff = PageImageDiff.compare(page, page)
        #expect(diff.changedPixels == 0)
        #expect(diff.ratio == 0)
        #expect(diff.regions.isEmpty)
        #expect(diff.omittedRegions == 0)
    }

    @Test func aChangedBlockIsBoxedInCSSPixels() {
        let before = grid(boxes: [[20, 20, 100, 40, 30]])
        let after = grid(boxes: [[20, 20, 100, 40, 30], [100, 100, 80, 40, 20]])
        let diff = PageImageDiff.compare(before, after)
        #expect(diff.changedPixels == 80 * 40)
        #expect(diff.ratio == Double(80 * 40) / Double(320 * 200))
        let region = diff.regions.first
        #expect(diff.regions.count == 1)
        // The box covers the block and is no more than a cell wider on each side.
        #expect(region.map { $0.x <= 100 && $0.x > 100 - PageImageDiff.cell } == true, "\(String(describing: region))")
        #expect(region.map { $0.y <= 100 && $0.y > 100 - PageImageDiff.cell } == true)
        #expect(region.map { $0.x + $0.width >= 180 && $0.x + $0.width < 180 + PageImageDiff.cell } == true)
        #expect(region.map { $0.y + $0.height >= 140 && $0.y + $0.height < 140 + PageImageDiff.cell } == true)
        #expect(region.map { $0.changed > 0.5 } == true)
    }

    @Test func boxesAreReportedInCSSPixelsWhenTheGridIsScaledDown() throws {
        let before = grid(160, 100)
        let after = grid(160, 100, boxes: [[48, 32, 32, 32, 0]])
        // The grid is half the page: its pixels are 2 CSS pixels each.
        let diff = PageImageDiff.compare(before, after, scale: 0.5)
        let region = try #require(diff.regions.first)
        #expect(region.x == 96)
        #expect(region.y == 64)
        #expect(region.width == 64)
        #expect(region.height == 64)
    }

    @Test func aShiftedElementIsBoxed() {
        let before = grid(boxes: [[40, 40, 60, 30, 20]])
        let after = grid(boxes: [[140, 40, 60, 30, 20]])
        let diff = PageImageDiff.compare(before, after)
        #expect(diff.changedPixels == 2 * 60 * 30)
        #expect(!diff.regions.isEmpty)
        // Both where it was and where it is lie inside a box.
        for (x, y) in [(70, 55), (170, 55)] {
            #expect(diff.regions.contains { $0.x <= x && x < $0.x + $0.width && $0.y <= y && y < $0.y + $0.height }, "\(x),\(y)")
        }
    }

    @Test func aShiftOfOnePixelIsNotADifference() {
        let before = grid(boxes: [[40, 40, 60, 30, 20]])
        let after = grid(boxes: [[41, 40, 60, 30, 20]])
        #expect(PageImageDiff.compare(before, after).changedPixels == 0)
        // The same holds for a thin line, which anti-aliasing moves by a pixel between engines.
        let line = grid(boxes: [[100, 0, 1, 200, 0]])
        let moved = grid(boxes: [[101, 0, 1, 200, 0]])
        #expect(PageImageDiff.compare(line, moved).changedPixels == 0)
    }

    @Test func aShiftOfThreePixelsIsADifference() {
        let before = grid(boxes: [[40, 40, 60, 30, 20]])
        let after = grid(boxes: [[43, 40, 60, 30, 20]])
        #expect(PageImageDiff.compare(before, after).changedPixels > 0)
    }

    @Test func smallColorChangesAreToleratedAndLargeOnesAreNot() {
        let base = grid(boxes: [[0, 0, 320, 200, 100]])
        let near = grid(boxes: [[0, 0, 320, 200, 100 + PageImageDiff.threshold]])
        let far = grid(boxes: [[0, 0, 320, 200, 100 + PageImageDiff.threshold + 1]])
        #expect(PageImageDiff.compare(base, near).changedPixels == 0)
        #expect(PageImageDiff.compare(base, far).changedPixels == 320 * 200)
        #expect(PageImageDiff.compare(base, far).ratio == 1)
    }

    @Test func anAddedBoxAndARemovedBoxAreTheSameDifference() {
        let empty = grid()
        let full = grid(boxes: [[60, 60, 50, 50, 0]])
        let one = PageImageDiff.compare(empty, full)
        let other = PageImageDiff.compare(full, empty)
        #expect(one.changedPixels == other.changedPixels)
        #expect(one.regions == other.regions)
        #expect(one.regions.count == 1)
    }

    @Test func theBiggestRegionsAreKeptAndTheRestCounted() {
        // Seven blocks, each a little bigger than the one before and an empty block apart from it.
        let boxes = (0..<7).map { [10 + $0 * 56, 20, 16 + $0 * 2, 40, 0] }
        let diff = PageImageDiff.compare(grid(400, 100), grid(400, 100, boxes: boxes))
        #expect(diff.regions.count == PageImageDiff.maxRegions)
        #expect(diff.omittedRegions == 2)
        // The two smallest, the first two blocks, are the ones left out; the biggest comes first.
        let left = diff.regions.map(\.x)
        #expect(left.allSatisfy { $0 > 80 }, "\(left)")
        #expect(left == left.sorted(by: >), "\(left)")
    }

    @Test func scatteredNoiseCountsAsChangedPixelsButStartsNoRegion() {
        var noisy = grid()
        for x in stride(from: 5, to: 300, by: 40) {
            noisy.pixels[10 * 320 + x] = 0
        }
        let diff = PageImageDiff.compare(grid(), noisy)
        #expect(diff.changedPixels > 0)
        #expect(diff.regions.isEmpty)
    }

    @Test func theGridKeepsTheProportionAndCapsTheWidth() throws {
        let small = try #require(PageImageDiff.grid(forCSS: CGSize(width: 640, height: 480)))
        #expect(small.width == 640 && small.height == 480)
        let wide = try #require(PageImageDiff.grid(forCSS: CGSize(width: 2_560, height: 1_600)))
        #expect(wide.width == PageImageDiff.maxGridWidth && wide.height == 800)
        #expect(PageImageDiff.grid(forCSS: CGSize(width: 0, height: 100)) == nil)
        #expect(PageImageDiff.grid(forCSS: CGSize(width: CGFloat.nan, height: 100)) == nil)
    }

    @Test func anImageBecomesGrayscaleOnTheGrid() throws {
        func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) throws -> CGImage {
            let context = try #require(
                CGContext(
                    data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            return try #require(context.makeImage())
        }
        let white = try #require(PageImageDiff.luma(of: try solid(1, 1, 1), width: 20, height: 10))
        let black = try #require(PageImageDiff.luma(of: try solid(0, 0, 0), width: 20, height: 10))
        let red = try #require(PageImageDiff.luma(of: try solid(1, 0, 0), width: 20, height: 10))
        #expect(white.width == 20 && white.height == 10 && white.pixels.count == 200)
        #expect(white.pixels.allSatisfy { $0 >= 250 })
        #expect(black.pixels.allSatisfy { $0 <= 5 })
        // Red is darker than white and lighter than black, by more than the threshold either way.
        let level = Int(red.pixels[0])
        #expect(level > Int(PageImageDiff.threshold) && level < 255 - PageImageDiff.threshold, "\(level)")
    }

    @Test func theOverlayIsAPictureOfTheDifferenceThatFitsItsLimit() throws {
        let before = grid(boxes: [[20, 20, 100, 40, 30]])
        let after = grid(boxes: [[20, 20, 100, 40, 30], [100, 100, 80, 40, 0]])
        let diff = PageImageDiff.compare(before, after)
        let data = try #require(PageImageDiff.overlayJPEG(before, diff, limit: 100_000))
        #expect(data.count <= 100_000)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 320 && bitmap.pixelsHigh == 200)
        // Red where the images differ; the faded page elsewhere.
        let changed = try #require(bitmap.colorAt(x: 140, y: 120)?.usingColorSpace(.sRGB))
        let same = try #require(bitmap.colorAt(x: 280, y: 20)?.usingColorSpace(.sRGB))
        #expect(changed.redComponent > 0.7 && changed.greenComponent < 0.4)
        #expect(same.redComponent > 0.6 && abs(same.redComponent - same.greenComponent) < 0.1)
        // A mask of another size makes no picture.
        #expect(PageImageDiff.overlay(grid(100, 100), diff) == nil)
    }
}
