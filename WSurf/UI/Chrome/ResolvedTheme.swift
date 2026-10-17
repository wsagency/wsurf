// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// What the person changed about the colors of a variant: the hue, a primary color that the window, sidebar,
/// surface and accent derive from, and the brightness knob.
struct PaletteChange: Equatable {
    var hue = 0.0
    var primary: UInt32?
    var brightness = 0.0

    var isActive: Bool {
        hue != 0 || primary != nil || brightness != 0
    }
}

/// One role in one appearance: a base color, and the change to lay over it.
struct RoleColor {
    let base: Color
    let change: PaletteChange
    let isAccent: Bool

    /// The color in `appearance`. A system base, such as the blue accent, depends on it.
    func resolved(in appearance: NSAppearance) -> NSColor {
        guard change.isActive else { return NSColor(base) }
        var resolved = NSColor(base)
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(base).usingColorSpace(.sRGB) ?? resolved
        }
        return Theme.customized(resolved, change: change, isAccent: isAccent)
    }
}

/// Every color the chrome draws for one appearance of a theme, after the knobs. Rows read these; nothing here is
/// computed per row.
struct ResolvedVariant {
    let window: RoleColor
    let sidebar: RoleColor
    let surface: RoleColor
    let accent: RoleColor
    let systemAccent: RoleColor
    /// Text and icons of loaded and unloaded tabs.
    let loadedInk: Color
    let unloadedInk: Color
    /// Overrides for control icons and URL text. nil: the surface draws its own ink.
    let controlInk: Color?
    let urlInk: Color?
    let change: PaletteChange

    /// True when the person changed the palette itself: it then replaces the website tint.
    var changesPalette: Bool {
        change.isActive
    }

    init(_ variant: ThemeVariant, isDark: Bool, brightness: Double) {
        let change = PaletteChange(hue: variant.hue, primary: variant.primary, brightness: brightness)
        let standard = StandardPalette.self
        func color(_ hex: UInt32?, standard fallback: Color) -> Color {
            hex.map(Color.init(hex:)) ?? fallback
        }
        func role(_ hex: UInt32?, standard fallback: NSColor, isAccent: Bool = false) -> RoleColor {
            RoleColor(base: color(hex, standard: Color(nsColor: fallback)), change: change, isAccent: isAccent)
        }
        window = role(variant.window, standard: standard.window(isDark: isDark))
        sidebar = role(variant.sidebar, standard: standard.sidebar(isDark: isDark))
        surface = role(variant.surface, standard: standard.surface(isDark: isDark))
        accent = RoleColor(base: color(variant.accent, standard: .blue), change: change, isAccent: true)
        systemAccent = RoleColor(
            base: color(variant.accent, standard: Color(nsColor: .controlAccentColor)), change: change, isAccent: true
        )
        self.change = change

        let text = variant.text.map(Color.init(hex:))
        func ink(_ style: SidebarTextStyle) -> Color {
            (style.color ?? text ?? (isDark ? .white : .black)).opacity(style.opacity)
        }
        func override(_ style: SidebarTextStyle) -> Color? {
            guard style.colorRGB != nil || style.opacity != 1 else { return text }
            return (style.color ?? .primary).opacity(style.opacity)
        }
        loadedInk = ink(variant.sidebarText)
        unloadedInk = ink(variant.unloadedText)
        controlInk = override(variant.icons)
        urlInk = override(variant.url)
    }
}

/// The theme the window draws, resolved once for both appearances. `BrowserSettings` caches one and rebuilds it
/// when the selected theme, a saved theme or an adjustment changes.
final class ResolvedTheme {
    let id: String
    let ground: ThemeGround
    let adjustment: ThemeAdjustment
    let light: ResolvedVariant
    let dark: ResolvedVariant

    let windowBackground: Color
    let sidebarTint: Color
    let controlSurface: Color
    let accent: Color
    let systemAccent: Color
    private let controlInks: InkPair
    private let urlInks: InkPair

    init(_ definition: ThemeDefinition, adjustment: ThemeAdjustment) {
        let light = ResolvedVariant(definition.light, isDark: false, brightness: adjustment.lightBrightness)
        let dark = ResolvedVariant(definition.dark, isDark: true, brightness: adjustment.darkBrightness)
        func dynamic(_ role: KeyPath<ResolvedVariant, RoleColor>) -> Color {
            let (lightRole, darkRole) = (light[keyPath: role], dark[keyPath: role])
            if !lightRole.change.isActive, !darkRole.change.isActive, lightRole.base == darkRole.base {
                return lightRole.base
            }
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return (isDark ? darkRole : lightRole).resolved(in: appearance)
            })
        }
        id = definition.id
        ground = definition.ground
        self.adjustment = adjustment
        self.light = light
        self.dark = dark
        windowBackground = dynamic(\.window)
        sidebarTint = dynamic(\.sidebar)
        controlSurface = dynamic(\.surface)
        accent = dynamic(\.accent)
        systemAccent = dynamic(\.systemAccent)
        controlInks = InkPair(light: light.controlInk, dark: dark.controlInk)
        urlInks = InkPair(light: light.urlInk, dark: dark.urlInk)
    }

    var material: ThemeMaterial {
        adjustment.material
    }

    var isSoftTinted: Bool {
        ground == .softTinted
    }

    func variant(_ scheme: ColorScheme) -> ResolvedVariant {
        scheme == .dark ? dark : light
    }

    /// The icon and URL overrides for the appearance the app is in. When only one appearance has one, the other
    /// has none, so a surface keeps its own ink there.
    var controlOverride: Color? {
        controlInks.current
    }

    var urlOverride: Color? {
        urlInks.current
    }

    private struct InkPair {
        let light: Color?
        let dark: Color?
        /// Set when both appearances have an ink, so it can follow the appearance a view is drawn in.
        let both: Color?

        init(light: Color?, dark: Color?) {
            self.light = light
            self.dark = dark
            guard let light, let dark else {
                both = nil
                return
            }
            both = Color(nsColor: NSColor(name: nil) { appearance in
                let ink = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                var resolved = NSColor(ink)
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(ink).usingColorSpace(.sRGB) ?? resolved
                }
                return resolved
            })
        }

        var current: Color? {
            if let both {
                return both
            }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }
}

/// The adaptive colors of the Standard theme, which every variant falls back to for a color it does not set.
enum StandardPalette {
    static func window(isDark: Bool) -> NSColor {
        isDark ? NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1) : NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    }

    static func surface(isDark: Bool) -> NSColor {
        NSColor(white: isDark ? 0.34 : 1, alpha: 1)
    }

    static func sidebar(isDark: Bool) -> NSColor {
        isDark ? NSColor(red: 0.05, green: 0.05, blue: 0.065, alpha: 1) : NSColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1)
    }
}

extension Color {
    /// An sRGB color from `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255
        )
    }
}
