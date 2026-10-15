// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit

nonisolated enum PageScreenshotEncoding {
    /// Smallest edge, in pixels, below which an image is no longer worth returning.
    private static let minimumEdge = 32

    /// JPEG data for `bitmap` and the pixel width of the image it holds. Without a limit the bitmap is encoded as is. With
    /// one, the quality drops first and the pixels shrink by a quarter per pass after that. Returns nil when nothing fits.
    static func jpeg(_ bitmap: NSBitmapImageRep, fitting limit: Int?) -> (data: Data, pixelsWide: Int)? {
        guard let limit else {
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]).map { ($0, bitmap.pixelsWide) }
        }
        var current = bitmap
        while min(current.pixelsWide, current.pixelsHigh) >= minimumEdge {
            for quality in [0.8, 0.6, 0.4] {
                if let data = current.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= limit {
                    return (data, current.pixelsWide)
                }
            }
            guard let smaller = scaled(current, by: 0.75) else { return nil }
            current = smaller
        }
        return nil
    }

    private static func scaled(_ bitmap: NSBitmapImageRep, by factor: Double) -> NSBitmapImageRep? {
        guard let source = bitmap.cgImage else { return nil }
        let width = Int(Double(source.width) * factor), height = Int(Double(source.height) * factor)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(NSBitmapImageRep.init(cgImage:))
    }
}
