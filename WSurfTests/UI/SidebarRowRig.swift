// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// What the tests that draw real sidebar rows share: a browser and a row context on the Standard theme with its knobs
/// at their defaults, a dark sidebar to put a row on, and a window that draws at the scale of a Retina display.
/// `restore` puts the theme back.
@MainActor
struct SidebarRowRig {
    let coordinator: AppCoordinator
    let context: SidebarRowContext
    let restore: () -> Void

    static let width: CGFloat = 260
    /// A mid gray that neither the sidebar's inverse fill, a folder color nor white text is.
    static let base = Color(red: 0.5, green: 0.5, blue: 0.5)

    var browser: BrowserModel {
        coordinator.browser
    }

    var rowHeight: CGFloat {
        SidebarMetrics.rowHeight(settings: BrowserSettings.application)
    }

    init(space: String) {
        let settings = BrowserSettings.application
        let saved = (settings.themeID, settings.themeAdjustments)
        settings.themeID = "standard"
        settings.themeAdjustments["standard"] = nil
        coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        context = SidebarRowContext(
            browser: coordinator.browser,
            coordinator: coordinator,
            selection: coordinator.browser.sidebarSelection,
            drag: nil,
            pinsCarried: false,
            space: space,
            frames: SidebarFrames()
        )
        restore = {
            settings.themeAdjustments = saved.1
            settings.themeID = saved.0
        }
    }

    /// Sets the knobs of the Standard theme and draws the sidebar with them.
    func adjust(_ adjustment: ThemeAdjustment) {
        BrowserSettings.application.themeAdjustments["standard"] = adjustment
        BrowserSettings.application.refreshTheme()
    }

    /// `row` as a dark full-width sidebar hosts it.
    func sidebar(_ row: some View, width: CGFloat = SidebarRowRig.width, height: CGFloat, style: SidebarStyle = .full) -> some View {
        row
            .frame(width: width, height: height)
            .environment(\.sidebarStyle, style)
            .environment(\.sidebarIsFloating, false)
            .environment(\.chromeWash, .of(NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1), isLight: false))
            .environment(\.chromeIsLight, false)
            .environment(\.colorScheme, .dark)
            .environment(\.windowColorScheme, .dark)
            .background(Self.base)
    }

    private final class RetinaWindow: NSWindow {
        override var backingScaleFactor: CGFloat {
            2
        }
    }

    /// `view` drawn by AppKit at 2 pixels to the point, which is how a Retina display draws it. Points, not pixels, are
    /// what `Picture` takes.
    func picture(of view: some View) throws -> Picture {
        let host = NSHostingView(rootView: view
            // The live Reduce Transparency / Increase Contrast settings swap glass for solid fills; pin them like ThemeLayoutRenderTests.
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = RetinaWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.colorSpace = .pixelTests
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        // A view that opens when it appears (a disclosure that a highlight expands) is its full size only now.
        let size = host.fittingSize
        if size != host.frame.size {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return Picture(bitmap: bitmap, scale: CGFloat(bitmap.pixelsWide) / host.bounds.width)
    }

    /// A drawn view that can be read in points from its top left.
    struct Picture {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat

        func color(x: CGFloat, y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }

        /// How far the pixel at `(x, y)` is from `base`, the largest difference of any channel.
        func distance(x: CGFloat, y: CGFloat, from base: NSColor) throws -> CGFloat {
            let color = try color(x: x, y: y)
            return max(
                abs(color.redComponent - base.redComponent),
                abs(color.greenComponent - base.greenComponent),
                abs(color.blueComponent - base.blueComponent)
            )
        }

        /// The pixel in the box that is farthest from `base`: the color of a glyph's stroke where it is fullest.
        func strongestColor(x xs: ClosedRange<CGFloat>, y ys: ClosedRange<CGFloat>, against base: NSColor) -> NSColor? {
            var best: (distance: CGFloat, color: NSColor)?
            for row in Int(ys.lowerBound * scale)..<Int(ys.upperBound * scale) {
                for column in Int(xs.lowerBound * scale)..<Int(xs.upperBound * scale) {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    let distance = max(
                        abs(pixel.redComponent - base.redComponent),
                        abs(pixel.greenComponent - base.greenComponent),
                        abs(pixel.blueComponent - base.blueComponent)
                    )
                    if distance > best?.distance ?? -1 {
                        best = (distance, pixel)
                    }
                }
            }
            return best?.color
        }

        /// The largest distance from `base` of any pixel in the box, which for a glyph with a hollow middle is its stroke.
        func peakDistance(x xs: ClosedRange<CGFloat>, y ys: ClosedRange<CGFloat>, from base: NSColor) -> CGFloat {
            var peak: CGFloat = 0
            for row in Int(ys.lowerBound * scale)..<Int(ys.upperBound * scale) {
                for column in Int(xs.lowerBound * scale)..<Int(xs.upperBound * scale) {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    peak = max(
                        peak,
                        abs(pixel.redComponent - base.redComponent),
                        abs(pixel.greenComponent - base.greenComponent),
                        abs(pixel.blueComponent - base.blueComponent)
                    )
                }
            }
            return peak
        }

        /// The first column, in points, from `x` on, where the ink in the rows `ys` reaches half of its strongest
        /// pixel against `base`.
        func leftEdge(in ys: ClosedRange<CGFloat>, from x: CGFloat, against base: NSColor) throws -> CGFloat? {
            let rows = Int((ys.lowerBound * scale).rounded(.down))..<Int((ys.upperBound * scale).rounded(.up))
            let start = Int(x * scale)
            let columns = try (start..<bitmap.pixelsWide).map { column in
                try rows.map { row in
                    let pixel = try #require(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
                    return max(
                        abs(pixel.redComponent - base.redComponent),
                        abs(pixel.greenComponent - base.greenComponent),
                        abs(pixel.blueComponent - base.blueComponent)
                    )
                }.max() ?? 0
            }
            guard let strongest = columns.max(), strongest > 0,
                  let first = columns.firstIndex(where: { $0 >= 0.5 * strongest }) else { return nil }
            return CGFloat(start + first) / scale
        }

        /// The top and bottom of the ink between the columns `xs` and the rows `ys` (points), in points from the top. A
        /// row weighs as much as its strongest pixel, so a round shape is read at its extremes like a flat one, and an
        /// edge sits inside its outermost row by the share of the pixel that the ink leaves empty.
        func verticalInk(in xs: ClosedRange<CGFloat>, rows ys: ClosedRange<CGFloat>, against base: NSColor) -> ClosedRange<CGFloat>? {
            let columns = Int((xs.lowerBound * scale).rounded(.down))..<min(bitmap.pixelsWide, Int((xs.upperBound * scale).rounded(.up)))
            let top = Int((ys.lowerBound * scale).rounded(.down))
            let bottom = min(bitmap.pixelsHigh, Int((ys.upperBound * scale).rounded(.up)))
            let grid = (top..<bottom).map { row in
                columns.map { column -> CGFloat in
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return 0 }
                    return max(
                        abs(pixel.redComponent - base.redComponent),
                        abs(pixel.greenComponent - base.greenComponent),
                        abs(pixel.blueComponent - base.blueComponent)
                    )
                }
            }
            guard let strongest = grid.joined().max(), strongest > 0 else { return nil }
            let weights = grid.map { ($0.max() ?? 0) / strongest }
            let inked = weights.indices.filter { weights[$0] > 0.08 }
            guard let first = inked.first, let last = inked.last, last > first else { return nil }
            let upper = CGFloat(top + first) + 1 - min(weights[first], 1)
            let lower = CGFloat(top + last) + min(weights[last], 1)
            return (upper / scale)...(lower / scale)
        }
    }

    static var baseColor: NSColor {
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    }
}
