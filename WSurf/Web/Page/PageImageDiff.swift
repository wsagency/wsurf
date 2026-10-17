// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics

/// A pixel comparison of two screenshots of one page in two engines, small enough to report in a few hundred bytes.
///
/// Both images are brought to one grid of luma values first. A pixel counts as changed when the other image has no pixel within
/// one pixel of it that is within `threshold` levels: two engines place anti-aliased text edges and fractional boxes a pixel
/// apart, and that is not a difference a person would act on. A shape that moves further, appears, vanishes or changes color
/// is. Changed pixels are then grouped in `cell`-sized blocks into at most `maxRegions` boxes.
nonisolated enum PageImageDiff {
    /// Luma levels (0 to 255) two pixels may differ by and still count as equal.
    static let threshold = 24
    /// Side of the blocks changed pixels are grouped in, in grid pixels.
    static let cell = 16
    /// A block with fewer changed pixels is scattered noise and starts no region.
    static let minimumBlockPixels = 6
    static let maxRegions = 5
    /// The widest grid, so a wide viewport costs no more than a laptop one.
    static let maxGridWidth = 1_280

    /// One grayscale image on the comparison grid.
    struct Luma: Equatable, Sendable {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int, pixels: [UInt8]) {
            precondition(pixels.count == width * height)
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        init(width: Int, height: Int, fill: UInt8 = 255) {
            self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
        }
    }

    /// A box where the images differ, in CSS pixels from the top-left of the viewport.
    struct Region: Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        /// The share of the box's pixels that changed.
        let changed: Double
    }

    struct Diff: Equatable, Sendable {
        let width: Int
        let height: Int
        let changedPixels: Int
        let regions: [Region]
        /// Regions found beyond `maxRegions`; the biggest are kept.
        let omittedRegions: Int
        /// Grid pixels per CSS pixel.
        let scale: Double
        /// One flag per grid pixel, row by row, set where the images differ.
        let mask: [Bool]

        var ratio: Double {
            width * height == 0 ? 0 : Double(changedPixels) / Double(width * height)
        }
    }

    /// The grid for a viewport of `css` pixels: its width capped at `maxGridWidth`, the height in the same proportion.
    static func grid(forCSS css: CGSize) -> (width: Int, height: Int)? {
        guard css.width.isFinite, css.height.isFinite, css.width >= 1, css.height >= 1 else { return nil }
        let width = min(Int(css.width.rounded()), maxGridWidth)
        let height = Int((css.height * Double(width) / css.width).rounded())
        return width > 0 && height > 0 ? (width, height) : nil
    }

    /// `image` drawn onto a `width` by `height` grayscale grid. Nil when no context can be made.
    static func luma(of image: CGImage, width: Int, height: Int) -> Luma? {
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Luma(width: width, height: height, pixels: pixels) : nil
    }

    /// The pixels where `a` and `b` differ, and the boxes they form. Both images must be the same size. `scale` is the grid's
    /// pixels per CSS pixel, which turns the boxes back into CSS pixels.
    static func compare(_ a: Luma, _ b: Luma, scale: Double = 1) -> Diff {
        precondition(a.width == b.width && a.height == b.height)
        let width = a.width, height = a.height
        let aRange = neighborhood(a), bRange = neighborhood(b)
        var mask = [Bool](repeating: false, count: width * height)
        var changed = 0
        var blocks = [Int](repeating: 0, count: Self.blocks(width) * Self.blocks(height))
        let across = Self.blocks(width)
        let limit = threshold
        mask.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let outside = Self.outside(Int(a.pixels[i]), bRange.low[i], bRange.high[i]) > limit
                        || Self.outside(Int(b.pixels[i]), aRange.low[i], aRange.high[i]) > limit
                    if outside {
                        out[i] = true
                        changed += 1
                        blocks[(y / cell) * across + x / cell] += 1
                    }
                }
            }
        }
        let found = regions(blocks: blocks, across: across, mask: mask, width: width, height: height, scale: scale)
        return Diff(
            width: width, height: height, changedPixels: changed, regions: Array(found.prefix(maxRegions)),
            omittedRegions: max(0, found.count - maxRegions), scale: scale, mask: mask)
    }

    // MARK: Regions

    private static func blocks(_ pixels: Int) -> Int {
        (pixels + cell - 1) / cell
    }

    /// How far `value` lies outside `low...high`.
    private static func outside(_ value: Int, _ low: UInt8, _ high: UInt8) -> Int {
        max(0, Int(low) - value, value - Int(high))
    }

    /// The lowest and highest value within one pixel of every pixel (a 3 by 3 window, cut at the edges).
    private static func neighborhood(_ image: Luma) -> (low: [UInt8], high: [UInt8]) {
        let width = image.width, height = image.height
        var low = image.pixels, high = image.pixels
        var rowLow = image.pixels, rowHigh = image.pixels
        image.pixels.withUnsafeBufferPointer { source in
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    var lowest = source[i], highest = source[i]
                    if x > 0 {
                        lowest = min(lowest, source[i - 1])
                        highest = max(highest, source[i - 1])
                    }
                    if x < width - 1 {
                        lowest = min(lowest, source[i + 1])
                        highest = max(highest, source[i + 1])
                    }
                    rowLow[i] = lowest
                    rowHigh[i] = highest
                }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                var lowest = rowLow[i], highest = rowHigh[i]
                if y > 0 {
                    lowest = min(lowest, rowLow[i - width])
                    highest = max(highest, rowHigh[i - width])
                }
                if y < height - 1 {
                    lowest = min(lowest, rowLow[i + width])
                    highest = max(highest, rowHigh[i + width])
                }
                low[i] = lowest
                high[i] = highest
            }
        }
        return (low, high)
    }

    /// Joins neighbouring blocks that hold enough changed pixels into boxes, the biggest first.
    private static func regions(blocks counts: [Int], across: Int, mask: [Bool], width: Int, height: Int, scale: Double) -> [Region] {
        let down = counts.count / max(across, 1)
        var visited = [Bool](repeating: false, count: counts.count)
        var found: [(pixels: Int, region: Region)] = []
        for start in counts.indices where counts[start] >= minimumBlockPixels && !visited[start] {
            var stack = [start]
            visited[start] = true
            var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0, pixels = 0
            while let block = stack.popLast() {
                let bx = block % across, by = block / across
                minX = min(minX, bx)
                maxX = max(maxX, bx)
                minY = min(minY, by)
                maxY = max(maxY, by)
                pixels += counts[block]
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = bx + dx, ny = by + dy
                        guard nx >= 0, ny >= 0, nx < across, ny < down else { continue }
                        let next = ny * across + nx
                        if counts[next] >= minimumBlockPixels, !visited[next] {
                            visited[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            let left = minX * cell, top = minY * cell
            let right = min(width, (maxX + 1) * cell), bottom = min(height, (maxY + 1) * cell)
            let area = (right - left) * (bottom - top)
            let box = Region(
                x: Int((Double(left) / scale).rounded(.down)), y: Int((Double(top) / scale).rounded(.down)),
                width: max(1, Int((Double(right - left) / scale).rounded(.up))),
                height: max(1, Int((Double(bottom - top) / scale).rounded(.up))),
                changed: area == 0 ? 0 : (Double(pixels) / Double(area) * 1_000).rounded() / 1_000)
            found.append((pixels, box))
        }
        // Biggest first; the position breaks ties so the report is the same every time.
        return found.sorted { ($0.pixels, $1.region.y, $1.region.x) > ($1.pixels, $0.region.y, $0.region.x) }.map(\.region)
    }

    // MARK: Picture

    /// The first image, faded, with the pixels that differ in red.
    static func overlay(_ base: Luma, _ diff: Diff) -> CGImage? {
        guard base.width == diff.width, base.height == diff.height else { return nil }
        var rgba = [UInt8](repeating: 255, count: base.width * base.height * 4)
        for i in 0..<(base.width * base.height) {
            if diff.mask[i] {
                rgba[i * 4] = 230
                rgba[i * 4 + 1] = 30
                rgba[i * 4 + 2] = 30
            } else {
                let faded = UInt8(170 + Int(base.pixels[i]) * 85 / 255)
                rgba[i * 4] = faded
                rgba[i * 4 + 1] = faded
                rgba[i * 4 + 2] = faded
            }
        }
        return rgba.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: base.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    /// JPEG data for the overlay within `limit` bytes, or nil when it cannot be made small enough.
    static func overlayJPEG(_ base: Luma, _ diff: Diff, limit: Int) -> Data? {
        guard let picture = overlay(base, diff) else { return nil }
        return PageScreenshotEncoding.jpeg(NSBitmapImageRep(cgImage: picture), fitting: limit)?.data
    }
}
