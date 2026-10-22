// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Measures how well the text colors of a theme variant read on the grounds they are drawn on. It only measures:
/// the Colors panel warns, and no stored color changes. What the chrome draws is `ThemeReadability`'s decision.
enum ThemeContrast {
    /// WCAG AA for text, the same floor the readability guard holds drawn text to.
    static let minimum: CGFloat = 4.5

    enum Role {
        /// The theme's text color, on the window, the sidebar and the surface.
        case primary
        /// The dimmer text of tabs that are asleep: its own color (the text color without one) at its opacity,
        /// on the window and the sidebar.
        case secondary
    }

    struct Shortfall: Equatable {
        enum Ground {
            case window, sidebar, surface
        }

        let ratio: CGFloat
        let ground: Ground

        /// The ratio cut to one decimal, not rounded: 4.46 is shown as 4.4, never as the 4.5 it falls short of.
        var shownRatio: Double {
            (Double(ratio) * 10).rounded(.down) / 10
        }
    }

    /// The weakest ground for `role` in `variant`, or nil when it reads at `minimum` on all of them. The grounds are
    /// the ones the variant draws after its hue, primary color and `brightness`.
    static func shortfall(
        _ role: Role, in variant: ThemeVariant, isDark: Bool, brightness: Double, ground: ThemeGround
    ) -> Shortfall? {
        let resolved = ResolvedVariant(variant, isDark: isDark, brightness: brightness, ground: ground)
        let scheme: ColorScheme = isDark ? .dark : .light
        let text = variant.text.map(srgb) ?? (isDark ? srgb(0xFFFFFF) : srgb(0x000000))
        let ink: NSColor
        let grounds: [(Shortfall.Ground, RoleColor)]
        switch role {
        case .primary:
            ink = text
            grounds = [(.window, resolved.window), (.sidebar, resolved.sidebar), (.surface, resolved.surface)]
        case .secondary:
            let style = variant.unloadedText
            ink = (style.colorRGB.map(srgb) ?? text).withAlphaComponent(style.opacity)
            grounds = [(.window, resolved.window), (.sidebar, resolved.sidebar)]
        }
        let weakest = grounds.map { name, base in
            let color = base.srgb(scheme: scheme)
            return Shortfall(
                ratio: SidebarRowStyle.contrast(ThemeReadability.composite(ink, on: color), color), ground: name
            )
        }.min { $0.ratio < $1.ratio }
        return weakest.flatMap { $0.ratio < minimum ? $0 : nil }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1
        )
    }
}
