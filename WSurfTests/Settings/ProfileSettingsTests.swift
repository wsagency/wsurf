// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized)
struct ProfileSettingsTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ProfileSettingsTests.\(UUID().uuidString)"))
    }

    private func forget(_ suite: UserDefaults) {
        suite.removePersistentDomain(forName: suite.description)
    }

    @Test func eachSettingsInstanceStaysBoundToItsProfile() throws {
        let app = try suite()
        let work = try suite()
        let personal = try suite()
        defer { [app, work, personal].forEach(forget) }

        let appSettings = BrowserSettings(defaults: app)
        let workSettings = BrowserSettings(sessionDefaults: work, application: appSettings)
        let personalSettings = BrowserSettings(sessionDefaults: personal, application: appSettings)
        workSettings.searchEngineID = "kagi"
        personalSettings.searchEngineID = "brave"
        workSettings.appearance = .dark

        #expect(workSettings.searchEngineID == "kagi")
        #expect(personalSettings.searchEngineID == "brave")
        #expect(BrowserSettings(defaults: app, sessionDefaults: work).searchEngineID == "kagi")
        #expect(BrowserSettings(defaults: app, sessionDefaults: personal).searchEngineID == "brave")
        #expect(personalSettings.appearance == .dark)
    }

    @Test func profileSettingsChangesPersistWithoutRetargetingOtherWindows() throws {
        let app = try suite()
        let work = try suite()
        let personal = try suite()
        defer { [app, work, personal].forEach(forget) }

        let workSettings = BrowserSettings(defaults: app, sessionDefaults: work)
        let personalSettings = BrowserSettings(defaults: app, sessionDefaults: personal)
        workSettings.javaScriptEnabled = false
        personalSettings.javaScriptEnabled = true

        #expect(!BrowserSettings(defaults: app, sessionDefaults: work).javaScriptEnabled)
        #expect(BrowserSettings(defaults: app, sessionDefaults: personal).javaScriptEnabled)
    }

    @Test func privateSettingsDisappearWithoutChangingTheInheritedProfile() throws {
        let app = try suite()
        let persistent = try suite()
        defer { [app, persistent].forEach(forget) }
        let settings = BrowserSettings(defaults: app, sessionDefaults: persistent)
        settings.javaScriptEnabled = false

        let privateSettings = BrowserSettings(
            defaults: app, sessionDefaults: InMemoryUserDefaults(inheriting: persistent)
        )
        #expect(!privateSettings.javaScriptEnabled)
        privateSettings.javaScriptEnabled = true
        #expect(privateSettings.javaScriptEnabled)

        let reopened = BrowserSettings(defaults: app, sessionDefaults: persistent)
        let nextPrivateSession = BrowserSettings(
            defaults: app, sessionDefaults: InMemoryUserDefaults(inheriting: persistent)
        )
        #expect(!reopened.javaScriptEnabled)
        #expect(!nextPrivateSession.javaScriptEnabled)
    }

    @Test func providerSelectionAndModelChoicesBelongToEachProfile() throws {
        let work = try suite()
        let personal = try suite()
        defer { [work, personal].forEach(forget) }

        let workSettings = LLMSettings(defaults: work)
        let personalSettings = LLMSettings(defaults: personal)
        let workProviders = ProfileProviderCatalog(settings: workSettings)
        let personalProviders = ProfileProviderCatalog(settings: personalSettings)
        let anthropic = try #require(workProviders.provider(id: "anthropic"))
        workProviders.select(anthropic)
        workSettings.reasoningEffort = .high
        workSettings.setModel("claude-sonnet-5", for: ProviderCatalog.openAI)

        #expect(workProviders.selected.id == "anthropic")
        #expect(personalProviders.selected.id == ProviderCatalog.openAI.id)
        #expect(workProviders.all.map(\.id) == personalProviders.all.map(\.id))
        #expect(workSettings.model(for: ProviderCatalog.openAI) == "claude-sonnet-5")
        #expect(work.string(forKey: "llm.provider") == "anthropic")
        #expect(work.string(forKey: "llm.reasoningEffort") == "high")
        #expect(work.string(forKey: "llm.model.\(ProviderCatalog.openAI.id)") == "claude-sonnet-5")
        #expect(personal.string(forKey: "llm.provider") != "anthropic")
    }

    @Test func eachProfileGetsItsOwnSuiteAndIconFolder() {
        let work = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let personal = Profile(id: UUID(), name: "Personal", symbol: "person", color: .green)

        #expect(ProfileSettingsStore.suiteName(for: work.id) != ProfileSettingsStore.suiteName(for: personal.id))
        #expect(FaviconLoader.cacheDirectory(for: work) != FaviconLoader.cacheDirectory(for: personal))
    }
}
