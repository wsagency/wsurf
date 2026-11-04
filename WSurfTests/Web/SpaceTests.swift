// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import GRDB
import Testing

@testable import WSurf

/// A window shows one space at a time. Pins and Favorites belong to the profile and show in every space; the window's
/// tab list, which the assistant and MCP clients read, keeps every tab.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SpaceTests {
    private let home = UUID()
    private let recipes = UUID()

    private func makeModel(database: AppDatabase = .temporary(), windowID: UUID = UUID()) -> BrowserModel {
        let model = BrowserModel(windowID: windowID, database: database)
        model.adoptSpaces([home, recipes])
        return model
    }

    private func listedTabs(_ model: BrowserModel) -> [UUID] {
        model.sidebarTree.flattenedTabs(known: Set(model.tabsByID.keys))
    }

    // MARK: - The list

    @Test func newTabsJoinTheCurrentSpace() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }

        #expect(model.currentSpaceID == home)
        #expect(model.newTab().spaceID == home)
    }

    @Test func theSidebarListsOnlyTheCurrentSpace() throws {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        model.switchSpace(to: recipes)
        let recipeTab = try #require(model.activeTab)

        #expect(listedTabs(model) == [recipeTab.id])
        model.switchSpace(to: home)
        #expect(listedTabs(model) == [homeTab.id])
    }

    @Test func pinsAndFavoritesShowInEverySpace() throws {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        let pin = model.pinned("https://pinned.example.test/")
        let favorite = model.pinned("https://favorite.example.test/")
        favorite.isFavorite = true
        let folder = model.createFolder(named: "Kept", containing: [model.addPage("https://kept.example.test/")])
        model.pin(folder)

        model.switchSpace(to: recipes)
        let recipeTab = try #require(model.activeTab)

        #expect(pin.spaceID == nil && favorite.spaceID == nil && folder.spaceID == nil)
        #expect(model.sidebarTree.root.contains(.tab(pin.id)))
        #expect(model.sidebarTree.root.contains(.folder(folder.id)))
        #expect(model.favorites.map(\.id) == [favorite.id])
        #expect(model.sidebarItems.contains(.tab(recipeTab.id)))
        #expect(!model.sidebarItems.contains(.tab(homeTab.id)))
    }

    @Test func anUnpinnedTabStaysInTheSpaceOnScreen() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        _ = model.newTab()
        let pin = model.pinned("https://pinned.example.test/")
        model.switchSpace(to: recipes)

        model.unpin(pin)
        #expect(listedTabs(model).contains(pin.id))
        model.switchSpace(to: home)

        #expect(pin.spaceID == recipes)
        #expect(!listedTabs(model).contains(pin.id))
    }

    @Test func switchingToAnEmptySpaceOpensATabThere() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        _ = model.newTab()

        model.switchSpace(to: recipes)

        #expect(model.currentSpaceID == recipes)
        #expect(model.activeTab?.spaceID == recipes)
    }

    @Test func aPinOnScreenStaysWhenTheNextSpaceIsEmpty() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        _ = model.newTab()
        let pin = model.pinned("https://pinned.example.test/")
        model.activate(pin)
        let count = model.tabs.count

        model.switchSpace(to: recipes)

        #expect(model.activeTab === pin)
        #expect(model.tabs.count == count)
    }

    @Test func switchingBackReturnsToTheLastActiveTab() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let first = model.newTab()
        _ = model.newTab()
        model.activate(first)
        model.switchSpace(to: recipes)

        model.switchSpace(to: home)

        #expect(model.activeTab === first)
    }

    @Test func activatingATabInAnotherSpaceGoesThere() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        model.switchSpace(to: recipes)

        model.activate(homeTab)

        #expect(model.currentSpaceID == home)
        #expect(listedTabs(model) == [homeTab.id])
    }

    @Test func aPageOpenedFromAnotherSpaceStaysWithItsOpener() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        model.switchSpace(to: recipes)

        let opened = model.newTab(activate: false, after: homeTab)

        #expect(opened.spaceID == home)
        #expect(model.currentSpaceID == recipes)
    }

    @Test func aWindowWithoutSpacesShowsEveryTab() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let first = model.newTab()
        first.spaceID = home

        model.adoptSpaces([])

        #expect(model.currentSpaceID == nil)
        #expect(listedTabs(model) == [first.id])
        #expect(first.spaceID == home)
    }

    // MARK: - Navigation stays in the space

    @Test func closingTheActiveTabPicksANeighborInTheSameSpace() throws {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        model.switchSpace(to: recipes)
        let recipeTab = try #require(model.activeTab)
        let second = model.newTab()
        model.activate(recipeTab)
        try #require(model.tabs.map(\.id) == [second.id, recipeTab.id, homeTab.id])

        model.close(recipeTab)

        #expect(model.activeTab === second)
        #expect(model.currentSpaceID == recipes)
    }

    @Test func numberedTabsCountOnlyTheCurrentSpace() throws {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        model.switchSpace(to: recipes)
        let recipeTab = try #require(model.activeTab)
        let second = model.newTab()
        try #require(model.tabs.map(\.id) == [second.id, recipeTab.id, homeTab.id])

        model.activateTab(at: 1)
        #expect(model.activeTab === recipeTab)

        model.activateTab(at: 2)
        #expect(model.activeTab === recipeTab)

        model.activateLastTab()
        #expect(model.activeTab === recipeTab)
        model.cycleTab(forward: true)
        #expect(model.activeTab === second)
    }

    @Test func closeOthersLeavesOtherSpacesAlone() throws {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        model.switchSpace(to: recipes)
        let kept = try #require(model.activeTab)
        _ = model.newTab()

        model.closeOthers(kept)

        #expect(Set(model.tabs.map(\.id)) == [homeTab.id, kept.id])
    }

    @Test func theWindowsTabListKeepsEverySpace() throws {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        homeTab.title = "Soup at home"
        model.switchSpace(to: recipes)
        let recipeTab = try #require(model.activeTab)

        #expect(Set(model.tabs.map(\.id)) == [homeTab.id, recipeTab.id])
        #expect(model.tab(matching: "soup at") === homeTab)
    }

    @Test func theAssistantAndMCPNeverFilterBySpace() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["WSurf/Agent", "WSurf/MCP", "WSurf/Web/Assistant"] {
            let files = try #require(FileManager.default.enumerator(at: root.appending(path: folder), includingPropertiesForKeys: nil))
            var scanned = 0
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                for name in ["currentSpaceTabs", "currentSpaceID", "isShown(", "firstShownTab"] {
                    #expect(!source.contains(name), "\(file.lastPathComponent) names \(name)")
                }
            }
            #expect(scanned > 0, "\(folder) has no sources to scan")
        }
    }

    // MARK: - Moving between spaces

    @Test func movingATabTakesItToTheOtherSpace() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let stays = model.newTab()
        let moves = model.newTab()

        model.move([.tab(moves.id)], toSpace: recipes)

        #expect(moves.spaceID == recipes)
        #expect(listedTabs(model) == [stays.id])
        #expect(model.activeTab === stays)
        #expect(model.currentSpaceID == home)
    }

    @Test func aFolderCarriesItsTabsAndKeepsItsID() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        _ = model.newTab()
        let tab = model.addPage("https://recipes.example.test/soup")
        let folder = model.createFolder(named: "Soups", containing: [tab])
        let folderID = folder.id

        model.move([.folder(folder.id)], toSpace: recipes)

        #expect(folder.spaceID == recipes)
        #expect(tab.spaceID == recipes)
        #expect(model.folder(id: folderID) === folder)
        #expect(model.folder(containing: tab) === folder)
        #expect(!model.sidebarTree.root.contains(.folder(folderID)))
    }

    @Test func bothPanesOfASplitMoveAndUndoForgetsItsSteps() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let stays = model.newTab()
        let left = model.newTab()
        let right = model.newTab()
        model.split(left, with: right, axis: .sideBySide)
        model.close(stays)
        #expect(model.sidebarUndoManager.canUndo)

        model.move([.tab(left.id)], toSpace: recipes)

        #expect(left.spaceID == recipes && right.spaceID == recipes)
        #expect(model.splits.split(containing: left.id)?.tabs.contains(right.id) == true)
        #expect(!model.sidebarUndoManager.canUndo)
    }

    @Test func pinsStayWhenTheyAreMoved() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        _ = model.newTab()
        let pin = model.pinned("https://pinned.example.test/")

        model.move([.tab(pin.id)], toSpace: recipes)

        #expect(pin.spaceID == nil)
        #expect(model.sidebarTree.root.contains(.tab(pin.id)))
    }

    @Test func aTabFromAnUnknownSpaceJoinsTheCurrentOne() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let tab = model.newTab()
        tab.spaceID = UUID()

        model.sidebarDidChange()

        #expect(tab.spaceID == home)
    }

    @Test func closingASpaceClosesOnlyItsTabsAndFolders() {
        let model = makeModel()
        defer { model.closeAllTabs(saving: false) }
        let homeTab = model.newTab()
        model.switchSpace(to: recipes)
        let folder = model.createFolder(named: "Soups", containing: [model.addPage("https://recipes.example.test/")])
        model.switchSpace(to: home)

        model.closeSpace(recipes)

        #expect(model.tabs.map(\.id) == [homeTab.id])
        #expect(!model.folders.contains { $0 === folder })
        #expect(!model.canReopenClosedTab)
    }

    @Test func aTabMovedToAnotherWindowJoinsTheSpaceItShows() {
        let database = AppDatabase.temporary()
        let source = makeModel(database: database)
        let destination = makeModel(database: database)
        defer {
            source.closeAllTabs(saving: false)
            destination.closeAllTabs(saving: false)
        }
        let tab = source.newTab()
        _ = source.newTab()
        destination.switchSpace(to: recipes)

        #expect(destination.adoptTab(tab, from: source))

        #expect(tab.spaceID == recipes)
        #expect(destination.currentSpaceID == recipes)
    }

    @Test func movingTheActiveTabToAnotherWindowKeepsTheSourceInItsSpace() throws {
        let database = AppDatabase.temporary()
        let source = makeModel(database: database)
        let destination = makeModel(database: database)
        defer {
            source.closeAllTabs(saving: false)
            destination.closeAllTabs(saving: false)
        }
        _ = source.newTab()
        source.switchSpace(to: recipes)
        let moving = try #require(source.activeTab)
        let stays = source.newTab()
        source.activate(moving)
        // The tab after the moving one belongs to the other space.
        try #require(source.tabs.firstIndex { $0 === moving } == 1)

        #expect(destination.adoptTab(moving, from: source))

        #expect(source.currentSpaceID == recipes)
        #expect(source.activeTab === stays)
    }

    // MARK: - Saving

    @Test func aRestoredWindowLandsInTheActiveTabsSpace() throws {
        let database = AppDatabase.temporary()
        let first = makeModel(database: database)
        let homeTab = first.newTab()
        first.switchSpace(to: recipes)
        let recipeTab = try #require(first.activeTab)
        first.saveBlocking()
        first.closeAllTabs(saving: false)

        let reopened = makeModel(database: database, windowID: first.windowID)
        defer { reopened.closeAllTabs(saving: false) }
        reopened.restoreSession()

        #expect(reopened.tab(id: homeTab.id)?.spaceID == home)
        #expect(reopened.tab(id: recipeTab.id)?.spaceID == recipes)
        #expect(reopened.currentSpaceID == recipes)
        #expect(listedTabs(reopened) == [recipeTab.id])
    }

    @Test func aRestoredWindowWithAPinInFrontLandsInTheSpaceUsedLast() throws {
        let database = AppDatabase.temporary()
        let first = makeModel(database: database)
        let homeTab = first.newTab()
        first.switchSpace(to: recipes)
        let recipeTab = try #require(first.activeTab)
        let pin = first.pinned("https://pinned.example.test/")
        homeTab.lastActiveAt = Date(timeIntervalSinceNow: -3600)
        recipeTab.lastActiveAt = Date()
        first.activate(pin)
        first.saveBlocking()
        first.closeAllTabs(saving: false)

        let reopened = makeModel(database: database, windowID: first.windowID)
        defer { reopened.closeAllTabs(saving: false) }
        reopened.restoreSession()

        #expect(reopened.activeTabID == pin.id)
        #expect(reopened.currentSpaceID == recipes)
    }

    @Test func rowsSavedBeforeSpacesJoinTheFirstSpace() throws {
        let database = AppDatabase.temporary()
        let old = BrowserModel(windowID: UUID(), database: database)
        let saved = old.newTab()
        old.saveBlocking()
        old.closeAllTabs(saving: false)

        let reopened = makeModel(database: database, windowID: old.windowID)
        defer { reopened.closeAllTabs(saving: false) }
        reopened.restoreSession()

        #expect(reopened.tab(id: saved.id)?.spaceID == home)
        #expect(reopened.currentSpaceID == home)
    }

    @Test func forgettingASpaceRemovesItsSavedTabsAndFolders() throws {
        let database = AppDatabase.temporary()
        let window = makeModel(database: database)
        let homeTab = window.newTab()
        window.switchSpace(to: recipes)
        _ = window.createFolder(named: "Soups", containing: [window.addPage("https://recipes.example.test/")])
        window.saveBlocking()
        window.closeAllTabs(saving: false)

        BrowserModel.forgetSpace(recipes, in: database)

        let reopened = makeModel(database: database, windowID: window.windowID)
        defer { reopened.closeAllTabs(saving: false) }
        reopened.restoreSession()
        #expect(reopened.tabs.map(\.id) == [homeTab.id])
        #expect(reopened.folders.isEmpty)
        #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessionItem") } == 1)
    }
}
