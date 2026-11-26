// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Every regular window of a profile shows the same tabs and folders in each Space, each with a page of its own.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SpaceTabWindowTests {
    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Space tabs in every window")
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

    private func run(_ defaults: UserDefaults) -> BrowserApplication {
        BrowserApplication(defaults: defaults, notifications: NotificationCenter())
    }

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

    /// A pin, a page and a folder with a page, the way a person leaves them.
    @discardableResult
    private func fill(_ window: AppCoordinator) -> (page: BrowserTab, folder: TabFolder, inner: BrowserTab) {
        let browser = window.browser
        browser.pinned("https://pin.example/")
        let page = browser.addPage("https://one.example/")
        let inner = browser.addPage("https://two.example/")
        let folder = browser.createFolder(named: "Work", containing: [inner])
        browser.scheduleSave()
        return (page, folder, inner)
    }

    private func copy(of tab: BrowserTab, in window: AppCoordinator) -> BrowserTab? {
        window.browser.tabs.first { $0.spaceTabID != nil && $0.spaceTabID == tab.spaceTabID }
    }

    /// Each shared row has exactly one page in the window.
    private func expectOneCopyPerRow(_ window: AppCoordinator, sourceLocation: SourceLocation = #_sourceLocation) {
        let links = window.browser.tabs.compactMap(\.spaceTabID)
        #expect(links.count == Set(links).count, sourceLocation: sourceLocation)
        let rows = window.browser.pinStore.spaceRows.filter { $0.kind == .tab }.map(\.id)
        #expect(Set(links) == Set(rows), sourceLocation: sourceLocation)
    }

    @Test func aNewWindowShowsEveryPinnedAndUnpinnedTabOfTheSpace() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            defer { finish(app) }
            let first = app.newWindow(profile: profile, show: false)
            let (page, folder, inner) = fill(first)

            let second = app.newWindow(profile: profile, show: false)

            #expect(second.browser.pinOutline == first.browser.pinOutline)
            #expect(second.browser.spaceOutline == "https://one.example/ Work[https://two.example/]")
            #expect(second.browser.spaceOutline == first.browser.spaceOutline)
            let mirrored = try #require(copy(of: page, in: second))
            // Its own page, which loads only when this window shows it.
            #expect(mirrored !== page && mirrored.id != page.id)
            #expect(mirrored.isDeferred)
            #expect(second.browser.folder(id: folder.id)?.name == "Work")
            #expect(second.browser.folder(containing: try #require(copy(of: inner, in: second)))?.id == folder.id)
            // The window's own new tab is in front, and it is not shared until it shows a page.
            #expect(second.browser.activeTab?.spaceTabID == nil)
            #expect(first.browser.tabs.allSatisfy { $0.urlString != "" || $0.spaceTabID == nil })
            expectOneCopyPerRow(first)
            expectOneCopyPerRow(second)
        }
    }

    @Test func changesInOneWindowReachTheOtherOnce() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            defer { finish(app) }
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let (page, folder, _) = fill(first)
            let browser = first.browser

            let added = browser.addPage("https://three.example/")
            browser.scheduleSave()
            let addedCopy = try #require(copy(of: added, in: second))

            browser.renameTab(added, to: "Renamed")
            #expect(addedCopy.customTitle == "Renamed")

            // A page this window navigates changes the other window's unloaded copy.
            added.applySharedURL(try #require(URL(string: "https://four.example/")))
            browser.scheduleSave()
            #expect(addedCopy.urlString == "https://four.example/")

            browser.place([.tab(added.id)], in: nil, before: .tab(page.id))
            browser.scheduleSave()
            #expect(second.browser.spaceOutline == "https://four.example/ https://one.example/ Work[https://two.example/]")

            browser.move(page, to: folder)
            #expect(second.browser.spaceOutline == "https://four.example/ Work[https://two.example/ https://one.example/]")

            // The second window's edits come back the same way.
            let pageCopy = try #require(copy(of: page, in: second))
            second.browser.move(pageCopy, to: nil)
            #expect(browser.folder(containing: page) == nil)

            browser.close(added)
            #expect(second.browser.tab(id: addedCopy.id) == nil)
            #expect(second.browser.spaceOutline == first.browser.spaceOutline)
            // Applying a change publishes nothing back: the rows stay as they are.
            let rows = browser.pinStore.spaceRows
            second.browser.scheduleSave()
            browser.scheduleSave()
            #expect(browser.pinStore.spaceRows == rows)
            expectOneCopyPerRow(first)
            expectOneCopyPerRow(second)
        }
    }

    @Test func aTabMovedToAnotherSpaceMovesInEveryWindow() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            defer { finish(app) }
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let (page, _, _) = fill(first)
            let home = try #require(first.browser.currentSpaceID)
            let other = try #require(first.createSpace(name: "Other", symbol: "star"))
            #expect(first.browser.knownSpaceIDs.contains(other.id) && second.browser.knownSpaceIDs.contains(other.id))

            first.browser.move([.tab(page.id)], toSpace: other.id)

            let moved = try #require(copy(of: page, in: second))
            #expect(moved.spaceID == other.id)
            #expect(second.browser.currentSpaceID == home)
            #expect(!second.browser.currentSpaceTabs.contains { $0 === moved })
            expectOneCopyPerRow(second)
        }
    }

    @Test func eachWindowKeepsItsOwnSelection() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            defer { finish(app) }
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let (page, _, inner) = fill(first)
            let innerCopy = try #require(copy(of: inner, in: second))

            first.browser.activeTabID = page.id
            second.browser.activeTabID = innerCopy.id
            first.browser.renameTab(page, to: "Either way")
            second.browser.scheduleSave()

            #expect(first.browser.activeTabID == page.id)
            #expect(second.browser.activeTabID == innerCopy.id)
            // The first window's page is not the second window's: a page is only ever in one window.
            #expect(copy(of: page, in: second)?.isDeferred == true)
        }
    }

    @Test func closingAWindowKeepsTheTabsAndARelaunchShowsEachOnce() async throws {
        try await withProfile { profile in
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            let app = run(defaults)
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let third = app.newWindow(profile: profile, show: false)
            fill(first)
            let outline = first.browser.spaceOutline

            third.closeWindow()
            #expect(first.browser.spaceOutline == outline)
            #expect(second.browser.spaceOutline == outline)
            #expect(first.browser.pinStore.spaceRows.count == 3)

            try await quit(app)

            let next = run(defaults)
            defer { finish(next) }
            next.restoreWindows(of: [profile], show: false)
            #expect(Set(next.windows.map(\.windowID)) == [first.windowID, second.windowID])
            for window in next.windows {
                #expect(window.browser.spaceOutline == outline)
                #expect(window.browser.pinOutline == "https://pin.example/")
                expectOneCopyPerRow(window)
            }
        }
    }

    @Test func privateAndMicroWindowsShowOnlyTheirOwnTabs() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            defer { finish(app) }
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let (page, _, _) = fill(first)
            let rows = first.browser.pinStore.spaceRows

            let secret = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)
            #expect(!secret.browser.sharesSpaceTabs)
            #expect(secret.browser.tabs.allSatisfy { $0.spaceTabID == nil && $0.urlString != page.urlString })
            secret.browser.addPage("https://private.example/")
            secret.browser.scheduleSave()
            #expect(first.browser.pinStore.spaceRows == rows)

            // The page goes to the micro window; its row stays in both windows, and the micro window shares nothing.
            let micro = try #require(first.moveToMicroWindow(page))
            #expect(!micro.browser.sharesSpaceTabs)
            #expect(micro.browser.tabs.map(\.id) == [page.id])
            let placeholder = try #require(first.browser.microPlaceholder(for: page.id))
            #expect(placeholder.spaceTabID == page.spaceTabID)
            #expect(second.browser.tabs.filter { $0.spaceTabID == placeholder.spaceTabID }.count == 1)
            #expect(first.browser.pinStore.spaceRows.map(\.id) == rows.map(\.id))

            let agentWindow = BrowserModel(context: first.browser.context, windowID: UUID(), database: .temporary())
            agentWindow.windowKind = .micro
            agentWindow.isEphemeralAgentWindow = true
            #expect(!agentWindow.sharesSpaceTabs)
        }
    }

    @Test func turningSharingOffKeepsEachTabInOneWindowAndTurningItOnShowsThemAll() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            defer { finish(app) }
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let (page, _, _) = fill(first)
            let outline = first.browser.spaceOutline
            let settings = first.settings
            let closedEarlier = app.newWindow(profile: profile, show: false)
            #expect(closedEarlier.browser.spaceOutline == outline)
            closedEarlier.closeWindow()

            settings.sharesSpaceTabsAcrossWindows = false

            #expect(first.browser.spaceOutline == outline)
            #expect(first.browser.tabs.allSatisfy { $0.spaceTabID == nil })
            #expect(second.browser.spaceOutline == "")
            #expect(second.browser.activeTab != nil)
            #expect(first.browser.pinStore.spaceRows.isEmpty)
            #expect(first.browser.tab(id: page.id) === page)
            let third = app.newWindow(profile: profile, show: false)
            #expect(third.browser.spaceOutline == "")
            #expect(third.browser.pinOutline == "https://pin.example/")
            // A window closed while sharing was on comes back without the copies the first window now keeps.
            let reopened = app.newWindow(profile: profile, windowID: closedEarlier.windowID, restoring: true, show: false)
            #expect(reopened.browser.spaceOutline == "")
            reopened.closeWindow()
            let own = second.browser.addPage("https://own.example/")
            second.browser.scheduleSave()
            #expect(first.browser.page(at: own.urlString) == nil)

            #expect(second.browser.page(at: own.urlString) != nil)
            settings.sharesSpaceTabsAcrossWindows = true

            #expect(second.browser.page(at: own.urlString) != nil)
            for window in [first, second, third] {
                #expect(window.browser.page(at: "https://one.example/") != nil)
                #expect(window.browser.page(at: own.urlString) != nil)
                expectOneCopyPerRow(window)
            }
            settings.sharesSpaceTabsAcrossWindows = true
        }
    }

    @Test func anExtensionWindowKeepsTheSharedTabs() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            defer { finish(app) }
            let first = app.newWindow(profile: profile, show: false)
            fill(first)
            let outline = first.browser.spaceOutline

            _ = app.openExtensionWindow(
                for: first.extensions, profile: profile, privately: false, focused: false,
                urls: [URL(string: "https://opened.example/")!], tabs: []
            )

            let opened = try #require(app.windows.last)
            #expect(opened.browser.page(at: "https://one.example/") != nil)
            // The extension's page is shared like any other; the rows the first window had stay.
            #expect(first.browser.page(at: "https://opened.example/") != nil)
            #expect(first.browser.page(at: "https://one.example/") != nil)
            #expect(first.browser.page(at: "https://two.example/") != nil)
            #expect(!outline.isEmpty)
        }
    }
}

extension BrowserModel {
    /// The ordinary rows of every Space as text: folders as `Name[children]`. Pins and a window's blank tabs are left out.
    var spaceOutline: String {
        spaceOutline(in: nil)
    }

    private func spaceOutline(in parent: UUID?) -> String {
        reconciledTree().rows(in: parent)
            .filter { parent != nil || !isKept($0) }
            .compactMap { item -> String? in
                switch item {
                case .tab(let id):
                    guard let page = tab(id: id), !page.urlString.isEmpty, page.microTabID == nil else { return nil }
                    return page.urlString
                case .folder(let id):
                    return "\(folder(id: id)?.name ?? "?")[\(spaceOutline(in: id))]"
                }
            }
            .joined(separator: " ")
    }
}
