// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// An SF Symbol drawn in a square of `box` points with the middle of its visible ink on the middle of the square, so
/// that icons of different symbols and sizes meet the capitals of the title beside them.
///
/// `Image(systemName:)` cannot do this. SwiftUI lays a symbol out as text: the glyph sits in a box that follows the
/// font's ascent and descent, with an offset that differs from symbol to symbol, and the glyph's baseline is rounded
/// to a whole pixel, which moved the ink between 0 and 1 pixel down (a point at 1x) depending on where the row
/// fell. This draws the symbol into a fine bitmap, finds its ink, and puts the middle of the ink on the middle of the
/// bitmap, which SwiftUI then scales to the display.
struct SidebarSymbol: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    let box: CGFloat

    init(_ name: String, size: CGFloat, weight: Font.Weight = .regular, box: CGFloat) {
        self.name = name
        self.size = size
        self.weight = weight
        self.box = box
    }

    var body: some View {
        if let image = SymbolBitmap.image(name, size: size, weight: weight, box: box) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: box, height: box)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .frame(width: box, height: box)
        }
    }
}

/// The bitmaps of `SidebarSymbol`, drawn once for each symbol, size, weight and box and kept.
@MainActor
enum SymbolBitmap {
    /// A symbol is drawn at this many pixels to the point: finer than any display, so the ink is found and placed to
    /// a fraction of a pixel, and SwiftUI only ever scales it down.
    static let scale = 8

    private struct Key: Hashable {
        let name: String
        let size: CGFloat
        let weight: Font.Weight
        let box: CGFloat
    }

    private static var images: [Key: NSImage] = [:]

    /// The symbol in a `box` square, or nil when the system has no such symbol.
    static func image(_ name: String, size: CGFloat, weight: Font.Weight, box: CGFloat) -> NSImage? {
        let key = Key(name: name, size: size, weight: weight, box: box)
        if let image = images[key] {
            return image
        }
        guard let image = paint(key) else { return nil }
        images[key] = image
        return image
    }

    /// The symbol drawn in black twice: once where AppKit centers it, to find where its ink is, and once lifted or
    /// lowered so that the middle of the ink is the middle of the bitmap.
    private static func paint(_ key: Key) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: key.size, weight: key.weight.appKit, scale: .medium)
        ) else { return nil }
        let side = Int((key.box * CGFloat(scale)).rounded())
        guard let probe = bitmap(side: side), let rep = bitmap(side: side) else { return nil }
        draw(symbol, lifted: 0, in: probe)
        guard let drop = inkDrop(of: probe) else { return nil }
        draw(symbol, lifted: drop, in: rep)
        rep.size = NSSize(width: key.box, height: key.box)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// The symbol in the middle of `rep`, raised by `drop` pixels: the context counts up from the bottom.
    private static func draw(_ symbol: NSImage, lifted drop: CGFloat, in rep: NSBitmapImageRep) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let width = symbol.size.width * CGFloat(scale)
        let height = symbol.size.height * CGFloat(scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(
            x: (CGFloat(rep.pixelsWide) - width) / 2,
            y: (CGFloat(rep.pixelsHigh) - height) / 2 + drop,
            width: width,
            height: height
        ))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// How many pixels below the middle of the bitmap the middle of its ink is, or nil when nothing is drawn. A pixel
    /// that is at least half covered is ink.
    private static func inkDrop(of rep: NSBitmapImageRep) -> CGFloat? {
        guard let bytes = rep.bitmapData else { return nil }
        let rows = (0..<rep.pixelsHigh).filter { row in
            (0..<rep.pixelsWide).contains { bytes[row * rep.bytesPerRow + $0 * 4 + 3] >= 128 }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return CGFloat(first + last + 1) / 2 - CGFloat(rep.pixelsHigh) / 2
    }

    private static func bitmap(side: Int) -> NSBitmapImageRep? {
        guard side > 0 else { return nil }
        return NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
    }
}

private extension Font.Weight {
    var appKit: NSFont.Weight {
        switch self {
        case .ultraLight:
            .ultraLight
        case .thin:
            .thin
        case .light:
            .light
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        case .heavy:
            .heavy
        case .black:
            .black
        default:
            .regular
        }
    }
}
