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
    private let adjusted: NSColor?
    private let fixedRGB: NSColor?

    init(base: @autoclosure () -> Color, change: PaletteChange, isAccent: Bool, isDark: Bool, hex: UInt32? = nil) {
        let base = hex.map(Color.init(hex:)) ?? base()
        self.base = base
        self.change = change
        self.isAccent = isAccent
        fixedRGB = hex == nil ? nil : base.fixedRGB
        if change.isActive, let fixedRGB {
            adjusted = Theme.customized(fixedRGB, change: change, isAccent: isAccent)
        } else {
            adjusted = nil
        }
    }

    /// Only explicit RGB is cached. System sources keep following macOS even with a palette change.
    func resolved(in appearance: NSAppearance) -> NSColor {
        if let adjusted {
            return adjusted
        }
        guard change.isActive else { return NSColor(base) }
        var source = NSColor(base)
        appearance.performAsCurrentDrawingAppearance {
            source = NSColor(base).usingColorSpace(.sRGB) ?? source
        }
        return Theme.customized(source, change: change, isAccent: isAccent)
    }

    func srgb(scheme: ColorScheme) -> NSColor {
        if let adjusted {
            return adjusted.usingColorSpace(.sRGB) ?? adjusted
        }
        let source = fixedRGB ?? SidebarRowStyle.srgb(base, scheme: scheme)
        guard change.isActive else { return source }
        let color = Theme.customized(source, change: change, isAccent: isAccent)
        return color.usingColorSpace(.sRGB) ?? color
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
    let assistant: RoleColor
    let accentText: Color
    let onAccent: Color
    /// Text on the window ground, and on a floating sidebar's own ground.
    let loadedInk: Color
    let unloadedInk: Color
    let floatingLoadedInk: Color
    let floatingUnloadedInk: Color
    /// Overrides for control icons and URL text. nil: the surface draws its own ink.
    let controlInk: Color?
    let urlInk: Color?
    let change: PaletteChange

    /// True when the person changed the palette itself: it then replaces the website tint.
    var changesPalette: Bool {
        change.isActive
    }

    init(_ variant: ThemeVariant, isDark: Bool, brightness: Double, ground: ThemeGround = .solid) {
        let change = PaletteChange(hue: variant.hue, primary: variant.primary, brightness: brightness)
        let standard = StandardPalette.self
        func role(_ hex: UInt32?, standard fallback: @autoclosure () -> NSColor, isAccent: Bool = false) -> RoleColor {
            RoleColor(base: Color(nsColor: fallback()), change: change, isAccent: isAccent, isDark: isDark, hex: hex)
        }
        window = role(variant.window, standard: standard.window(isDark: isDark))
        sidebar = role(variant.sidebar, standard: standard.sidebar(isDark: isDark))
        surface = role(variant.surface, standard: standard.surface(isDark: isDark))
        accent = RoleColor(base: .blue, change: change, isAccent: true, isDark: isDark, hex: variant.accent)
        systemAccent = variant.accent == nil ? RoleColor(
            base: Color(nsColor: .controlAccentColor), change: change, isAccent: true, isDark: isDark
        ) : accent
        assistant = variant.assistant.map {
            RoleColor(base: .clear, change: PaletteChange(), isAccent: true, isDark: isDark, hex: $0)
        } ?? accent
        let scheme: ColorScheme = isDark ? .dark : .light
        let grounds = [window, sidebar, surface].map { ThemeReadability.Ground($0.srgb(scheme: scheme)) }
        let accentColor = accent.srgb(scheme: scheme)
        accentText = Color(nsColor: ThemeReadability.accentText(accentColor, onResolved: grounds, isDark: isDark))
        onAccent = Color(nsColor: ThemeReadability.ink(on: [accentColor]))
        self.change = change

        let text = variant.text.map(Color.init(hex:))
        func ink(_ style: SidebarTextStyle) -> Color {
            (style.color ?? text ?? (isDark ? .white : .black)).opacity(style.opacity)
        }
        func override(_ style: SidebarTextStyle) -> Color? {
            guard style.colorRGB != nil || style.opacity != 1 else { return text }
            return (style.color ?? .primary).opacity(style.opacity)
        }
        let loaded = ink(variant.sidebarText)
        let unloaded = ink(variant.unloadedText)
        let loadedRGB = ThemeReadability.Ink(loaded.fixedRGB)
        let unloadedRGB = ThemeReadability.Ink(unloaded.fixedRGB)
        loadedInk = ThemeReadability.guarded(loaded, ink: loadedRGB, onResolved: [grounds[0]], minimum: 4.5)
        unloadedInk = ThemeReadability.guarded(unloaded, ink: unloadedRGB, onResolved: [grounds[0]], minimum: 4.5)
        if ground == .solid {
            floatingLoadedInk = ThemeReadability.guarded(loaded, ink: loadedRGB, onResolved: [grounds[1]], minimum: 4.5)
            floatingUnloadedInk = ThemeReadability.guarded(unloaded, ink: unloadedRGB, onResolved: [grounds[1]], minimum: 4.5)
        } else {
            floatingLoadedInk = loadedInk
            floatingUnloadedInk = unloadedInk
        }
        controlInk = override(variant.icons).map {
            let isFixed = variant.icons.colorRGB != nil || variant.icons.opacity == 1
            let rgb: ThemeReadability.Ink
            if isFixed, $0 == loaded {
                rgb = loadedRGB
            } else if isFixed, $0 == unloaded {
                rgb = unloadedRGB
            } else {
                let color = isFixed ? $0.fixedRGB : SidebarRowStyle.srgb($0, scheme: scheme)
                rgb = ThemeReadability.Ink(color)
            }
            // Adaptive primary must stay with the window variant, even on a locally inverted surface.
            let ink = isFixed ? $0 : Color(nsColor: rgb.color)
            return ThemeReadability.guarded(ink, ink: rgb, onResolved: Array(grounds.prefix(2)), minimum: 3)
        }
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
    let assistant: Color
    let accentText: Color
    let onAccent: Color
    private let controlInks: InkPair
    private let urlInks: InkPair

    init(_ definition: ThemeDefinition, adjustment: ThemeAdjustment) {
        let light = ResolvedVariant(definition.light, isDark: false, brightness: adjustment.lightBrightness, ground: definition.ground)
        let dark = ResolvedVariant(definition.dark, isDark: true, brightness: adjustment.darkBrightness, ground: definition.ground)
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
        systemAccent = definition.light.accent != nil && definition.dark.accent != nil ? accent : dynamic(\.systemAccent)
        assistant = definition.light.assistant == nil && definition.dark.assistant == nil ? accent : dynamic(\.assistant)
        accentText = light.accentText == dark.accentText ? light.accentText
            : Theme.adaptive(dark: NSColor(dark.accentText), light: NSColor(light.accentText))
        onAccent = light.onAccent == dark.onAccent ? light.onAccent
            : Theme.adaptive(dark: NSColor(dark.onAccent), light: NSColor(light.onAccent))
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

    /// Local surface appearances may differ from the window whose palette supplied the guarded ink.
    func controlOverride(in windowScheme: ColorScheme) -> Color? {
        variant(windowScheme).controlInk
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

private extension Color {
    /// Only explicit RGB/black/white colors: adaptive colors still need the drawing-appearance path.
    var fixedRGB: NSColor {
        let native = NSColor(self)
        return native.usingColorSpace(.sRGB) ?? native
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
