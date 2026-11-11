// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Testing
import WebKit

@testable import WSurf

/// Key equivalents through AppKit's own dispatch, not a direct selector
/// call: `performKeyEquivalent(with:)` is exactly what the app does with a
/// keystroke, so a hidden item that AppKit would skip fails here too. This
/// is the test that catches `allowsKeyEquivalentWhenHidden` being lost -
/// without it every hidden alias (⌘=, ⌘1-9, ⌃Tab) beeps.
@MainActor
struct MainMenuKeyTests {
    private func pressed(_ character: String, modifiers: NSEvent.ModifierFlags, in menu: NSMenu) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ) else { return false }
        return menu.performKeyEquivalent(with: event)
    }

    @Test func aHiddenAliasStillAnswersItsKey() throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)

        #expect(pressed("=", modifiers: .command, in: root), "⌘= is the hidden alias for Zoom In")
    }

    @Test func commandNIsBoundToNewWindow() throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.title == String(localized: "New Window") })

        #expect(item.keyEquivalent == "n")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(menu.validateMenuItem(item))
    }

    // Shift-letter shortcuts use the uppercase character in AppKit's menu matching.
    @Test func shiftCommandNIsBoundToNewPrivateWindow() throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)

        let item = try #require(
            root.items
                .compactMap(\.submenu)
                .flatMap(\.items)
                .first { $0.title == String(localized: "New Private Window") }
        )
        #expect(item.keyEquivalent == "N")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.isEnabled)
    }

    private func event(_ character: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ))
    }

    /// A site that calls `preventDefault` on every keydown - hackertyper.com
    /// is the one people meet - reports ⌘R, ⌘T and ⌘K as handled, and the
    /// views are offered a key equivalent before the main menu.
    @Test func browserCommandsOutrankThePage() throws {
        for key in ["r", "t", "k", "l", "w", "y", "["] {
            #expect(ShortcutPriority.menuAnswersFirst(try event(key, modifiers: .command)))
        }
        #expect(ShortcutPriority.menuAnswersFirst(try event("T", modifiers: [.command, .shift])))
        #expect(ShortcutPriority.menuAnswersFirst(try event("C", modifiers: [.command, .shift])))
        #expect(ShortcutPriority.menuAnswersFirst(try event("\t", modifiers: .control)))
    }

    /// Editing and find act on what is focused, so a page keeps them: web
    /// editors carry their own undo and their own find.
    @Test func editingAndFindStayWithThePage() throws {
        for key in ["z", "x", "c", "v", "a", "f", "g"] {
            #expect(!ShortcutPriority.menuAnswersFirst(try event(key, modifiers: .command)))
        }
        for key in [NSLeftArrowFunctionKey, NSRightArrowFunctionKey] {
            let arrow = String(UnicodeScalar(key)!)
            #expect(!ShortcutPriority.menuAnswersFirst(try event(arrow, modifiers: .command)))
        }
        #expect(!ShortcutPriority.menuAnswersFirst(try event("Z", modifiers: [.command, .shift])))
        #expect(!ShortcutPriority.menuAnswersFirst(try event("G", modifiers: [.command, .shift])))
    }

    /// A plain keystroke is not a key equivalent; nothing about its route
    /// changes.
    @Test func typingIsUntouched() throws {
        #expect(!ShortcutPriority.menuAnswersFirst(try event("a", modifiers: [])))
        #expect(!ShortcutPriority.menuAnswersFirst(try event("A", modifiers: .shift)))
    }

    @Test func privateWindowsUseTheNormalCloseWindowCommand() throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let items = root.items.compactMap(\.submenu).flatMap(\.items)
        #expect(!items.contains { $0.title == String(localized: "Leave Private Browsing") })
        #expect(items.contains { $0.title == String(localized: "Close Window") })
    }

    @Test func windowCommandsStayAvailableWithoutAnOpenBrowserWindow() throws {
        let app = BrowserApplication()
        let menu = MainMenu(application: app)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let items = root.items.compactMap(\.submenu).flatMap(\.items)

        for title in [String(localized: "New Window"), String(localized: "New Private Window")] {
            let item = try #require(items.first { $0.title == title })
            #expect(menu.validateMenuItem(item))
        }
        let reopen = try #require(items.first { $0.title == String(localized: "Reopen Last Closed Window") })
        #expect(menu.validateMenuItem(reopen) == app.canReopenWindow)
        #expect(app.windows.isEmpty, "Validating a menu must not create a browser window")
    }

    // MARK: - Passwords window

    /// Production builds the menu over the application, and with no browser window open `validateMenuItem` refuses everything not in
    /// `withoutAWindow`. `MainMenu(coordinator:)` skips that gate, so these cases use the application with no coordinator.
    @Test func passwordsAnswersOptionCommandKWithNoBrowserWindow() throws {
        let app = BrowserApplication()
        let menu = MainMenu(application: app)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let items = root.items.compactMap(\.submenu).flatMap(\.items)
        let item = try #require(items.first { $0.title == String(localized: "Passwords…") })

        #expect(item.keyEquivalent == "k")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        #expect(menu.validateMenuItem(item), "Passwords… works with no browser window open")
        let search = try #require(items.first { $0.title == String(localized: "Search Everything…") })
        #expect(search.keyEquivalentModifierMask == [.command], "⌘K stays Search Everything")
        #expect(app.windows.isEmpty, "Validating a menu must not create a browser window")
    }

    @Test func optionCommandKOpensThePasswordsWindowAndNoBrowserWindow() throws {
        let rig = PasswordsWindowRig()
        let shared = PasswordsWindow.shared
        PasswordsWindow.shared = rig.controller
        let app = BrowserApplication()
        let menu = MainMenu(application: app)
        menu.install()
        defer {
            NSApp.mainMenu = nil
            PasswordsWindow.shared = shared
            rig.tearDown()
        }
        let root = try #require(NSApp.mainMenu)

        #expect(pressed("k", modifiers: [.command, .option], in: root))

        #expect(rig.controller.window?.isVisible == true)
        #expect(app.windows.isEmpty, "Opening Passwords must not create a browser window")
    }

    /// A window is key only in an active app, which a test host in the background is not and cannot make itself: the menu reads
    /// the key window through `PasswordsWindow.keyWindow`, which a test points at the window it means to be key.
    private func makeKey(_ window: NSWindow) -> () -> Void {
        let original = PasswordsWindow.keyWindow
        PasswordsWindow.keyWindow = { window }
        return { PasswordsWindow.keyWindow = original }
    }

    /// ⌘W with the Passwords window as the only window open: Close Tab is enabled for it, closes it, and opens no browser window.
    @Test func commandWClosesThePasswordsWindowWhenItIsAllThatIsOpen() async throws {
        let rig = PasswordsWindowRig()
        let app = BrowserApplication()
        let menu = MainMenu(application: app)
        menu.install()
        var restoreKey: () -> Void = {}
        defer {
            restoreKey()
            NSApp.mainMenu = nil
            rig.tearDown()
        }
        let root = try #require(NSApp.mainMenu)
        let close = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command })
        rig.controller.show()
        let window = try #require(rig.controller.window)
        restoreKey = makeKey(window)

        #expect(menu.validateMenuItem(close), "⌘W is enabled although no browser window is open")
        #expect(pressed("w", modifiers: .command, in: root))

        #expect(!window.isVisible)
        #expect(window.contentViewController == nil)
        #expect(app.windows.isEmpty, "⌘W must not open a browser window")
    }

    @Test func commandWClosesThePasswordsWindowNotATabBehindIt() async throws {
        let rig = PasswordsWindowRig()
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        var restoreKey: () -> Void = {}
        defer {
            restoreKey()
            NSApp.mainMenu = nil
            coordinator.closePeekImmediately()
            coordinator.browser.closeAllTabs(saving: false)
            rig.tearDown()
        }
        let root = try #require(NSApp.mainMenu)
        let tab = coordinator.browser.newTab()
        tab.urlString = "https://example.test/behind"
        let tabs = coordinator.browser.tabs.count
        rig.controller.show()
        let window = try #require(rig.controller.window)
        restoreKey = makeKey(window)

        #expect(pressed("w", modifiers: .command, in: root))

        #expect(!window.isVisible)
        #expect(coordinator.browser.tabs.count == tabs)
        #expect(!tab.isClosed)
    }

    @Test func translatePageWaitsForAWebPage() throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.title == String(localized: "Translate Page") })

        #expect(!menu.validateMenuItem(item), "there is no web page to translate")
        #expect(item.title == String(localized: "Translate Page"))
        #expect(item.keyEquivalent.isEmpty)
    }

    @Test(.boundedWebViews) func commandsActOnTheFocusedWindow() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Unload target</title><p>Loaded</p>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let app = BrowserApplication()
        let context = BrowserProfileContext.shared(for: .original())
        let first = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        let second = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        app.register(first)
        app.register(second)
        let firstTab = first.browser.newTab()
        let secondTab = second.browser.newTab(url: try server.url("/"))
        try #require(await PageSettle.untilIdle(secondTab.page))
        try #require(secondTab.canDiscardWebContent)
        second.browser.pin(secondTab)  // ⌘W unloads a pinned tab and closes any other
        let menu = MainMenu(application: app)
        menu.install()
        defer {
            NSApp.mainMenu = nil
            first.closeWindow()
            second.closeWindow()
        }
        let root = try #require(NSApp.mainMenu)
        app.focus(second)
        #expect(pressed("w", modifiers: .command, in: root))
        #expect(!secondTab.isMaterialised)
        #expect(secondTab.isDeferred)
        #expect(second.browser.tab(id: secondTab.id) === secondTab)
        #expect(!firstTab.isClosed)
        #expect(first.browser.activeTab === firstTab)
    }
}
