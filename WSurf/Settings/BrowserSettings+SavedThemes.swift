// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Saved themes: copies of a theme, with both appearances and every knob, that the person names and keeps. They are
/// the same `ThemeDefinition` as a copy made by editing a built-in theme, so they preview, resolve and persist
/// through the same path.
extension BrowserSettings {
    /// True while the saved themes are below `userThemeLimit`.
    var canSaveAnotherTheme: Bool {
        userThemes.count < Self.userThemeLimit
    }

    /// Saves a copy of the theme `id` (the selected theme when nil) with its colors and knobs under `name`, and
    /// selects it. A name that is empty becomes "<theme> copy"; a name that is taken gets a number. Returns nil
    /// when the saved themes are at the limit or `id` names no theme.
    @discardableResult
    func saveTheme(named name: String, from id: String? = nil) -> ThemeDefinition? {
        // The copy is exactly what the window shows, including a color or slider still being dragged.
        commitThemePreview()
        guard canSaveAnotherTheme else { return nil }
        let source: ThemeDefinition
        if let id {
            guard let named = allThemes.first(where: { $0.id == id }) else { return nil }
            source = named
        } else {
            source = selectedTheme
        }
        var theme = source
        theme.id = UUID().uuidString
        theme.basedOn = ThemeCatalog.isBuiltIn(source.id) ? source.id : source.basedOn
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        theme.name = ThemeNames.unique(wanted.isEmpty ? String(localized: "\(source.name) copy") : wanted, among: allThemes.map(\.name))
        theme = theme.bounded()
        let adjustment = themeAdjustments[source.id] ?? ThemeAdjustment()
        userThemes += [theme]
        if adjustment != ThemeAdjustment() {
            themeAdjustments[theme.id] = adjustment
        }
        themeID = theme.id
        return theme
    }

    /// Saves a copy of the theme `id` as "<name> copy" and selects it.
    @discardableResult
    func duplicateTheme(_ id: String) -> ThemeDefinition? {
        saveTheme(named: "", from: id)
    }

    /// Gives a saved theme another name: trimmed, and different from every other theme's. Built-in themes are
    /// read-only, and a name with nothing in it changes nothing.
    @discardableResult
    func renameTheme(_ id: String, to name: String) -> Bool {
        guard let index = userThemes.firstIndex(where: { $0.id == id }) else { return false }
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        var themes = userThemes
        themes[index].name = ThemeNames.unique(wanted, among: allThemes.filter { $0.id != id }.map(\.name))
        userThemes = themes
        return true
    }

    /// The built-in theme the shown theme goes back to on Reset Theme to Default: the one a custom theme was made
    /// from. nil for a built-in theme, which has no colors of its own to restore, and for a custom theme that
    /// names no built-in theme, whose colors then stay as they are.
    var themeResetOrigin: ThemeDefinition? {
        let theme = selectedTheme
        guard !ThemeCatalog.isBuiltIn(theme.id) else { return nil }
        return theme.basedOn.flatMap(ThemeCatalog.builtIn)
    }

    /// False when the shown theme already is its defaults: no knob moved and, for a custom theme, no color changed.
    var canResetTheme: Bool {
        if themeAdjustment != ThemeAdjustment() {
            return true
        }
        guard let origin = themeResetOrigin else { return false }
        let theme = previewedTheme
        return theme.light.bounded() != origin.light.bounded() || theme.dark.bounded() != origin.dark.bounded()
    }

    /// Puts the selected theme back to its defaults, both appearances at once: every knob (brightness, glass opacity,
    /// spacing, indent, edges, corners, icons) to the default, and for a custom theme its colors, including their
    /// opacities, to those of the theme it was made from. A built-in theme only has its knobs to reset. The name
    /// and the saved themes list stay. Settings have no undo, so the caller confirms first.
    func resetSelectedTheme() {
        cancelThemePreview()
        let theme = selectedTheme
        if let origin = themeResetOrigin {
            var restored = theme
            restored.light = origin.light
            restored.dark = origin.dark
            restored.ground = origin.ground
            userThemes = userThemes.map { $0.id == theme.id ? restored : $0 }
        }
        var adjustments = themeAdjustments
        adjustments[theme.id] = nil
        themeAdjustments = adjustments
    }

    /// Deletes a saved theme and its knobs. When it is the selected theme, the window moves to the built-in theme
    /// it came from, or to the default theme.
    func deleteTheme(_ id: String) {
        guard let theme = userThemes.first(where: { $0.id == id }) else { return }
        if themeID == id {
            themeID = theme.basedOn.flatMap(ThemeCatalog.builtIn)?.id ?? ThemeCatalog.defaultID
        }
        userThemes = userThemes.filter { $0.id != id }
        var adjustments = themeAdjustments
        adjustments[id] = nil
        themeAdjustments = adjustments
    }
}
