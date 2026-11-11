// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// "Show Passwords in Menu Bar": an app-wide choice, on by default. Every case owns its settings and a throwaway defaults suite.
@MainActor
struct PasswordsMenuBarSettingTests {
    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("PasswordsMenuBarSettingTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false), defaults)
    }

    @Test func itIsOnUntilItIsTurnedOffAndTheChoiceSurvivesARestart() throws {
        try withSettings { settings, defaults in
            #expect(settings.showsPasswordsInMenuBar, "on by default")
            #expect(defaults.object(forKey: BrowserSettings.Key.passwordsMenuBar) == nil, "reading the default writes nothing")

            settings.showsPasswordsInMenuBar = false
            #expect(defaults.object(forKey: BrowserSettings.Key.passwordsMenuBar) as? Bool == false)
            #expect(!BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false).showsPasswordsInMenuBar)

            settings.showsPasswordsInMenuBar = true
            #expect(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false).showsPasswordsInMenuBar)
        }
    }

    @Test func itIsOneAppWideChoiceAndResetTurnsItBackOn() throws {
        try withSettings { settings, defaults in
            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: settings)
            profile.showsPasswordsInMenuBar = false
            #expect(!settings.showsPasswordsInMenuBar, "a profile writes the app-wide value")

            settings.resetToDefaults()
            #expect(settings.showsPasswordsInMenuBar)
            #expect(profile.showsPasswordsInMenuBar)
        }
    }

    @Test func theHookFiresOncePerChangeWithTheNewValue() throws {
        try withSettings { settings, _ in
            var seen: [Bool] = []
            settings.onPasswordsMenuBarChanged = { seen.append($0) }

            settings.showsPasswordsInMenuBar = true
            #expect(seen.isEmpty, "setting the value it already has is not a change")

            settings.showsPasswordsInMenuBar = false
            settings.showsPasswordsInMenuBar = false
            settings.showsPasswordsInMenuBar = true
            #expect(seen == [false, true])
        }
    }

    @Test func theSearchEntryLeadsToTheGeneralPageRow() throws {
        let entry = try #require(SettingsIndex.all.first { $0.id == "general.passwordsMenuBar" })
        #expect(entry.category == .general)
        #expect(entry.targetAnchor == "general.passwordsMenuBar")
        for query in ["menu bar", "passwords in menu bar", "menubar"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "general.passwordsMenuBar" }, "\(query)")
        }
    }

    /// A search hit scrolls to the row with the same anchor, so the General page must carry it exactly once.
    @Test func theGeneralPageCarriesTheRowTheSearchEntryPointsAt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WSurf/Settings/Pages/GeneralSettings.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.components(separatedBy: ".settingsAnchor(\"general.passwordsMenuBar\")").count == 2)
        #expect(source.contains("SettingsToggle($settings.showsPasswordsInMenuBar)"))
    }
}
