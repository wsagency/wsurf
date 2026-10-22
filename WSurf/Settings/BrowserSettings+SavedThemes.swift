// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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
