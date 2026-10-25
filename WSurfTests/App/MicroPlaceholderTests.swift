// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import GRDB
import MCP
import SwiftUI
import Testing
import WSurfCore

@testable import WSurf

/// A page moved to a micro window leaves its row in the sidebar where it was, marked, and clicking the row brings the page
/// back there. The row refers to the micro window's tab and is not a tab: it never loads, is never in front, and nothing that
/// counts, lists, saves or unloads tabs takes it for a second page.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MicroPlaceholderTests {
    /// Runs `body` with a profile of its own, so the saved windows of other suites cannot be restored with it.
    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Micro rows")
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

    /// A page of `window` that shows `address` and loads nothing, like a tab restored from a session.
    private func unloadedPage(_ address: String, in window: AppCoordinator) -> BrowserTab {
        let tab = window.browser.addPage(address)
        window.browser.activate(tab)
        return tab
    }

    /// `first`, a folder holding `inside`, then `last`: a page with something on each side and a parent.
    private struct Layout {
        let first: BrowserTab
        let folder: TabFolder
        let inside: BrowserTab
        let last: BrowserTab
    }

    private func layout(in main: AppCoordinator) -> Layout {
        let first = main.browser.addPage("https://one.example/")
        let inside = main.browser.addPage("https://two.example/")
        let last = main.browser.addPage("https://three.example/")
        let folder = main.browser.createFolder(named: "Work", containing: [inside])
        main.browser.activate(first)
        return Layout(first: first, folder: folder, inside: inside, last: last)
    }

    // MARK: - The row stays

    @Test func poppingOutLeavesTheRowInItsPlaceWithItsMark() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let index = try #require(main.browser.tabs.firstIndex { $0 === pages.inside })
            let successor = main.browser.sidebarTree.successor(of: .tab(pages.inside.id))
            let space = pages.inside.spaceID

            let micro = try #require(main.moveToMicroWindow(pages.inside))

            #expect(micro.browser.tabs.map(\.id) == [pages.inside.id], "one page, in the micro window")
            #expect(main.browser.tab(id: pages.inside.id) == nil, "the page is not here twice")
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))
            #expect(row.microTabID == pages.inside.id && row.id != pages.inside.id)
            #expect(main.browser.tabs.firstIndex { $0 === row } == index, "the same position")
            #expect(main.browser.folder(containing: row) === pages.folder, "in the same folder")
            #expect(main.browser.sidebarTree.successor(of: .tab(row.id)) == successor)
            #expect(row.spaceID == space)
            #expect(row.title == pages.inside.title && row.urlString == pages.inside.urlString)
            #expect(!row.isMaterialised, "a row, not a second page")
            #expect(main.browser.activeTab === pages.first)
            #expect(!main.canMoveToMicroWindow(row), "the row itself never moves out")
            finish(app)
        }
    }

    @Test func theRowFollowsThePageAsItMovesOn() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/a": .html("<title>First page</title>"), "/b": .html("<title>Next page</title>"),
        ])
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            _ = main.browser.addPage("https://other.example/")
            let tab = main.browser.newTab(url: try server.url("/a"))
            try #require(await waitUntil { tab.page.title == "First page" && !tab.page.isLoading })
            let micro = try #require(main.moveToMicroWindow(tab))
            let row = try #require(main.browser.microPlaceholder(for: tab.id))
            #expect(row.title == "First page")

            tab.load(try server.url("/b"))

            #expect(await waitUntil { row.title == "Next page" }, "the row says what the micro window shows")
            #expect(row.urlString == (try server.url("/b")).absoluteString)
            #expect(!row.isMaterialised, "by following the page, not by loading it")
            micro.closeWindow()
            finish(app)
            await tab.waitForRetirement()
        }
        withExtendedLifetime(server) {}
    }

    @Test func theRowWearsTheMicroMark() throws {
        let plain = BrowserModel(database: .temporary()).addPage("https://one.example/")
        let row = BrowserModel(database: .temporary()).addPage("https://one.example/")
        row.microTabID = UUID()

        #expect(NSHostingView(rootView: MicroRowBadge(tab: plain)).fittingSize.width == 0, "nothing on an ordinary row")
        #expect(NSHostingView(rootView: MicroRowBadge(tab: row)).fittingSize.width > 0)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "WSurf/UI/Sidebar/SidebarTabRow.swift"), encoding: .utf8)
        #expect(source.contains("MicroRowBadge(tab: tab)"), "the row draws it beside its other marks")
        #expect(source.contains("MicroRowMenuItems(tab: tab, coordinator: coordinator)"))
    }

    @Test func aPinsRowIsThePinsPageAndThePinStays() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pin = main.browser.pinned("https://pin.example/")
            _ = unloadedPage("https://other.example/", in: main)
            let pinID = try #require(pin.pinID)
            let pins = main.browser.pinStore.pins
            let outline = main.browser.pinOutline

            let micro = try #require(main.moveToMicroWindow(pin))

            let row = try #require(main.browser.microPlaceholder(for: pin.id))
            #expect(main.browser.page(for: pinID) === row, "the pin's own page here is the row")
            #expect(main.browser.pinStore.pins == pins && main.browser.pinOutline == outline)

            micro.closeWindow()
            try #require(await waitUntil { micro.isClosed })
            #expect(main.browser.tabs.contains { $0 === row } && row.microTabID == nil, "the pin stays, as it always has")
            #expect(main.browser.pinStore.pins == pins)
            finish(app)
        }
    }

    // MARK: - Bringing the page back

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func clickingTheRowBringsThePageBackToItsPlaceWithoutReloading(engine: BrowserEngine) async throws {
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
            let pages = layout(in: main)
            let tab = main.browser.newTab(url: url)
            main.browser.move([.tab(tab.id)], into: pages.folder, before: .tab(pages.inside.id), settlingPins: false)
            let page = tab.page
            try #require(await waitUntil { page.title == "Form" && !page.isLoading })
            _ = try await page.evaluateJavaScript("window.marker = 'kept'; document.getElementById('note').value = 'typed'; true")
            #expect(page.engine == engine)
            let index = try #require(main.browser.tabs.firstIndex { $0 === tab })
            let micro = try #require(main.moveToMicroWindow(tab))
            let row = try #require(main.browser.microPlaceholder(for: tab.id))
            main.browser.activate(pages.last)

            main.openTab(row)

            #expect(main.browser.tab(id: tab.id) === tab, "the same tab")
            #expect(tab.page === page && !page.isClosed, "the same page, never a copy")
            #expect(main.browser.activeTab === tab)
            #expect(main.browser.folder(containing: tab) === pages.folder)
            #expect(main.browser.tabs.firstIndex { $0 === tab } == index, "where its row was")
            #expect(row.isClosed && !main.browser.tabs.contains { $0 === row }, "the row is gone")
            #expect(try await page.evaluateJavaScript("window.marker") as? String == "kept")
            #expect(try await page.evaluateJavaScript("document.getElementById('note').value") as? String == "typed")
            #expect(gate.requestCount == 1, "nothing was fetched again")
            try #require(await waitUntil { micro.isClosed }, "the micro window, empty, closes")

            finish(app)
            await tab.waitForRetirement()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            withExtendedLifetime(server) {}
        }
    }

    @Test func movingBackFromTheMicroWindowAlsoReturnsToTheRow() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let index = try #require(main.browser.tabs.firstIndex { $0 === pages.inside })
            let micro = try #require(main.moveToMicroWindow(pages.inside))

            micro.moveBackToMainWindow()

            #expect(main.browser.tabs.firstIndex { $0 === pages.inside } == index)
            #expect(main.browser.folder(containing: pages.inside) === pages.folder)
            #expect(main.browser.microPlaceholder(for: pages.inside.id) == nil)
            try #require(await waitUntil { micro.isClosed })
            finish(app)
        }
    }

    @Test func aPinComesBackAsThePin() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pin = main.browser.pinned("https://pin.example/")
            _ = unloadedPage("https://other.example/", in: main)
            let pinID = try #require(pin.pinID)
            let pins = main.browser.pinStore.pins
            let micro = try #require(main.moveToMicroWindow(pin))
            let row = try #require(main.browser.microPlaceholder(for: pin.id))

            main.openTab(row)

            #expect(main.browser.page(for: pinID) === pin, "the page is the pin's page again")
            #expect(main.browser.tabs.filter { $0.pinID == pinID }.count == 1, "and the only one")
            #expect(main.browser.pinStore.pins.map(\.id) == pins.map(\.id))
            try #require(await waitUntil { micro.isClosed })
            finish(app)
        }
    }

    @Test func optionClickShowsTheMicroWindowAndKeepsTheRow() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))
            micro.nativeWindow?.orderOut(nil)

            main.openMicroPlaceholder(row, showingWindow: true)

            #expect(micro.nativeWindow?.isVisible == true)
            #expect(micro.browser.tabs.map(\.id) == [pages.inside.id] && main.browser.tabs.contains { $0 === row })
            finish(app)
        }
    }

    // MARK: - Closing

    @Test func closingTheMicroWindowRemovesTheRow() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))
            let reopenable = main.browser.closedTabs.count

            micro.closeWindow()

            try #require(await waitUntil { micro.isClosed })
            #expect(!main.browser.tabs.contains { $0 === row } && row.isClosed)
            #expect(main.browser.closedTabs.count == reopenable, "the row is not a tab to reopen")
            finish(app)
        }
    }

    @Test func aMicroPageThatClosesItselfTakesItsRow() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))

            micro.browser.close(pages.inside)

            try #require(await waitUntil { micro.isClosed })
            #expect(!main.browser.tabs.contains { $0 === row })
            finish(app)
        }
    }

    /// Closing the row closes no page: the micro window and its page stay, and Move Back still finds a window.
    @Test func closingTheRowLeavesTheMicroWindow() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))

            main.browser.close([.tab(row.id)])

            #expect(!micro.isClosed && micro.browser.tabs.map(\.id) == [pages.inside.id])
            micro.moveBackToMainWindow()
            #expect(main.browser.tab(id: pages.inside.id) === pages.inside)
            try #require(await waitUntil { micro.isClosed })
            finish(app)
        }
    }

    // MARK: - Restoring

    @Test func theRowAndItsMicroWindowComeBackTogether() async throws {
        try await withProfile { profile in
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            let first = run(defaults)
            let main = first.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))
            let rowID = row.id
            let tabID = pages.inside.id
            let index = try #require(main.browser.tabs.firstIndex { $0 === row })
            main.browser.saveBlocking()
            micro.browser.saveBlocking()
            let stored = try await main.context.database.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT id, microTabID FROM sessionTab WHERE id IN (?, ?)", arguments: [rowID, tabID])
                    .map { (id: $0["id"] as UUID?, microTabID: $0["microTabID"] as UUID?) }
            }
            #expect(stored.count == 2, "the row and the page are two rows of the session, one a reference")
            #expect(stored.first { $0.id == rowID }?.microTabID == tabID)
            #expect(stored.first { $0.id == tabID }?.microTabID == nil)

            try await quit(first)

            let next = run(defaults)
            next.restoreWindows(of: [profile], show: false)
            let nextMain = try #require(next.windows.first { !$0.isMicro })
            let nextMicro = try #require(next.windows.first { $0.isMicro })
            let restored = try #require(nextMain.browser.tab(id: rowID))
            #expect(restored.microTabID == tabID, "linked again")
            #expect(nextMain.browser.tabs.firstIndex { $0 === restored } == index)
            #expect(nextMicro.browser.tabs.map(\.id) == [tabID])
            #expect(nextMain.browser.activeTab !== restored)
            #expect(!restored.isMaterialised)

            nextMain.openTab(restored)
            #expect(nextMain.browser.tab(id: tabID) != nil && nextMain.browser.tab(id: rowID) == nil)
            try #require(await waitUntil { nextMicro.isClosed })
            finish(next)
        }
    }

    @Test func aRowWhoseMicroWindowDidNotComeBackIsAnOrdinaryRow() async throws {
        try await withProfile { profile in
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            let first = run(defaults)
            let main = first.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let rowID = try #require(main.browser.microPlaceholder(for: pages.inside.id)).id
            let database = main.context.database
            let microID = micro.windowID
            main.browser.saveBlocking()
            micro.browser.saveBlocking()
            try await quit(first)
            // The micro window's saved session is gone, as if it never reached the disk.
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM sessionTab WHERE windowID = ?", arguments: [microID])
                try db.execute(sql: "DELETE FROM sessionWindow WHERE id = ?", arguments: [microID])
            }

            let next = run(defaults)
            next.restoreWindows(of: [profile], show: false)
            #expect(!next.windows.contains { $0.isMicro })
            let nextMain = try #require(next.windows.first)
            let row = try #require(nextMain.browser.tab(id: rowID))
            #expect(row.microTabID == nil, "an ordinary row now")

            nextMain.openTab(row)
            #expect(nextMain.browser.activeTab === row, "which opens its page here")
            finish(next)
        }
    }

    // MARK: - Not a tab

    @Test func commandWUnloadingAndTabSwitchingPassTheRowBy() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))
            // The row sits between the active page and the next.
            main.browser.move([.tab(pages.first.id)], into: pages.folder, before: .tab(row.id), settlingPins: false)
            main.browser.activate(pages.first)

            main.browser.cycleTab(forward: true)
            #expect(main.browser.activeTab !== row, "tab switching passes it by")
            main.browser.activate(pages.first)

            main.unloadTab(row)
            _ = main.browser.freeMemory()
            main.browser.sleepIdleTabs(after: .zero)
            #expect(!row.isMaterialised && main.browser.tabs.contains { $0 === row }, "nothing to unload, nothing loaded")

            // ⌘W, as the menu sends it: the next page in front is never the row.
            main.browser.close([.tab(pages.first.id)])
            #expect(main.browser.activeTab !== row)
            #expect(main.browser.activeTab === pages.last)
            for tab in main.browser.tabs where tab !== row {
                main.browser.close([.tab(tab.id)])
            }
            #expect(main.browser.tabs.map(\.id) == [row.id])
            #expect(main.browser.activeTab == nil, "with only the row left nothing is in front")
            #expect(!row.isMaterialised)
            #expect(!micro.isClosed && micro.browser.tabs.map(\.id) == [pages.inside.id])
            finish(app)
        }
    }

    @Test func pickingTheRowByNumberBringsThePageBack() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            let micro = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))
            let index = try #require(main.browser.currentSpaceTabs.firstIndex { $0 === row })

            main.browser.activateTab(at: index)

            #expect(main.browser.activeTab === pages.inside)
            try #require(await waitUntil { micro.isClosed })
            finish(app)
        }
    }

    @Test func connectedAppsAndICloudTabsSeeThePageOnce() async throws {
        try await withProfile { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let pages = layout(in: main)
            _ = try #require(main.moveToMicroWindow(pages.inside))
            let row = try #require(main.browser.microPlaceholder(for: pages.inside.id))

            let session = MCPBrowserSession(browser: main.browser, available: { true }, consent: { _, _, _ in .control })
            session.grants[row.id] = .init(origin: "https://two.example", access: .control)
            #expect(session.sharedTab(row.id) == nil, "a connected app can never act on the row")
            #expect(!session.sharedTabs.contains { $0 === row })
            let listed = String(describing: session.tabList().structuredContent)
            #expect(!listed.contains(row.id.uuidString), "nor see it in the list")

            func ids(_ nodes: [SessionNode]) -> [UUID] {
                nodes.flatMap { [$0.id] + ids($0.children ?? []) }
            }
            #expect(!ids(main.browser.cloudTabsNodes()).contains(row.id), "the micro window reports the page, not this row")
            #expect(IslandBar.tabCount(of: main.browser) == main.browser.tabs.count - 1, "nor counted as a tab")
            finish(app)
        }
    }
}
