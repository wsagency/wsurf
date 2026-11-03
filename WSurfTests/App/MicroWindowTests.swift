// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import Testing
import WebKit

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
            func flattened(_ menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { [$0] + ($0.submenu.map(flattened) ?? []) }
            }
            let items = flattened(root)
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

    // MARK: - Moving a page out and back

    /// A page of `main` that shows `address` and loads nothing, like a tab restored from a session.
    private func unloadedPage(_ address: String, in window: AppCoordinator) -> BrowserTab {
        let tab = window.browser.addPage(address)
        window.browser.activate(tab)
        return tab
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func movingToAMicroWindowKeepsTheLivePage(engine: BrowserEngine) async throws {
        let gate = ResponseGate()
        gate.open()
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Form</title><input id='note'>", gate: gate),
        ])
        let url = try server.url("/")
        try await withProfile { profile in
            let context = BrowserProfileContext.shared(for: profile)
            context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: url))
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = main.browser.newTab(url: url)
            let page = tab.page
            try #require(await waitUntil { page.title == "Form" && !page.isLoading })
            _ = try await page.evaluateJavaScript("window.marker = 'kept'; document.getElementById('note').value = 'typed, not sent'; true")
            #expect(page.engine == engine)
            #expect(gate.requestCount == 1)

            let micro = try #require(main.moveToMicroWindow(tab))
            let microWindow = try #require(micro.nativeWindow)

            #expect(micro.isMicro && micro.browser.tabs.map(\.id) == [tab.id], "the placeholder window tab is gone")
            #expect(main.browser.tab(id: tab.id) == nil, "the page left its window")
            #expect(tab.page === page && tab.liveView === page && !page.isClosed && !tab.isClosed, "the same page, not a copy")
            try #require(await waitUntil { page.window === microWindow })
            #expect(try await page.evaluateJavaScript("window.marker") as? String == "kept")
            #expect(try await page.evaluateJavaScript("document.getElementById('note').value") as? String == "typed, not sent")
            #expect(gate.requestCount == 1, "nothing was fetched again")

            finish(app)
            await tab.waitForRetirement()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            withExtendedLifetime(server) {}
        }
    }

    @Test func movingAPinKeepsThePinInTheMainWindow() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pin = main.browser.pinned("https://one.example/")
            let folder = main.browser.createFolder(named: "Work")
            main.browser.pin(folder)
            let inFolder = main.browser.addPage("https://two.example/")
            main.browser.move([.tab(inFolder.id)], into: folder, settlingPins: true)
            main.browser.addFavorite(main.browser.addPage("https://three.example/"))
            let pins = main.browser.pinStore.pins
            let outline = main.browser.pinOutline
            #expect(pins.count >= 3 && pin.pinID != nil && inFolder.pinID != nil)

            for page in [pin, inFolder, try #require(main.browser.page(at: "https://three.example/"))] {
                let pinID = try #require(page.pinID)
                let address = page.urlString
                let micro = try #require(main.moveToMicroWindow(page))
                let moved = try #require(micro.browser.tab(id: page.id))
                #expect(moved.pinID == nil && moved.pinnedURL == nil && !moved.isFavorite, "an ordinary tab over there")
                #expect(micro.browser.attachedPinStore == nil)
                let left = try #require(main.browser.page(for: pinID))
                #expect(left !== moved && left.urlString == address, "the pin keeps an unloaded page of its own here")
                #expect(main.browser.pinStore.pins == pins, "the person removes pins, not a pop-out")
                #expect(main.browser.pinOutline == outline)
                micro.closeWindow()
            }
            finish(app)
        }
    }

    /// A window that opens for a page used to forget the assistant conversations of every other window of the profile, the
    /// page's own among them, before the page arrived.
    @Test func openingAMicroWindowKeepsTheConversationsOfTheProfile() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = unloadedPage("https://one.example/", in: main)
            let other = unloadedPage("https://two.example/", in: main)
            for page in [tab, other] {
                main.conversationLog.completeTask(main.conversationLog.beginTask("work on \(page.urlString)", tabID: page.id), response: "done")
            }

            let micro = try #require(main.moveToMicroWindow(tab))

            #expect(main.conversationLog.traces(forTab: tab.id).count == 1, "the moved page's conversation went with it")
            #expect(main.conversationLog.traces(forTab: other.id).count == 1, "and the page that stayed kept its own")
            #expect(micro.conversationLog === main.conversationLog)
            finish(app)
        }
    }

    @Test func movingBackReturnsTheSamePageAndRetiresTheMicroWindow() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            main.browser.pinned("https://pin.example/")
            let other = unloadedPage("https://other.example/", in: main)
            let tab = unloadedPage("https://one.example/", in: main)
            let database = main.context.database
            let micro = try #require(main.moveToMicroWindow(tab))
            let microID = micro.windowID
            micro.browser.saveBlocking()
            #expect(BrowserModel.savedWindows(in: database).contains { $0.id == microID })

            micro.moveBackToMainWindow()

            #expect(main.browser.tab(id: tab.id) === tab, "the same tab object")
            #expect(main.browser.activeTab === tab)
            #expect(tab.pinID == nil && main.browser.tabs.contains { $0 === other })
            let tabs = main.browser.tabs
            let line = try #require(tabs.firstIndex { $0.pinID != nil })
            let position = try #require(tabs.firstIndex { $0 === tab })
            #expect(position > line, "under the pin line")
            try #require(await waitUntil { micro.isClosed })
            #expect(!BrowserModel.savedWindows(in: database, includeClosed: true).contains { $0.id == microID },
                    "Reopen Last Closed Window never brings back an empty micro window")
            let leftovers = try await database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessionTab WHERE windowID = ?", arguments: [microID])
            }
            #expect(leftovers == 0, "and no rows are left to be adopted as a window")
            finish(app)
        }
    }

    @Test func movingBackWithNoMainWindowOpensOne() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = unloadedPage("https://one.example/", in: main)
            let micro = try #require(main.moveToMicroWindow(tab))
            main.closeWindow()
            #expect(app.browsingWindow(for: micro) == nil)

            micro.moveBackToMainWindow()

            let opened = try #require(app.windows.first { !$0.isMicro && !$0.isClosed })
            #expect(opened !== main && opened.context === micro.context)
            #expect(opened.browser.tabs.map(\.id) == [tab.id], "the page, and no placeholder")
            try #require(await waitUntil { micro.isClosed })
            finish(app)
        }
    }

    @Test func aTabTheMicroPageOpensGoesToTheMainWindow() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/two": .html("<title>Two</title>"), "/three": .html("<title>Three</title>"),
        ])
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = unloadedPage("https://one.example/", in: main)
            let micro = try #require(main.moveToMicroWindow(tab))
            let before = main.browser.activeTab
            let count = main.browser.tabs.count

            // Opened in the background: it waits there, unseen, and the micro window stays as it was.
            tab.onOpenInNewTab?(try server.url("/two"), false)
            try #require(await waitUntil { main.browser.tabs.count == count + 1 })
            let two = try #require(main.browser.page(at: try server.url("/two").absoluteString))
            #expect(micro.browser.tabs.map(\.id) == [tab.id] && micro.browser.activeTab === tab)
            #expect(two.isUnseen && main.browser.activeTab === before)

            // Opened in front: it is in front over there.
            tab.onOpenInNewTab?(try server.url("/three"), true)
            try #require(await waitUntil { main.browser.tabs.count == count + 2 })
            let three = try #require(main.browser.page(at: try server.url("/three").absoluteString))
            #expect(main.browser.activeTab === three)
            #expect(micro.browser.tabs.map(\.id) == [tab.id] && micro.browser.activeTab === tab)

            // A popup is the page it already is: the same web view, so what it was opened with goes with it.
            let popup = WKWebView(frame: .zero, configuration: WebViewPool.makeConfiguration())
            tab.onNewWindow?(popup, true)
            try #require(await waitUntil { main.browser.tabs.contains { $0.liveView?.webKit === popup } })
            #expect(micro.browser.tabs.map(\.id) == [tab.id])
            finish(app)
            withExtendedLifetime(server) {}
        }
    }

    @Test func closingAMicroWindowClosesItsPageAndReopensAsMicro() async throws {
        try await withProfile { profile in
            let savedMenus = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = unloadedPage("https://one.example/", in: main)
            let micro = try #require(main.moveToMicroWindow(tab))
            let database = main.context.database
            let menu = MainMenu(application: app)
            menu.install()
            defer { (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = savedMenus }
            let root = try #require(NSApp.mainMenu)
            app.focus(micro)

            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 0
            ))
            #expect(root.performKeyEquivalent(with: event), "Command-W")

            #expect(micro.isClosed, "the window closed, not only its tab")
            #expect(!app.windows.contains { $0 === micro } && app.windows.contains { $0 === main })
            let saved = try #require(BrowserModel.savedWindows(in: database, includeClosed: true).first { $0.id == micro.windowID })
            #expect(saved.closedAt != nil && saved.windowKind == .micro)

            app.reopenLastClosedWindow()

            let reopened = try #require(app.windows.first { $0.windowID == micro.windowID })
            #expect(reopened.isMicro)
            #expect(reopened.browser.tabs.map(\.urlString) == ["https://one.example/"], "the same page")
            #expect(reopened.browser.attachedPinStore == nil)
            finish(app)
        }
    }

    @Test func aMicroWindowWhoseOwnPageClosesRetiresItsSession() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = unloadedPage("https://one.example/", in: main)
            let micro = try #require(main.moveToMicroWindow(tab))
            let database = main.context.database
            micro.browser.saveBlocking()

            tab.onCloseRequested?()

            try #require(await waitUntil { micro.isClosed })
            #expect(!BrowserModel.savedWindows(in: database, includeClosed: true).contains { $0.id == micro.windowID })
            #expect(main.browser.tab(id: tab.id) == nil && tab.isClosed)
            finish(app)
        }
    }

    @Test func theWindowMenuMovesThePageOutAndBack() async throws {
        try await withProfile { profile in
            let savedMenus = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = unloadedPage("https://one.example/", in: main)
            let menu = MainMenu(application: app)
            menu.install()
            defer {
                (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = savedMenus
                finish(app)
            }
            let root = try #require(NSApp.mainMenu)
            let item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
                .first { $0.title == String(localized: "Move to Micro Window") })
            #expect(item.keyEquivalent == "N" && item.keyEquivalentModifierMask == [.command, .option])

            app.focus(main)
            #expect(menu.validateMenuItem(item) && item.title == String(localized: "Move to Micro Window"))
            let address = tab.urlString
            tab.urlString = ""
            #expect(!menu.validateMenuItem(item), "a page with no address has nothing to move")
            tab.urlString = address
            let micro = try #require(main.moveToMicroWindow(tab))
            app.focus(micro)
            #expect(menu.validateMenuItem(item) && item.title == String(localized: "Move Back to Main Window"))
        }
    }

    // MARK: - Private tabs

    /// A private window with a page that is loaded from the fixture, and the cookie its session holds.
    private func withPrivateWindow(
        _ body: (BrowserApplication, AppCoordinator) async throws -> Void
    ) async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)
            try await body(app, main)
            finish(app)
        }
    }

    @Test func aPrivateTabMovesIntoTheSamePrivateSession() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Private</title>")])
        let url = try server.url("/")
        try await withPrivateWindow { app, main in
            let context = main.context
            let host = try #require(url.host())
            let cookie = try #require(HTTPCookie(properties: [
                .domain: host, .path: "/", .name: "session", .value: "abc", .originURL: url,
            ]))
            await context.dataStore.httpCookieStore.setCookie(cookie)
            let tab = main.browser.newTab(url: url)
            let page = tab.page
            try #require(await waitUntil { page.title == "Private" && !page.isLoading })
            #expect(try await page.evaluateJavaScript("document.cookie") as? String == "session=abc")

            let micro = try #require(main.moveToMicroWindow(tab))

            #expect(micro.isMicro && micro.profiles.isPrivate && micro.browser.opensPrivately)
            #expect(micro.context === context && micro.context.dataStore === context.dataStore, "the same session, not a new one")
            #expect(micro.context.database.isEphemeral, "and it keeps nothing")
            #expect(app.windows.count == 2 && micro.browser.tabs.map(\.id) == [tab.id])
            try #require(await waitUntil { page.window === micro.nativeWindow })
            #expect(try await page.evaluateJavaScript("document.cookie") as? String == "session=abc", "still signed in")
            #expect(await context.dataStore.httpCookieStore.allCookies().contains { $0.name == "session" })

            // A private window never reaches another's cookie store, micro or not.
            let stranger = app.newWindow(profile: .privateBrowsing(), settingsOwner: main.profiles.profileToReturnTo, show: false)
            #expect(stranger.context !== context)
            #expect(!stranger.browser.adoptTab(tab, from: micro.browser))
            #expect(micro.browser.tab(id: tab.id) === tab)
            finish(app)
            await tab.waitForRetirement()
            withExtendedLifetime(server) {}
        }
    }

    @Test func closingThePrivateMicroWindowKeepsTheSessionForItsWindow() async throws {
        try await withPrivateWindow { _, main in
            let context = main.context
            let tab = unloadedPage("https://one.example/", in: main)
            let kept = unloadedPage("https://two.example/", in: main)
            let trace = main.conversationLog.beginTask("private work", tabID: kept.id)
            main.conversationLog.completeTask(trace, response: "done")
            let micro = try #require(main.moveToMicroWindow(tab))

            micro.closeWindow()

            #expect(micro.isClosed && !main.isClosed)
            #expect(!context.privateSessionEnded, "another window still shows pages of the session")
            #expect(main.conversationLog.traces(forTab: kept.id).count == 1, "and its assistant log is kept")
            #expect(main.browser.tab(id: kept.id) === kept && !kept.isClosed)
        }
    }

    @Test func closingThePrivateWindowKeepsTheSessionForTheMicroWindowItGave() async throws {
        try await withPrivateWindow { app, main in
            let context = main.context
            let tab = unloadedPage("https://one.example/", in: main)
            let micro = try #require(main.moveToMicroWindow(tab))

            main.closeWindow()

            #expect(main.isClosed && !micro.isClosed)
            #expect(!context.privateSessionEnded, "the page in the micro window is still in the session")
            #expect(micro.browser.tab(id: tab.id) === tab && !tab.isClosed)
            #expect(app.windows.map(\.windowID) == [micro.windowID])
        }
    }

    @Test func closingTheLastPrivateWindowEndsTheSession() async throws {
        try await withPrivateWindow { app, main in
            let context = main.context
            let tab = unloadedPage("https://one.example/", in: main)
            let trace = main.conversationLog.beginTask("private work", tabID: tab.id)
            main.conversationLog.completeTask(trace, response: "done")
            let micro = try #require(main.moveToMicroWindow(tab))
            let log = main.conversationLog

            main.closeWindow()
            #expect(!context.privateSessionEnded)
            micro.closeWindow()

            try #require(await waitUntil { context.privateSessionEnded })
            #expect(log.traces.isEmpty, "the log went with the session")
            #expect(app.windows.isEmpty)
            #expect(tab.isClosed)
        }
    }

    @Test func aPrivateWindowAndItsMicroWindowLeaveNothingOnDisk() async throws {
        try await withProfile { profile in
            let app = run()
            let regular = app.newWindow(profile: profile, show: false)
            let database = regular.context.database
            regular.browser.saveBlocking()
            let before = BrowserModel.savedWindows(in: database, includeClosed: true).map(\.id)
            let main = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)
            let tab = unloadedPage("https://one.example/", in: main)
            let micro = try #require(main.moveToMicroWindow(tab))
            micro.browser.saveBlocking()
            micro.closeWindow()
            main.closeWindow()

            #expect(BrowserModel.savedWindows(in: database, includeClosed: true).map(\.id) == before)
            #expect(micro.windowID != regular.windowID)
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
            // AppKit reports the frame, which is the content size and the band the traffic lights sit in.
            #expect(window.minSize.width == MicroWindowMetrics.minSize.width)
            #expect(window.minSize.height >= MicroWindowMetrics.minSize.height)
            #expect(mainWindow.collectionBehavior.contains(.fullScreenPrimary), "a standard window does")
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
