// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// Custom themes: made from the shown theme, given their own base colors, kept, reset and deleted. Every case owns
/// its settings and a throwaway defaults suite, so none of them touches the app-wide theme.
@MainActor
struct ThemeEditorTests {
    private let schemes = [ColorScheme.light, .dark]

    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("ThemeEditorTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
        settings.previewsEveryStep()
        try test(settings, defaults)
    }

    private func reopened(_ defaults: UserDefaults) -> BrowserSettings {
        BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
    }

    private func hex(_ color: NSColor) -> UInt32 {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((value * 255).rounded())
        }
        return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
    }

    private func hex(_ color: Color, _ scheme: ColorScheme) -> UInt32 {
        hex(SidebarRowStyle.srgb(color, scheme: scheme))
    }

    /// The base colors a person picks for one appearance of a custom theme.
    private func base(_ scheme: ColorScheme) -> ThemeVariant {
        var variant = ThemeVariant()
        if scheme == .dark {
            variant.window = 0x14110F
            variant.sidebar = 0x1D1916
            variant.surface = 0x2B2521
            variant.text = 0xF3E9DC
            variant.unloadedText = SidebarTextStyle(colorRGB: 0xD9C7B0, opacity: 0.8)
            variant.accent = 0xE9A23B
            variant.assistant = 0x52D1A6
        } else {
            variant.window = 0xFFF8E7
            variant.sidebar = 0xF3E9D2
            variant.surface = 0xFFFFFF
            variant.text = 0x2B2118
            variant.unloadedText = SidebarTextStyle(colorRGB: 0x4A3B2C, opacity: 0.8)
            variant.accent = 0xB3261E
            variant.assistant = 0x0B6B52
        }
        return variant
    }

    /// Edits the base colors the way the Colors panel does, one role at a time.
    private func paint(_ settings: BrowserSettings, _ scheme: ColorScheme) {
        let colors = base(scheme)
        settings.editColors(scheme: scheme) { $0.window = colors.window }
        settings.editColors(scheme: scheme) { $0.sidebar = colors.sidebar }
        settings.editColors(scheme: scheme) { $0.surface = colors.surface }
        settings.editColors(scheme: scheme) { $0.text = colors.text }
        settings.editColors(scheme: scheme) { $0.unloadedText = colors.unloadedText }
        settings.editColors(scheme: scheme) { $0.accent = colors.accent }
        settings.editColors(scheme: scheme) { $0.assistant = colors.assistant }
    }

    private let knobs = ThemeAdjustment(
        material: .glass, glassOpacity: 0.8, lightBrightness: 0.3, darkBrightness: -0.2, pageFrame: .hairline,
        rowFrame: FrameStyle.none, cornerScale: 0.4, loadedFavicons: .color, pageSpacing: 2, sidebarMargin: 3,
        rowPadding: 4, tabIconSize: 20, folderIndentLevel1: 10
    )

    // MARK: - Making and keeping one

    @Test func aCustomThemeIsMadeEditedRenamedAndDecodedAgain() throws {
        try withSettings { settings, defaults in
            settings.themeID = "nord"
            let nordKnobs = ThemeAdjustment(rowPadding: 4, folderIndentLevel1: 8)
            settings.themeAdjustment = nordKnobs
            let name = settings.customThemeName(for: settings.selectedTheme)
            #expect(name == "Nord Custom")

            let custom = try #require(settings.saveTheme(named: name))

            #expect(custom.name == "Nord Custom" && custom.basedOn == "nord" && settings.themeID == custom.id)
            #expect(custom.light == ThemeCatalog.builtIn("nord")?.light && custom.dark == ThemeCatalog.builtIn("nord")?.dark)
            #expect(settings.themeAdjustment == nordKnobs, "the knobs come along")

            for scheme in schemes {
                paint(settings, scheme)
            }

            #expect(settings.userThemes.count == 1, "editing a custom theme makes no other copy")
            let edited = settings.selectedTheme
            #expect(edited.id == custom.id && edited.name == "Nord Custom")
            #expect(edited.light.window == 0xFFF8E7 && edited.light.text == 0x2B2118 && edited.light.accent == 0xB3261E)
            #expect(edited.dark.sidebar == 0x1D1916 && edited.dark.surface == 0x2B2521 && edited.dark.assistant == 0x52D1A6)
            #expect(edited.dark.unloadedText == SidebarTextStyle(colorRGB: 0xD9C7B0, opacity: 0.8))
            #expect(ThemeCatalog.builtIn("nord")?.light.window == 0xECEFF4, "the built-in theme does not change")

            #expect(settings.renameTheme(custom.id, to: "  Harbor "))
            var renamed = edited
            renamed.name = "Harbor"
            #expect(settings.selectedTheme == renamed)

            let again = reopened(defaults)
            #expect(again.selectedTheme == renamed && again.themeAdjustment == nordKnobs)
            #expect(again.userThemes == [renamed])
            #expect(again.resolvedTheme.id == custom.id)

            let data = try JSONEncoder().encode(renamed)
            #expect(try JSONDecoder().decode(ThemeDefinition.self, from: data) == renamed)
        }
    }

    @Test func aThemeSavedBeforeCustomThemesDecodesAndDrawsAsItDid() throws {
        try withSettings { _, defaults in
            // What the theme settings looked like before this editor: no `basedOn` on one theme, fields this build
            // does not know on another, and a Calm copy that only changed hue.
            let old = """
            [{"id":"loose","name":"Loose","ground":"solid","light":{"window":16316666,"accent":3874257},"dark":{"hue":0.1}},
             {"id":"standard-copy","name":"Standard copy","basedOn":"standard","ground":"pageTinted",
              "light":{"hue":0.2,"future":true},"dark":{}},
             {"id":"calm-copy","name":"Calm copy","basedOn":"calm","ground":"softTinted",
              "light":{"window":14404809,"sidebar":13087677,"surface":15260121,"accent":11363210},
              "dark":{"window":2104622,"sidebar":1578532,"surface":3879754,"accent":13738434,"hue":0.1}}]
            """
            let adjustments = #"{"loose":{"material":"glass","glassOpacity":0.7},"calm-copy":{"darkBrightness":0.2}}"#
            defaults.set(Data(old.utf8), forKey: "appearance.themes.user")
            defaults.set(Data(adjustments.utf8), forKey: "appearance.themes.adjustments")
            defaults.set("calm-copy", forKey: "appearance.themeID")
            defaults.set(BrowserSettings.themesVersion, forKey: "appearance.themes.version")

            let loaded = reopened(defaults)

            #expect(loaded.userThemes.map(\.name).sorted() == ["Calm copy", "Loose", "Standard copy"])
            let loose = try #require(loaded.userThemes.first { $0.id == "loose" })
            #expect(loose.light.window == 16316666 && loose.light.accent == 3874257 && loose.dark.hue == 0.1)
            #expect(loose.light.text == nil && loose.basedOn == nil && loose.drawnGround == .solid)
            #expect(loaded.themeAdjustments["loose"]?.glassOpacity == 0.7 && loaded.themeAdjustments["loose"]?.folderIndentLevel1 == 0)
            // Their own colors, not an edit, so a copy of a tinted theme keeps its tint.
            let calm = try #require(loaded.userThemes.first { $0.id == "calm-copy" })
            let standard = try #require(loaded.userThemes.first { $0.id == "standard-copy" })
            // The copy was saved with no secondary text of its own (the 0.55 default), so only its colors are Calm's.
            let origin = try #require(ThemeCatalog.builtIn("calm")?.light)
            #expect([calm.light.window, calm.light.sidebar, calm.light.surface, calm.light.accent]
                == [origin.window, origin.sidebar, origin.surface, origin.accent] && calm.drawnGround == .softTinted)
            #expect(calm.dark.window == ThemeCatalog.builtIn("calm")?.dark.window && calm.dark.hue == 0.1)
            #expect(standard.drawnGround == .pageTinted && standard.light.hue == 0.2)
            #expect(loaded.themeID == "calm-copy" && loaded.resolvedTheme.ground == .softTinted)
            #expect(loaded.resolvedTheme.adjustment.darkBrightness == 0.2)
        }
    }

    // MARK: - What a custom theme draws

    @Test func theResolvedColorsAreTheCustomBaseColors() throws {
        try withSettings { settings, _ in
            settings.themeID = "gruvbox"
            let custom = try #require(settings.saveTheme(named: "Mine"))
            for scheme in schemes {
                paint(settings, scheme)
            }
            let resolved = settings.resolvedTheme
            #expect(resolved.id == custom.id && resolved.adjustment == ThemeAdjustment())

            for scheme in schemes {
                let colors = base(scheme)
                let variant = resolved.variant(scheme)
                #expect(hex(variant.window.srgb(scheme: scheme)) == colors.window)
                #expect(hex(variant.sidebar.srgb(scheme: scheme)) == colors.sidebar)
                #expect(hex(variant.surface.srgb(scheme: scheme)) == colors.surface)
                #expect(hex(variant.accent.srgb(scheme: scheme)) == colors.accent)
                #expect(hex(variant.assistant.srgb(scheme: scheme)) == colors.assistant)
                // Text that reads is drawn as it was picked, secondary text at its own opacity.
                #expect(hex(variant.loadedInk, scheme) == colors.text)
                #expect(hex(variant.unloadedInk, scheme) == colors.unloadedText.colorRGB)
                let unloaded = SidebarRowStyle.srgb(variant.unloadedInk, scheme: scheme)
                #expect(abs(unloaded.alphaComponent - 0.8) < 0.005)
            }

            // The colors every consumer reads, in the appearance they are drawn in.
            #expect(hex(resolved.windowBackground, .light) == 0xFFF8E7 && hex(resolved.windowBackground, .dark) == 0x14110F)
            #expect(hex(resolved.sidebarTint, .dark) == 0x1D1916 && hex(resolved.controlSurface, .light) == 0xFFFFFF)
            #expect(hex(resolved.accent, .light) == 0xB3261E && hex(resolved.assistant, .dark) == 0x52D1A6)
        }
    }

    @Test func theMiniatureShowsTheCustomBaseColors() throws {
        try withSettings { settings, _ in
            settings.themeID = "nord"
            _ = try #require(settings.saveTheme(named: "Mine"))
            for scheme in schemes {
                paint(settings, scheme)
            }
            let theme = settings.selectedTheme

            for scheme in schemes {
                let colors = base(scheme)
                let palette = ThemeThumbnailPalette(theme, adjustment: ThemeAdjustment(), scheme: scheme)
                #expect(hex(palette.backdrop, scheme) == colors.window)
                #expect(palette.sidebar.map { hex($0, scheme) } == colors.sidebar)
                #expect(hex(palette.surface, scheme) == colors.surface)
                #expect(hex(palette.accent, scheme) == colors.accent)
                #expect(hex(palette.primary, scheme) == colors.text)
            }
            #expect(settings.allThemes.contains { $0.id == theme.id }, "the picker lists it after the built-in themes")
            #expect(settings.allThemes.prefix(ThemeCatalog.builtIn.count).map(\.id) == ThemeCatalog.builtIn.map(\.id))
        }
    }

    @Test(arguments: ["standard", "calm"])
    func aCopyOfATintedThemeDrawsItsBaseColorsSolidOnlyOnceTheyDiffer(origin: String) throws {
        try withSettings { settings, _ in
            let original = try #require(ThemeCatalog.builtIn(origin))
            settings.themeID = origin
            let custom = try #require(settings.saveTheme(named: settings.customThemeName(for: settings.selectedTheme)))
            #expect(custom.name == "\(original.name) Custom")
            #expect(settings.resolvedTheme.ground == original.ground, "an untouched copy looks like its origin")

            // Text, accent and hue do not hide under a tint, so they leave it as it is.
            settings.editColors(scheme: .light) {
                $0.hue = 0.1
                $0.accent = 0x118833
                $0.text = 0x222222
            }
            #expect(settings.resolvedTheme.ground == original.ground)

            settings.editColors(scheme: .dark) { $0.window = 0x102030 }
            #expect(settings.resolvedTheme.ground == .solid, "a tint would hide the window color")
            #expect(settings.selectedTheme.ground == original.ground, "nothing is stored for it")
            #expect(hex(settings.resolvedTheme.variant(.dark).window.srgb(scheme: .dark)) == 0x102030)
            let palette = ThemeThumbnailPalette(settings.selectedTheme, adjustment: ThemeAdjustment(), scheme: .dark)
            #expect(hex(palette.backdrop, .dark) == 0x102030 && palette.sidebar != nil)
            #expect(WindowOpacity.isOpaque(
                ground: settings.resolvedTheme.ground, material: .plain, reduceTransparency: false, increaseContrast: false
            ))

            settings.editColors(scheme: .dark) { $0.window = original.dark.window }
            #expect(settings.resolvedTheme.ground == original.ground, "the original color puts the tint back")
        }
    }

    @Test func brightnessSlidersSpacingAndIndentKeepWorkingOnACustomTheme() throws {
        try withSettings { settings, defaults in
            settings.themeID = "dracula"
            _ = try #require(settings.saveTheme(named: "Mine"))
            for scheme in schemes {
                paint(settings, scheme)
            }
            #expect(hex(settings.resolvedTheme.variant(.dark).window.srgb(scheme: .dark)) == 0x14110F)

            settings.themeAdjustment = knobs

            let resolved = settings.resolvedTheme
            #expect(resolved.adjustment == knobs && resolved.adjustment.folderIndentLevel1 == 10)
            #expect(settings.chromeShape == ThemeShape(knobs))
            #expect(hex(resolved.variant(.dark).window.srgb(scheme: .dark)) != 0x14110F, "brightness is laid over the base color")
            #expect(settings.themeAdjustments[settings.selectedTheme.id] == knobs)
            #expect(reopened(defaults).themeAdjustment == knobs)

            settings.editColors(scheme: .light) { $0.url = SidebarTextStyle(colorRGB: 0x336699, opacity: 0.9) }
            #expect(settings.selectedTheme.light.url == SidebarTextStyle(colorRGB: 0x336699, opacity: 0.9))
            #expect(settings.themeAdjustment == knobs, "a color edit keeps the knobs")
        }
    }

    // MARK: - Names

    @Test func customNamesAreThemeCustomMadeUnique() throws {
        try withSettings { settings, _ in
            settings.themeID = "nord"
            #expect(settings.customThemeName(for: settings.selectedTheme) == "Nord Custom")
            _ = try #require(settings.saveTheme(named: settings.customThemeName(for: settings.selectedTheme)))
            settings.themeID = "nord"
            #expect(settings.customThemeName(for: settings.selectedTheme) == "Nord Custom 2")

            // The first color edit of a built-in theme makes the same kind of copy.
            settings.editColors(scheme: .light) { $0.accent = 0x123456 }

            #expect(settings.selectedTheme.name == "Nord Custom 2" && settings.selectedTheme.basedOn == "nord")
            #expect(ThemeCatalog.builtIn("nord")?.name == "Nord")
        }
    }

    // MARK: - Reset

    @Test func resettingABuiltInThemeRestoresItsKnobsAndNothingElse() throws {
        try withSettings { settings, defaults in
            settings.themeID = "gruvbox"
            settings.themeAdjustment = knobs
            settings.themeAdjustments["nord"] = ThemeAdjustment(material: .glass)
            #expect(settings.canResetTheme && settings.themeResetOrigin == nil)

            settings.resetSelectedTheme()

            #expect(settings.themeID == "gruvbox" && settings.themeAdjustment == ThemeAdjustment())
            #expect(settings.themeAdjustments["gruvbox"] == nil && !settings.canResetTheme)
            #expect(settings.themeAdjustments["nord"] == ThemeAdjustment(material: .glass), "another theme keeps its knobs")
            #expect(settings.userThemes.isEmpty, "a reset makes no copy")
            #expect(settings.resolvedTheme.adjustment == ThemeAdjustment())
            #expect(reopened(defaults).themeAdjustment == ThemeAdjustment())
        }
    }

    @Test func resettingACustomThemeRestoresTheThemeItCameFrom() throws {
        try withSettings { settings, defaults in
            settings.themeID = "nord"
            settings.themeAdjustment = ThemeAdjustment(material: .glass)
            let custom = try #require(settings.saveTheme(named: "Mine"))
            let neighbor = try #require(settings.duplicateTheme("nord"))
            settings.themeID = custom.id
            for scheme in schemes {
                paint(settings, scheme)
                settings.editColors(scheme: scheme) {
                    $0.hue = 0.2
                    $0.primary = 0x336699
                    $0.sidebarText = SidebarTextStyle(colorRGB: 0x123456, opacity: 0.3)
                    $0.icons = SidebarTextStyle(colorRGB: 0x654321, opacity: 0.5)
                }
            }
            settings.themeAdjustment = knobs
            #expect(settings.canResetTheme)
            let before = try #require(settings.userThemes.first { $0.id == neighbor.id })
            #expect(settings.themeResetOrigin?.id == "nord")

            settings.resetSelectedTheme()

            let nord = try #require(ThemeCatalog.builtIn("nord"))
            let restored = settings.selectedTheme
            #expect(restored.id == custom.id && restored.name == "Mine" && restored.basedOn == "nord")
            #expect(restored.light == nord.light && restored.dark == nord.dark && restored.ground == nord.ground)
            #expect(settings.themeAdjustment == ThemeAdjustment() && settings.themeAdjustments[custom.id] == nil)
            #expect(!settings.canResetTheme)
            #expect(settings.themeID == custom.id, "the theme stays selected")
            #expect(settings.userThemes.first { $0.id == neighbor.id } == before, "another custom theme is untouched")
            #expect(settings.themeAdjustments["nord"] == ThemeAdjustment(material: .glass), "so are the knobs of the built-in theme")

            let again = reopened(defaults)
            #expect(again.selectedTheme == restored && again.themeAdjustment == ThemeAdjustment())
        }
    }

    @Test func resettingACopyOfACopyGoesBackToTheBuiltInTheme() throws {
        try withSettings { settings, _ in
            settings.themeID = "catppuccin"
            let first = try #require(settings.saveTheme(named: "First"))
            paint(settings, .light)
            let second = try #require(settings.duplicateTheme(first.id))
            #expect(second.basedOn == "catppuccin" && second.light.window == 0xFFF8E7)

            settings.resetSelectedTheme()

            #expect(settings.selectedTheme.light == ThemeCatalog.builtIn("catppuccin")?.light)
            #expect(settings.userThemes.first { $0.id == first.id }?.light.window == 0xFFF8E7, "the first copy keeps its colors")
        }
    }

    @Test func resettingACustomThemeWithNoOriginResetsOnlyItsKnobs() throws {
        try withSettings { settings, _ in
            let loose = ThemeDefinition(id: "loose", name: "Loose", ground: .solid, light: ThemeVariant(window: 0x112233))
            settings.userThemes = [loose]
            settings.themeID = "loose"
            #expect(!settings.canResetTheme, "nothing to restore: the colors have no origin and the knobs are at default")

            settings.themeAdjustment = ThemeAdjustment(rowPadding: 3)
            #expect(settings.canResetTheme && settings.themeResetOrigin == nil)
            settings.resetSelectedTheme()

            #expect(settings.themeAdjustment == ThemeAdjustment() && settings.selectedTheme == loose)
        }
    }

    @Test func aResetDropsADragStillInFlight() throws {
        try withSettings { settings, _ in
            settings.themeID = "nord"
            settings.beginThemePreview()
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.4))
            #expect(settings.themePreview != nil)

            settings.resetSelectedTheme()

            #expect(settings.themePreview == nil && settings.resolvedTheme.adjustment == ThemeAdjustment())
        }
    }

    // MARK: - Delete

    @Test func deletingTheSelectedCustomThemeFallsBackToItsOrigin() throws {
        try withSettings { settings, defaults in
            settings.themeID = "dracula"
            let custom = try #require(settings.saveTheme(named: "Mine"))
            paint(settings, .dark)
            settings.themeAdjustment = knobs
            let copy = try #require(settings.duplicateTheme(custom.id))
            #expect(settings.themeID == copy.id && copy.basedOn == "dracula")

            settings.deleteTheme(copy.id)

            #expect(settings.themeID == "dracula" && settings.resolvedTheme.id == "dracula", "the origin, not the copy it was copied from")
            #expect(settings.userThemes.map(\.id) == [custom.id] && settings.themeAdjustments[copy.id] == nil)
            #expect(settings.themeAdjustments[custom.id] == knobs)

            settings.themeID = custom.id
            settings.deleteTheme(custom.id)

            #expect(settings.themeID == "dracula" && settings.userThemes.isEmpty && settings.themeAdjustments[custom.id] == nil)
            #expect(!settings.allThemes.contains { $0.id == custom.id })
            let again = reopened(defaults)
            #expect(again.themeID == "dracula" && again.userThemes.isEmpty && again.themeAdjustments[custom.id] == nil)
        }
    }

    // MARK: - Contrast

    /// A solid ground of one color in all three roles, so one ratio decides.
    private func variant(ground: UInt32, text: UInt32? = nil, secondary: SidebarTextStyle? = nil) -> ThemeVariant {
        var variant = ThemeVariant(window: ground, sidebar: ground, surface: ground, text: text)
        if let secondary {
            variant.unloadedText = secondary
        }
        return variant
    }

    private func shortfall(
        _ role: ThemeContrast.Role, _ variant: ThemeVariant, isDark: Bool = false, brightness: Double = 0
    ) -> ThemeContrast.Shortfall? {
        ThemeContrast.shortfall(role, in: variant, isDark: isDark, brightness: brightness, ground: .solid)
    }

    @Test func primaryTextWarnsExactlyBelowFourPointFive() {
        // On white, #767676 is 4.54:1 and #777777 is 4.48:1: the two neighbors on either side of the floor.
        #expect(shortfall(.primary, variant(ground: 0xFFFFFF, text: 0x767676)) == nil)
        let weak = shortfall(.primary, variant(ground: 0xFFFFFF, text: 0x777777))
        #expect(weak != nil && abs((weak?.ratio ?? 0) - 4.48) < 0.01)
        #expect(weak?.shownRatio == 4.4, "a 4.48 is cut to 4.4, never rounded up to the 4.5 it misses")
        #expect(shortfall(.primary, variant(ground: 0xFFFFFF, text: 0x000000)) == nil)
        // No text color means black in a light variant and white in a dark one.
        #expect(shortfall(.primary, variant(ground: 0xFFFFFF)) == nil)
        #expect(shortfall(.primary, variant(ground: 0x101010), isDark: true) == nil)
        #expect(shortfall(.primary, variant(ground: 0x101010), isDark: false)?.ground == .window)
    }

    @Test func theWarningNamesTheWeakestGround() {
        var colors = ThemeVariant(window: 0xFFFFFF, sidebar: 0xEEEEEE, surface: 0xFFFFFF, text: 0x777777)
        #expect(shortfall(.primary, colors)?.ground == .sidebar)
        colors.sidebar = 0xFFFFFF
        colors.surface = 0xF0F0F0
        #expect(shortfall(.primary, colors)?.ground == .surface)
        colors.surface = 0xFFFFFF
        colors.window = 0xF4F4F4
        #expect(shortfall(.primary, colors)?.ground == .window)
    }

    @Test func secondaryTextCountsItsOpacityAndFallsBackToTheTextColor() {
        let black = 0x000000 as UInt32
        // Black at 50 % on white is 4.0:1, at 60 % it is 5.7:1.
        #expect(shortfall(.secondary, variant(ground: 0xFFFFFF, text: black, secondary: SidebarTextStyle(opacity: 0.5))) != nil)
        #expect(shortfall(.secondary, variant(ground: 0xFFFFFF, text: black, secondary: SidebarTextStyle(opacity: 0.6))) == nil)
        // Its own color wins over the text color, and the text color alone makes no warning here.
        let grey = SidebarTextStyle(colorRGB: 0x999999, opacity: 1)
        #expect(shortfall(.secondary, variant(ground: 0xFFFFFF, text: black, secondary: grey))?.ground == .window)
        #expect(shortfall(.primary, variant(ground: 0xFFFFFF, text: black, secondary: grey)) == nil)
        // Only the window and the sidebar are its grounds: a black surface fails the primary text, not this one.
        var surfaceOnly = variant(ground: 0xFFFFFF, text: black, secondary: SidebarTextStyle(opacity: 1))
        surfaceOnly.surface = black
        #expect(shortfall(.secondary, surfaceOnly) == nil && shortfall(.primary, surfaceOnly)?.ground == .surface)
    }

    @Test func theWarningFollowsTheBrightnessAndLeavesTheColorsAlone() throws {
        let soft = variant(ground: 0xFFFFFF, text: 0x767676)
        #expect(shortfall(.primary, soft) == nil)
        #expect(shortfall(.primary, soft, brightness: -0.1) != nil, "a darker ground is a weaker ground for it")

        try withSettings { settings, _ in
            settings.themeID = "nord"
            settings.editColors(scheme: .light) {
                $0.window = 0xFFFFFF
                $0.sidebar = 0xFFFFFF
                $0.surface = 0xFFFFFF
                $0.text = 0x999999
            }
            let theme = settings.selectedTheme
            let warning = ThemeContrast.shortfall(
                .primary, in: theme.light, isDark: false, brightness: 0, ground: theme.drawnGround
            )

            #expect(warning != nil && theme.light.text == 0x999999, "the choice is kept as it was made")
            let drawn = hex(settings.resolvedTheme.variant(.light).loadedInk, .light)
            #expect(drawn != 0x999999, "what is drawn still stays readable, through the guard that was there")
            #expect(theme.light.window == 0xFFFFFF && theme.light.unloadedText == ThemeCatalog.builtIn("nord")?.light.unloadedText)
        }
    }

    @Test func noSolidBuiltInThemeWarnsAboutItsPrimaryText() {
        var checked = 0
        for theme in ThemeCatalog.builtIn where theme.ground == .solid {
            for scheme in schemes {
                let found = ThemeContrast.shortfall(
                    .primary, in: theme.variant(scheme), isDark: scheme == .dark, brightness: 0, ground: theme.ground
                )
                #expect(found == nil, "\(theme.id) \(scheme) primary text")
                checked += 1
            }
        }
        #expect(checked == 12)
    }

    // MARK: - Search

    /// Save as Theme and Customize made the same copy, so there is one row, Customize. The words of the old row find it.
    @Test func saveAsThemeIsFoundOnTheCustomizeRow() {
        #expect(!SettingsIndex.all.contains { $0.id == "appearance.savedThemes" })
        for query in ["save", "save as theme", "rename", "duplicate", "delete"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "appearance.customize" }, "\(query)")
        }
    }

    @Test func searchFindsCustomizeAndResetTheme() throws {
        for query in ["customize", "custom theme", "own theme"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "appearance.customize" }, "\(query)")
        }
        for query in ["reset theme", "restore", "defaults"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "appearance.resetTheme" }, "\(query)")
        }
        for query in ["secondary text", "window background", "surface"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "appearance.colors" }, "\(query)")
        }
        let reset = try #require(SettingsIndex.all.first { $0.id == "appearance.resetTheme" })
        #expect(reset.targetAnchor == "appearance.resetTheme")
    }
}
