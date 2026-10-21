// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Observation
import WebKit

struct CommandPaletteInteraction: Equatable {
    var query = "" {
        didSet {
            if query != oldValue {
                selection = 0
            }
        }
    }
    var selection = 0

    mutating func moveSelection(by delta: Int, resultCount: Int) {
        selection = OmniboxSelection.moved(from: selection, by: delta, resultCount: resultCount)
    }

    mutating func moveSection(by delta: Int, itemCounts: [Int]) {
        selection = OmniboxSelection.movedBySection(from: selection, by: delta, itemCounts: itemCounts)
    }

    mutating func clampSelection(to resultCount: Int) {
        guard resultCount > 0 else {
            selection = 0
            return
        }
        selection = min(max(selection, 0), resultCount - 1)
    }
}

struct CommandPaletteLayout: Equatable {
    static let fieldHeight: CGFloat = 62
    static let margin: CGFloat = 40

    let containerSize: CGSize

    var maxListHeight: CGFloat {
        min(420, max(120, containerSize.height - Self.fieldHeight - Self.margin * 2))
    }

    var topInset: CGFloat {
        max(Self.margin, (containerSize.height - Self.fieldHeight - maxListHeight) / 2)
    }

    var panelWidth: CGFloat {
        let preferred = min(max(containerSize.width * 0.5, 480), 680)
        return min(preferred, max(containerSize.width - Self.margin * 2, 0))
    }
}

enum CommandPaletteShortcutPolicy {
    static let arrowKeys: Set<String> = Set(
        [NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSLeftArrowFunctionKey, NSRightArrowFunctionKey]
            .compactMap { UnicodeScalar($0).map(String.init) }
    )

    static let returnKeys: Set<String> = ["\r", "\u{3}"]

    static func showsCurrentTab(modifiers: NSEvent.ModifierFlags) -> Bool {
        let actionModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return modifiers.intersection(actionModifiers) == .option
    }

    static func opensInCurrentTab(modifiers: NSEvent.ModifierFlags, key: String) -> Bool {
        showsCurrentTab(modifiers: modifiers) && returnKeys.contains(key)
    }

    static func shouldDismiss(_ event: NSEvent) -> Bool {
        let commandKey = event.modifierFlags.contains(.command)
            ? event.characters(byApplyingModifiers: .command)
            : nil
        return shouldDismiss(
            modifiers: event.modifierFlags,
            key: event.charactersIgnoringModifiers ?? "",
            commandKey: commandKey
        )
    }

    static func shouldDismiss(modifiers: NSEvent.ModifierFlags, key: String, commandKey: String? = nil) -> Bool {
        // Caps Lock and key-type flags do not change an editing shortcut.
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        let editingKeys: Set<String> = ["a", "c", "v", "x", "z"]
        // Some layouts use different letters while Command is held.
        let normalizedKey = (modifiers.contains(.command) ? commandKey ?? key : key).lowercased()
        let isTextEditing = modifiers == .command && editingKeys.contains(normalizedKey)
            || modifiers == [.command, .shift] && normalizedKey == "z"
            || modifiers == [.command, .option, .shift] && normalizedKey == "v"
        let isPaletteShortcut = modifiers == .command && (normalizedKey == "k" || normalizedKey == "t")
        let isListNavigation = arrowKeys.contains(key)
        let isRun = returnKeys.contains(key)
        let isCommand = !modifiers.isDisjoint(with: [.command, .control, .option])
        return isCommand && !isTextEditing && !isPaletteShortcut && !isListNavigation && !isRun
    }
}

struct CommandPaletteActions {
    var openCurrent: (URL) -> Void = { _ in }
    var ask: (String) -> Void = { _ in }
    var switchTo: (BrowserTab) -> Void = { _ in }
    var mention: (BrowserTab) -> Void = { _ in }
    var openNew: (URL) -> Void = { _ in }
    var perform: (CommandPaletteAction) -> Void = { _ in }
}

enum CommandPaletteProjection {
    static let commandPrefix = ">"

    static func placeholder(agentOnly: Bool) -> String {
        let resource: LocalizedStringResource = agentOnly
            ? "Search tabs, history, actions, or ask"
            : "Search tabs, history, actions, or the web"
        return String(localized: resource)
    }

    static func suggestionQuery(for query: String) -> String {
        commandQuery(in: query) == nil ? query : ""
    }

    static func isAssistantQuery(_ query: String, hasMentions: Bool, agentOnly: Bool) -> Bool {
        if hasMentions {
            return true
        }

        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return false }
        if AskSurfaceInteraction.agentPrompt(in: input) != nil {
            return true
        }
        return agentOnly && Omnibox.location(for: input) == nil
    }

    /// True for a query that starts spelling "archived tabs" or "show archived tabs". The longer phrase needs more
    /// than "show " so that a word like "show" alone stays an ordinary search.
    static func opensArchive(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 3 else { return false }
        return "archived tabs".hasPrefix(query)
            || query.count > "show ".count && "show archived tabs".hasPrefix(query)
    }

    static func commandQuery(in query: String) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.hasPrefix(commandPrefix) else { return nil }
        return String(query.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sections(
        query: String,
        agentName: String,
        context: CommandPaletteContext = CommandPaletteContext(),
        history: HistoryStore,
        tabs: [BrowserTab],
        mentions: [MentionChip] = [],
        activeTabID: UUID? = nil,
        recentTabIDs: [UUID] = [],
        phrases: [String],
        actions: CommandPaletteActions,
        settings: BrowserSettings = .application
    ) -> [OmniboxSection] {
        let commands = CommandPaletteCatalog.commands(context: context, perform: actions.perform)

        if let command = commandQuery(in: query) {
            guard !command.isEmpty else { return CommandPaletteCatalog.groupedSections(commands) }
            return [actionsSection(CommandPaletteCatalog.matching(command, in: commands))].compactMap { $0 }
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return restingSections(
                history: history,
                tabs: tabs,
                recentTabIDs: recentTabIDs,
                commands: commands,
                actions: actions,
                order: settings.commandPaletteOrder
            )
        }

        if AskSurfaceInteraction.mentionFragment(in: query) != nil {
            return AskSurfaceResults.sections(
                placement: .startPage,
                query: query,
                isFocused: true,
                isListening: false,
                currentURL: "",
                agentOnly: false,
                settings: settings,
                agentName: agentName,
                history: history,
                tabs: tabs,
                mentions: mentions,
                activeTabID: activeTabID,
                phrases: [],
                open: { _ in },
                switchTo: { _ in },
                mention: actions.mention,
                ask: { _ in }
            )
        }

        if let prompt = AskSurfaceInteraction.agentPrompt(in: needle) {
            return prompt.isEmpty ? [] : [askSection(prompt, agentName: agentName, ask: actions.ask)]
        }

        if !mentions.isEmpty {
            let prompt = MentionText.resolved(needle, chips: mentions)
            return [askSection(prompt, agentName: agentName, ask: actions.ask)]
        }

        let matching = CommandPaletteCatalog.matching(needle, in: commands)
        let matched = actionsSection(matching)
        let promoted = (matching.first.flatMap { CommandMatch.score($0, for: needle) } ?? 0) >= CommandMatch.strong
        let webItems = Omnibox.topSection(
            query: needle,
            settings: settings,
            symbol: OmniboxItem.Kind.newTab.defaultSymbol,
            openInCurrentTab: actions.openCurrent,
            open: actions.openNew
        )?.items ?? []
        let slots: [CommandPaletteSection: CommandPaletteBudget.Slot] = [
            .search: CommandPaletteBudget.Slot(
                OmniboxSection(
                    id: "top",
                    title: "",
                    items: webItems + [askItem(needle, agentName: agentName, ask: actions.ask)]
                ),
                floor: 1,
                quota: 2
            ),
            .suggestions: CommandPaletteBudget.Slot(
                Omnibox.phrasesSection(
                    query: needle,
                    phrases: phrases,
                    limit: 3,
                    settings: settings,
                    openInCurrentTab: actions.openCurrent,
                    open: actions.openNew
                ),
                floor: 2,
                quota: 3
            ),
            .tabs: CommandPaletteBudget.Slot(
                Omnibox.tabsSection(query: needle, tabs: tabs, limit: 4, switchTo: actions.switchTo),
                floor: 2,
                quota: 4
            ),
            .history: CommandPaletteBudget.Slot(
                Omnibox.historySection(
                    query: needle,
                    store: history,
                    limit: 5,
                    openInCurrentTab: actions.openCurrent,
                    open: actions.openNew
                ),
                floor: 2,
                quota: 5
            ),
            .actions: CommandPaletteBudget.Slot(matched, floor: 1, quota: 3),
        ]
        let order = CommandPaletteSection.typingOrder(
            settings.commandPaletteOrder,
            isAddress: Omnibox.location(for: needle) != nil,
            hasStrongCommand: promoted
        )
        return headingSearch(
            CommandPaletteBudget.fit(order.compactMap { slots[$0] }, total: CommandPaletteBudget.typing)
        )
    }

    /// Search or ask opens the palette without a heading. Anywhere else its rows would read as the end of the
    /// group above them, so they get one.
    private static func headingSearch(_ sections: [OmniboxSection]) -> [OmniboxSection] {
        sections.enumerated().map { index, section in
            guard index > 0, section.id == "top" else { return section }
            return OmniboxSection(
                id: section.id,
                title: String(localized: "Search or Ask"),
                hint: section.hint,
                items: section.items
            )
        }
    }

    private static func askSection(
        _ prompt: String,
        agentName: String,
        ask: @escaping (String) -> Void
    ) -> OmniboxSection {
        OmniboxSection(
            id: "ask",
            title: "",
            items: [askItem(prompt, agentName: agentName, ask: ask)]
        )
    }

    private static func askItem(
        _ prompt: String,
        agentName: String,
        ask: @escaping (String) -> Void
    ) -> OmniboxItem {
        OmniboxItem(
            id: "ask-agent",
            kind: .ask,
            title: prompt,
            detail: String(localized: "Ask \(agentName)"),
            shortcut: "⌘↩"
        ) {
            ask(prompt)
        }
    }

    private static func actionsSection(_ commands: [CommandPaletteCommand], hint: String = "") -> OmniboxSection? {
        guard !commands.isEmpty else { return nil }
        return OmniboxSection(
            id: "actions",
            title: String(localized: "Actions"),
            hint: hint,
            items: CommandPaletteCatalog.items(commands)
        )
    }

    private static func restingSections(
        history: HistoryStore,
        tabs: [BrowserTab],
        recentTabIDs: [UUID],
        commands: [CommandPaletteCommand],
        actions: CommandPaletteActions,
        order: [CommandPaletteSection]
    ) -> [OmniboxSection] {
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let recentlyUsedTabs = recentTabIDs.compactMap { tabsByID[$0] }
        let recentlyUsedIDs = Set(recentlyUsedTabs.map(\.id))
        let orderedTabs = recentlyUsedTabs + tabs.filter { !recentlyUsedIDs.contains($0.id) }
        let openTabs = orderedTabs.prefix(5).map { tab in
            let host = URL(string: tab.urlString)?.displayHost
            return OmniboxItem(
                id: "tab-\(tab.id)",
                kind: .tab,
                title: tab.title,
                detail: host ?? String(localized: "tab"),
                iconHost: host,
                completionText: tab.urlString
            ) {
                actions.switchTo(tab)
            }
        }

        let openURLs = Set(tabs.map(\.urlString))
        let recent = history.entries
            .filter { !openURLs.contains($0.url) }
            .prefix(8)
            .compactMap { entry -> OmniboxItem? in
                guard let url = URL(string: entry.url) else { return nil }
                return OmniboxItem(
                    id: "recent-\(entry.id)",
                    kind: .history,
                    title: entry.title,
                    detail: url.displayAddress ?? entry.url,
                    iconHost: url.displayHost,
                    completionText: url.absoluteString,
                    alternate: { actions.openCurrent(url) }
                ) {
                    actions.openNew(url)
                }
            }

        let slots: [CommandPaletteSection: CommandPaletteBudget.Slot] = [
            .tabs: CommandPaletteBudget.Slot(
                OmniboxSection(id: "tabs", title: String(localized: "Open Tabs"), items: openTabs),
                floor: 3,
                quota: 5
            ),
            .actions: CommandPaletteBudget.Slot(
                actionsSection(
                    CommandPaletteCatalog.suggested(commands),
                    hint: String(localized: "Type > for commands")
                ),
                floor: 3,
                quota: 6
            ),
            .recent: CommandPaletteBudget.Slot(
                OmniboxSection(id: "recent", title: String(localized: "Recently Visited"), items: Array(recent)),
                floor: 2,
                quota: 4
            ),
        ]
        return CommandPaletteBudget.fit(order.compactMap { slots[$0] }, total: CommandPaletteBudget.resting)
    }
}

@MainActor
@Observable
final class CommandPaletteModel {
    let browser: BrowserModel
    let coordinator: AppCoordinator
    let dismiss: () -> Void
    let suggestions = SearchSuggestions()

    var interaction = CommandPaletteInteraction() {
        didSet {
            guard interaction.query != oldValue.query, !isPreviewingSelection else { return }
            suggestionPreview.clear()
            if !isScoped {
                suggestions.update(
                    for: MentionText.stripped(
                        CommandPaletteProjection.suggestionQuery(for: interaction.query)
                    ),
                    settings: coordinator.context.settings
                )
            } else {
                suggestions.clear()
            }
            refreshSections()
        }
    }
    private(set) var sections: [OmniboxSection] = []
    private(set) var mentionedTabIDs: [UUID] = []
    private(set) var searchSite: SearchEngine?
    private(set) var showsArchive = false
    private var isPreviewingSelection = false
    private var suggestionPreview = OmniboxSuggestionPreview()

    var resultQuery: String {
        suggestionPreview.query ?? interaction.query
    }

    init(
        browser: BrowserModel,
        coordinator: AppCoordinator,
        dismiss: @escaping () -> Void
    ) {
        self.browser = browser
        self.coordinator = coordinator
        self.dismiss = dismiss
    }

    var placeholder: String {
        if let searchSite {
            return String(localized: "Search \(searchSite.name)")
        }
        if showsArchive {
            return String(localized: "Search archived tabs")
        }
        return CommandPaletteProjection.placeholder(agentOnly: Omnibox.isAgentOnly(settings: coordinator.context.settings))
    }

    /// Searching one site, or only the archive, replaces the usual results.
    private var isScoped: Bool {
        searchSite != nil || showsArchive
    }

    /// A private window has no archive to offer, whatever its store holds.
    private var archivedCount: Int {
        browser.opensPrivately ? 0 : browser.tabArchive.entries.count
    }

    var suggestedSite: SearchEngine? {
        guard !isScoped, mentionedTabIDs.isEmpty else { return nil }
        return SiteSearch.match(interaction.query, customEngine: coordinator.context.settings.searchEngine)
    }

    /// A site name wins over the archive when a query could mean either. A private window has no archive to offer.
    var suggestsArchive: Bool {
        !isScoped && mentionedTabIDs.isEmpty && suggestedSite == nil
            && archivedCount > 0
            && CommandPaletteProjection.opensArchive(interaction.query)
    }

    var scopeHint: String? {
        if let suggestedSite {
            return String(localized: "Search \(suggestedSite.name)")
        }
        return suggestsArchive ? String(localized: "Search archived tabs") : nil
    }

    @discardableResult
    func activateSiteSearch() -> Bool {
        if suggestsArchive {
            showArchive()
            return true
        }
        guard let site = suggestedSite else { return false }
        searchSite = site
        suggestionPreview.clear()
        suggestions.clear()
        interaction.query = ""
        refreshSections()
        return true
    }

    @discardableResult
    func removeSearchSite() -> Bool {
        guard isScoped else { return false }
        searchSite = nil
        showsArchive = false
        suggestionPreview.clear()
        interaction.selection = 0
        suggestions.update(
            for: MentionText.stripped(CommandPaletteProjection.suggestionQuery(for: interaction.query)),
            settings: coordinator.context.settings
        )
        refreshSections()
        return true
    }

    func prepare() {
        refreshSections()
    }

    func suggestionsDidChange() {
        guard suggestionPreview.sections == nil else { return }
        let selectedID = sections.flattened.indices.contains(interaction.selection)
            ? sections.flattened[interaction.selection].id
            : nil
        refreshSections()
        if let selectedID, let index = sections.flattened.firstIndex(where: { $0.id == selectedID }) {
            interaction.selection = index
        } else {
            interaction.selection = 0
        }
    }

    func moveSelection(by delta: Int) {
        interaction.moveSelection(by: delta, resultCount: sections.flattened.count)
        selectSuggestion(at: interaction.selection)
    }

    func moveSection(by delta: Int) {
        interaction.moveSection(by: delta, itemCounts: sections.itemCounts)
        selectSuggestion(at: interaction.selection)
    }

    func selectSuggestion(at index: Int) {
        guard let text = suggestionPreview.select(at: index, in: sections, query: interaction.query) else { return }
        isPreviewingSelection = true
        defer { isPreviewingSelection = false }
        interaction.query = text
        interaction.selection = index
    }

    func hoverSuggestion(at index: Int) {
        guard sections.flattened.indices.contains(index) else { return }
        interaction.selection = index
    }

    func submit() {
        guard !isScoped || !sections.isEmpty else { return }
        run(at: interaction.selection)
    }

    func submitInCurrentTab() {
        guard !isScoped || !sections.isEmpty else { return }
        runAlternate(at: interaction.selection)
    }

    func askWhateverIsTyped() {
        if isScoped {
            submit()
            return
        }
        ask(interaction.query)
    }

    func run(at index: Int) {
        let items = sections.flattened
        guard items.indices.contains(index) else {
            dismiss()
            return
        }
        items[index].run()
    }

    func runAlternate(at index: Int) {
        let items = sections.flattened
        guard items.indices.contains(index) else {
            dismiss()
            return
        }
        let item = items[index]
        (item.alternate ?? item.run)()
    }

    /// Deletes the row's entry from its store, then rebuilds the list and keeps the selection at the same position.
    func remove(at index: Int) {
        let items = sections.flattened
        guard items.indices.contains(index), let removal = items[index].remove else { return }
        removal()
        if let typed = suggestionPreview.query {
            suggestionPreview.clear()
            interaction.query = typed
        }
        refreshSections()
        interaction.selection = min(index, max(sections.flattened.count - 1, 0))
    }

    var mentionedTabs: [BrowserTab] {
        mentionedTabIDs.compactMap { id in
            browser.tabs.first { $0.id == id }
        }
    }

    var mentionChips: [MentionChip] {
        mentionedTabs.map { tab in
            MentionChip(id: tab.id, title: tab.title, host: URL(string: tab.urlString)?.displayHost)
        }
    }

    var contextPages: [AskContextPage] {
        guard !isScoped, CommandPaletteProjection.isAssistantQuery(
            interaction.query,
            hasMentions: !mentionedTabIDs.isEmpty,
            agentOnly: Omnibox.isAgentOnly(settings: coordinator.context.settings)
        ) else { return [] }
        return AskContext.pages(browser: browser, mentionedTabIDs: mentionedTabIDs)
    }

    func mention(_ tab: BrowserTab) {
        guard !mentionedTabIDs.contains(tab.id) else { return }
        mentionedTabIDs.append(tab.id)
        interaction.query = MentionText.appending(to: interaction.query)
        refreshSections()
    }

    func mentionsDidChange(_ ids: [UUID]) {
        guard mentionedTabIDs != ids else { return }
        mentionedTabIDs = ids
        refreshSections()
    }

    private func refreshSections() {
        guard suggestionPreview.sections == nil else { return }
        if let searchSite {
            let query = interaction.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, let url = searchSite.searchURL(for: query) {
                sections = [
                    OmniboxSection(id: "site-search", title: "", items: [
                        OmniboxItem(
                            id: "site-search-\(searchSite.id)",
                            kind: .search,
                            title: query,
                            detail: String(localized: "Search \(searchSite.name)"),
                            iconHost: searchSite.host,
                            alternate: { [weak self] in self?.openCurrent(url) },
                            run: { [weak self] in self?.openNew(url) }
                        ),
                    ]),
                ]
            } else {
                sections = []
            }
            interaction.clampSelection(to: sections.flattened.count)
            return
        }
        if showsArchive {
            let archive = browser.tabArchive
            let section = Omnibox.archivedSection(
                query: interaction.query,
                entries: archive.entries,
                excluding: Set(browser.tabs.map(\.urlString)),
                restore: { [weak self] entry in self?.restore(entry) },
                remove: { archive.remove($0) }
            )
            sections = section.map { [$0] } ?? []
            interaction.clampSelection(to: sections.flattened.count)
            return
        }
        sections = CommandPaletteProjection.sections(
            query: interaction.query,
            agentName: coordinator.agentDisplayName,
            context: context,
            history: browser.history,
            tabs: browser.tabs,
            mentions: mentionChips,
            activeTabID: browser.activeTab?.id,
            recentTabIDs: browser.recentlyActive,
            phrases: suggestions.phrases,
            actions: projectionActions,
            settings: coordinator.context.settings
        )
        interaction.clampSelection(to: sections.flattened.count)
    }

    private var context: CommandPaletteContext {
        let tab = browser.activeTab
        let page = coordinator.pageCommandTab
        let split = browser.activeSplit
        let window = coordinator.nativeWindow
        return CommandPaletteContext(
            isSpeechMuted: coordinator.isSpeechMuted,
            isListening: coordinator.voiceInput.phase == .listening,
            historyCount: browser.history.count,
            tabCount: browser.tabs.count,
            hasActiveTab: tab != nil,
            canReload: page?.canReload ?? false,
            canGoBack: page?.canGoBack ?? false,
            canGoForward: page?.canGoForward ?? false,
            isLoading: page?.isLoading ?? false,
            isZoomed: page?.isZoomed ?? false,
            isShowingPin: tab?.isShowingPin ?? false,
            isAwayFromPin: tab?.isAwayFromPin ?? false,
            canReopenClosedTab: browser.canReopenClosedTab,
            archivedCount: archivedCount,
            canSplit: tab != nil && !(split?.isFull ?? false),
            isSplit: coordinator.isSplit,
            canSwapPanes: browser.activeTabID.flatMap { split?.sibling(of: $0) } != nil,
            isStacked: split?.axis == .stacked,
            hasSplitAxis: split?.axis != nil,
            isSidebarVisible: coordinator.sidebar.isVisible,
            isActivityVisible: coordinator.sidePanel.isShowing(.activity),
            isLyricsVisible: coordinator.sidePanel.isShowing(.lyrics),
            canShowLyrics: BrowserSettings.application.showsLyrics,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false,
            canCheckForUpdates: coordinator.updates.canCheck,
            hasExternalConnections: coordinator.hasExternalConnections
        )
    }

    private var projectionActions: CommandPaletteActions {
        CommandPaletteActions(
            openCurrent: { [weak self] url in self?.openCurrent(url) },
            ask: { [weak self] prompt in self?.ask(prompt) },
            switchTo: { [weak self] tab in self?.switchTo(tab) },
            mention: { [weak self] tab in self?.mention(tab) },
            openNew: { [weak self] url in self?.openNew(url) },
            perform: { [weak self] action in self?.perform(action) }
        )
    }

    private func openCurrent(_ url: URL) {
        browser.ensureActiveTab().load(url)
        dismiss()
    }

    private func ask(_ prompt: String) {
        let prompt = MentionText.resolved(prompt, chips: mentionChips)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let mentions = mentionedTabIDs
        mentionedTabIDs = []
        dismiss()
        Task { await coordinator.handleTypedUtterance(prompt, mentionedTabIDs: mentions) }
    }

    private func switchTo(_ tab: BrowserTab) {
        coordinator.openTab(tab)
        dismiss()
    }

    private func restore(_ entry: TabArchive.Entry) {
        browser.restore(entry)
        dismiss()
    }

    private func openNew(_ url: URL) {
        coordinator.openNewTab(url: url)
        dismiss()
    }

    private func showArchive() {
        guard archivedCount > 0 else { return }
        showsArchive = true
        mentionedTabIDs = []
        suggestionPreview.clear()
        suggestions.clear()
        interaction.query = ""
        refreshSections()
    }

    private func perform(_ action: CommandPaletteAction) {  // swiftlint:disable:this cyclomatic_complexity
        if action == .showArchivedTabs {
            showArchive()
            return
        }
        dismiss()
        let tab = browser.activeTab
        let page = coordinator.pageCommandTab
        switch action {
        case .newTab:
            coordinator.requestNewTab()
        case .newWindow:
            coordinator.requestNewWindow()
        case .openStartPage:
            coordinator.openNewTab()
        case .openLocation:
            coordinator.focusAddressBar()
        case .privateBrowsing:
            coordinator.requestNewWindow(isPrivate: true)
        case .unloadTab:
            if !coordinator.closePeek(), let tab {
                coordinator.unloadTab(tab)
            }
        case .freeMemory:
            coordinator.freeMemory()
        case .reopenTab:
            browser.reopenLastClosedTab()
        case .showArchivedTabs:
            break
        case .duplicateTab:
            if let tab {
                browser.duplicate(tab)
            }
        case .togglePin:
            coordinator.togglePin()
        case .returnToPin:
            if let tab {
                browser.returnToPin(tab)
            }
        case .organizeTabs:
            coordinator.organizeTabs()
        case .nextTab:
            browser.cycleTab(forward: true)
        case .previousTab:
            browser.cycleTab(forward: false)
        case .lastTab:
            browser.activateLastTab()
        case .showTab1, .showTab2, .showTab3, .showTab4, .showTab5, .showTab6, .showTab7, .showTab8:
            if let index = CommandPaletteAction.indexedTabs.firstIndex(of: action) {
                browser.activateTab(at: index)
            }
        case .reload:
            page?.reload()
        case .hardReload:
            page?.page.reloadFromOrigin()
        case .stopLoading:
            page?.stopLoading()
        case .goBack:
            page?.goBack()
        case .goForward:
            page?.goForward()
        case .find:
            page?.find.open()
        case .findNext:
            page?.find.findNext(backwards: false)
        case .findPrevious:
            page?.find.findNext(backwards: true)
        case .copyLink:
            coordinator.copyCurrentURL()
        case .printPage:
            coordinator.printActivePage()
        case .zoomIn:
            page?.zoomIn()
        case .zoomOut:
            page?.zoomOut()
        case .actualSize:
            page?.resetZoom()
        case .splitRight:
            coordinator.splitActiveTab(axis: .sideBySide)
        case .splitDown:
            coordinator.splitActiveTab(axis: .stacked)
        case .otherPane:
            coordinator.focusOtherPane()
        case .swapPanes:
            coordinator.swapSplitPanes()
        case .toggleSplitAxis:
            coordinator.toggleSplitAxis()
        case .exitSplit:
            coordinator.exitSplit()
        case .closeOtherPanes:
            coordinator.closeOtherPanes()
        case .toggleSidebar, .toggleActivity, .toggleLyrics, .toggleFullScreen, .closeWindow, .minimizeWindow,
            .toggleSpeech, .toggleListening, .stopExternalConnections, .showHistory, .showDownloads, .clearHistory,
            .settings, .extensions, .checkForUpdates, .releaseNotes, .aboutWSurf, .quitWSurf:
            performApplicationAction(action)
        }
    }

    /// The window, panel and app commands. `perform` forwards exactly these, so a new action still has to be placed there.
    private func performApplicationAction(_ action: CommandPaletteAction) {
        switch action {
        case .toggleSidebar:
            coordinator.toggleSidebar()
        case .toggleActivity:
            coordinator.toggleAgentInspector()
        case .toggleLyrics:
            coordinator.toggleLyrics()
        case .toggleFullScreen:
            coordinator.toggleFullScreen()
        case .closeWindow:
            (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
        case .minimizeWindow:
            (NSApp.keyWindow ?? NSApp.mainWindow)?.performMiniaturize(nil)
        case .toggleSpeech:
            coordinator.toggleSpeechMute()
        case .toggleListening:
            coordinator.toggleMicListening()
        case .stopExternalConnections:
            coordinator.stopExternalConnections()
        case .showHistory:
            coordinator.showHistory()
        case .showDownloads:
            coordinator.showDownloads()
        case .clearHistory:
            coordinator.confirmClearHistory()
        case .settings:
            coordinator.openSettings()
        case .extensions:
            coordinator.openSettings(.extensions)
        case .checkForUpdates:
            coordinator.updates.checkNow()
        case .releaseNotes:
            coordinator.showReleaseNotes()
        case .aboutWSurf:
            BuildIdentity.showAboutPanel()
        case .quitWSurf:
            NSApp.terminate(nil)
        default:
            break
        }
    }
}
