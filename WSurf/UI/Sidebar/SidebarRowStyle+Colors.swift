// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

extension SidebarRowStyle {
    /// WCAG contrast for the inverse fill and the dot against the sidebar (non-text), and for text on the fill.
    static let minimumFillContrast: CGFloat = 3
    static let minimumContentContrast: CGFloat = 4.5
    static let minimumMarkContrast: CGFloat = 3

    /// The colors of an inverse row and of the new-tab dot.
    struct Colors: Equatable {
        /// The inverse fill: the sidebar's own text color, or ink when that color is too faint on the ground.
        let fill: NSColor
        /// Text and icons on the fill: the sidebar ground, or ink on the fill when the ground is too faint there.
        let content: NSColor
        /// The dot: the accent, or ink when the accent is too faint on the ground.
        let accent: NSColor
        /// Black or white, whichever reads better on the ground.
        let ink: NSColor
        /// The fill is light enough to want dark text, so the row's controls draw as they do on a light chrome.
        let fillIsLight: Bool

        func mark(_ mark: Mark) -> NSColor? {
            switch mark {
            case .none:
                nil
            case .accent:
                accent
            case .ink:
                ink
            }
        }
    }

    /// Works out the colors from what the sidebar already uses: the text color of a loaded tab, the ground it
    /// sits on, and the accent. It keeps the sidebar's own palette wherever that stays readable and falls back to
    /// black or white where a custom text color or a preset does not.
    static func colors(text: NSColor, ground: NSColor, accent: NSColor) -> Colors {
        let ground = opaque(ground)
        let ink = readableInk(on: ground)
        let text = opaque(text)
        let fill = contrast(text, ground) >= minimumFillContrast ? text : ink
        let content = contrast(ground, fill) >= minimumContentContrast ? ground : readableInk(on: fill)
        let accent = opaque(accent)
        return Colors(
            fill: fill,
            content: content,
            accent: contrast(accent, ground) >= minimumMarkContrast ? accent : ink,
            ink: ink,
            fillIsLight: isLight(fill)
        )
    }

    static func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let one = PageInk.luminance(of: opaque(first)) + 0.05
        let two = PageInk.luminance(of: opaque(second)) + 0.05
        return max(one, two) / min(one, two)
    }

    /// A SwiftUI color as sRGB, resolved the way it draws in `scheme`.
    static func srgb(_ color: Color, scheme: ColorScheme) -> NSColor {
        var resolved = NSColor(color)
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    private static let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    private static func opaque(_ color: NSColor) -> NSColor {
        (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(1)
    }

    private static func isLight(_ color: NSColor) -> Bool {
        contrast(black, color) > contrast(white, color)
    }

    private static func readableInk(on color: NSColor) -> NSColor {
        isLight(color) ? black : white
    }
}
