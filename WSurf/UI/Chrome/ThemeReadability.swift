// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Runs while a theme is resolved, never while a resting row draws. Stored colors and opacities stay intact.
enum ThemeReadability {
    private static let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    struct Ground {
        let color: NSColor
        let luminance: CGFloat

        init(_ color: NSColor) {
            self.color = color
            luminance = SidebarRowStyle.luminance(color)
        }
    }

    /// Reused within one variant only. Translucent ink still needs each ground's compositing.
    struct Ink {
        let color: NSColor
        let opaqueLuminance: CGFloat?

        init(_ color: NSColor) {
            self.color = color
            opaqueLuminance = color.alphaComponent == 1 ? SidebarRowStyle.luminance(color) : nil
        }
    }

    static func ink(on grounds: [NSColor]) -> NSColor {
        ink(onResolved: grounds.map(Ground.init))
    }

    static func ink(onResolved grounds: [Ground]) -> NSColor {
        func minimumContrast(_ color: NSColor) -> CGFloat {
            let luminance = SidebarRowStyle.luminance(color)
            return grounds.map { SidebarRowStyle.contrast(luminance, $0.luminance) }.min() ?? 1
        }
        return minimumContrast(black) >= minimumContrast(white) ? black : white
    }

    static func guarded(_ color: Color, rgb: NSColor, on grounds: [NSColor], minimum: CGFloat) -> Color {
        guarded(color, rgb: rgb, onResolved: grounds.map(Ground.init), minimum: minimum)
    }

    static func guarded(_ color: Color, rgb: NSColor, onResolved grounds: [Ground], minimum: CGFloat) -> Color {
        guarded(color, ink: Ink(rgb), onResolved: grounds, minimum: minimum)
    }

    static func guarded(_ color: Color, ink candidate: Ink, onResolved grounds: [Ground], minimum: CGFloat) -> Color {
        guard grounds.contains(where: {
            let luminance = candidate.opaqueLuminance
                ?? SidebarRowStyle.luminance(composite(candidate.color, on: $0.color))
            return SidebarRowStyle.contrast(luminance, $0.luminance) < minimum
        }) else {
            return color
        }
        return Color(nsColor: ink(onResolved: grounds))
    }

    static func accentText(_ accent: NSColor, on grounds: [NSColor], isDark: Bool) -> NSColor {
        accentText(accent, onResolved: grounds.map(Ground.init), isDark: isDark)
    }

    static func accentText(_ accent: NSColor, onResolved grounds: [Ground], isDark: Bool) -> NSColor {
        let target: CGFloat = isDark ? 1 : 0
        func blend(_ step: Int) -> NSColor {
            let fraction = CGFloat(step) / 100
            return NSColor(
                srgbRed: accent.redComponent + (target - accent.redComponent) * fraction,
                green: accent.greenComponent + (target - accent.greenComponent) * fraction,
                blue: accent.blueComponent + (target - accent.blueComponent) * fraction,
                alpha: 1
            )
        }
        func reads(_ color: NSColor) -> Bool {
            let luminance = SidebarRowStyle.luminance(color)
            return !grounds.isEmpty && grounds.allSatisfy { SidebarRowStyle.contrast(luminance, $0.luminance) >= 4.5 }
        }
        let original = blend(0)
        if reads(original) {
            return original
        }
        // A readable black/white endpoint confines all grounds to the opposite tonal family. After an
        // initial failure, readability is monotone toward that endpoint; keep the first integer 1% step.
        if reads(blend(100)) {
            var lower = 1
            var upper = 100
            while lower < upper {
                let middle = (lower + upper) / 2
                if reads(blend(middle)) {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            return blend(lower)
        }
        // Mixed or reversed grounds need the full scan: a readable interval may end before the endpoint.
        for step in 1...100 {
            let color = blend(step)
            if reads(color) {
                return color
            }
        }
        // An extreme brightness can reverse the tonal family. Prefer the better ink there too.
        return ink(onResolved: grounds)
    }

    static func composite(_ ink: NSColor, on ground: NSColor) -> NSColor {
        let alpha = ink.alphaComponent
        guard alpha != 1 else { return ink }
        return NSColor(
            srgbRed: ink.redComponent * alpha + ground.redComponent * (1 - alpha),
            green: ink.greenComponent * alpha + ground.greenComponent * (1 - alpha),
            blue: ink.blueComponent * alpha + ground.blueComponent * (1 - alpha), alpha: 1
        )
    }
}
