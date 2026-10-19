// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

@MainActor
struct CommandPaletteOrderTests {
    private let builtIn: [CommandPaletteSection] = [.search, .suggestions, .tabs, .history, .actions, .recent]

    // MARK: - Default

    @Test func theDefaultOrderIsTheBuiltInOrder() {
        withSettings { settings, _ in
            #expect(settings.commandPaletteOrder == builtIn)
            #expect(CommandPaletteSection.allCases == builtIn)
        }
    }

    @Test func theDefaultOrderLeavesTheTypedSectionsAsTheyWere() {
        withSettings { settings, _ in
            let fixture = Fixture()

            #expect(fixture.typed("organize", settings).map(\.id) == ["top", "actions", "suggestions", "tabs", "history"])
            #expect(fixture.typed("ogt", settings).map(\.id) == ["top", "suggestions", "actions"])
            #expect(fixture.typed("organize", settings).first?.items.map(\.id) == ["omnibox-search", "ask-agent"])
        }
    }

    @Test func theDefaultOrderLeavesTheRestingSectionsAsTheyWere() {
        withSettings { settings, _ in
            #expect(Fixture().resting(settings).map(\.id) == ["tabs", "actions", "recent"])
        }
    }

    // MARK: - Applying an order

    @Test func tabsThenActionsThenSuggestionsIsApplied() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.tabs, .actions, .suggestions, .search, .history, .recent]
            let sections = Fixture().typed("organize", settings)

            #expect(sections.map(\.id) == ["tabs", "actions", "suggestions", "top", "history"])
        }
    }

    @Test func searchOrAskHasNoHeadingOnlyWhileItLeads() {
        withSettings { settings, _ in
            let fixture = Fixture()
            #expect(fixture.searchHeading("organize", settings) == "")

            settings.commandPaletteOrder = [.tabs, .search, .suggestions, .history, .actions, .recent]
            #expect(fixture.searchHeading("organize", settings) == String(localized: "Search or Ask"))
            #expect(fixture.searchHeading("zzqq", settings) == "")
        }
    }

    @Test func theBestMatchIsTheFirstRowOfTheFirstSection() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.tabs, .actions, .suggestions, .search, .history, .recent]
            let fixture = Fixture()
            let best = fixture.typed("organize", settings).flattened.first

            #expect(best?.kind == .tab)
            #expect(best?.id.hasPrefix("omnibox-tab-") == true)

            settings.commandPaletteOrder = [.history, .tabs, .actions, .suggestions, .search, .recent]
            #expect(fixture.typed("organize", settings).flattened.first?.kind == .history)
        }
    }

    @Test func aSectionWithNoResultsLeavesNoGapAtTheTop() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.tabs, .history, .suggestions, .search, .actions, .recent]
            let sections = Fixture().typed("zzqq", settings)

            #expect(sections.map(\.id) == ["suggestions", "top"])
        }
    }

    @Test func aWeakCommandStaysWhereThePersonPlacedIt() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.actions, .search, .suggestions, .tabs, .history, .recent]
            #expect(Fixture().typed("ogt", settings).map(\.id) == ["actions", "top", "suggestions"])

            settings.commandPaletteOrder = [.search, .suggestions, .tabs, .history, .actions, .recent]
            #expect(Fixture().typed("ogt", settings).map(\.id) == ["top", "suggestions", "actions"])
        }
    }

    @Test func aStrongCommandSitsRightUnderTheFirstSection() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.tabs, .suggestions, .search, .history, .actions, .recent]
            let sections = Fixture().typed("organize", settings)

            #expect(sections.map(\.id) == ["tabs", "actions", "suggestions", "top", "history"])
            #expect(sections.dropFirst().first?.items.first?.id == "action-organizeTabs")
        }
    }

    @Test func anAddressKeepsSearchOrAskFirst() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.tabs, .actions, .suggestions, .search, .history, .recent]
            let sections = Fixture().typed("tabs.example", settings)

            #expect(sections.map(\.id).prefix(2) == ["top", "tabs"])
            #expect(sections.first?.items.first?.id == "omnibox-go")
        }
    }

    @Test func theTypingRulesAreInvisibleForTheDefaultOrder() {
        #expect(CommandPaletteSection.typingOrder(builtIn, isAddress: true, hasStrongCommand: false) == builtIn)
        #expect(
            CommandPaletteSection.typingOrder(builtIn, isAddress: false, hasStrongCommand: true)
                == [.search, .actions, .suggestions, .tabs, .history, .recent]
        )
        #expect(
            CommandPaletteSection.typingOrder([.tabs, .search, .actions, .history, .suggestions, .recent],
                                              isAddress: true, hasStrongCommand: true)
                == [.search, .actions, .tabs, .history, .suggestions, .recent]
        )
    }

    @Test func restingSectionsFollowTheOrderAndIgnoreTheTypingOnlyOnes() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.recent, .search, .actions, .suggestions, .tabs, .history]
            #expect(Fixture().resting(settings).map(\.id) == ["recent", "actions", "tabs"])

            settings.commandPaletteOrder = [.actions, .history, .tabs, .search, .suggestions, .recent]
            #expect(Fixture().resting(settings).map(\.id) == ["actions", "tabs", "recent"])
        }
    }

    @Test func theCommandPrefixIgnoresTheOrder() {
        withSettings { settings, _ in
            let fixture = Fixture()
            let before = fixture.typed(">organize", settings).map(\.id)
            settings.commandPaletteOrder = [.recent, .history, .tabs, .suggestions, .actions, .search]

            #expect(fixture.typed(">organize", settings).map(\.id) == before)
            #expect(before == ["actions"])
        }
    }

    @Test func rankingInsideASectionDoesNotDependOnTheOrder() {
        withSettings { settings, _ in
            let fixture = Fixture()
            let standard = fixture.typed("project", settings)
            settings.commandPaletteOrder = [.history, .tabs, .suggestions, .search, .actions, .recent]
            let reordered = fixture.typed("project", settings)

            let ranked = fixture.rankedTabs.map { "omnibox-tab-\($0.id)" }
            #expect(standard.first { $0.id == "tabs" }?.items.map(\.id) == ranked)
            #expect(reordered.first { $0.id == "tabs" }?.items.map(\.id) == ranked)

            for section in standard {
                let moved = reordered.first { $0.id == section.id }
                let shared = min(section.items.count, moved?.items.count ?? 0)
                #expect(shared > 0)
                #expect(section.items.prefix(shared).map(\.id) == moved?.items.prefix(shared).map(\.id))
            }
            #expect(Set(standard.map(\.id)) == Set(reordered.map(\.id)))
        }
    }

    // MARK: - Persistence and reset

    @Test func theOrderIsSavedAndRestored() {
        withSettings { settings, defaults in
            settings.moveCommandPaletteSection(.tabs, by: -2)
            settings.moveCommandPaletteSection(.actions, by: -1)
            let expected: [CommandPaletteSection] = [.tabs, .search, .suggestions, .actions, .history, .recent]

            #expect(settings.commandPaletteOrder == expected)
            #expect(defaults.stringArray(forKey: BrowserSettings.Key.commandPaletteOrder) == expected.map(\.rawValue))
            #expect(BrowserSettings(defaults: defaults).commandPaletteOrder == expected)
        }
    }

    @Test func resetRestoresTheBuiltInOrderEverywhere() {
        withSettings { settings, defaults in
            settings.commandPaletteOrder = [.tabs, .actions, .suggestions, .search, .history, .recent]
            settings.resetCommandPaletteOrder()

            #expect(settings.commandPaletteOrder == builtIn)
            #expect(BrowserSettings(defaults: defaults).commandPaletteOrder == builtIn)
            #expect(
                Fixture().typed("organize", settings).map(\.id)
                    == ["top", "actions", "suggestions", "tabs", "history"]
            )
        }
    }

    @Test func resettingAllSettingsRestoresTheOrder() {
        withSettings { settings, _ in
            settings.moveCommandPaletteSection(.tabs, by: -2)
            settings.resetToDefaults()

            #expect(settings.commandPaletteOrder == builtIn)
        }
    }

    @Test func aMoveOffEitherEndChangesNothing() {
        withSettings { settings, defaults in
            settings.moveCommandPaletteSection(.search, by: -1)
            settings.moveCommandPaletteSection(.recent, by: 1)

            #expect(settings.commandPaletteOrder == builtIn)
            #expect(defaults.object(forKey: BrowserSettings.Key.commandPaletteOrder) == nil)
        }
    }

    @Test func aDamagedStoredOrderIsRepaired() {
        withSettings { _, defaults in
            defaults.set(["tabs", "bogus", "tabs", "actions"], forKey: BrowserSettings.Key.commandPaletteOrder)
            let repaired = BrowserSettings(defaults: defaults).commandPaletteOrder

            #expect(Set(repaired) == Set(CommandPaletteSection.allCases))
            #expect(repaired.count == CommandPaletteSection.allCases.count)
            #expect(repaired.firstIndex(of: .tabs)! < repaired.firstIndex(of: .actions)!)
        }
    }

    @Test func aPartialOrderCannotHideASection() {
        withSettings { settings, _ in
            settings.commandPaletteOrder = [.recent]

            #expect(Set(settings.commandPaletteOrder) == Set(CommandPaletteSection.allCases))
            #expect(settings.commandPaletteOrder.count == CommandPaletteSection.allCases.count)
        }
    }

    @Test func aWindowSettingsObjectFollowsTheApplicationOrder() {
        let suites = (0..<2).map { "CommandPaletteOrder-\($0)-\(UUID().uuidString)" }
        let defaults = suites.compactMap { UserDefaults(suiteName: $0) }
        defer {
            for (suite, store) in zip(suites, defaults) {
                store.removePersistentDomain(forName: suite)
            }
        }
        let application = BrowserSettings(defaults: defaults[0])
        let window = BrowserSettings(defaults: defaults[0], sessionDefaults: defaults[1], application: application)

        application.moveCommandPaletteSection(.tabs, by: -2)
        #expect(window.commandPaletteOrder == application.commandPaletteOrder)
        #expect(window.commandPaletteOrder.first == .tabs)

        window.resetCommandPaletteOrder()
        #expect(application.commandPaletteOrder == builtIn)
    }

    // MARK: - Fixtures

    private func withSettings<T>(_ body: (BrowserSettings, UserDefaults) throws -> T) rethrows -> T {
        let suite = "CommandPaletteOrder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return try body(BrowserSettings(defaults: defaults), defaults)
    }

    /// Tabs and history that match "organize", "project" and "tabs.example", and a catalog with the Organize Tabs command.
    private struct Fixture {
        let history = HistoryStore(database: .temporary(), windowSize: 40)
        let tabs: [BrowserTab]
        let rankedTabs: [BrowserTab]

        init() {
            func tab(_ title: String, _ path: String) -> BrowserTab {
                let tab = BrowserTab(restoring: true)
                tab.title = title
                tab.urlString = "https://tabs.example/\(path)"
                return tab
            }
            // Relevance: a title that starts with the word beats one that contains a word that starts with it,
            // which beats a title that only contains it.
            let prefix = tab("Project plan", "a")
            let word = tab("Weekly project notes", "b")
            let inside = tab("Reproject", "c")
            let others = (0..<3).map { tab("Organize notes \($0)", "n\($0)") }
            tabs = [inside, word, prefix] + others
            rankedTabs = [prefix, word, inside]
            for index in 0..<4 {
                history.record(url: "https://docs.example/h/\(index)", title: "Organize project history \(index)")
            }
        }

        func typed(_ query: String, _ settings: BrowserSettings) -> [OmniboxSection] {
            CommandPaletteProjection.sections(
                query: query,
                agentName: "Assistant",
                context: CommandPaletteContext(historyCount: 12, tabCount: 6, hasActiveTab: true),
                history: history,
                tabs: tabs,
                phrases: ["organize my life", "project ideas"],
                actions: CommandPaletteActions(),
                settings: settings
            )
        }

        func searchHeading(_ query: String, _ settings: BrowserSettings) -> String? {
            typed(query, settings).first { $0.id == "top" }?.title
        }

        func resting(_ settings: BrowserSettings) -> [OmniboxSection] {
            CommandPaletteProjection.sections(
                query: "",
                agentName: "Assistant",
                context: CommandPaletteContext(historyCount: 12, tabCount: 6, hasActiveTab: true),
                history: history,
                tabs: Array(tabs.prefix(3)),
                phrases: [],
                actions: CommandPaletteActions(),
                settings: settings
            )
        }
    }
}
