// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A window whose File menu is installed, so ⌘W goes through AppKit's own key-equivalent dispatch and validation.
@MainActor
private final class CloseTabWindow {
    let coordinator: AppCoordinator
    let menu: MainMenu
    let root: NSMenu
    /// The File menu item on ⌘W.
    let item: NSMenuItem

    @MainActor
    private struct SavedMenus {
        let main = NSApp.mainMenu
        let windows = NSApp.windowsMenu
        let help = NSApp.helpMenu
        let services = NSApp.servicesMenu
    }

    private let savedMenus = SavedMenus()

    init(browser: BrowserModel = BrowserModel(database: .temporary())) throws {
        coordinator = AppCoordinator(browser: browser)
        menu = MainMenu(coordinator: coordinator)
        menu.install()
        root = try #require(NSApp.mainMenu)
        item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command })
    }

    var browser: BrowserModel {
        coordinator.browser
    }

    /// The title the item shows once the menu has validated it for the current active tab.
    var title: String {
        _ = menu.validateMenuItem(item)
        return item.title
    }

    /// A tab that shows `name` on screen, as a page that has loaded: the address is set by hand so nothing navigates.
    @discardableResult
    func page(_ name: String, activate: Bool = true) -> BrowserTab {
        let tab = browser.newTab(activate: activate)
        tab.urlString = "https://example.test/\(name)"
        tab.pageTitle = name
        return tab
    }

    @discardableResult
    func press(_ key: String, modifiers: NSEvent.ModifierFlags = .command) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ) else { return false }
        return root.performKeyEquivalent(with: event)
    }

    func closeTab() {
        press("w")
    }

    func tearDown() {
        coordinator.closePeekImmediately()
        browser.closeAllTabs(saving: false)
        NSApp.mainMenu = savedMenus.main
        NSApp.windowsMenu = savedMenus.windows
        NSApp.helpMenu = savedMenus.help
        NSApp.servicesMenu = savedMenus.services
    }
}

/// ⌘W on the active tab: a Peek closes first; a tab that is pinned, a Favorite or inside a pinned folder unloads; any other
/// tab closes the way its sidebar X does, with the sidebar undo and ⇧⌘T. The File menu item names the one it will do.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct CloseTabCommandTests {
    // MARK: - An unpinned tab closes

    @Test func anUnpinnedTabClosesAndComesBackWithUndoOrReopen() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        let browser = window.browser
        let other = window.page("other")
        let tab = window.page("doomed")
        #expect(window.title == "Close Tab")

        window.closeTab()

        #expect(tab.isClosed)
        #expect(browser.tab(id: tab.id) == nil)
        #expect(browser.activeTab === other)
        #expect(browser.canReopenClosedTab)
        #expect(browser.sidebarUndoManager.undoActionName == "Close Tab")

        browser.sidebarUndoManager.undo()
        let restored = try #require(browser.tab(id: tab.id))
        #expect(restored.urlString == "https://example.test/doomed")
        #expect(browser.activeTab === restored)
        #expect(!browser.canReopenClosedTab)

        window.closeTab()
        #expect(browser.tab(id: tab.id) == nil)
        #expect(window.press("T", modifiers: [.command, .shift]), "⇧⌘T answers after ⌘W")
        #expect(browser.tab(id: tab.id) != nil)
    }

    @Test func aTabInASpaceIsStillAnOrdinaryTab() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        window.page("other")
        let tab = window.page("spaced")
        tab.spaceID = UUID()

        #expect(window.title == "Close Tab")
        window.closeTab()
        #expect(tab.isClosed)
    }

    // MARK: - A pinned tab unloads

    enum Kept: String, CaseIterable, CustomStringConvertible {
        case pin
        case favorite
        case pageInPinnedFolder

        var description: String {
            rawValue
        }

        /// Makes `tab` that kind of persistent row.
        @MainActor
        func keep(_ tab: BrowserTab, in browser: BrowserModel) throws {
            switch self {
            case .pin:
                browser.pin(tab)
            case .favorite:
                browser.addFavorite(tab)
            case .pageInPinnedFolder:
                let folder = browser.createFolder(named: "Work", containing: [tab])
                browser.pin(folder)
                // The window publishes its pinned folders to the profile, which links each page inside to its pin.
                browser.attachProfilePins()
                try #require(tab.pinID != nil, "a page in a pinned folder carries its pin link")
                #expect(tab.pinnedURL == nil, "and has no bookmark of its own, unlike the pin and the Favorite")
            }
        }
    }

    @Test(arguments: Kept.allCases) func aPersistentTabUnloadsAndStaysInTheSidebar(kind: Kept) throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        let browser = window.browser
        let other = window.page("other")
        let tab = window.page("kept")
        try kind.keep(tab, in: browser)
        browser.activate(tab)
        #expect(window.title == "Unload Tab")

        window.closeTab()

        #expect(tab.isDeferred)
        #expect(!tab.isMaterialised)
        #expect(!tab.isClosed)
        #expect(browser.tab(id: tab.id) === tab)
        #expect(browser.sidebarTree.walk().contains(.tab(tab.id)))
        #expect(tab.urlString == "https://example.test/kept")
        #expect(browser.activeTab === other)
        #expect(!browser.canReopenClosedTab)
        #expect(!browser.sidebarUndoManager.canUndo, "nothing was removed, so there is nothing to undo")
    }

    @Test func aRefusedUnloadShowsTheSameNoticeAndKeepsThePageLoaded() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        let browser = window.browser
        window.page("other")
        let tab = window.page("busy")
        browser.pin(tab)
        tab.setAgentWorking(true)

        window.closeTab()

        #expect(window.coordinator.notice == String(localized: "The assistant is working in this tab."))
        #expect(tab.isMaterialised)
        #expect(!tab.isDeferred)
        #expect(!tab.isClosed)
        #expect(browser.activeTab === tab)
    }

    // MARK: - Peek

    private func showPeek(in window: CloseTabWindow) -> BrowserTab {
        let peek = window.browser.makePeekTab(URL(string: "about:blank")!)
        window.coordinator.peek.show(peek, from: window.browser.activeTabID, at: .zero)
        return peek
    }

    @Test func aPeekClosesBeforeAnUnpinnedTab() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        let tab = window.page("page")
        _ = showPeek(in: window)

        window.closeTab()

        #expect(window.coordinator.peek.tab == nil)
        #expect(!tab.isClosed)
        #expect(window.browser.tab(id: tab.id) === tab)
        #expect(!window.browser.sidebarUndoManager.canUndo)

        window.closeTab()
        #expect(tab.isClosed)
    }

    @Test func aPeekClosesBeforeAPinnedTabUnloads() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        window.page("other")
        let tab = window.page("pinned")
        window.browser.pin(tab)
        _ = showPeek(in: window)

        window.closeTab()

        #expect(window.coordinator.peek.tab == nil)
        #expect(tab.isMaterialised)
        #expect(!tab.isDeferred)

        window.closeTab()
        #expect(tab.isDeferred)
        #expect(!tab.isClosed)
    }

    // MARK: - Where the sidebar X decides

    @Test func theLastTabClosesAndLeavesTheWindowEmptyLikeTheSidebarX() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        let browser = window.browser
        let tab = window.page("only")

        window.closeTab()

        #expect(tab.isClosed)
        #expect(browser.tabs.isEmpty)
        #expect(browser.activeTab == nil)
        #expect(!window.coordinator.isClosed, "the window stays, as it does after the sidebar X")
        #expect(!window.menu.validateMenuItem(window.item), "with no tab ⌘W has nothing to act on")
        #expect(window.item.title == "Close Tab")

        browser.sidebarUndoManager.undo()
        #expect(browser.activeTab?.id == tab.id)
    }

    @Test func aSplitPaneClosesAloneAndItsSiblingTakesOver() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        let browser = window.browser
        let sibling = window.page("sibling")
        let pane = window.page("pane")
        browser.split(pane, with: sibling, axis: .sideBySide)
        browser.activate(pane)

        window.closeTab()

        #expect(pane.isClosed)
        #expect(!sibling.isClosed)
        #expect(browser.activeTab === sibling)
        #expect(browser.activeSplit == nil)

        browser.sidebarUndoManager.undo()
        let restored = try #require(browser.tab(id: pane.id))
        #expect(browser.isVisibleInSplit(restored))
    }

    @Test func aPrivateTabClosesWithoutARecordLikeTheSidebarX() throws {
        let browser = BrowserModel(context: BrowserProfileContext.shared(for: .privateBrowsing()), windowID: UUID())
        let window = try CloseTabWindow(browser: browser)
        defer { window.tearDown() }
        window.page("other")
        let tab = window.page("private")
        #expect(tab.isPrivate)
        #expect(window.title == "Close Tab")

        window.closeTab()

        #expect(tab.isClosed)
        #expect(!browser.canReopenClosedTab)
        browser.sidebarUndoManager.undo()
        #expect(browser.tab(id: tab.id) == nil, "a private tab leaves nothing to restore")
    }

    // MARK: - The menu item

    @Test func theItemKeepsCommandWAndNamesWhatItWillDo() throws {
        let window = try CloseTabWindow()
        defer { window.tearDown() }
        let browser = window.browser
        let plain = window.page("plain")
        let pinned = window.page("pinned")
        browser.pin(pinned)
        let favorite = window.page("favorite")
        browser.addFavorite(favorite)
        let folder = browser.createFolder(named: "Work", containing: [window.page("folder")])
        browser.pin(folder)
        browser.attachProfilePins()
        let inFolder = try #require(browser.tabs(in: folder).first)

        #expect(window.item.keyEquivalent == "w")
        #expect(window.item.keyEquivalentModifierMask == .command)
        for (tab, expected) in [
            (plain, "Close Tab"), (pinned, "Unload Tab"), (favorite, "Unload Tab"),
            (inFolder, "Unload Tab"), (plain, "Close Tab"),
        ] {
            browser.activate(tab)
            #expect(window.menu.validateMenuItem(window.item))
            #expect(window.item.title == expected)
        }

        browser.activate(pinned)
        window.item.menu?.update()
        #expect(window.item.title == "Unload Tab", "the File menu validates the title as it opens")
        browser.activate(plain)
        window.item.menu?.update()
        #expect(window.item.title == "Close Tab")
    }
}
