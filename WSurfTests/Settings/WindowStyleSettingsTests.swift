// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The app-wide window choices: the full address. Every case owns its settings and a throwaway defaults suite.
@MainActor
struct WindowStyleSettingsTests {
    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("WindowStyleSettingsTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false), defaults)
    }

    private func resting(_ url: String, full: Bool) -> AskRestingContent? {
        AskRestingContent.resolve(
            isListening: false,
            transcript: "",
            agentMessage: nil,
            mirrorsPageURL: true,
            isFocused: false,
            typedText: "",
            notice: nil,
            status: nil,
            placeholder: "Search",
            currentURL: url,
            showsFullAddress: full
        )
    }

    // MARK: - Full address

    @Test func theAddressShowsTheWebsiteNameUnlessTheFullAddressIsOn() {
        let url = "https://www.example.com/docs/page?query=1#part"

        #expect(resting(url, full: false) == .address("example.com"))
        #expect(resting(url, full: true) == .address(url))
        #expect(AskRestingContent.displayAddress(for: url) == "example.com", "the default stays the website name")
    }

    @Test func aPageWithoutAnAddressStillShowsThePlaceholder() {
        #expect(resting("", full: true) == .placeholder("Search"))
        #expect(resting("", full: false) == .placeholder("Search"))
    }

    @Test func theFullAddressIsOneAppWideChoiceThatSurvivesARestartAndResets() throws {
        try withSettings { settings, defaults in
            #expect(!settings.showsFullAddress, "off by default")

            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: settings)
            profile.showsFullAddress = true
            #expect(settings.showsFullAddress, "a profile writes the app-wide value")
            #expect(defaults.object(forKey: BrowserSettings.Key.fullAddress) as? Bool == true)
            #expect(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false).showsFullAddress)

            settings.resetToDefaults()
            #expect(!settings.showsFullAddress)
            #expect(!profile.showsFullAddress)
        }
    }

    @Test func searchFindsTheFullAddressRowInGeneral() throws {
        let entries = SettingsIndex.all.filter { $0.id == "general.fullAddress" }
        let entry = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(entry.category == .general)
        for query in ["full address", "full url", "path", "url bar"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "general.fullAddress" }, "\(query)")
        }
    }
}
