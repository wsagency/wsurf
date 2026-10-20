// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct CommandPaletteSiteSearchTests {
    @Test(arguments: ["yo", "You", "YOUTUBE", "youtube.com", "https://www.youtube.com/"])
    func matchesYouTubePrefixes(query: String) {
        #expect(SiteSearch.match(query)?.id == "youtube")
    }

    @Test(arguments: ["", "y", "youtube music", "> youtube", "@youtube", "?youtube", "youtube.com.evil.test", "youtube.com/watch?v=123"])
    func ignoresQueriesThatAreNotSiteNames(query: String) {
        #expect(SiteSearch.match(query) == nil)
    }

    @Test func supportsOtherSitesAndCustomSearch() {
        #expect(SiteSearch.match("red")?.id == "reddit")
        #expect(SiteSearch.match("git")?.id == "github")
        #expect(SiteSearch.match("ama")?.id == "amazon")
        #expect(SiteSearch.match("wiki")?.id == "wikipedia")
        #expect(SiteSearch.match("goo")?.id == "google")
        let custom = SearchEngine.custom(name: "My library", template: "https://library.example/search?q=%s")
        #expect(SiteSearch.match("my lib", customEngine: custom) == custom)
        #expect(SiteSearch.match("library.example", customEngine: custom) == custom)
        let invalid = SearchEngine.custom(name: "Broken", template: "javascript:alert('%s')")
        #expect(SiteSearch.match("broken", customEngine: invalid) == nil)
    }

    @Test func encodesQueriesWithoutAddingParametersOrFragments() throws {
        let site = try #require(SiteSearch.match("you"))
        let query = "café & C++ #music? 你好 / 100%"
        let url = try #require(site.searchURL(for: query))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "www.youtube.com")
        #expect(components.path == "/results")
        #expect(components.queryItems == [URLQueryItem(name: "search_query", value: query)])
        #expect(components.fragment == nil)
    }

    @Test func tabActivatesSiteAndEmptySubmitKeepsPaletteOpen() {
        let coordinator = AppCoordinator()
        var dismissed = false
        let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator) { dismissed = true }
        model.prepare()
        model.interaction.query = "You"
        #expect(model.suggestedSite?.name == "YouTube")
        #expect(model.activateSiteSearch())
        #expect(model.searchSite?.id == "youtube")
        #expect(model.placeholder == String(localized: "Search \("YouTube")"))
        #expect(model.interaction.query.isEmpty)
        #expect(model.suggestedSite == nil)
        #expect(model.sections.isEmpty)
        #expect(!model.activateSiteSearch())
        model.submit()
        model.submitInCurrentTab()
        #expect(!dismissed)
        model.interaction.query = "   "
        model.submit()
        #expect(!dismissed)
    }

    @Test func siteModeReplacesAssistantAndWebSuggestions() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let coordinator = AppCoordinator()
            let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator) {}
            model.interaction.query = "you"
            #expect(model.activateSiteSearch())
            for query in ["music", "https://example.com", "> settings", "@a tab", "?a question"] {
                model.interaction.query = query
                #expect(model.sections.flattened.count == 1)
                #expect(model.sections.flattened.first?.id == "site-search-youtube")
                #expect(model.sections.flattened.first?.title == query)
                #expect(model.contextPages.isEmpty)
                #expect(model.suggestions.phrases.isEmpty)
            }
        }
    }

    @Test func removingSitePreservesQueryAndRestoresNormalResults() {
        let coordinator = AppCoordinator()
        let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator) {}
        model.interaction.query = "youtube"
        #expect(model.activateSiteSearch())
        model.interaction.query = "music"
        #expect(model.removeSearchSite())
        #expect(model.searchSite == nil)
        #expect(model.interaction.query == "music")
        #expect(!model.sections.flattened.contains { $0.id == "site-search-youtube" })
        #expect(!model.removeSearchSite())
    }

    @Test func mentionsDoNotActivateSiteSearch() {
        let coordinator = AppCoordinator()
        let tab = coordinator.browser.newTab()
        let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator) {}
        model.mention(tab)
        model.interaction.query = "you"
        #expect(model.suggestedSite == nil)
        #expect(!model.activateSiteSearch())
    }

    @Test(.boundedWebViews) func enterSearchesSiteInNewTab() {
        let coordinator = AppCoordinator()
        let previous = coordinator.browser.newTab()
        let count = coordinator.browser.tabs.count
        var dismissed = false
        let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator) { dismissed = true }
        model.interaction.query = "you"
        #expect(model.activateSiteSearch())
        model.interaction.query = "ambient music"
        model.submit()
        #expect(dismissed)
        #expect(coordinator.browser.tabs.count == count + 1)
        #expect(coordinator.browser.activeTab !== previous)
        #expect(coordinator.browser.activeTab?.urlString == "https://www.youtube.com/results?search_query=ambient%20music")
    }

    @Test(.boundedWebViews) func optionEnterSearchesSiteInCurrentTab() {
        let coordinator = AppCoordinator()
        let previous = coordinator.browser.newTab()
        let count = coordinator.browser.tabs.count
        let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator) {}
        model.interaction.query = "git"
        #expect(model.activateSiteSearch())
        model.interaction.query = "swift"
        model.submitInCurrentTab()
        #expect(coordinator.browser.tabs.count == count)
        #expect(coordinator.browser.activeTab === previous)
        #expect(previous.urlString == "https://github.com/search?q=swift")
    }

    // MARK: - Archived tabs

    /// Runs `body` over a palette whose window holds `pages` in its archive. The window shares the profile's archive
    /// otherwise, so each test swaps in its own. Agent-only input keeps a typed query from asking a search engine
    /// for suggestions.
    private func withArchivePalette(
        _ pages: [(title: String, url: String)],
        dismiss: @escaping () -> Void = {},
        _ body: (AppCoordinator, CommandPaletteModel) throws -> Void
    ) throws {
        try Omnibox.$agentOnlyForTesting.withValue(true) {
            let coordinator = AppCoordinator()
            coordinator.browser.tabArchive = TabArchive(database: .temporary())
            coordinator.browser.tabArchive.add(pages)
            let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator, dismiss: dismiss)
            model.prepare()
            try body(coordinator, model)
        }
    }

    @Test func tabOpensTheArchiveAndBackspaceLeavesIt() throws {
        try withArchivePalette([(title: "Report", url: "https://example.com/report")]) { _, model in
            model.interaction.query = "archived"
            #expect(model.scopeHint == String(localized: "Search archived tabs"))
            #expect(model.activateSiteSearch())
            #expect(model.showsArchive)
            #expect(model.placeholder == String(localized: "Search archived tabs"))
            #expect(model.interaction.query.isEmpty)
            #expect(model.sections.flattened.map(\.title) == ["Report"])
            #expect(model.scopeHint == nil)
            #expect(model.removeSearchSite())
            #expect(!model.showsArchive)
        }
    }

    @Test func anEmptyArchiveOffersNoTab() throws {
        try withArchivePalette([]) { _, model in
            model.interaction.query = "archived"
            #expect(model.scopeHint == nil)
            #expect(!model.activateSiteSearch())
            model.interaction.query = "> archived"
            #expect(!model.sections.flattened.contains { $0.id == "action-showArchivedTabs" })
        }
    }

    @Test func theArchiveCommandOpensTheListWithoutClosingThePalette() throws {
        var dismissed = false
        try withArchivePalette([(title: "Report", url: "https://example.com/report")], dismiss: { dismissed = true }) { _, model in
            model.interaction.query = "> archived"

            let command = try #require(model.sections.flattened.first { $0.id == "action-showArchivedTabs" })
            command.run()

            #expect(model.showsArchive)
            #expect(model.interaction.query.isEmpty)
            #expect(model.sections.flattened.map(\.title) == ["Report"])
        }
        #expect(!dismissed)
    }

    @Test func theArchiveListSkipsPagesOpenInTheWindow() throws {
        try withArchivePalette([
            (title: "Open", url: "https://example.com/open"),
            (title: "Closed", url: "https://example.com/closed"),
        ]) { coordinator, model in
            coordinator.browser.addPage("https://example.com/open")
            model.interaction.query = "archived"
            #expect(model.activateSiteSearch())

            #expect(model.sections.flattened.map(\.title) == ["Closed"])
        }
    }

    @Test func removingARowDeletesTheEntryAndKeepsTheModeOpen() throws {
        try withArchivePalette([
            (title: "Report", url: "https://example.com/report"),
            (title: "Recipes", url: "https://example.com/recipes"),
        ]) { coordinator, model in
            model.interaction.query = "archived"
            #expect(model.activateSiteSearch())
            #expect(model.sections.flattened.map(\.title) == ["Recipes", "Report"])

            model.remove(at: 0)

            #expect(model.sections.flattened.map(\.title) == ["Report"])
            #expect(coordinator.browser.tabArchive.entries.map(\.title) == ["Report"])
            #expect(model.showsArchive)
            model.remove(at: 0)
            #expect(model.sections.isEmpty)
            #expect(coordinator.browser.tabArchive.entries.isEmpty)
            #expect(model.showsArchive)
        }
    }

    @Test(.boundedWebViews) func restoringFromTheListOpensTheTabAfterTheActiveOneAndForgetsTheEntry() throws {
        var dismissed = false
        try withArchivePalette([
            (title: "Report", url: "https://example.test/report"),
            (title: "Recipes", url: "https://example.test/recipes"),
        ], dismiss: { dismissed = true }) { coordinator, model in
            let browser = coordinator.browser
            // A new tab opens at the top of the list, so this order leaves `front` active with `behind` below it.
            let behind = browser.newTab(activate: false)
            let front = browser.newTab()
            model.interaction.query = "archived"
            #expect(model.activateSiteSearch())

            try #require(model.sections.flattened.first { $0.title == "Report" }).run()

            let restored = try #require(browser.activeTab)
            let frontIndex = try #require(browser.tabs.firstIndex { $0 === front })
            #expect(restored.urlString == "https://example.test/report")
            #expect(browser.tabs.firstIndex { $0 === restored } == frontIndex + 1)
            #expect(browser.tabs.firstIndex { $0 === behind } == frontIndex + 2)
            #expect(browser.tabArchive.entries.map(\.url) == ["https://example.test/recipes"])
        }
        #expect(dismissed)
    }

    @Test func aPrivateWindowOffersNoArchive() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let permissions = SitePermissions(
                storageURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("PaletteArchivePrivate-\(UUID().uuidString).json")
            )
            let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
            browser.adopt(database: .temporary(), sitePermissions: permissions, privately: true)
            browser.tabArchive = TabArchive(database: .temporary())
            browser.tabArchive.add([(title: "Report", url: "https://example.com/report")])
            let model = CommandPaletteModel(browser: browser, coordinator: AppCoordinator(browser: browser)) {}
            model.prepare()
            #expect(browser.opensPrivately)
            #expect(browser.tabArchive.entries.count == 1)

            model.interaction.query = "archived"
            #expect(model.scopeHint == nil)
            #expect(!model.suggestsArchive)
            #expect(!model.activateSiteSearch())
            #expect(!model.showsArchive)
            model.interaction.query = "> archived"
            #expect(!model.sections.flattened.contains { $0.id == "action-showArchivedTabs" })
        }
    }

    @Test func archiveModeNeverAsksTheAssistant() throws {
        var dismissed = false
        try withArchivePalette([(title: "Report", url: "https://example.com/report")], dismiss: { dismissed = true }) { coordinator, model in
            model.mention(coordinator.browser.newTab())
            #expect(!model.contextPages.isEmpty)
            model.interaction.query = "> archived"
            try #require(model.sections.flattened.first { $0.id == "action-showArchivedTabs" }).run()
            #expect(model.showsArchive)
            #expect(model.mentionChips.isEmpty)
            #expect(model.contextPages.isEmpty)

            model.interaction.query = "what is this page about"

            #expect(model.contextPages.isEmpty)
            #expect(model.sections.isEmpty)
            model.askWhateverIsTyped()
        }
        #expect(!dismissed)
    }
}
