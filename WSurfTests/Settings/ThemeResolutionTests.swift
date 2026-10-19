// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import WSurf

@MainActor
struct ThemeResolutionTests {
    private func withSettings<Result>(_ body: (BrowserSettings, UserDefaults) throws -> Result) throws -> Result {
        let name = "ThemeResolution-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        return try body(BrowserSettings(defaults: defaults), defaults)
    }

    private func hex(_ color: NSColor?) throws -> UInt32 {
        let rgb = try #require(color?.usingColorSpace(.sRGB))
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((value * 255).rounded())
        }
        return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
    }

    /// `color` as drawn in `name`'s appearance.
    private func ink(_ color: Color?, in name: NSAppearance.Name) throws -> UInt32 {
        var resolved: NSColor?
        try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            resolved = color.flatMap { NSColor($0).usingColorSpace(.sRGB) }
        }
        return try hex(resolved)
    }

    // MARK: - Copies

    @Test func editingABuiltInColorMakesASelectedCopy() throws {
        try withSettings { settings, defaults in
            settings.themeID = "nord"

            settings.editColors(scheme: .dark) { $0.accent = 0xFF8800 }

            let copy = settings.selectedTheme
            #expect(copy.id != "nord" && !ThemeCatalog.isBuiltIn(copy.id))
            #expect(copy.basedOn == "nord")
            #expect(copy.name == "Nord copy")
            #expect(copy.dark.accent == 0xFF8800)
            #expect(copy.light == ThemeCatalog.builtIn("nord")?.light, "the other variant is untouched")
            #expect(settings.userThemes.map(\.id) == [copy.id])
            #expect(ThemeCatalog.builtIn("nord")?.dark.accent == 0x88C0D0, "the built-in theme does not change")

            // A second edit changes the copy and makes no other.
            settings.editColors(scheme: .light) { $0.hue = 0.2 }
            #expect(settings.userThemes.count == 1)
            #expect(settings.selectedTheme.light.hue == 0.2 && settings.selectedTheme.dark.accent == 0xFF8800)

            let restored = BrowserSettings(defaults: defaults)
            #expect(restored.themeID == copy.id)
            #expect(restored.selectedTheme == settings.selectedTheme)
        }
    }

    @Test func aCopyGetsAUniqueName() throws {
        try withSettings { settings, _ in
            settings.themeID = "calm"
            settings.editColors(scheme: .light) { $0.hue = 0.1 }
            settings.themeID = "calm"
            settings.editColors(scheme: .light) { $0.hue = 0.2 }

            #expect(settings.userThemes.map(\.name) == ["Calm copy", "Calm copy 2"])
        }
    }

    @Test func knobsOnABuiltInNeverMakeACopy() throws {
        try withSettings { settings, defaults in
            settings.themeID = "gruvbox"

            var adjustment = settings.themeAdjustment
            adjustment.material = .glass
            adjustment.glassOpacity = 0.8
            adjustment.setBrightness(0.3, for: .light)
            adjustment.setBrightness(-0.2, for: .dark)
            adjustment.cornerScale = 0
            adjustment.pageFrame = .none
            settings.themeAdjustment = adjustment

            #expect(settings.userThemes.isEmpty)
            #expect(settings.themeID == "gruvbox")
            #expect(settings.themeAdjustments["gruvbox"] == adjustment)
            #expect(settings.themeAdjustments["nord"] == nil, "a knob belongs to one theme")
            #expect(BrowserSettings(defaults: defaults).themeAdjustments["gruvbox"] == adjustment)
            #expect(settings.themeMaterial == .glass && settings.transparency == 0.8)
        }
    }

    @Test func aCopyCarriesTheKnobsOfItsSource() throws {
        try withSettings { settings, _ in
            settings.themeID = "dracula"
            var adjustment = settings.themeAdjustment
            adjustment.setBrightness(0.25, for: .dark)
            settings.themeAdjustment = adjustment

            settings.editColors(scheme: .dark) { $0.hue = 0.1 }

            #expect(settings.themeAdjustment.darkBrightness == 0.25)
            #expect(settings.themeAdjustments["dracula"]?.darkBrightness == 0.25, "the source keeps its own")
        }
    }

    @Test func colorsResetRestoresTheBuiltInColors() throws {
        try withSettings { settings, _ in
            settings.themeID = "rosePine"
            settings.editColors(scheme: .dark) { $0.accent = 0x123456 }
            settings.editColors(scheme: .light) { $0.accent = 0x654321 }
            var adjustment = settings.themeAdjustment
            adjustment.setBrightness(0.4, for: .dark)
            settings.themeAdjustment = adjustment

            settings.resetColors(scheme: .dark)

            let original = try #require(ThemeCatalog.builtIn("rosePine"))
            #expect(settings.selectedTheme.dark == original.dark)
            #expect(settings.selectedTheme.light.accent == 0x654321, "the other variant is not reset")
            #expect(settings.themeAdjustment.darkBrightness == 0)
        }
    }

    @Test func theCopyLimitStopsTheEditInsteadOfDroppingThemes() throws {
        try withSettings { settings, _ in
            settings.userThemes = (0..<BrowserSettings.userThemeLimit).map {
                ThemeDefinition(id: "t\($0)", name: "Theme \($0)", ground: .solid)
            }
            settings.themeID = "nord"

            settings.editColors(scheme: .dark) { $0.accent = 0xFF0000 }

            #expect(settings.userThemes.count == BrowserSettings.userThemeLimit)
            #expect(settings.themeID == "nord")
        }
    }

    // MARK: - Loading

    @Test func savedThemesAreBoundedAndTheirNamesUnique() {
        let themes = [
            ThemeDefinition(id: "a", name: "  Mine  ", ground: .solid),
            ThemeDefinition(id: "b", name: "mine", ground: .solid),
            ThemeDefinition(id: "nord", name: "Impostor", ground: .solid),
            ThemeDefinition(id: "a", name: "Duplicate id", ground: .solid),
            ThemeDefinition(id: "c", name: String(repeating: "x", count: 90), ground: .solid),
            ThemeDefinition(id: "d", name: "Nord", ground: .solid, light: ThemeVariant(window: 0xFFFFFFFF)),
            ThemeDefinition(id: "", name: "No id", ground: .solid),
        ]

        let normalized = BrowserSettings.normalized(themes)

        #expect(normalized.map(\.id) == ["a", "b", "c", "d"])
        #expect(normalized[0].name == "Mine" && normalized[1].name == "mine 2")
        #expect(normalized[2].name.count == ThemeDefinition.nameLimit)
        #expect(normalized[3].name == "Nord 2", "a saved theme cannot take a built-in name")
        #expect(normalized[3].light.window == nil, "an impossible color is dropped")
    }

    @Test func aThemeDecodesWhateverItsFileHolds() throws {
        let json = #"""
        [
          {"id": "keep", "name": "Kept", "ground": "solid", "light": {"window": 16777215, "hue": "loud"},
           "dark": {"accent": 255, "extra": true}, "futureField": 1},
          {"name": "no id"},
          {"id": "odd", "name": "Odd", "ground": "holographic"}
        ]
        """#
        let themes = BrowserSettings.decodeUserThemes(Data(json.utf8))

        #expect(themes.map(\.id) == ["keep", "odd"])
        #expect(themes[0].light.window == 0xFFFFFF && themes[0].light.hue == 0)
        #expect(themes[0].dark.accent == 0xFF)
        #expect(themes[1].ground == .pageTinted, "an unknown ground decodes to the default")
        #expect(BrowserSettings.decodeUserThemes(Data("{}".utf8)).isEmpty)
    }

    @Test func adjustmentsDecodeLeniently() {
        let json = #"{"nord": {"material": "glass", "cornerScale": 9, "pageFrame": "wavy"}, "bad": 3}"#
        let adjustments = BrowserSettings.decodeThemeAdjustments(Data(json.utf8))

        #expect(adjustments.keys.sorted() == ["nord"])
        #expect(adjustments["nord"]?.material == .glass)
        #expect(adjustments["nord"]?.cornerScale == 1.5)
        #expect(adjustments["nord"]?.pageFrame == .standard)
    }

    @Test func resetKeepsSavedThemes() throws {
        try withSettings { settings, defaults in
            settings.themeID = "nord"
            settings.editColors(scheme: .dark) { $0.hue = 0.2 }
            settings.colorMode = .dark
            var adjustment = settings.themeAdjustment
            adjustment.material = .glass
            settings.themeAdjustment = adjustment
            let saved = settings.userThemes

            settings.resetToDefaults()

            #expect(settings.userThemes == saved, "deleting the person's themes would lose data")
            #expect(settings.themeID == ThemeCatalog.defaultID)
            #expect(settings.colorMode == .system)
            #expect(settings.themeAdjustments.isEmpty)
            let restored = BrowserSettings(defaults: defaults)
            #expect(restored.userThemes == saved && restored.themeID == ThemeCatalog.defaultID)
        }
    }

    @Test func unknownThemeIDFallsBackToTheDefault() throws {
        try withSettings { settings, _ in
            settings.themeID = "deleted-theme"

            #expect(settings.selectedTheme.id == ThemeCatalog.defaultID)
            #expect(settings.resolvedTheme.id == ThemeCatalog.defaultID)
        }
    }

    // MARK: - Resolving

    @Test func theResolvedThemeIsCachedUntilSomethingItReadsChanges() throws {
        try withSettings { settings, _ in
            let first = settings.resolvedTheme
            #expect(settings.resolvedTheme === first)

            settings.colorMode = .dark
            #expect(settings.resolvedTheme === first, "the mode does not change the colors, only which variant shows")

            settings.themeID = "nord"
            let nord = settings.resolvedTheme
            #expect(nord !== first && nord.id == "nord")

            var adjustment = settings.themeAdjustment
            adjustment.setBrightness(0.2, for: .light)
            settings.themeAdjustment = adjustment
            #expect(settings.resolvedTheme !== nord)
            #expect(settings.resolvedTheme.light.changesPalette)
            #expect(!settings.resolvedTheme.dark.changesPalette)
        }
    }

    @Test func choosingAThemeInvalidatesWhatReadsTheColors() throws {
        try withSettings { settings, _ in
            let invalidated = Mutex(false)
            withObservationTracking {
                _ = settings.resolvedTheme
            } onChange: {
                invalidated.withLock { $0 = true }
            }

            settings.themeID = "dracula"

            #expect(invalidated.withLock { $0 })
        }
    }

    @Test func standardAndCalmKeepTheirAdaptiveColors() throws {
        let standard = ResolvedTheme(try #require(ThemeCatalog.builtIn("standard")), adjustment: ThemeAdjustment())

        #expect(standard.accent == Color.blue, "Standard keeps the system blue")
        #expect(standard.controlOverride == nil && standard.urlOverride == nil)
        #expect(!standard.light.changesPalette && !standard.isSoftTinted)
        #expect(try ink(standard.windowBackground, in: .aqua) == 0xFAFAFC)
        #expect(try ink(standard.windowBackground, in: .darkAqua) == 0x17171C)

        let calm = ResolvedTheme(try #require(ThemeCatalog.builtIn("calm")), adjustment: ThemeAdjustment())
        #expect(calm.isSoftTinted)
    }

    // MARK: - The application's theme

    /// Runs `body` on the application settings, then puts the theme settings and the appearance back.
    private func onApplication(_ body: (BrowserSettings) throws -> Void) throws {
        let settings = BrowserSettings.application
        let saved = (settings.colorMode, settings.themeID, settings.userThemes, settings.themeAdjustments)
        let savedNative = NSApp.appearance
        defer {
            settings.userThemes = saved.2
            settings.themeAdjustments = saved.3
            settings.themeID = saved.1
            settings.colorMode = saved.0
            NSApp.appearance = savedNative
        }
        settings.colorMode = .light
        try body(settings)
    }

    @Test func aPrivateWindowDrawsTheThemesDarkVariant() throws {
        try onApplication { settings in
            settings.themeID = "catppuccin"
            let mocha = try #require(ThemeCatalog.builtIn("catppuccin")?.dark)

            // The app is light, but this window is drawn dark, as a private window is.
            NSApp.appearance = NSAppearance(named: .aqua)
            #expect(try ink(Theme.windowBackground, in: .darkAqua) == mocha.window)
            #expect(try ink(Theme.sidebarTint, in: .darkAqua) == mocha.sidebar)
            #expect(try ink(Theme.accent, in: .darkAqua) == mocha.accent)
            #expect(try ink(Theme.controlOverride, in: .darkAqua) == mocha.text)
            #expect(try ink(Theme.urlOverride, in: .darkAqua) == mocha.text)
            #expect(try hex(NSColor(settings.sidebarTextColor(scheme: .dark))) == mocha.text)
            #expect(try hex(LoomChrome.sampledColor(nil, scheme: .dark)) == mocha.window)
            #expect(try hex(LoomChrome.sampledColor(nil, scheme: .dark, isFloating: true)) == mocha.sidebar)
        }
    }

    @Test func theLightCustomizationsOfACopyDoNotReachAPrivateWindow() throws {
        try onApplication { settings in
            settings.themeID = "standard"
            settings.editColors(scheme: .light) { $0.primary = 0xCC3300 }
            NSApp.appearance = NSAppearance(named: .aqua)

            let light = try ink(Theme.windowBackground, in: .aqua)
            let dark = try ink(Theme.windowBackground, in: .darkAqua)
            let darkGround = try hex(LoomChrome.sampledColor(nil, scheme: .dark))
            #expect(light != 0xFAFAFC, "the light variant changed")
            #expect(dark == 0x17171C, "the dark variant did not")
            #expect(darkGround == 0x1B1B20, "and it keeps the neutral dark ground")
        }
    }

    @Test func aSolidThemePaintsTheSidebarInItsOwnColorAndIgnoresTheWebsite() throws {
        try onApplication { settings in
            settings.themeID = "standard"
            let page = NSColor(srgbRed: 0, green: 0.2, blue: 1, alpha: 1)
            let standard = try hex(LoomChrome.sampledColor(page, scheme: .light))

            settings.themeID = "nord"
            let nord = try #require(ThemeCatalog.builtIn("nord")?.light)
            #expect(try hex(LoomChrome.sampledColor(page, scheme: .light)) == nord.window)
            #expect(try hex(LoomChrome.sampledColor(page, scheme: .light, isFloating: true)) == nord.sidebar)

            settings.themeID = "standard"
            #expect(try hex(LoomChrome.sampledColor(page, scheme: .light)) == standard)
        }
    }

    @Test func aChangedPaletteReplacesTheWebsiteTintAndResetBringsItBack() throws {
        try onApplication { settings in
            settings.themeID = "standard"
            let page = NSColor(srgbRed: 0, green: 0.2, blue: 1, alpha: 1)
            let sampled = LoomChrome.sampledColor(page, scheme: .light)

            var adjustment = settings.themeAdjustment
            adjustment.setBrightness(0.2, for: .light)
            settings.themeAdjustment = adjustment
            let before = try hex(sampled)
            let after = try hex(LoomChrome.sampledColor(page, scheme: .light))
            #expect(after != before)
            #expect(settings.userThemes.isEmpty, "brightness is a knob")

            settings.resetColors(scheme: .light)
            #expect(LoomChrome.sampledColor(page, scheme: .light) == sampled)
        }
    }

    @Test func editedInksWinOverTheDefaultsAndResetRemovesThem() throws {
        try onApplication { settings in
            settings.themeID = "standard"
            NSApp.appearance = NSAppearance(named: .aqua)
            #expect(Theme.controlOverride == nil && Theme.urlOverride == nil)

            settings.editColors(scheme: .light) {
                $0.icons = SidebarTextStyle(colorRGB: 0x00FF00, opacity: 0.4)
                $0.url = SidebarTextStyle(colorRGB: 0x0000FF, opacity: 0.7)
            }

            let controls = try #require(Theme.controlOverride.flatMap { NSColor($0).usingColorSpace(.sRGB) })
            let url = try #require(Theme.urlOverride.flatMap { NSColor($0).usingColorSpace(.sRGB) })
            #expect(settings.selectedTheme.light.icons == SidebarTextStyle(colorRGB: 0x00FF00, opacity: 0.4))
            let variant = settings.resolvedTheme.light
            let appearance = try #require(NSAppearance(named: .aqua))
            let grounds = [variant.window, variant.sidebar].map {
                SidebarRowStyle.srgb(Color(nsColor: $0.resolved(in: appearance)), scheme: .light)
            }
            let raw = SidebarRowStyle.srgb(Color(hex: 0x00FF00).opacity(0.4), scheme: .light)
            #expect(grounds.contains {
                SidebarRowStyle.contrast(ThemeReadability.composite(raw, on: $0), $0) < 3
            })
            let channels = [controls.redComponent, controls.greenComponent, controls.blueComponent]
            #expect(controls.alphaComponent == 1 && (channels.allSatisfy { $0 == 0 } || channels.allSatisfy { $0 == 1 }))
            for ground in grounds {
                #expect(SidebarRowStyle.contrast(ThemeReadability.composite(controls, on: ground), ground) >= 3)
            }
            #expect(url.blueComponent > 0.99 && abs(url.alphaComponent - 0.7) < 0.01)

            // Only the light variant has an ink, so a dark app keeps each surface's own.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            #expect(Theme.controlOverride == nil && Theme.urlOverride == nil)

            NSApp.appearance = NSAppearance(named: .aqua)
            settings.resetColors(scheme: .light)
            #expect(Theme.controlOverride == nil && Theme.urlOverride == nil)
        }
    }

    @Test func aPaletteChangeTurnsTheAccentAndSurfacesAsTheOldCustomizationDid() {
        let base = NSColor(srgbRed: 0.2, green: 0.25, blue: 0.3, alpha: 1)
        #expect(Theme.customized(base, change: PaletteChange(), isAccent: false) == base)
        let tint = PaletteChange(primary: 0xFF0000)
        let surface = Theme.customized(base, change: tint, isAccent: false).usingColorSpace(.sRGB)
        let accent = Theme.customized(base, change: tint, isAccent: true).usingColorSpace(.sRGB)
        #expect((surface?.redComponent ?? 0) > (surface?.greenComponent ?? 1))
        #expect(abs((surface?.brightnessComponent ?? 0) - base.brightnessComponent) < 0.01)
        #expect((accent?.redComponent ?? 0) > 0.99 && (accent?.greenComponent ?? 1) < 0.01)
        let brighter = Theme.customized(base, change: PaletteChange(brightness: 0.2), isAccent: false)
        #expect(brighter.brightnessComponent > base.brightnessComponent)
    }
}
