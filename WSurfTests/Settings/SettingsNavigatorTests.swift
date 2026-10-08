// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import SwiftUI
import Testing

@testable import WSurf

struct SettingsNavigatorTests {
    @Test func categoryRawValuesAreStable() {
        let expected = [
            "general", "appearance", "search", "provider", "profiles",
            "privacy", "autofill", "websites", "downloads", "extensions", "advanced", "experiments", "about",
        ]
        #expect(SettingsCategory.allCases.map(\.rawValue) == expected)
    }

    @Test func theProviderPageIsTitledAssistant() {
        #expect(String(localized: SettingsCategory.provider.title) == "Assistant")
        #expect(SettingsCategory.provider.id == "provider")
    }

    @Test func profilesIsReachedFromTheProfileBlockNotAGroup() {
        #expect(SettingsCategory.profiles.group == nil)
        for group in SettingsGroup.allCases {
            #expect(!group.categories.contains(.profiles))
        }
    }

    @Test func everyOtherCategoryBelongsToExactlyOneGroup() {
        let grouped = SettingsGroup.allCases.flatMap(\.categories)
        #expect(Set(grouped).count == grouped.count)
        #expect(Set(grouped) == Set(SettingsCategory.allCases).subtracting([.profiles]))
    }

    @Test func theFirstGroupIsUnheaded() {
        #expect(SettingsGroup.setup.header == nil)
    }

    @Test func theHeadedGroupsReadAsChosen() {
        let headers = SettingsGroup.allCases
            .compactMap(\.header)
            .map { String(localized: $0) }
        #expect(headers == ["Browsing", "System"])
    }

    @Test func noGroupHeaderRepeatsACategoryInsideIt() {
        for group in SettingsGroup.allCases {
            guard let header = group.header else { continue }
            let titles = group.categories.map { String(localized: $0.title) }
            #expect(!titles.contains(String(localized: header)), "\(titles)")
        }
    }

    @Test func everyCategoryCarriesATileTint() {
        for category in SettingsCategory.allCases {
            #expect(category.tint != .clear)
        }
    }

    @Test func profilesIsStillFoundBySearch() {
        #expect(SettingsCategory.profiles.matches("profiles"))
        #expect(SettingsCategory.profiles.matches("work"))
        #expect(!SettingsCategory.profiles.matches("javascript"))
    }

    @Test func theOldProviderNameStillFindsThePage() {
        #expect(SettingsCategory.provider.matches("provider"))
    }

    @Test func theOldVoicePageStillFindsTheAssistantPage() {
        #expect(SettingsCategory.provider.matches("voice"))
        #expect(SettingsCategory.provider.matches("microphone"))
        #expect(SettingsCategory.provider.matches("push to talk"))
    }

    @MainActor
    @Test(.boundedWebViews) func downloadsBackReturnsToTheSettingsCategory() async {
        let browser = BrowserModel(database: .temporary())
        let settings = browser.showSettings()
        let settingsURL = SystemPages.settingsURL(.downloads)
        #expect(await settled(settings, at: BrowserTab.InternalPage.settings.url))
        settings.load(settingsURL)
        #expect(await settled(settings, at: settingsURL))

        let downloads = browser.showDownloads()
        #expect(await settled(downloads, at: BrowserTab.InternalPage.downloads.url))
        #expect(browser.activeTab === downloads)
        #expect(downloads !== settings)
        #expect(settings.internalPage == .settings)

        // Downloads' Back control dismisses its destination, rather than
        // navigating the dedicated settings tab away from its category.
        browser.dismissInternalPage(.downloads)

        #expect(browser.activeTab === settings)
        #expect(settings.urlString == settingsURL.absoluteString)
        #expect(settings.internalPage == .settings)
        #expect(!browser.tabs.contains { $0.id == downloads.id })
    }
}
