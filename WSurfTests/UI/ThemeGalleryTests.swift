// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

@MainActor
struct ThemeGalleryTests {
    private func hex(_ color: Color) throws -> UInt32 {
        let rgb = try #require(NSColor(color).usingColorSpace(.sRGB))
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((value * 255).rounded())
        }
        return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func aSolidThemeThumbnailShowsItsOwnColorsInEachAppearance(scheme: ColorScheme) throws {
        let nord = try #require(ThemeCatalog.builtIn("nord"))
        let variant = nord.variant(scheme)

        let palette = ThemeThumbnailPalette(nord, adjustment: ThemeAdjustment(), scheme: scheme)

        #expect(try hex(palette.backdrop) == variant.window)
        #expect(try palette.sidebar.map(hex) == variant.sidebar)
        #expect(try hex(palette.surface) == variant.surface)
        #expect(try hex(palette.accent) == variant.accent)
        #expect(try hex(palette.primary) == variant.text)
    }

    @Test func aTintedThemeThumbnailFollowsTheBrightnessAndColorsOfItsTheme() throws {
        let standard = try #require(ThemeCatalog.builtIn("standard"))
        let plain = ThemeThumbnailPalette(standard, adjustment: ThemeAdjustment(), scheme: .light)
        var brighter = ThemeAdjustment()
        brighter.lightBrightness = -0.3
        let darker = ThemeThumbnailPalette(standard, adjustment: brighter, scheme: .light)
        var copy = standard
        copy.light.icons = SidebarTextStyle(colorRGB: 0x00AA00)
        let inked = ThemeThumbnailPalette(copy, adjustment: ThemeAdjustment(), scheme: .light)

        #expect(plain.sidebar == nil, "a tinted theme shares one ground")
        #expect(try hex(plain.backdrop) != hex(darker.backdrop))
        #expect(try hex(plain.canvas) == hex(darker.canvas), "the page stays as it is")
        #expect(copy.light.icons == SidebarTextStyle(colorRGB: 0x00AA00), "the stored choice is not changed by previewing")
        let resolved = ResolvedTheme(copy, adjustment: ThemeAdjustment()).light
        let control = try #require(resolved.controlInk)
        #expect(inked.primary == control, "the thumbnail uses the guarded foreground, not a guarded surface")
        let appearance = try #require(NSAppearance(named: .aqua))
        let grounds = [resolved.window, resolved.sidebar].map {
            SidebarRowStyle.srgb(Color(nsColor: $0.resolved(in: appearance)), scheme: .light)
        }
        let raw = SidebarRowStyle.srgb(Color(hex: 0x00AA00), scheme: .light)
        #expect(grounds.contains {
            SidebarRowStyle.contrast(ThemeReadability.composite(raw, on: $0), $0) < 3
        })
        let foreground = SidebarRowStyle.srgb(inked.primary, scheme: .light)
        // A green that cannot be read stays green, and reads on the grounds the icons are drawn on.
        #expect(foreground.greenComponent > foreground.redComponent + 0.2 && foreground.greenComponent > foreground.blueComponent + 0.2)
        for ground in grounds {
            #expect(SidebarRowStyle.contrast(ThemeReadability.composite(foreground, on: ground), ground) >= 3)
        }
        #expect(try hex(plain.primary) != 0x00AA00)
        #expect(plain.id != ThemeThumbnailPalette(standard, adjustment: ThemeAdjustment(), scheme: .dark).id)
    }

    @Test func calmShowsItsOwnPictureInBothAppearances() throws {
        let calm = try #require(ThemeCatalog.builtIn("calm"))
        let standard = try #require(ThemeCatalog.builtIn("standard"))

        for scheme in [ColorScheme.light, .dark] {
            let calmPalette = ThemeThumbnailPalette(calm, adjustment: ThemeAdjustment(), scheme: scheme)
            let standardPalette = ThemeThumbnailPalette(standard, adjustment: ThemeAdjustment(), scheme: scheme)
            #expect(try hex(calmPalette.backdrop) != hex(standardPalette.backdrop), "\(scheme)")
        }
    }

    @Test func aThemeCardIsEqualWhenItDrawsTheSameWhateverItsAction() throws {
        let nord = try #require(ThemeCatalog.builtIn("nord"))
        var taps = 0
        func card(
            _ theme: ThemeDefinition? = nil, adjustment: ThemeAdjustment = ThemeAdjustment(),
            mode: AppearanceMode = .system, isSelected: Bool = false, action: @escaping () -> Void = {}
        ) -> ThemeCard {
            ThemeCard(theme: theme ?? nord, adjustment: adjustment, mode: mode, isSelected: isSelected, action: action)
        }
        var brighter = ThemeAdjustment()
        brighter.darkBrightness = 0.2
        var renamed = nord
        renamed.name = "Renamed"

        #expect(card(action: { taps += 1 }) == card())
        #expect(taps == 0, "comparing cards never selects a theme")
        #expect(card() != card(renamed))
        #expect(card() != card(adjustment: brighter))
        #expect(card() != card(mode: .dark))
        #expect(card() != card(isSelected: true))
    }
}
