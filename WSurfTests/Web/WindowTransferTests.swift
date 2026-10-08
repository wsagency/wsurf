// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import GRDB
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct WindowTransferTests {
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func transferPreservesForkStateAndRejectsStaleUndo(engine: BrowserEngine) async throws {
        let submitted = ResponseGate()
        submitted.open()
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Form</title><form method='post' action='/submitted'><input name='value' value='once'></form>"),
            "/submitted": .html("<title>Submitted once</title><p>Saved response</p>", gate: submitted),
        ])
        let url = try server.url("/")
        let responseURL = try server.url("/submitted")
        let profile = Profile(id: UUID(), name: "Transfer fixture", symbol: "person", color: .gray)
        let context = BrowserProfileContext.shared(for: profile)
        context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let database = AppDatabase.temporary()
        let source = BrowserModel(context: context, windowID: UUID(), database: database)
        let destination = BrowserModel(context: context, windowID: UUID(), database: database)
        let fromWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        let toWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                styleMask: .borderless, backing: .buffered, defer: false)
        fromWindow.isReleasedWhenClosed = false
        toWindow.isReleasedWhenClosed = false
        func cleanUp() async {
            let tabs = source.tabs + destination.tabs
            source.closeAllTabs(saving: false)
            destination.closeAllTabs(saving: false)
            for tab in tabs {
                await tab.waitForRetirement()
            }
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            await context.sitePermissions.waitForPendingSave()
            fromWindow.close()
            toWindow.close()
            BrowserProfileContext.forget(profile.id)
            ProfileSettingsStore.forget(profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        }
        do {
            source.split(source.newTab(), with: source.newTab(), axis: .sideBySide)
            let parent = source.createFolder(named: "Pinned parent")
            source.pin(parent)
            let nested = source.createFolder(named: "Nested")
            source.move([.folder(nested.id)], into: parent, settlingPins: false)
            let tab = source.newTab(url: url)
            let page = tab.page
            fromWindow.contentView = page
            fromWindow.orderFront(nil)
            try #require(await waitUntil { page.title == "Form" && !page.isLoading })
            do {
                _ = try await page.evaluateJavaScript("document.querySelector('form').submit(); true")
            } catch ChromiumError.staleFrame {
                // The POST may commit before Chromium validates the old document's result.
                try #require(submitted.requestCount == 1)
            }
            try #require(await waitUntil { page.url == responseURL && page.title == "Submitted once" && !page.isLoading })
            #expect(page.engine == engine)
            _ = try await page.evaluateJavaScript("window.transferMarker = 'original-post-document'; true")
            source.addFavorite(tab)
            let oldFolder = source.createFolder(named: "Previous owner")
            source.move([.tab(tab.id)], into: oldFolder, settlingPins: false)
            source.deleteFolder(oldFolder)
            source.move([.tab(tab.id)], into: nested, settlingPins: false)
            let existing = destination.newTab()
            let otherFolder = destination.createFolder(named: "Destination", containing: [existing])
            let destinationLeft = destination.newTab()
            let destinationRight = destination.newTab()
            destination.split(destinationLeft, with: destinationRight, axis: .stacked)
            destination.deleteFolder(destination.createFolder(named: "Previous destination"))
            source.saveBlocking()
            destination.saveBlocking()
            let state = tab.sessionState
            let sourceTree = source.sidebarTree.removing([.tab(tab.id)])
            let sourceSplits = source.splits
            let destinationTree = destination.sidebarTree
            let destinationSplits = destination.splits
            #expect(source.sidebarUndoManager.canUndo)
            #expect(destination.sidebarUndoManager.canUndo)
            #expect(submitted.requestCount == 1)
            source.saveNow()
            destination.saveNow()

            try #require(destination.adoptTab(tab, from: source))
            toWindow.contentView = page
            toWindow.orderFront(nil)
            await source.saveChain?.value
            await destination.saveChain?.value
            #expect(tab.liveView === page)
            #expect(page.window === toWindow)
            #expect(!page.isClosed && !tab.isClosed)
            #expect(try await page.evaluateJavaScript("window.transferMarker") as? String == "original-post-document")
            #expect(submitted.requestCount == 1)
            #expect(tab.isFavorite && tab.pinnedURL == responseURL)
            #expect(source.sidebarTree == sourceTree)
            #expect(source.splits == sourceSplits)
            #expect(destination.splits == destinationSplits)
            #expect(destination.folder(containing: existing) === otherFolder)
            #expect(destination.sidebarTree.removing([.tab(tab.id)]) == destinationTree)
            #expect(!source.sidebarUndoManager.canUndo && !destination.sidebarUndoManager.canUndo)
            source.sidebarUndoManager.undo()
            destination.sidebarUndoManager.undo()
            source.close(tab)
            #expect(source.tab(id: tab.id) == nil)
            #expect(destination.tab(id: tab.id) === tab)
            #expect(!tab.isClosed)
            let tabID = tab.id
            let destinationID = destination.windowID
            let parentID = parent.id
            let nestedID = nested.id
            try await database.writer.read { db throws in
                let saved = try #require(try Row.fetchOne(db, sql: "SELECT windowID, state, isFavorite, pinnedURL FROM sessionTab WHERE id = ?", arguments: [tabID]))
                #expect(saved["windowID"] as UUID == destinationID)
                #expect(saved["state"] as Data? == state)
                #expect(saved["isFavorite"] as Bool)
                #expect(saved["pinnedURL"] as String == responseURL.absoluteString)
                #expect(try Bool.fetchOne(db, sql: "SELECT isPinned FROM sessionFolder WHERE id = ?", arguments: [parentID]) == true)
                #expect(try UUID.fetchOne(db, sql: "SELECT parentID FROM sessionItem WHERE folderID = ?", arguments: [nestedID]) == parentID)
            }
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    @Test func transferringBeforeQueuedSavesRunKeepsEveryTabsLatestState() async throws {
        let context = BrowserProfileContext.shared(for: .original())
        let database = AppDatabase.temporary()
        let source = BrowserModel(context: context, windowID: UUID(), database: database)
        let destination = BrowserModel(context: context, windowID: UUID(), database: database)
        defer { source.closeAllTabs(saving: false); destination.closeAllTabs(saving: false) }
        _ = source.newTab()
        let moved = source.newTab(activate: false)
        let left = source.newTab(activate: false)
        let right = destination.newTab(activate: false)
        let old = Data("old back-forward state".utf8)
        for tab in [left, right] {
            tab.deferRestore(state: old, url: nil)
        }
        source.saveBlocking()
        destination.saveBlocking()
        let latestLeft = Data("latest source form and navigation state".utf8)
        let latestRight = Data("latest destination form and navigation state".utf8)
        left.deferRestore(state: latestLeft, url: nil)
        right.deferRestore(state: latestRight, url: nil)
        left.invalidateSessionState()
        right.invalidateSessionState()
        // No suspension until transfer commits: both queued snapshots are still waiting.
        source.saveNow()
        destination.saveNow()
        try #require(destination.adoptTab(moved, from: source))
        await source.saveChain?.value
        await destination.saveChain?.value

        func verifySavedStates() throws {
            try database.writer.read { db throws in
                #expect(try Data.fetchOne(db, sql: "SELECT state FROM sessionTab WHERE id = ?", arguments: [left.id]) == latestLeft)
                #expect(try Data.fetchOne(db, sql: "SELECT state FROM sessionTab WHERE id = ?", arguments: [right.id]) == latestRight)
                #expect(try UUID.fetchOne(db, sql: "SELECT windowID FROM sessionTab WHERE id = ?", arguments: [moved.id]) == destination.windowID)
            }
        }
        try verifySavedStates()
        source.saveNow()
        destination.saveNow()
        await source.saveChain?.value
        await destination.saveChain?.value
        try verifySavedStates()
    }

    @Test func unregisteredOwnerCannotTransferOrConsumeUndo() {
        let context = BrowserProfileContext.shared(for: .original())
        let database = AppDatabase.temporary()
        let source = BrowserModel(context: context, windowID: UUID(), database: database)
        let destination = BrowserModel(context: context, windowID: UUID(), database: database)
        defer { source.closeAllTabs(saving: false); destination.closeAllTabs(saving: false) }
        let tab = source.newTab()
        let folder = source.createFolder(named: "Owned", containing: [tab])
        source.deleteFolder(source.createFolder(named: "Undoable deletion"))
        #expect(source.sidebarUndoManager.canUndo)
        context.unregister(destination)
        #expect(!destination.adoptTab(tab, from: source))
        #expect(source.tab(id: tab.id) === tab)
        #expect(source.folder(containing: tab) === folder)
        #expect(source.sidebarUndoManager.canUndo)
        context.register(destination)
        context.unregister(source)
        #expect(!destination.adoptTab(tab, from: source))
        #expect(!tab.isClosed)
    }
}
