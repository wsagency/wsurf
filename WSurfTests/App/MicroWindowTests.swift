// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import GRDB
import Testing

@testable import WSurf

/// The micro window: one page and no chrome until the pointer reaches the top. It is a window of its own kind, so these
/// tests hold the places where that kind has to differ from a standard window.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MicroWindowTests {
    /// Runs `body` with a profile of its own, so the saved windows of other suites cannot be restored with it.
    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Micro windows")
        var failure: (any Error)?
        do {
            try await body(profile)
        } catch {
            failure = error
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    /// One app run. Runs that share `defaults` follow each other, as launches of the installed app do.
    private func run(_ defaults: UserDefaults = InMemoryUserDefaults(inheriting: .standard)) -> BrowserApplication {
        BrowserApplication(defaults: defaults, notifications: NotificationCenter())
    }

    /// The steps of a quit in the order the application delegate and AppKit take them.
    private func quit(_ app: BrowserApplication) async throws {
        for coordinator in app.windows {
            coordinator.browser.saveBlocking()
        }
        try await app.clearDataOnQuitIfNeeded()
        await app.closeTabsForTermination()
        app.finishTermination()
        for coordinator in app.windows {
            coordinator.nativeWindow?.close()
        }
    }

    private func finish(_ app: BrowserApplication) {
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
    }

    // MARK: - A micro window holds one page

    @Test func aNewMicroWindowHoldsOnePageAndNoPins() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            main.browser.pinned("https://one.example/")
            main.browser.pin(main.browser.createFolder(named: "Work"))
            let pins = main.browser.pinStore.pins
            let outline = main.browser.pinOutline

            let micro = app.newWindow(profile: profile, show: false, kind: .micro)

            #expect(micro.isMicro && !main.isMicro)
            #expect(micro.browser.windowKind == .micro)
            #expect(micro.browser.tabs.count == 1)
            #expect(micro.browser.tabs.allSatisfy { $0.pinID == nil && $0.pinnedURL == nil })
            #expect(micro.browser.attachedPinStore == nil)
            #expect(micro.browser.folders.isEmpty)
            micro.browser.saveBlocking()
            micro.closeWindow()
            // Closing a window that never attached the set must not publish an empty one.
            #expect(main.browser.pinStore.pins == pins)
            #expect(main.browser.pinOutline == outline)
            finish(app)
        }
    }

    // MARK: - Restoring

    @Test func microWindowsRestoreAsMicroAfterTheirMainWindow() async throws {
        try await withProfile { profile in
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            let first = run(defaults)
            // Opened first, so it is the one a naive restore would reach first.
            let micro = first.newWindow(profile: profile, show: false, kind: .micro)
            let main = first.newWindow(profile: profile, show: false)
            let database = main.context.database
            micro.browser.saveBlocking()
            main.browser.saveBlocking()

            let saved = BrowserModel.savedWindows(in: database)
            #expect(Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.windowKind) })
                == [micro.windowID: .micro, main.windowID: .standard])
            #expect(saved.first { $0.id == main.windowID }?.kind == nil, "a standard window stores no kind")
            // A row written before micro windows has no kind at all.
            let legacyID = UUID()
            try await database.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO sessionWindow (id, lastActiveAt, closedAt, revision) VALUES (?, ?, NULL, 0)",
                    arguments: [legacyID, Date()]
                )
            }
            #expect(BrowserModel.savedWindows(in: database).first { $0.id == legacyID }?.windowKind == .standard)
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM sessionWindow WHERE id = ?", arguments: [legacyID])
            }

            try await quit(first)

            let next = run(defaults)
            next.restoreWindows(of: [profile], show: false)
            #expect(next.windows.map(\.windowID) == [main.windowID, micro.windowID], "standard windows open before micro ones")
            #expect(next.windows.map(\.isMicro) == [false, true])
            #expect(next.windows.last?.browser.attachedPinStore == nil)
            finish(next)
        }
    }

    @Test func aMicroWindowOpenAtQuitDoesNotHideThatTheMainWindowClosedLast() async throws {
        try await withProfile { profile in
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            let first = run(defaults)
            let micro = first.newWindow(profile: profile, show: false, kind: .micro)
            let main = first.newWindow(profile: profile, show: false)
            let database = main.context.database

            main.closeWindow()
            #expect(
                defaults.stringArray(forKey: BrowserApplication.closedAsLastKey) == [profile.id.uuidString, main.windowID.uuidString],
                "the main window was the last regular window"
            )
            // Opening a micro window is not opening a window to browse in.
            let another = first.newWindow(profile: profile, show: false, kind: .micro)
            #expect(defaults.stringArray(forKey: BrowserApplication.closedAsLastKey) != nil)
            another.closeWindow()
            #expect(defaults.stringArray(forKey: BrowserApplication.closedAsLastKey)
                == [profile.id.uuidString, main.windowID.uuidString], "closing a micro window leaves it as it was")
            micro.browser.saveBlocking()
            #expect(BrowserModel.savedWindows(in: database).map(\.id) == [micro.windowID])

            try await quit(first)

            let next = run(defaults)
            next.restoreWindows(of: [profile], show: false)
            #expect(next.windows.map(\.windowID) == [main.windowID, micro.windowID], "the main window comes back first")
            #expect(next.windows.map(\.isMicro) == [false, true])
            finish(next)
        }
    }

    // MARK: - Never a target

    @Test func microWindowsAreNeverConnectionOrLinkTargets() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let micro = app.newWindow(profile: profile, show: false, kind: .micro)
            app.focus(micro)
            #expect(app.activeCoordinator === micro)

            #expect(app.externalLinkTarget === main)
            #expect(app.activeBrowsingCoordinator === main)
            #expect(app.browsingWindow(for: micro) === main)
            #expect(app.mcpServer.makeSessionForConnection()?.isBound(to: main.browser) == true)
            #expect(app.mcpServer.makeSessionForConnection(browser: micro.browser) == nil, "a micro window is never available")
            #expect(app.developerWindow(profileID: profile.id) === main)

            // The window to browse in is the one used last, not the first or the newest.
            let later = app.newWindow(profile: profile, show: false)
            app.focus(main)
            app.focus(micro)
            #expect(app.activeBrowsingCoordinator === main)
            #expect(app.browsingWindow(for: micro) === main)
            app.focus(later)
            app.focus(micro)
            #expect(app.activeBrowsingCoordinator === later)
            #expect(app.browsingWindow(for: micro) === later)

            // A private micro window in front refuses new connections, as a private window does.
            let privateMicro = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false, kind: .micro)
            app.focus(privateMicro)
            #expect(app.activeBrowsingCoordinator == nil)
            #expect(app.mcpServer.makeSessionForConnection() == nil)
            #expect(app.externalLinkTarget === later)
            finish(app)
        }
    }

    // MARK: - Menu

    @Test func optionCommandNIsBoundToNewMicroWindowAndWorksWithNoWindowOpen() throws {
        let savedMenus = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
        let app = run()
        let menu = MainMenu(application: app)
        menu.install()
        defer { (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = savedMenus }
        let root = try #require(NSApp.mainMenu)
        let item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.title == String(localized: "New Micro Window") })

        #expect(item.keyEquivalent == "n")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        #expect(app.windows.isEmpty)
        #expect(menu.validateMenuItem(item), "it works with no window open, like New Window")
        #expect(item.target === menu)
        #expect(item.action != nil)
    }

    @Test func tabSwitchingSplitsTheSidebarAndPinsAreOffInAMicroWindow() async throws {
        try await withProfile { profile in
            let savedMenus = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let micro = app.newWindow(profile: profile, show: false, kind: .micro)
            for window in [main, micro] {
                window.browser.newTab()
                window.browser.newTab()
            }
            let menu = MainMenu(application: app)
            menu.install()
            defer {
                (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = savedMenus
                finish(app)
            }
            let root = try #require(NSApp.mainMenu)
            // Looked up before any item is validated: validation retitles some of them.
            let items = root.items.compactMap(\.submenu).flatMap(\.items)
            func item(_ title: LocalizedStringResource) throws -> NSMenuItem {
                try #require(items.first { $0.title == String(localized: title) }, "\(String(localized: title))")
            }
            let atWork = [
                try item("Show Next Tab"), try item("Show Previous Tab"), try item("Show Last Tab"), try item("Show Tab 1"),
                try item("Show Space 1"), try item("Split Right"), try item("Split Down"), try item("Hide Sidebar"),
                try item("Use Minimal Window Style"), try item("Keep Sidebar Open"), try item("Move Bar to Top"),
                try item("Show Assistant"), try item("Show Lyrics"), try item("Pin This Page"), try item("Back to Pinned Page"),
                try item("Swap Panes"), try item("Exit Split"),
            ]
            let forAPage = [
                try item("Find…"), try item("Zoom In"), try item("Print…"), try item("Open Location…"), try item("New Tab"),
                try item("Search Everything…"), try item("New Micro Window"), try item("Settings…"),
            ]
            let float = try item("Float on Top")

            app.focus(main)
            #expect(app.activeCoordinator === main)
            for title in ["Show Next Tab", "Split Right", "Hide Sidebar", "Use Minimal Window Style", "Pin This Page", "Show Assistant"] {
                let found = atWork.first { $0.title == title }
                #expect(found.map(menu.validateMenuItem) == true, "\(title) works in a window that has a sidebar")
            }
            #expect(!menu.validateMenuItem(float) && float.isHidden, "Float on Top is a micro window's item")

            app.focus(micro)
            #expect(app.activeCoordinator === micro)
            for found in atWork {
                #expect(!menu.validateMenuItem(found), "\(found.title) is off in a micro window")
            }
            for found in forAPage {
                #expect(menu.validateMenuItem(found), "\(found.title) still works")
            }
            #expect(menu.validateMenuItem(float) && !float.isHidden && float.state == .off)
            micro.floatsOnTop = true
            _ = menu.validateMenuItem(float)
            #expect(float.state == .on)
            micro.floatsOnTop = false

            // A new tab, the palette, Settings, History and Downloads go to the window to browse in.
            #expect(micro.mainWindowForCommands() === main)
            #expect(main.mainWindowForCommands() === main)
            #expect(micro.browser.tabs.count == 3, "and nothing was added to the micro window")
        }
    }

    @Test func closingTheLastRegularWindowLeavesNowhereToSendCommands() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let micro = app.newWindow(profile: profile, show: false, kind: .micro)
            #expect(app.browsingWindow(for: micro) === main)

            main.closeWindow()

            #expect(app.browsingWindow(for: micro) == nil)
            #expect(app.activeBrowsingCoordinator == nil)
            #expect(app.externalLinkTarget == nil)
            finish(app)
        }
    }

    // MARK: - Window

    @Test func floatOnTopRaisesTheLevelAndJoinsEveryDesktop() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let micro = app.newWindow(profile: profile, show: false, kind: .micro)
            let window = try #require(micro.nativeWindow)
            let mainWindow = try #require(main.nativeWindow)

            #expect(window.level == .normal)
            #expect(window.collectionBehavior == [.fullScreenNone], "a micro window never enters full screen")
            #expect(window.minSize == MicroWindowMetrics.minSize)
            #expect(mainWindow.collectionBehavior.contains(.fullScreenPrimary), "a standard window does")
            #expect(mainWindow.minSize.width == BrowserWindowMetrics.minWidth)
            #expect(!micro.floatsOnTop)

            micro.floatsOnTop = true
            #expect(window.level == .floating)
            #expect(window.collectionBehavior == [.fullScreenAuxiliary, .canJoinAllSpaces])

            micro.floatsOnTop = false
            #expect(window.level == .normal)
            #expect(window.collectionBehavior == [.fullScreenNone])

            // The setting belongs to a micro window: a standard window ignores it.
            main.floatsOnTop = true
            #expect(mainWindow.level == .normal)
            #expect(mainWindow.collectionBehavior.contains(.fullScreenPrimary))
            main.floatsOnTop = false
            finish(app)
        }
    }

    @Test func newMicroWindowFromAPrivateWindowOpensARegularOne() async throws {
        try await withProfile { profile in
            let app = run()
            let privateWindow = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)

            let micro = try #require(privateWindow.requestNewMicroWindow(show: false))

            #expect(micro.isMicro)
            #expect(!micro.profiles.isPrivate)
            #expect(micro.context.profile.id == profile.id)
            #expect(app.windows.map(\.windowID) == [privateWindow.windowID, micro.windowID])
            #expect(micro.addressBarFocusToken > 0, "the address is focused")
            finish(app)
        }
    }
}
