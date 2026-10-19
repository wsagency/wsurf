// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI

/// The theme settings. Colors are the theme and knobs are the person's: changing a color of a built-in theme makes
/// a copy, while brightness, material and shape are stored per theme id and never do.
extension BrowserSettings {
    static let userThemeLimit = 200
    /// Written once the old appearance settings have been turned into themes.
    static let themesVersion = 2

    /// The old keys. A fresh install has none of them; they are read once and never written or removed.
    static let legacyAppearanceKeys = [
        Key.appearance, Key.themePreset, Key.themeCustomizations, Key.sidebarTextStyles, Key.loomStyle,
        Key.transparency, Key.websiteTint, Key.websiteColor,
    ]

    // MARK: - Stored settings

    /// System, Light or Dark: which variant of the theme the window shows.
    var colorMode: AppearanceMode {
        get { globalValue(\.colorMode, storage: storedColorMode) }
        set {
            setGlobal(\BrowserSettings.colorMode, storage: \BrowserSettings.storedColorMode, value: newValue,
                      key: Key.colorMode, encode: { $0.rawValue }) { $0.applyAppearance() }
        }
    }

    /// The selected theme. An id that names no theme falls back to the default theme.
    var themeID: String {
        get { globalValue(\.themeID, storage: storedThemeID) }
        set {
            setGlobal(\BrowserSettings.themeID, storage: \BrowserSettings.storedThemeID, value: newValue,
                      key: Key.themeID, didChange: {
                          $0.themePreview = nil
                          $0.refreshTheme()
                      })
        }
    }

    /// The themes the person saved or that a copy made.
    var userThemes: [ThemeDefinition] {
        get { globalValue(\.userThemes, storage: storedUserThemes) }
        set {
            setGlobal(\BrowserSettings.userThemes, storage: \BrowserSettings.storedUserThemes,
                      value: Self.normalized(newValue), key: Key.userThemes, encode: { try? JSONEncoder().encode($0) }) {
                $0.refreshTheme()
            }
        }
    }

    /// The knobs, by theme id. A theme without an entry has the default knobs.
    var themeAdjustments: [String: ThemeAdjustment] {
        get { globalValue(\.themeAdjustments, storage: storedThemeAdjustments) }
        set {
            setGlobal(\BrowserSettings.themeAdjustments, storage: \BrowserSettings.storedThemeAdjustments,
                      value: newValue.mapValues { $0.bounded() }, key: Key.themeAdjustments,
                      encode: { try? JSONEncoder().encode($0) }) { $0.refreshTheme() }
        }
    }

    // MARK: - The selected theme

    var allThemes: [ThemeDefinition] {
        ThemeCatalog.builtIn + userThemes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var selectedTheme: ThemeDefinition {
        let id = themeID
        return userThemes.first { $0.id == id } ?? ThemeCatalog.builtIn(id) ?? ThemeCatalog.fallback
    }

    /// The knobs of the selected theme. Setting them never makes a copy.
    var themeAdjustment: ThemeAdjustment {
        get {
            let id = selectedTheme.id
            if let preview = globalSettings.themePreview, preview.themeID == id {
                return preview.adjustment
            }
            return themeAdjustments[id] ?? ThemeAdjustment()
        }
        set {
            let hadPreview = globalSettings.themePreview != nil
            globalSettings.themePreview = nil
            var adjustments = themeAdjustments
            let bounded = newValue.bounded()
            adjustments[selectedTheme.id] = bounded == ThemeAdjustment() ? nil : bounded
            themeAdjustments = adjustments
            if hadPreview || globalSettings.themeCache?.adjustment != bounded {
                globalSettings.refreshTheme()
            }
        }
    }

    /// The selected theme with its knobs applied, for both appearances. Every chrome color reads this cache, which
    /// is rebuilt only when the theme, a saved theme or an adjustment changes.
    var resolvedTheme: ResolvedTheme {
        let settings = globalSettings
        // Reading these registers the observation of the caller; the cache itself is not observed.
        let id = themeID
        let themes = userThemes
        let adjustments = themeAdjustments
        let preview = settings.themePreview
        if let cached = settings.themeCache {
            return cached
        }
        let selected = themes.first { $0.id == id } ?? ThemeCatalog.builtIn(id) ?? ThemeCatalog.fallback
        let theme = preview?.applying(to: selected) ?? selected
        let adjustment: ThemeAdjustment
        if let preview, preview.themeID == selected.id {
            adjustment = preview.adjustment
        } else {
            adjustment = adjustments[selected.id] ?? ThemeAdjustment()
        }
        let resolved = ResolvedTheme(theme, adjustment: adjustment)
        settings.themeCache = resolved
        return resolved
    }

    // MARK: - Material

    var themeMaterial: ThemeMaterial {
        get { themeAdjustment.material }
        set {
            var adjustment = themeAdjustment
            adjustment.material = newValue
            themeAdjustment = adjustment
        }
    }

    var transparency: Double {
        get { themeAdjustment.glassOpacity }
        set {
            var adjustment = themeAdjustment
            adjustment.glassOpacity = newValue
            themeAdjustment = adjustment.bounded()
        }
    }

    // MARK: - Editing

    /// Applies `edit` to the colors the window shows for `scheme`. A built-in theme is read-only, so the first edit
    /// copies it, with its knobs, selects the copy and edits that. The copy limit makes an edit a no-op.
    func editColors(scheme: ColorScheme, _ edit: (inout ThemeVariant) -> Void) {
        var theme = selectedTheme
        let wasBuiltIn = ThemeCatalog.isBuiltIn(theme.id)
        if wasBuiltIn {
            guard userThemes.count < Self.userThemeLimit else { return }
            theme.basedOn = theme.id
            theme.id = UUID().uuidString
            theme.name = ThemeNames.unique(String(localized: "\(theme.name) copy"), among: allThemes.map(\.name))
        }
        var variant = theme.variant(scheme)
        edit(&variant)
        theme.setVariant(variant, for: scheme)
        if wasBuiltIn {
            let adjustment = themeAdjustment
            userThemes += [theme]
            themeAdjustments[theme.id] = adjustment == ThemeAdjustment() ? nil : adjustment
            themeID = theme.id
        } else {
            userThemes = userThemes.map { $0.id == theme.id ? theme : $0 }
        }
    }

    /// Restores the colors and the brightness of the shown variant: a copy takes the colors of the built-in theme
    /// it came from, and a built-in theme only has its brightness to reset.
    func resetColors(scheme: ColorScheme) {
        var adjustment = themeAdjustment
        adjustment.setBrightness(0, for: scheme)
        themeAdjustment = adjustment
        let theme = selectedTheme
        guard !ThemeCatalog.isBuiltIn(theme.id), let original = theme.basedOn.flatMap(ThemeCatalog.builtIn) else { return }
        var restored = theme
        restored.setVariant(original.variant(scheme), for: scheme)
        userThemes = userThemes.map { $0.id == restored.id ? restored : $0 }
    }

    // MARK: - Loading

    /// The saved themes as they are stored: bounded, within the limit, with ids and names that cannot clash.
    static func normalized(_ themes: [ThemeDefinition]) -> [ThemeDefinition] {
        var result: [ThemeDefinition] = []
        var ids = Set(ThemeCatalog.builtIn.map(\.id))
        var names = ThemeCatalog.builtIn.map(\.name)
        for theme in themes where result.count < userThemeLimit && !theme.id.isEmpty && ids.insert(theme.id).inserted {
            var bounded = theme.bounded()
            bounded.name = ThemeNames.unique(bounded.name, among: names)
            names.append(bounded.name)
            result.append(bounded)
        }
        return result
    }

    static func decodeUserThemes(_ data: Data?) -> [ThemeDefinition] {
        guard let data, let stored = try? JSONDecoder().decode([LenientDecodable<ThemeDefinition>].self, from: data) else {
            return []
        }
        return normalized(stored.compactMap(\.value))
    }

    static func decodeThemeAdjustments(_ data: Data?) -> [String: ThemeAdjustment] {
        guard let data,
              let stored = try? JSONDecoder().decode([String: LenientDecodable<ThemeAdjustment>].self, from: data)
        else { return [:] }
        return stored.compactMapValues { $0.value?.bounded() }
    }

    /// The theme settings of this install: stored ones once they exist, otherwise the migration of the old
    /// appearance settings. The migration writes the new keys and leaves the old ones as they are.
    static func loadThemeSettings(from defaults: UserDefaults) -> MigratedAppearance {
        let keys = Key.self
        if defaults.integer(forKey: keys.themesVersion) >= themesVersion {
            return MigratedAppearance(
                colorMode: defaults.string(forKey: keys.colorMode).flatMap(AppearanceMode.init(rawValue:)) ?? .system,
                themeID: defaults.string(forKey: keys.themeID) ?? ThemeCatalog.defaultID,
                userThemes: decodeUserThemes(defaults.data(forKey: keys.userThemes)),
                adjustments: decodeThemeAdjustments(defaults.data(forKey: keys.themeAdjustments))
            )
        }
        let migrated = ThemeMigration.migrate(LegacyAppearance.read(from: defaults))
        defaults.set(migrated.colorMode.rawValue, forKey: keys.colorMode)
        defaults.set(migrated.themeID, forKey: keys.themeID)
        defaults.set(try? JSONEncoder().encode(migrated.userThemes), forKey: keys.userThemes)
        defaults.set(try? JSONEncoder().encode(migrated.adjustments), forKey: keys.themeAdjustments)
        defaults.set(themesVersion, forKey: keys.themesVersion)
        return migrated
    }
}
