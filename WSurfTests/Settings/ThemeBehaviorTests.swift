// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import WSurf

@MainActor
struct ThemeBehaviorTests {
    private func grounds(_ variant: ResolvedVariant, scheme: ColorScheme) -> [NSColor] {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        return [variant.window, variant.sidebar, variant.surface].map {
            SidebarRowStyle.srgb(Color(nsColor: $0.resolved(in: appearance)), scheme: scheme)
        }
    }

    private func contrast(_ ink: Color, on ground: NSColor, scheme: ColorScheme) -> CGFloat {
        SidebarRowStyle.contrast(ThemeReadability.composite(SidebarRowStyle.srgb(ink, scheme: scheme), on: ground), ground)
    }

    @Test func theWSurfThemeMeetsItsContrastTargets() throws {
        let definition = try #require(ThemeCatalog.builtIn("wsurf"))
        let theme = ResolvedTheme(definition, adjustment: ThemeAdjustment())
        for scheme in [ColorScheme.light, .dark] {
            let variant = theme.variant(scheme)
            let backgrounds = grounds(variant, scheme: scheme)
            for ground in backgrounds {
                #expect(contrast(variant.loadedInk, on: ground, scheme: scheme) >= 7)
                #expect(contrast(try #require(variant.urlInk), on: ground, scheme: scheme) >= 7)
                #expect(contrast(try #require(variant.controlInk), on: ground, scheme: scheme) >= 7)
                #expect(contrast(theme.accent, on: ground, scheme: scheme) >= 3)
                #expect(contrast(theme.accentText, on: ground, scheme: scheme) >= 4.5)
                #expect(contrast(theme.assistant, on: ground, scheme: scheme) >= 4.5)
            }
            #expect(contrast(variant.unloadedInk, on: backgrounds[1], scheme: scheme) >= 4.5)
            let accent = SidebarRowStyle.srgb(theme.accent, scheme: scheme)
            #expect(contrast(theme.onAccent, on: accent, scheme: scheme) >= 4.5)
            #expect(SidebarRowStyle.srgb(theme.onAccent, scheme: scheme) == NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        }
    }

    @Test func mintIsOnlyTheAssistantColorInWSurf() throws {
        for definition in ThemeCatalog.builtIn {
            let theme = ResolvedTheme(definition, adjustment: ThemeAdjustment())
            for scheme in [ColorScheme.light, .dark] {
                let variant = definition.variant(scheme)
                if definition.id == "wsurf" {
                    let mint: UInt32 = scheme == .dark ? 0x2FE0B2 : 0x087258
                    #expect(variant.assistant == mint)
                    #expect(variant.accent != mint)
                    #expect(theme.assistant != theme.accent)
                    #expect(SidebarRowStyle.srgb(theme.systemAccent, scheme: scheme)
                        == SidebarRowStyle.srgb(theme.accent, scheme: scheme))
                } else {
                    #expect(variant.assistant == nil)
                    #expect(theme.assistant == theme.accent)
                }
            }
        }
    }

    @Test func accentTextReadsOnEveryGroundOfEveryTheme() {
        for definition in ThemeCatalog.builtIn {
            let theme = ResolvedTheme(definition, adjustment: ThemeAdjustment())
            for scheme in [ColorScheme.light, .dark] {
                for ground in grounds(theme.variant(scheme), scheme: scheme) {
                    #expect(contrast(theme.accentText, on: ground, scheme: scheme) >= 4.5, "\(definition.id), \(scheme)")
                }
            }
        }
    }

    /// Brightness reaches 100 % either way. The readability guard runs on the grounds the knob produces, so text,
    /// icons and accent text stay legible at both ends, in light and dark, for every built-in theme.
    @Test(arguments: [1.0, -1.0])
    func everyThemeStaysReadableAtFullBrightness(_ brightness: Double) {
        #expect(ThemeAdjustment(lightBrightness: brightness, darkBrightness: brightness).bounded().lightBrightness == brightness)
        for definition in ThemeCatalog.builtIn {
            let theme = ResolvedTheme(
                definition, adjustment: ThemeAdjustment(lightBrightness: brightness, darkBrightness: brightness)
            )
            for scheme in [ColorScheme.light, .dark] {
                let variant = theme.variant(scheme)
                let backgrounds = grounds(variant, scheme: scheme)
                let label = "\(definition.id), \(scheme), \(brightness)"
                #expect(contrast(variant.loadedInk, on: backgrounds[0], scheme: scheme) >= 4.5, "\(label)")
                #expect(contrast(variant.unloadedInk, on: backgrounds[0], scheme: scheme) >= 4.5, "\(label)")
                if definition.ground == .solid {
                    #expect(contrast(variant.floatingLoadedInk, on: backgrounds[1], scheme: scheme) >= 4.5, "\(label)")
                    #expect(contrast(variant.floatingUnloadedInk, on: backgrounds[1], scheme: scheme) >= 4.5, "\(label)")
                }
                if let controlInk = variant.controlInk {
                    for ground in backgrounds.prefix(2) {
                        #expect(contrast(controlInk, on: ground, scheme: scheme) >= 3, "\(label)")
                    }
                }
                for ground in backgrounds {
                    #expect(contrast(theme.accentText, on: ground, scheme: scheme) >= 4.5, "\(label)")
                }
                let accent = SidebarRowStyle.srgb(theme.accent, scheme: scheme)
                #expect(contrast(theme.onAccent, on: accent, scheme: scheme) >= 4.5, "\(label)")
            }
        }
    }

    @Test func accentTextKeepsTheFirstReadableOnePercentStep() {
        func expectFirstStep(_ accent: NSColor, on backgrounds: [NSColor], isDark: Bool) {
            let target: CGFloat = isDark ? 1 : 0
            var expected: NSColor?
            for step in 0...100 {
                let fraction = CGFloat(step) / 100
                let candidate = NSColor(
                    srgbRed: accent.redComponent + (target - accent.redComponent) * fraction,
                    green: accent.greenComponent + (target - accent.greenComponent) * fraction,
                    blue: accent.blueComponent + (target - accent.blueComponent) * fraction,
                    alpha: 1
                )
                if !backgrounds.isEmpty, backgrounds.allSatisfy({ SidebarRowStyle.contrast(candidate, $0) >= 4.5 }) {
                    expected = candidate
                    break
                }
            }
            #expect(ThemeReadability.accentText(accent, on: backgrounds, isDark: isDark)
                == (expected ?? ThemeReadability.ink(on: backgrounds)))
        }
        for definition in ThemeCatalog.builtIn {
            for step in -10...10 {
                for scheme in [ColorScheme.light, .dark] {
                    let variant = ResolvedVariant(
                        definition.variant(scheme), isDark: scheme == .dark, brightness: Double(step) / 20,
                        ground: definition.ground
                    )
                    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
                    let accent = SidebarRowStyle.srgb(Color(nsColor: variant.accent.resolved(in: appearance)), scheme: scheme)
                    expectFirstStep(accent, on: grounds(variant, scheme: scheme), isDark: scheme == .dark)
                }
            }
        }
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let accents = [
            black, white, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        ]
        for step in 0...20 {
            let gray = NSColor(srgbRed: CGFloat(step) / 20, green: CGFloat(step) / 20, blue: CGFloat(step) / 20, alpha: 1)
            for backgrounds in [[], [gray], [black, white], [black, gray, white]] {
                for accent in accents + [gray] {
                    for isDark in [false, true] {
                        expectFirstStep(accent, on: backgrounds, isDark: isDark)
                    }
                }
            }
        }
    }

    @Test func contrastLuminanceExtractionMatchesTheOriginalColorMathExactly() throws {
        func originalLuminance(_ color: NSColor) -> CGFloat {
            PageInk.luminance(of: (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(1))
        }
        func originalContrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
            let one = originalLuminance(first) + 0.05
            let two = originalLuminance(second) + 0.05
            return max(one, two) / min(one, two)
        }
        func expectEquivalent(_ first: NSColor, _ second: NSColor) {
            let expected = originalContrast(first, second)
            let firstLuminance = SidebarRowStyle.luminance(first)
            let secondLuminance = SidebarRowStyle.luminance(second)
            #expect(firstLuminance == originalLuminance(first))
            #expect(secondLuminance == originalLuminance(second))
            #expect(SidebarRowStyle.contrast(first, second) == expected)
            #expect(SidebarRowStyle.contrast(firstLuminance, secondLuminance) == expected)
        }
        let dynamic = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.8, green: 0.7, blue: 0.9, alpha: 1)
                : NSColor(displayP3Red: 0.2, green: 0.3, blue: 0.1, alpha: 1)
        }
        let colors = [
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            NSColor(colorSpace: .extendedSRGB, components: [-0.05, 1.05, 0.6, 1], count: 4),
            NSColor(displayP3Red: 0.9, green: 0.2, blue: 0.5, alpha: 1),
            NSColor(white: 0.37, alpha: 1),
            dynamic,
        ]
        let alphas: [CGFloat] = [0, 0.1, 0.3, 0.4, 0.55, 0.65, 0.88, 1]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for color in colors {
                    for alpha in alphas {
                        let candidate = color.withAlphaComponent(alpha)
                        let rgb = candidate.usingColorSpace(.sRGB) ?? candidate
                        for ground in colors {
                            // The original contrast discards both alphas; compositing must happen first when needed.
                            expectEquivalent(candidate, ground.withAlphaComponent(1 - alpha))
                            let background = (ground.usingColorSpace(.sRGB) ?? ground).withAlphaComponent(1)
                            expectEquivalent(ThemeReadability.composite(rgb, on: background), background)
                        }
                    }
                }
            }
        }
    }

    @Test func cachedInkKeepsTheOriginalPerGroundContrast() {
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        @MainActor func original(_ color: Color, rgb: NSColor, on grounds: [NSColor], minimum: CGFloat) -> Color {
            guard grounds.contains(where: {
                SidebarRowStyle.contrast(ThemeReadability.composite(rgb, on: $0), $0) < minimum
            }) else { return color }
            let blackMinimum = grounds.map { SidebarRowStyle.contrast(black, $0) }.min() ?? 1
            let whiteMinimum = grounds.map { SidebarRowStyle.contrast(white, $0) }.min() ?? 1
            return Color(nsColor: blackMinimum >= whiteMinimum ? black : white)
        }
        let sources = [
            black, white, NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            NSColor(displayP3Red: 0.9, green: 0.2, blue: 0.5, alpha: 1),
            NSColor(white: 0.37, alpha: 1), .controlAccentColor,
        ]
        let grounds: [[NSColor]] = [
            [], [black], [white], [black, white],
            [
                NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1),
                NSColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1),
            ],
        ]
        let minima: [CGFloat] = [3, 4.5]
        for scheme in [ColorScheme.light, .dark] {
            for source in sources {
                for alpha in [0.0, 0.1, 0.3, 0.4, 0.55, 0.65, 0.88, 1] {
                    let color = Color(nsColor: source).opacity(alpha)
                    let rgb = SidebarRowStyle.srgb(color, scheme: scheme)
                    let candidate = ThemeReadability.Ink(rgb)
                    #expect(candidate.opaqueLuminance == (rgb.alphaComponent == 1 ? SidebarRowStyle.luminance(rgb) : nil))
                    for backgrounds in grounds {
                        for minimum in minima {
                            #expect(ThemeReadability.guarded(
                                color, ink: candidate, onResolved: backgrounds.map(ThemeReadability.Ground.init), minimum: minimum
                            ) == original(color, rgb: rgb, on: backgrounds, minimum: minimum))
                        }
                    }
                }
            }
        }
    }

    @Test func explicitRoleColorsDoNotEvaluateTheirFallback() {
        let colors: [UInt32?] = [nil, 0x336699]
        for isDark in [false, true] {
            for brightness in [-0.5, 0, 0.5] {
                for hex in colors {
                    var evaluations = 0
                    func fallback() -> Color {
                        evaluations += 1
                        return Color(nsColor: .controlAccentColor)
                    }
                    let role = RoleColor(
                        base: fallback(), change: PaletteChange(brightness: brightness),
                        isAccent: true, isDark: isDark, hex: hex
                    )
                    #expect(evaluations == (hex == nil ? 1 : 0))
                    #expect(role.base == (hex.map(Color.init(hex:)) ?? Color(nsColor: .controlAccentColor)))
                    _ = role.srgb(scheme: isDark ? .dark : .light)
                    #expect(evaluations == (hex == nil ? 1 : 0))
                }
            }
        }
    }

    @Test func anAdjustedCachedRoleKeepsFollowingItsAdaptiveSource() throws {
        let changed = Mutex(false)
        let source = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if changed.withLock({ $0 }) {
                return dark ? NSColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: 0.65)
                    : NSColor(srgbRed: 0.3, green: 0.7, blue: 0.2, alpha: 0.8)
            }
            return dark ? NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.65)
                : NSColor(srgbRed: 0.7, green: 0.3, blue: 0.6, alpha: 0.8)
        }
        for change in [
            PaletteChange(), PaletteChange(hue: 0.2), PaletteChange(brightness: 0.2),
            PaletteChange(hue: -0.1, brightness: -0.1),
        ] {
            changed.withLock { $0 = false }
            let role = RoleColor(base: Color(nsColor: source), change: change, isAccent: true, isDark: false)
            var before: [NSColor] = []
            for changesSource in [false, true] {
                changed.withLock { $0 = changesSource }
                for (index, scheme) in [ColorScheme.light, .dark].enumerated() {
                    let dark = scheme == .dark
                    let expectedSource: NSColor
                    if changesSource {
                        expectedSource = dark ? NSColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: 0.65)
                            : NSColor(srgbRed: 0.3, green: 0.7, blue: 0.2, alpha: 0.8)
                    } else {
                        expectedSource = dark ? NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.65)
                            : NSColor(srgbRed: 0.7, green: 0.3, blue: 0.6, alpha: 0.8)
                    }
                    #expect(SidebarRowStyle.srgb(Color(nsColor: source), scheme: scheme) == expectedSource)
                    let original = Theme.customized(expectedSource, change: change, isAccent: true)
                    let expected = original.usingColorSpace(.sRGB) ?? original
                    #expect(role.srgb(scheme: scheme) == expected)
                    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                    var resolved = role.resolved(in: appearance)
                    appearance.performAsCurrentDrawingAppearance {
                        resolved = resolved.usingColorSpace(.sRGB) ?? resolved
                    }
                    #expect(resolved == expected)
                    if changesSource {
                        #expect(resolved != before[index], "the same cached role follows the changed source")
                    } else {
                        before.append(resolved)
                    }
                }
            }
        }
    }

    @Test func tintedThumbnailAccentsKeepTheDefaultPictureUnlessExplicitlyOverridden() throws {
        let defaults: [(String, ColorScheme, Color)] = [
            ("standard", .light, Color(red: 0.18, green: 0.48, blue: 0.94)),
            ("standard", .dark, Color(red: 0.26, green: 0.57, blue: 1)),
            ("calm", .light, Color(red: 0.70, green: 0.40, blue: 0.55)),
            ("calm", .dark, Color(red: 0.82, green: 0.57, blue: 0.72)),
        ]
        for (id, scheme, original) in defaults {
            let builtIn = try #require(ThemeCatalog.builtIn(id))
            for changedPalette in [false, true] {
                var theme = builtIn
                var colors = theme.variant(scheme)
                colors.hue = changedPalette ? 0.15 : 0
                theme.setVariant(colors, for: scheme)
                var adjustment = ThemeAdjustment()
                adjustment.setBrightness(changedPalette ? -0.1 : 0, for: scheme)
                let change = PaletteChange(hue: colors.hue, brightness: adjustment.brightness(scheme))
                let expected = changedPalette
                    ? Color(nsColor: Theme.customized(NSColor(original), change: change, isAccent: true)) : original
                let before = ThemeThumbnailPalette(theme, adjustment: adjustment, scheme: scheme)
                #expect(before.accent == expected, "the default static illustration stays unchanged")

                colors.accent = 0xE01C32
                theme.setVariant(colors, for: scheme)
                let explicit = ThemeThumbnailPalette(theme, adjustment: adjustment, scheme: scheme)
                let resolved = ResolvedTheme(theme, adjustment: adjustment).variant(scheme)
                #expect(SidebarRowStyle.srgb(explicit.accent, scheme: scheme) == resolved.accent.srgb(scheme: scheme))
                #expect(explicit.accent != before.accent)
                #expect(explicit.backdrop == before.backdrop && explicit.chrome == before.chrome)
                #expect(explicit.canvas == before.canvas && explicit.surface == before.surface)
            }
        }
    }

    @Test func nativeRGBResolutionMatchesTheAdaptiveColorPath() {
        let custom = ThemeVariant(
            window: 0x808080, sidebar: 0x707070, text: 0x22DD88,
            sidebarText: SidebarTextStyle(colorRGB: 0xCC3300, opacity: 0.8),
            unloadedText: SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.3),
            icons: SidebarTextStyle(colorRGB: 0x00FF00, opacity: 0.4)
        )
        let copy = ThemeDefinition(id: "native-rgb-copy", name: "Native RGB copy", ground: .solid, light: custom, dark: custom)
        let mixed = ThemeDefinition(
            id: "mixed-accent-copy", name: "Mixed accent copy", ground: .solid,
            light: ThemeVariant(accent: 0x336699), dark: custom
        )
        for definition in ThemeCatalog.builtIn + [copy, mixed] {
            for brightness in [-0.5, 0, 0.5] {
                let theme = ResolvedTheme(
                    definition, adjustment: ThemeAdjustment(lightBrightness: brightness, darkBrightness: brightness)
                )
                let originalAccentText = Theme.adaptive(dark: NSColor(theme.dark.accentText), light: NSColor(theme.light.accentText))
                let originalOnAccent = Theme.adaptive(dark: NSColor(theme.dark.onAccent), light: NSColor(theme.light.onAccent))
                let originalLightSystemAccent = RoleColor(
                    base: Color(nsColor: .controlAccentColor), change: theme.light.change,
                    isAccent: true, isDark: false, hex: definition.light.accent
                )
                let originalDarkSystemAccent = RoleColor(
                    base: Color(nsColor: .controlAccentColor), change: theme.dark.change,
                    isAccent: true, isDark: true, hex: definition.dark.accent
                )
                let originalSystemColor: Color
                if !originalLightSystemAccent.change.isActive, !originalDarkSystemAccent.change.isActive,
                   originalLightSystemAccent.base == originalDarkSystemAccent.base {
                    originalSystemColor = originalLightSystemAccent.base
                } else {
                    originalSystemColor = Color(nsColor: NSColor(name: nil) { appearance in
                        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        return (isDark ? originalDarkSystemAccent : originalLightSystemAccent).resolved(in: appearance)
                    })
                }
                for scheme in [ColorScheme.light, .dark] {
                    let variant = theme.variant(scheme)
                    #expect(SidebarRowStyle.srgb(theme.accentText, scheme: scheme)
                        == SidebarRowStyle.srgb(originalAccentText, scheme: scheme))
                    #expect(SidebarRowStyle.srgb(theme.onAccent, scheme: scheme)
                        == SidebarRowStyle.srgb(originalOnAccent, scheme: scheme))
                    #expect(SidebarRowStyle.srgb(theme.systemAccent, scheme: scheme)
                        == SidebarRowStyle.srgb(originalSystemColor, scheme: scheme))
                    let originalSystemAccent = scheme == .dark ? originalDarkSystemAccent : originalLightSystemAccent
                    #expect(variant.systemAccent.base == originalSystemAccent.base)
                    #expect(variant.systemAccent.srgb(scheme: scheme) == originalSystemAccent.srgb(scheme: scheme))
                    for role in [variant.window, variant.sidebar, variant.surface, variant.accent, variant.systemAccent, variant.assistant] {
                        let source = SidebarRowStyle.srgb(role.base, scheme: scheme)
                        let adjusted = role.change.isActive
                            ? Theme.customized(source, change: role.change, isAccent: role.isAccent) : source
                        #expect(role.srgb(scheme: scheme) == (adjusted.usingColorSpace(.sRGB) ?? adjusted))
                    }
                    let stored = definition.variant(scheme)
                    let backgrounds = grounds(variant, scheme: scheme)
                    for (index, style) in [stored.sidebarText, stored.unloadedText].enumerated() {
                        let color = (style.color ?? stored.text.map(Color.init(hex:)) ?? (scheme == .dark ? .white : .black))
                            .opacity(style.opacity)
                        let rgb = SidebarRowStyle.srgb(color, scheme: scheme)
                        #expect([variant.loadedInk, variant.unloadedInk][index]
                            == ThemeReadability.guarded(color, rgb: rgb, on: [backgrounds[0]], minimum: 4.5))
                        let floating = backgrounds[definition.ground == .solid ? 1 : 0]
                        #expect([variant.floatingLoadedInk, variant.floatingUnloadedInk][index]
                            == ThemeReadability.guarded(color, rgb: rgb, on: [floating], minimum: 4.5))
                    }
                    let icons = stored.icons
                    let oldControl = icons.colorRGB == nil && icons.opacity == 1
                        ? stored.text.map(Color.init(hex:)) : (icons.color ?? .primary).opacity(icons.opacity)
                    let legacyControl = oldControl.map {
                        ThemeReadability.guarded($0, rgb: SidebarRowStyle.srgb($0, scheme: scheme),
                                                 on: Array(backgrounds.prefix(2)), minimum: 3)
                    }
                    #expect(variant.controlInk == oldControl.map {
                        let rgb = SidebarRowStyle.srgb($0, scheme: scheme)
                        let ink = icons.colorRGB == nil && icons.opacity != 1 ? Color(nsColor: rgb) : $0
                        return ThemeReadability.guarded(ink, rgb: rgb, on: Array(backgrounds.prefix(2)), minimum: 3)
                    })
                    #expect(variant.controlInk.map { SidebarRowStyle.srgb($0, scheme: scheme) }
                        == legacyControl.map { SidebarRowStyle.srgb($0, scheme: scheme) })
                }
            }
        }
    }

    @Test func onAccentPicksTheReadableInk() {
        for definition in ThemeCatalog.builtIn {
            let theme = ResolvedTheme(definition, adjustment: ThemeAdjustment())
            for scheme in [ColorScheme.light, .dark] {
                let accent = SidebarRowStyle.srgb(theme.accent, scheme: scheme)
                let chosen = contrast(theme.onAccent, on: accent, scheme: scheme)
                #expect(chosen >= max(contrast(.black, on: accent, scheme: scheme), contrast(.white, on: accent, scheme: scheme)))
            }
        }
    }

    @Test func brightnessNeverDropsSidebarTextBelowAA() {
        for definition in ThemeCatalog.builtIn {
            for step in -10...10 {
                let brightness = Double(step) / 20
                for scheme in [ColorScheme.light, .dark] {
                    let variant = ResolvedVariant(
                        definition.variant(scheme), isDark: scheme == .dark, brightness: brightness, ground: definition.ground
                    )
                    let backgrounds = grounds(variant, scheme: scheme)
                    let floatingGround = backgrounds[definition.ground == .solid ? 1 : 0]
                    for (ground, inks) in [
                        (backgrounds[0], [variant.loadedInk, variant.unloadedInk]),
                        (floatingGround, [variant.floatingLoadedInk, variant.floatingUnloadedInk]),
                    ] {
                        for ink in inks {
                            #expect(contrast(ink, on: ground, scheme: scheme) >= 4.5,
                                    "\(definition.id), \(scheme), \(brightness)")
                        }
                    }
                    if let icons = variant.controlInk {
                        for ground in backgrounds.prefix(2) {
                            #expect(contrast(icons, on: ground, scheme: scheme) >= 3)
                        }
                    }
                }
            }
        }
    }

    @Test func readabilityCompositesOpacityWithoutChangingStoredColors() {
        let original = ThemeVariant(
            window: 0xFFFFFF, sidebar: 0xFFFFFF, text: 0,
            sidebarText: SidebarTextStyle(opacity: 0.1), icons: SidebarTextStyle(colorRGB: 0, opacity: 0.1)
        )
        let resolved = ResolvedVariant(original, isDark: false, brightness: 0)
        #expect(resolved.loadedInk == Color(nsColor: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        #expect(original.sidebarText.opacity == 0.1 && original.icons.opacity == 0.1)
    }

    @Test func glassThemesStillFallBackUnderReduceTransparency() {
        for ground in [ThemeGround.solid, .pageTinted, .softTinted] {
            for material in [ThemeMaterial.plain, .glass] {
                for reduced in [true, false] {
                    for contrast in [ColorSchemeContrast.standard, .increased] {
                        let fallback = GlassPolicy.fallsBack(reduceTransparency: reduced, contrast: contrast)
                        let kind = LoomBackdrop.kind(ground: ground, material: material, fallsBack: fallback)
                        if reduced || contrast == .increased {
                            #expect(kind == .solid)
                        } else if material == .glass {
                            #expect(kind == .glass)
                        } else {
                            #expect(kind == (ground == .solid ? .solid : .tinted))
                        }
                    }
                }
            }
        }
    }

    @Test func plainOnASolidGroundMakesTheWindowOpaque() {
        for ground in [ThemeGround.solid, .pageTinted, .softTinted] {
            for material in [ThemeMaterial.plain, .glass] {
                for reduced in [true, false] {
                    for increased in [true, false] {
                        #expect(WindowOpacity.isOpaque(
                            ground: ground, material: material, reduceTransparency: reduced, increaseContrast: increased
                        ) == (reduced || increased || (ground == .solid && material == .plain)))
                    }
                }
            }
        }
    }

    @Test func websiteTintStaysOffWhileBrightnessIsChanged() throws {
        for id in ["standard", "calm"] {
            let theme = try #require(ThemeCatalog.builtIn(id))
            let original = ResolvedTheme(theme, adjustment: ThemeAdjustment())
            #expect(!original.light.changesPalette && !original.dark.changesPalette)
            let changed = ResolvedTheme(theme, adjustment: ThemeAdjustment(lightBrightness: -0.1, darkBrightness: 0.2))
            #expect(changed.light.changesPalette && changed.dark.changesPalette)
        }
    }

    @Test func glassGalleryPreviewsAreFlatTranslucentColors() throws {
        let theme = try #require(ThemeCatalog.builtIn("wsurf"))
        let plain = ThemeThumbnailPalette(theme, adjustment: ThemeAdjustment(), scheme: .dark)
        let clear = ThemeThumbnailPalette(theme, adjustment: ThemeAdjustment(material: .glass, glassOpacity: 0), scheme: .dark)
        let opaque = ThemeThumbnailPalette(theme, adjustment: ThemeAdjustment(material: .glass, glassOpacity: 1), scheme: .dark)
        #expect(plain.materialOpacity == 1)
        #expect(clear.materialOpacity < opaque.materialOpacity && opaque.materialOpacity < 1)
        #expect(plain.accent == clear.accent && plain.primary == clear.primary)
    }
}
