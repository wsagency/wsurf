// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// Saving, duplicating, renaming and deleting the person's own themes. Every case owns its settings and a throwaway
/// defaults suite, so none of them touches the app-wide theme.
@MainActor
struct SavedThemeTests {
    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = "SavedThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false), defaults)
    }

    private func reopened(_ defaults: UserDefaults) -> BrowserSettings {
        BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
    }

    /// A theme that sets every role color, ink and knob, in both appearances.
    private func fullVariant(_ seed: UInt32) -> ThemeVariant {
        ThemeVariant(
            window: seed + 1, sidebar: seed + 2, surface: seed + 3, accent: seed + 4, assistant: seed + 5, text: seed + 6,
            primary: seed + 7, hue: 0.1,
            sidebarText: SidebarTextStyle(colorRGB: seed + 8, opacity: 0.9),
            unloadedText: SidebarTextStyle(colorRGB: seed + 9, opacity: 0.6),
            icons: SidebarTextStyle(colorRGB: seed + 10, opacity: 0.8),
            url: SidebarTextStyle(colorRGB: seed + 11, opacity: 0.7)
        )
    }

    private func rgba(_ color: Color?) -> [CGFloat]? {
        color.flatMap { NSColor($0).usingColorSpace(.sRGB) }.map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent]
        }
    }

    @Test func savingCapturesColorsAndKnobs() throws {
        try withSettings { settings, defaults in
            let full = ThemeDefinition(
                id: "full", name: "Full", basedOn: "nord", ground: .solid, light: fullVariant(0x100000), dark: fullVariant(0x200000)
            )
            settings.userThemes = [full]
            settings.themeID = "full"
            let knobs = ThemeAdjustment(
                material: .glass, glassOpacity: 0.8, lightBrightness: -0.2, darkBrightness: 0.3,
                pageFrame: .hairline, rowFrame: .none, cornerScale: 0.5, loadedFavicons: .color
            )
            settings.themeAdjustment = knobs

            let saved = try #require(settings.saveTheme(named: "Mine"))

            #expect(saved.name == "Mine" && saved.basedOn == "nord" && saved.ground == .solid)
            #expect(saved.light == fullVariant(0x100000) && saved.dark == fullVariant(0x200000))
            #expect(settings.themeID == saved.id && settings.selectedTheme == saved)
            #expect(settings.themeAdjustment == knobs)
            #expect(settings.themeAdjustments["full"] == knobs, "the source keeps its own knobs")
            #expect(settings.userThemes.map(\.name).sorted() == ["Full", "Mine"])

            let source = ResolvedTheme(settings.userThemes.first { $0.id == "full" }!, adjustment: knobs)
            let copy = settings.resolvedTheme
            for scheme in [ColorScheme.light, .dark] {
                let (was, now) = (source.variant(scheme), copy.variant(scheme))
                #expect(was.window.srgb(scheme: scheme) == now.window.srgb(scheme: scheme))
                #expect(was.sidebar.srgb(scheme: scheme) == now.sidebar.srgb(scheme: scheme))
                #expect(was.surface.srgb(scheme: scheme) == now.surface.srgb(scheme: scheme))
                #expect(was.accent.srgb(scheme: scheme) == now.accent.srgb(scheme: scheme))
                #expect(was.assistant.srgb(scheme: scheme) == now.assistant.srgb(scheme: scheme))
                #expect(rgba(was.accentText) == rgba(now.accentText) && rgba(was.onAccent) == rgba(now.onAccent))
                #expect(rgba(was.loadedInk) == rgba(now.loadedInk) && rgba(was.unloadedInk) == rgba(now.unloadedInk))
                #expect(rgba(was.controlInk) == rgba(now.controlInk) && rgba(was.urlInk) == rgba(now.urlInk))
            }
            #expect(copy.adjustment == knobs && copy.id == saved.id)

            let again = reopened(defaults)
            #expect(again.selectedTheme == saved && again.themeAdjustment == knobs)
        }
    }

    @Test func savingABuiltInThemeKeepsItAndItsKnobsSeparate() throws {
        try withSettings { settings, _ in
            settings.themeID = "nord"
            settings.themeAdjustment = ThemeAdjustment(material: .glass, darkBrightness: -0.1)

            let saved = try #require(settings.saveTheme(named: "Night"))

            #expect(saved.basedOn == "nord" && saved.light == ThemeCatalog.builtIn("nord")?.light)
            #expect(settings.themeAdjustment == ThemeAdjustment(material: .glass, darkBrightness: -0.1))
            settings.themeAdjustment = ThemeAdjustment()
            settings.themeID = "nord"
            #expect(settings.themeAdjustment == ThemeAdjustment(material: .glass, darkBrightness: -0.1))
            #expect(ThemeCatalog.builtIn("nord")?.name == "Nord")
        }
    }

    @Test func savingUsesWhatTheWindowShowsWhileADragIsInFlight() throws {
        try withSettings { settings, _ in
            settings.beginThemePreview()
            settings.previewThemeAdjustment(ThemeAdjustment(material: .glass, glassOpacity: 0.9, lightBrightness: 0.25))

            let saved = try #require(settings.saveTheme(named: "Glassy"))

            #expect(settings.themePreview == nil)
            #expect(settings.themeAdjustments[saved.id] == ThemeAdjustment(material: .glass, glassOpacity: 0.9, lightBrightness: 0.25))
        }
    }

    @Test func aSavedThemePreviewsAndEditsInPlaceLikeABuiltInCopy() throws {
        try withSettings { settings, defaults in
            let saved = try #require(settings.saveTheme(named: "Mine"))
            let before = defaults.data(forKey: "appearance.themes.user")

            settings.beginThemePreview()
            for step in 1...10 {
                settings.previewThemeColors(scheme: .dark) { $0.hue = Double(step) / 100 }
                #expect(settings.resolvedTheme.dark.change.hue == Double(step) / 100, "the open window shows each step")
                #expect(settings.userThemes == [saved] && defaults.data(forKey: "appearance.themes.user") == before)
            }
            settings.commitThemePreview()

            #expect(settings.userThemes.count == 1 && settings.themeID == saved.id)
            #expect(settings.selectedTheme.dark.hue == 0.1 && settings.selectedTheme.light == saved.light)
            #expect(reopened(defaults).selectedTheme.dark.hue == 0.1)
        }
    }

    @Test func duplicateRenameAndDeleteKeepTheListConsistent() throws {
        try withSettings { settings, defaults in
            let first = try #require(settings.saveTheme(named: "First"))
            let copy = try #require(settings.duplicateTheme(first.id))
            #expect(copy.name == "First copy" && copy.id != first.id && copy.basedOn == first.basedOn)
            #expect(settings.themeID == copy.id, "a duplicate is selected so it can be edited at once")
            let fromBuiltIn = try #require(settings.duplicateTheme("dracula"))
            #expect(fromBuiltIn.name == "Dracula copy" && fromBuiltIn.basedOn == "dracula")
            #expect(fromBuiltIn.light == ThemeCatalog.builtIn("dracula")?.light)

            #expect(settings.renameTheme(first.id, to: "  Renamed  "))
            #expect(settings.userThemes.map(\.name).sorted() == ["Dracula copy", "First copy", "Renamed"])
            #expect(settings.themeID == fromBuiltIn.id, "renaming another theme does not move the selection")

            settings.deleteTheme(copy.id)
            #expect(settings.userThemes.map(\.name).sorted() == ["Dracula copy", "Renamed"])
            #expect(Array(settings.allThemes.map(\.id).prefix(ThemeCatalog.builtIn.count)) == ThemeCatalog.builtIn.map(\.id))

            let again = reopened(defaults)
            #expect(again.userThemes.map(\.name).sorted() == ["Dracula copy", "Renamed"])
            #expect(again.themeID == fromBuiltIn.id)
        }
    }

    @Test func builtInThemesCannotBeRenamedOrDeleted() throws {
        try withSettings { settings, _ in
            #expect(!settings.renameTheme("nord", to: "Mine"))
            settings.deleteTheme("nord")
            #expect(ThemeCatalog.builtIn("nord")?.name == "Nord" && settings.allThemes.count == ThemeCatalog.builtIn.count)
            #expect(!settings.renameTheme("no-such-theme", to: "Mine"))
        }
    }

    @Test func deletingTheSelectedThemeSelectsItsBase() throws {
        try withSettings { settings, defaults in
            settings.themeID = "gruvbox"
            let saved = try #require(settings.saveTheme(named: "Warm"))
            settings.themeAdjustment = ThemeAdjustment(material: .glass)
            #expect(settings.themeID == saved.id && settings.themeAdjustments[saved.id] != nil)

            settings.deleteTheme(saved.id)

            #expect(settings.themeID == "gruvbox" && settings.selectedTheme.id == "gruvbox")
            #expect(settings.userThemes.isEmpty && settings.themeAdjustments[saved.id] == nil)
            #expect(reopened(defaults).themeID == "gruvbox")
        }
    }

    @Test func deletingTheSelectedThemeWithNoBaseSelectsTheDefault() throws {
        try withSettings { settings, _ in
            settings.userThemes = [ThemeDefinition(id: "loose", name: "Loose", ground: .solid)]
            settings.themeID = "loose"

            settings.deleteTheme("loose")

            #expect(settings.themeID == ThemeCatalog.defaultID && settings.userThemes.isEmpty)
        }
    }

    @Test func deletingAnotherThemeLeavesTheSelectionAlone() throws {
        try withSettings { settings, _ in
            let other = try #require(settings.saveTheme(named: "Other"))
            let mine = try #require(settings.saveTheme(named: "Mine"))
            settings.themeAdjustment = ThemeAdjustment(darkBrightness: 0.2)

            settings.deleteTheme(other.id)

            #expect(settings.themeID == mine.id && settings.themeAdjustment.darkBrightness == 0.2)
            #expect(settings.userThemes == [mine])
        }
    }

    @Test func deletingTheSelectedThemeDropsItsPreview() throws {
        try withSettings { settings, _ in
            let saved = try #require(settings.saveTheme(named: "Mine"))
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.4))
            #expect(settings.themePreview?.themeID == saved.id)

            settings.deleteTheme(saved.id)

            #expect(settings.themePreview == nil && settings.resolvedTheme.id == ThemeCatalog.defaultID)
        }
    }

    @Test func namesAreTrimmedAndMadeUnique() throws {
        try withSettings { settings, _ in
            let first = try #require(settings.saveTheme(named: "   Mine \n"))
            let second = try #require(settings.saveTheme(named: "mine"))
            let third = try #require(settings.saveTheme(named: "Nord"))
            let long = try #require(settings.saveTheme(named: String(repeating: "x", count: 90)))
            settings.themeID = "nord"
            let blank = try #require(settings.saveTheme(named: "  "))

            #expect(first.name == "Mine" && second.name == "mine 2" && third.name == "Nord 2")
            #expect(long.name.count == ThemeDefinition.nameLimit)
            #expect(blank.name == "Nord copy", "a blank name falls back to the copy name of the theme it came from")
            let names = settings.allThemes.map { $0.name.lowercased() }
            #expect(Set(names).count == names.count)

            #expect(settings.renameTheme(first.id, to: "MINE"), "a theme may change the case of its own name")
            #expect(settings.userThemes.first { $0.id == first.id }?.name == "MINE")
            #expect(settings.renameTheme(second.id, to: " Mine "))
            #expect(settings.userThemes.first { $0.id == second.id }?.name == "Mine 2")
            #expect(settings.renameTheme(third.id, to: "Dracula"))
            #expect(settings.userThemes.first { $0.id == third.id }?.name == "Dracula 2")
        }
    }

    @Test func theNameSheetAcceptsOnlyNamesTheSettingsKeepWhole() {
        #expect(ThemeNames.isAcceptable("Mine") && ThemeNames.isAcceptable("  Mine \n"))
        #expect(ThemeNames.isAcceptable(String(repeating: "x", count: ThemeDefinition.nameLimit)))
        #expect(!ThemeNames.isAcceptable("") && !ThemeNames.isAcceptable(" \t\n "))
        #expect(!ThemeNames.isAcceptable(String(repeating: "x", count: ThemeDefinition.nameLimit + 1)))
    }

    @Test func renamingToNothingChangesNothing() throws {
        try withSettings { settings, defaults in
            let saved = try #require(settings.saveTheme(named: "Mine"))
            let stored = defaults.data(forKey: "appearance.themes.user")

            #expect(!settings.renameTheme(saved.id, to: " \t "))

            #expect(settings.userThemes == [saved] && defaults.data(forKey: "appearance.themes.user") == stored)
        }
    }

    @Test func userThemesSurviveRestart() throws {
        try withSettings { settings, defaults in
            settings.themeID = "rosePine"
            settings.themeAdjustment = ThemeAdjustment(material: .glass, glassOpacity: 0.7, lightBrightness: 0.1)
            let saved = try #require(settings.saveTheme(named: "Soft"))
            let other = try #require(settings.duplicateTheme("catppuccin"))
            settings.themeID = saved.id

            let again = reopened(defaults)

            #expect(again.userThemes.map(\.id).sorted() == [saved.id, other.id].sorted())
            #expect(again.selectedTheme == saved)
            #expect(again.themeAdjustment == ThemeAdjustment(material: .glass, glassOpacity: 0.7, lightBrightness: 0.1))
            #expect(again.resolvedTheme.id == saved.id && again.resolvedTheme.adjustment == again.themeAdjustment)
        }
    }

    @Test func theListStopsAtTheLimit() throws {
        try withSettings { settings, defaults in
            settings.userThemes = (0..<BrowserSettings.userThemeLimit).map {
                ThemeDefinition(id: "t\($0)", name: "Theme \($0)", basedOn: "nord", ground: .solid)
            }
            #expect(settings.userThemes.count == BrowserSettings.userThemeLimit && !settings.canSaveAnotherTheme)

            #expect(settings.saveTheme(named: "One too many") == nil)
            #expect(settings.duplicateTheme("nord") == nil)
            settings.themeID = "nord"
            settings.editColors(scheme: .light) { $0.hue = 0.2 }
            #expect(settings.userThemes.count == BrowserSettings.userThemeLimit && settings.themeID == "nord")

            settings.deleteTheme("t0")
            #expect(settings.canSaveAnotherTheme && settings.saveTheme(named: "Fits again") != nil)
            #expect(settings.userThemes.count == BrowserSettings.userThemeLimit)

            // A longer list in the defaults loads as far as the limit.
            let long = (0..<(BrowserSettings.userThemeLimit + 50)).map {
                ThemeDefinition(id: "u\($0)", name: "U\($0)", ground: .solid)
            }
            defaults.set(try JSONEncoder().encode(long), forKey: "appearance.themes.user")
            #expect(reopened(defaults).userThemes.count == BrowserSettings.userThemeLimit)
        }
    }

    @Test func savingWithNoSuchSourceChangesNothing() throws {
        try withSettings { settings, _ in
            #expect(settings.saveTheme(named: "Nothing", from: "no-such-theme") == nil)
            #expect(settings.userThemes.isEmpty && settings.themeID == ThemeCatalog.defaultID)
        }
    }

    @Test func resettingToDefaultsKeepsSavedThemesButNotTheirSelection() throws {
        try withSettings { settings, _ in
            let saved = try #require(settings.saveTheme(named: "Mine"))
            settings.themeAdjustment = ThemeAdjustment(material: .glass)

            settings.resetToDefaults()

            #expect(settings.userThemes == [saved] && settings.themeID == ThemeCatalog.defaultID)
            #expect(settings.themeAdjustments.isEmpty)
        }
    }
}
