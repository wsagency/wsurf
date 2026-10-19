// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The eight old color presets, the theme each belongs to, and the mode each forced.
private nonisolated let legacyPresets: [(raw: String, theme: String, mode: String)] = [
    ("catppuccinLatte", "catppuccin", "light"), ("catppuccinMocha", "catppuccin", "dark"),
    ("gruvboxLight", "gruvbox", "light"), ("gruvboxDark", "gruvbox", "dark"),
    ("rosePineDawn", "rosePine", "light"), ("rosePine", "rosePine", "dark"),
    ("nord", "nord", "dark"), ("dracula", "dracula", "dark"),
]

struct ThemeMigrationTests {
    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func suite() throws -> (UserDefaults, String) {
        let name = "ThemeMigration-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test(arguments: [
        ("system", "system", "standard"), ("light", "light", "standard"), ("dark", "dark", "standard"),
        ("lightCalm", "light", "calm"), ("darkCalm", "dark", "calm"), ("nonsense", "system", "standard"),
    ])
    func everyLegacyModeMapsToAThemeAndAMode(raw: String, mode: String, theme: String) {
        let migrated = ThemeMigration.migrate(LegacyAppearance(mode: raw))

        #expect(migrated.colorMode.rawValue == mode)
        #expect(migrated.themeID == theme)
        #expect(migrated.userThemes.isEmpty)
        #expect(migrated.adjustments.isEmpty)
    }

    @Test(arguments: legacyPresets)
    func aPresetMapsToItsFamilyAndKeepsTheModeItForced(raw: String, theme: String, mode: String) {
        let customization = ThemeCustomization(brightness: 0.2, primary: SidebarTextStyle(colorRGB: 0xFF0000))
        let migrated = ThemeMigration.migrate(LegacyAppearance(
            mode: "darkCalm", preset: raw, customizations: ["darkCalm": customization, "light": customization]
        ))

        #expect(migrated.themeID == theme)
        #expect(migrated.colorMode.rawValue == mode)
        // The customizations the preset hid are kept, as copies that wait; the preset stays selected.
        #expect(migrated.userThemes.map(\.basedOn) == ["standard", "calm"])
    }

    @Test func customizationsOfEachBaseBecomeACopy() throws {
        let light = ThemeCustomization(
            hue: 0.1, primary: SidebarTextStyle(colorRGB: 0xCC3300),
            controls: SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.4),
            url: SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.7)
        )
        let legacy = LegacyAppearance(
            mode: "darkCalm",
            customizations: ["light": light, "darkCalm": ThemeCustomization(hue: -0.2)],
            textStyles: [
                "light.loaded": SidebarTextStyle(colorRGB: 0x112233, opacity: 0.8),
                "darkCalm.unloaded": SidebarTextStyle(colorRGB: 0xDDBBFF, opacity: 0.4),
            ]
        )
        let migrated = ThemeMigration.migrate(legacy)

        let standard = try #require(migrated.userThemes.first { $0.basedOn == "standard" })
        let calm = try #require(migrated.userThemes.first { $0.basedOn == "calm" })
        #expect(standard.name == "Standard copy" && calm.name == "Calm copy")
        #expect(standard.ground == .pageTinted && calm.ground == .softTinted)
        #expect(standard.light.hue == 0.1 && standard.light.primary == 0xCC3300)
        #expect(standard.light.icons == SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.4))
        #expect(standard.light.url == SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.7))
        #expect(standard.light.sidebarText == SidebarTextStyle(colorRGB: 0x112233, opacity: 0.8))
        #expect(standard.dark == ThemeVariant(), "the dark variant had no customization")
        #expect(calm.dark.hue == -0.2)
        #expect(calm.dark.unloadedText == SidebarTextStyle(colorRGB: 0xDDBBFF, opacity: 0.4))
        #expect(calm.light == ThemeCatalog.builtIn("calm")?.light)
        // Calm was the active base, so its copy is selected.
        #expect(migrated.themeID == calm.id)
    }

    @Test func theCopyOfTheActiveBaseIsSelected() throws {
        let migrated = ThemeMigration.migrate(LegacyAppearance(
            mode: "system", customizations: ["dark": ThemeCustomization(hue: 0.2)]
        ))

        let copy = try #require(migrated.userThemes.first)
        #expect(migrated.themeID == copy.id)
        #expect(migrated.colorMode == .system)
    }

    @Test func brightnessAloneStaysAnAdjustmentOfTheBuiltIn() {
        let migrated = ThemeMigration.migrate(LegacyAppearance(
            mode: "lightCalm",
            customizations: ["lightCalm": ThemeCustomization(brightness: 0.25), "dark": ThemeCustomization(brightness: -0.1)]
        ))

        #expect(migrated.userThemes.isEmpty)
        #expect(migrated.themeID == "calm")
        #expect(migrated.adjustments["calm"]?.lightBrightness == 0.25)
        #expect(migrated.adjustments["standard"]?.darkBrightness == -0.1)
        #expect(migrated.adjustments["standard"]?.lightBrightness == 0)
    }

    @Test func brightnessOfACustomizedVariantTravelsWithTheCopy() throws {
        let migrated = ThemeMigration.migrate(LegacyAppearance(customizations: [
            "light": ThemeCustomization(brightness: 0.3, hue: 0.1),
            "dark": ThemeCustomization(brightness: -0.2),
        ]))

        let copy = try #require(migrated.userThemes.first)
        #expect(migrated.adjustments[copy.id]?.lightBrightness == 0.3)
        #expect(migrated.adjustments[copy.id]?.darkBrightness == -0.2)
        #expect(migrated.adjustments["standard"] == nil, "the built-in theme stays as it was")
    }

    @Test func transparentWindowStyleBecomesGlassForEveryThemeButPresets() throws {
        let transparent = ThemeMigration.migrate(LegacyAppearance(
            customizations: ["light": ThemeCustomization(hue: 0.1)],
            loomStyle: "transparent", transparency: 0.8
        ))
        let copy = try #require(transparent.userThemes.first)
        for id in ["standard", "calm", copy.id] {
            #expect(transparent.adjustments[id]?.material == .glass, "\(id)")
            #expect(transparent.adjustments[id]?.glassOpacity == 0.8, "\(id)")
        }

        let preset = ThemeMigration.migrate(LegacyAppearance(preset: "nord", loomStyle: "transparent"))
        #expect(preset.themeID == "nord")
        #expect(preset.adjustments["nord"] == nil, "a preset was always solid")
        #expect(preset.adjustments["standard"]?.material == .glass, "the setting waits for the themes that use it")

        let standard = ThemeMigration.migrate(LegacyAppearance(loomStyle: "standard", transparency: 0.9))
        #expect(standard.adjustments.isEmpty)
    }

    @Test func malformedLegacyValuesFallBackWithoutLosingTheRest() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("sepia", forKey: "appearance.mode")
        defaults.set("neon", forKey: "appearance.themePreset")
        defaults.set(Double.nan, forKey: "appearance.transparency")
        // One customization is garbage and one is valid: the valid one is kept.
        let valid = String(decoding: try encoded(ThemeCustomization(hue: 0.2)), as: UTF8.self)
        defaults.set(Data(#"{"light":{"hue":"loud"},"dark":\#(valid)}"#.utf8), forKey: "appearance.themeCustomizations")
        defaults.set(Data("not json".utf8), forKey: "appearance.sidebar.textStyles")

        let legacy = LegacyAppearance.read(from: defaults)
        #expect(legacy.isExistingInstall)
        #expect(legacy.customizations.keys.sorted() == ["dark"])
        #expect(legacy.textStyles.isEmpty)
        #expect(legacy.transparency == nil)

        let migrated = ThemeMigration.migrate(legacy)
        #expect(migrated.colorMode == .system)
        let copy = try #require(migrated.userThemes.first)
        #expect(copy.dark.hue == 0.2)
        #expect(migrated.themeID == copy.id)
    }

    @Test func outOfRangeLegacyValuesAreBounded() throws {
        let migrated = ThemeMigration.migrate(LegacyAppearance(
            customizations: ["light": ThemeCustomization(brightness: 9, hue: .infinity)],
            loomStyle: "transparent", transparency: 7
        ))

        #expect(migrated.adjustments["standard"]?.glassOpacity == 1)
        #expect(migrated.adjustments["standard"]?.lightBrightness == 0.5)
        #expect(migrated.userThemes.isEmpty, "an infinite hue is dropped, leaving brightness alone")
    }

    @Test func aFreshInstallGetsTheDefaultTheme() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = BrowserSettings(defaults: defaults)

        #expect(settings.themeID == ThemeCatalog.defaultID)
        #expect(settings.colorMode == .system)
        #expect(settings.userThemes.isEmpty)
        #expect(settings.themeAdjustments.isEmpty)
        #expect(defaults.integer(forKey: "appearance.themes.version") == BrowserSettings.themesVersion)
    }

    @Test func anExistingInstallWithNoChangesKeepsStandard() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // Every install writes this key on its first launch, whatever else the person changed.
        defaults.set(true, forKey: "appearance.websiteTint")

        let settings = BrowserSettings(defaults: defaults)

        #expect(settings.themeID == "standard")
        #expect(settings.colorMode == .system)
        #expect(settings.userThemes.isEmpty)
    }

    @Test func anExistingInstallKeepsItsLookThroughTheSettingsInit() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("darkCalm", forKey: "appearance.mode")
        defaults.set("transparent", forKey: "appearance.loomStyle")
        defaults.set(0.3, forKey: "appearance.transparency")
        defaults.set(
            try encoded(["darkCalm": ThemeCustomization(primary: SidebarTextStyle(colorRGB: 0x884488))]),
            forKey: "appearance.themeCustomizations"
        )

        let settings = BrowserSettings(defaults: defaults)

        let copy = try #require(settings.userThemes.first)
        #expect(settings.themeID == copy.id)
        #expect(settings.colorMode == .dark)
        #expect(copy.dark.primary == 0x884488)
        #expect(settings.themeAdjustment.material == .glass)
        #expect(settings.themeAdjustment.glassOpacity == 0.3)
        #expect(settings.themeMaterial == .glass)
    }

    @Test func migrationRunsOnceAndLeavesLegacyKeysInPlace() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let customizations = try encoded(["light": ThemeCustomization(hue: 0.1)])
        defaults.set("light", forKey: "appearance.mode")
        defaults.set("rosePineDawn", forKey: "appearance.themePreset")
        defaults.set("transparent", forKey: "appearance.loomStyle")
        defaults.set(0.6, forKey: "appearance.transparency")
        defaults.set(customizations, forKey: "appearance.themeCustomizations")

        let first = BrowserSettings(defaults: defaults)
        #expect(first.themeID == "rosePine")

        // The old keys are as they were, so an older build still finds them.
        #expect(defaults.string(forKey: "appearance.mode") == "light")
        #expect(defaults.string(forKey: "appearance.themePreset") == "rosePineDawn")
        #expect(defaults.string(forKey: "appearance.loomStyle") == "transparent")
        #expect(defaults.double(forKey: "appearance.transparency") == 0.6)
        #expect(defaults.data(forKey: "appearance.themeCustomizations") == customizations)

        // A change to an old key after the migration is not read again.
        defaults.set("nord", forKey: "appearance.themePreset")
        let second = BrowserSettings(defaults: defaults)
        #expect(second.themeID == "rosePine")
        #expect(second.userThemes == first.userThemes)
        #expect(second.themeAdjustments == first.themeAdjustments)
    }

    @Test func migratedThemesSurviveARestart() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: "appearance.mode")
        defaults.set(
            try encoded(["dark": ThemeCustomization(brightness: 0.2, hue: 0.3)]),
            forKey: "appearance.themeCustomizations"
        )
        let first = BrowserSettings(defaults: defaults)

        let restored = BrowserSettings(defaults: defaults)

        #expect(restored.userThemes == first.userThemes)
        #expect(restored.themeAdjustments == first.themeAdjustments)
        #expect(restored.themeID == first.themeID)
        #expect(restored.colorMode == .dark)
        #expect(restored.themeAdjustment.darkBrightness == 0.2)
    }
}
