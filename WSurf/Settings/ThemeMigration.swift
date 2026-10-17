// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The stored format of the per-appearance customizations from before themes had variants. Only the migration
/// reads it: the keys stay in place, so an older build still finds them.
struct ThemeCustomization: Codable, Equatable {
    var brightness: Double = 0
    var hue: Double = 0
    var primary = SidebarTextStyle()
    var controls = SidebarTextStyle()
    var url = SidebarTextStyle()

    func bounded() -> Self {
        var result = self
        result.brightness = brightness.isFinite ? min(max(brightness, -0.5), 0.5) : 0
        result.hue = hue.isFinite ? min(max(hue, -0.5), 0.5) : 0
        result.primary = primary.bounded(defaultOpacity: 1)
        result.controls = controls.bounded(defaultOpacity: 1)
        result.url = url.bounded(defaultOpacity: 1)
        return result
    }
}

/// The appearance settings of an install that predates themes, as the old keys stored them.
struct LegacyAppearance {
    /// False for a fresh install, which starts with the default theme.
    var isExistingInstall = true
    var mode: String?
    var preset: String?
    var customizations: [String: ThemeCustomization] = [:]
    var textStyles: [String: SidebarTextStyle] = [:]
    var loomStyle: String?
    var transparency: Double?

    /// Reads the old keys. A malformed entry is dropped alone; the rest is kept.
    static func read(from defaults: UserDefaults) -> Self {
        func decode<Value: Decodable>(_ key: String, as _: Value.Type) -> [String: Value] {
            guard let data = defaults.data(forKey: key),
                  let stored = try? JSONDecoder().decode([String: LenientDecodable<Value>].self, from: data)
            else { return [:] }
            return stored.compactMapValues(\.value)
        }
        let keys = BrowserSettings.Key.self
        let transparency = (defaults.object(forKey: keys.transparency) as? NSNumber)?.doubleValue
        return Self(
            isExistingInstall: BrowserSettings.legacyAppearanceKeys.contains { defaults.object(forKey: $0) != nil },
            mode: defaults.string(forKey: keys.appearance),
            preset: defaults.string(forKey: keys.themePreset),
            customizations: decode(keys.themeCustomizations, as: ThemeCustomization.self),
            textStyles: decode(keys.sidebarTextStyles, as: SidebarTextStyle.self),
            loomStyle: defaults.string(forKey: keys.loomStyle),
            transparency: transparency.flatMap { $0.isFinite ? $0 : nil }
        )
    }
}

/// A value that decodes to nil instead of failing, so one bad entry of a dictionary or array does not hide the rest.
struct LenientDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct MigratedAppearance: Equatable {
    var colorMode: AppearanceMode
    var themeID: String
    var userThemes: [ThemeDefinition]
    var adjustments: [String: ThemeAdjustment]
}

/// Turns the five appearances, the eight color presets and the per-appearance customizations into themes without
/// losing a color: `ThemeGoldenTests` holds the proof.
enum ThemeMigration {
    /// A preset becomes the family it belongs to, in the appearance it was drawn in.
    private static let families: [String: (theme: String, isDark: Bool)] = [
        "catppuccinLatte": ("catppuccin", false), "catppuccinMocha": ("catppuccin", true),
        "gruvboxLight": ("gruvbox", false), "gruvboxDark": ("gruvbox", true),
        "rosePineDawn": ("rosePine", false), "rosePine": ("rosePine", true),
        "nord": ("nord", true), "dracula": ("dracula", true),
    ]

    static func migrate(_ legacy: LegacyAppearance) -> MigratedAppearance {
        guard legacy.isExistingInstall else {
            return MigratedAppearance(colorMode: .system, themeID: ThemeCatalog.defaultID, userThemes: [], adjustments: [:])
        }
        let family = legacy.preset.flatMap { families[$0] }
        let isCalm = legacy.mode == "lightCalm" || legacy.mode == "darkCalm"
        let mode: AppearanceMode
        if let family {
            mode = family.isDark ? .dark : .light
        } else {
            switch legacy.mode {
            case "light", "lightCalm":
                mode = .light
            case "dark", "darkCalm":
                mode = .dark
            default:
                mode = .system
            }
        }

        var themeID = family?.theme ?? (isCalm ? ThemeCatalog.calmID : ThemeCatalog.standardID)
        var userThemes: [ThemeDefinition] = []
        var adjustments: [String: ThemeAdjustment] = [:]
        let glass = legacy.loomStyle == "transparent"
        let opacity = legacy.transparency.map { min(max($0, 0), 1) } ?? 0.5

        // Standard and Calm each had their own customizations, whether or not they were the active one.
        for (id, keys) in [(ThemeCatalog.standardID, ("light", "dark")), (ThemeCatalog.calmID, ("lightCalm", "darkCalm"))] {
            guard let base = ThemeCatalog.builtIn(id) else { continue }
            let light = customized(base.light, key: keys.0, legacy)
            let dark = customized(base.dark, key: keys.1, legacy)
            var adjustment = ThemeAdjustment()
            if glass {
                adjustment.material = .glass
                adjustment.glassOpacity = opacity
            }
            if light.changesColors || dark.changesColors {
                var copy = ThemeDefinition(
                    id: UUID().uuidString, name: String(localized: "\(base.name) copy"), basedOn: id,
                    ground: base.ground, light: light.variant, dark: dark.variant
                )
                copy.name = ThemeNames.unique(copy.name, among: userThemes.map(\.name))
                var carried = adjustment
                carried.lightBrightness = light.brightness
                carried.darkBrightness = dark.brightness
                adjustments[copy.id] = carried.bounded()
                userThemes.append(copy.bounded())
                if family == nil, themeID == id {
                    themeID = copy.id
                }
                if adjustment != ThemeAdjustment() {
                    adjustments[id] = adjustment.bounded()
                }
            } else {
                adjustment.lightBrightness = light.brightness
                adjustment.darkBrightness = dark.brightness
                if adjustment != ThemeAdjustment() {
                    adjustments[id] = adjustment.bounded()
                }
            }
        }
        return MigratedAppearance(colorMode: mode, themeID: themeID, userThemes: userThemes, adjustments: adjustments)
    }

    /// `base` with the customizations stored under `key` laid over it.
    private static func customized(
        _ base: ThemeVariant, key: String, _ legacy: LegacyAppearance
    ) -> (variant: ThemeVariant, brightness: Double, changesColors: Bool) {
        let customization = (legacy.customizations[key] ?? ThemeCustomization()).bounded()
        var variant = base
        variant.hue = customization.hue
        variant.primary = customization.primary.colorRGB
        variant.icons = customization.controls
        variant.url = customization.url
        if let loaded = legacy.textStyles["\(key).loaded"] {
            variant.sidebarText = loaded.bounded(defaultOpacity: 1)
        }
        if let unloaded = legacy.textStyles["\(key).unloaded"] {
            variant.unloadedText = unloaded.bounded(defaultOpacity: ThemeVariant.unloadedOpacity)
        }
        return (variant.bounded(), customization.brightness, variant.bounded() != base.bounded())
    }
}

enum ThemeNames {
    /// `name` trimmed to the limit and made different from every name in `taken`, ignoring case.
    static func unique(_ name: String, among taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String((trimmed.isEmpty ? String(localized: "Theme") : trimmed).prefix(ThemeDefinition.nameLimit))
        var candidate = base
        var number = 2
        while used.contains(candidate.lowercased()) {
            let suffix = " \(number)"
            candidate = String(base.prefix(ThemeDefinition.nameLimit - suffix.count)) + suffix
            number += 1
        }
        return candidate
    }
}
