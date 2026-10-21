// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

struct ThemePickerTests {
    @Test func tintDefaultsPreserveOptOutsUntilSettingsAreReset() throws {
        let name = AppDatabase.defaultsSuite("TintDefaultsTests.\(UUID().uuidString)")
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        let settings = BrowserSettings(defaults: suite)
        #expect(settings.matchesWebsiteColor)
        #expect(settings.refractsTabColor)

        settings.matchesWebsiteColor = false
        settings.refractsTabColor = false
        let restored = BrowserSettings(defaults: suite)
        #expect(!restored.matchesWebsiteColor)
        #expect(!restored.refractsTabColor)

        restored.resetToDefaults()
        let reset = BrowserSettings(defaults: suite)
        #expect(reset.matchesWebsiteColor)
        #expect(reset.refractsTabColor)
    }

    @Test func choosingAModePersistsIt() throws {
        let name = AppDatabase.defaultsSuite("ThemePickerTests.\(UUID().uuidString)")
        let suite = try #require(UserDefaults(suiteName: name))
        let previousAppearance = NSApp.appearance
        defer {
            suite.removePersistentDomain(forName: name)
            NSApp.appearance = previousAppearance
        }

        let settings = BrowserSettings(defaults: suite)
        for mode in AppearanceMode.allCases {
            settings.colorMode = mode
            #expect(BrowserSettings(defaults: suite).colorMode == mode)
        }
    }

    @Test func standardThemeMaterialDefaultsToPlainAndPersists() throws {
        let suite = try #require(UserDefaults(suiteName: AppDatabase.defaultsSuite("WebsiteColorTests.\(UUID().uuidString)")))
        defer { suite.removePersistentDomain(forName: suite.description) }

        let settings = BrowserSettings(defaults: suite)
        settings.themeID = "standard"
        #expect(settings.themeMaterial == .plain)
        settings.themeMaterial = .glass
        #expect(BrowserSettings(defaults: suite).themeMaterial == .glass)
    }

    @Test func websiteTintPersistsIndependentlyOfWindowStyle() throws {
        let suite = try #require(UserDefaults(suiteName: AppDatabase.defaultsSuite("WebsiteTintTests.\(UUID().uuidString)")))
        defer { suite.removePersistentDomain(forName: suite.description) }

        let settings = BrowserSettings(defaults: suite)
        settings.themeID = "standard"
        settings.themeMaterial = .glass
        settings.matchesWebsiteColor = true

        let restored = BrowserSettings(defaults: suite)
        #expect(restored.themeMaterial == .glass)
        #expect(restored.matchesWebsiteColor)
    }

    @Test func legacyWebsiteTintStyleMigratesToStandardWithTintEnabled() throws {
        let suite = try #require(UserDefaults(suiteName: AppDatabase.defaultsSuite("WebsiteTintMigrationTests.\(UUID().uuidString)")))
        defer { suite.removePersistentDomain(forName: suite.description) }
        suite.set("websiteTint", forKey: "appearance.loomStyle")

        let settings = BrowserSettings(defaults: suite)
        #expect(settings.themeMaterial == .plain)
        #expect(settings.matchesWebsiteColor)
    }

    @Test func legacyTintOptOutSurvivesAWindowStyleChange() throws {
        let name = AppDatabase.defaultsSuite("LegacyTintOptOutTests.\(UUID().uuidString)")
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(false, forKey: "appearance.websiteColor")

        let settings = BrowserSettings(defaults: suite)
        #expect(!settings.matchesWebsiteColor)
        settings.themeMaterial = .glass
        #expect(!BrowserSettings(defaults: suite).matchesWebsiteColor)
    }
}
