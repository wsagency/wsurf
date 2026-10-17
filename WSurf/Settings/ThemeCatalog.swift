// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The built-in themes. They are read-only: a change to their colors makes a copy (`BrowserSettings.editColors`),
/// while their knobs live in `ThemeAdjustment`. Every color is an exact value from the palette's own published
/// definition; see NOTICE and Acknowledgements for the licenses.
enum ThemeCatalog {
    static let standardID = "standard"
    static let calmID = "calm"
    /// The theme a fresh install starts with, and the one a missing theme id falls back to. Existing installs
    /// keep the theme they had: `ThemeMigration` picks it from their old settings.
    static let defaultID = standardID

    static func builtIn(_ id: String) -> ThemeDefinition? {
        builtIn.first { $0.id == id }
    }

    static func isBuiltIn(_ id: String) -> Bool {
        builtIn.contains { $0.id == id }
    }

    /// The theme that stands in for an id that names no theme.
    static var fallback: ThemeDefinition {
        builtIn(defaultID) ?? builtIn[0]
    }

    static let builtIn: [ThemeDefinition] = [
        // Standard has no colors of its own: nil is the adaptive value Standard has always drawn. Calm's are the 8-bit
        // sRGB values of the colors it always drew; the earlier ones were floating point.
        ThemeDefinition(id: standardID, name: String(localized: "Standard"), ground: .pageTinted),
        ThemeDefinition(
            id: calmID, name: String(localized: "Calm"), ground: .softTinted,
            light: ThemeVariant(window: 0xDBCCC9, sidebar: 0xC7B3BD, surface: 0xE8D9D9, accent: 0xAD638A),
            dark: ThemeVariant(window: 0x201D2E, sidebar: 0x181624, surface: 0x3B334A, accent: 0xD1A1C2)
        ),
        ThemeDefinition(
            id: "catppuccin", name: String(localized: "Catppuccin"), ground: .solid,
            light: palette(0xEFF1F5, 0xE6E9EF, 0xCCD0DA, 0x8839EF, 0x4C4F69, unloaded: lightUnloaded),
            dark: palette(0x1E1E2E, 0x181825, 0x313244, 0xCBA6F7, 0xCDD6F4, unloaded: darkUnloaded)
        ),
        ThemeDefinition(
            id: "gruvbox", name: String(localized: "Gruvbox"), ground: .solid,
            light: palette(0xFBF1C7, 0xF2E5BC, 0xEBDBB2, 0x076678, 0x3C3836, unloaded: lightUnloaded),
            dark: palette(0x282828, 0x1D2021, 0x3C3836, 0x83A598, 0xEBDBB2, unloaded: darkUnloaded)
        ),
        ThemeDefinition(
            id: "rosePine", name: String(localized: "Rosé Pine"), ground: .solid,
            light: palette(0xFAF4ED, 0xF2E9E1, 0xFFFAF3, 0x286983, 0x575279, unloaded: lightUnloaded),
            dark: palette(0x1F1D2E, 0x191724, 0x26233A, 0xC4A7E7, 0xE0DEF4, unloaded: darkUnloaded)
        ),
        ThemeDefinition(
            id: "nord", name: String(localized: "Nord"), ground: .solid,
            light: palette(0xECEFF4, 0xE5E9F0, 0xD8DEE9, 0x5E81AC, 0x2E3440, unloaded: lightUnloaded),
            dark: palette(0x3B4252, 0x2E3440, 0x434C5E, 0x88C0D0, 0xD8DEE9, unloaded: darkUnloaded)
        ),
        ThemeDefinition(
            id: "dracula", name: String(localized: "Dracula"), ground: .solid,
            light: palette(0xFFFBEB, 0xFFFBEB, 0xCFCFDE, 0x644AC9, 0x1F1F1F, unloaded: lightUnloaded),
            dark: palette(0x282A36, 0x282A36, 0x44475A, 0xBD93F9, 0xF8F8F2, unloaded: darkUnloaded)
        ),
    ]

    /// Dimming for unloaded tabs. Every variant keeps 4.5:1 text contrast on its sidebar; the light palettes need
    /// more ink, and Rosé Pine Dawn sets the floor.
    private static let lightUnloaded = 0.88
    private static let darkUnloaded = 0.65

    /// sRGB hex values: window, sidebar, control surface, accent, text.
    ///
    /// Sources: Catppuccin palette 1.8.0 (Latte and Mocha: base, mantle, surface0, mauve, text); Nord (dark: nord1,
    /// nord0, nord2, nord8, nord4; light, Snow Storm: nord6, nord5, nord4, nord10, nord0); Dracula (dark:
    /// background, selection, purple, foreground; light, Alucard from draculatheme.com/spec: background,
    /// selection, purple, foreground); Gruvbox as published in tinted-theming/schemes spec-0.11 (light:
    /// light-medium base00, light-soft base00, base01, base0D, base06; dark: dark-medium base00, dark-hard
    /// base00, base01, base0D, base06); Rosé Pine @rose-pine/palette 4.0.1 `dist/index.js` (dawn text is 575279
    /// there; the repository's palette.json still lists the older 464261).
    private static func palette(
        _ window: UInt32, _ sidebar: UInt32, _ surface: UInt32, _ accent: UInt32, _ text: UInt32,
        unloaded: Double
    ) -> ThemeVariant {
        ThemeVariant(
            window: window, sidebar: sidebar, surface: surface, accent: accent, text: text,
            unloadedText: SidebarTextStyle(opacity: unloaded)
        )
    }
}
