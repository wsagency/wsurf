// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import GRDB
import Testing

@testable import WSurf

/// Each profile keeps its own spaces, and every tab and folder of a window remembers its space across a restart.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SpaceStoreTests {
    private let work = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)

    private func spacesFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Spaces-\(UUID().uuidString).json")
    }

    // MARK: - The store

    @Test func aProfileStartsWithOneSpaceNamedAfterIt() throws {
        let file = spacesFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = SpaceStore(profile: work, file: file)

        let space = try #require(store.spaces.first)
        #expect(store.spaces.count == 1)
        #expect(space.name == "Work")
        #expect(space.symbol == "briefcase")
        #expect(space.color == .blue)
        #expect(SpaceStore(profile: work, file: file).spaces == [space])
    }

    @Test func spacesSurviveAReloadInOrder() {
        let file = spacesFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SpaceStore(profile: work, file: file)

        let recipes = store.add(name: "  Recipes ", symbol: "fork.knife")
        let travel = store.add(name: "Travel")

        #expect(recipes.name == "Recipes")
        #expect(SpaceStore(profile: work, file: file).spaces.map(\.id) == store.spaces.map(\.id))
        #expect(store.spaces.last == travel)
    }

    @Test func aNewSpaceWearsAColorNoOtherSpaceWears() {
        let store = SpaceStore(profile: work, file: nil)

        let added = store.add(name: "Recipes")

        #expect(added.color != .blue)
        #expect(added.color != .gray)
    }

    @Test func aProfileAlwaysKeepsOneSpace() throws {
        let store = SpaceStore(profile: work, file: nil)
        let only = try #require(store.spaces.first)

        #expect(!store.canRemove(only))
        store.remove(only)
        #expect(store.spaces == [only])

        let second = store.add(name: "Recipes")
        #expect(store.canRemove(only))
        store.remove(only)
        #expect(store.spaces == [second])
    }

    @Test func renamingToNothingKeepsTheName() throws {
        let store = SpaceStore(profile: work, file: nil)
        var space = try #require(store.spaces.first)

        space.name = "   "
        space.symbol = "house"
        store.update(space)

        #expect(store.spaces.first?.name == "Work")
        #expect(store.spaces.first?.symbol == "house")
    }

    @Test func privateBrowsingHasNoSpaces() {
        #expect(SpaceStore.shared(for: .privateBrowsing()) == nil)
    }

    @Test func eachProfileHasOneStoreInItsOwnDirectory() {
        defer { SpaceStore.forget(work.id) }

        let store = SpaceStore.shared(for: work)

        #expect(store === SpaceStore.shared(for: work))
        #expect(store?.profileID == work.id)
        #expect(work.spacesFile.deletingLastPathComponent() == work.supportDirectory)
        SpaceStore.forget(work.id)
        #expect(store !== SpaceStore.shared(for: work))
    }

    @Test func removingAProfileTakesItsSpacesWithIt() async throws {
        let catalogFile = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: catalogFile) }
        let catalog = ProfileStore(file: catalogFile)
        let profile = catalog.add(name: "Doomed")
        let cached = SpaceStore.shared(for: profile)
        _ = SpaceStore(profile: profile, file: profile.spacesFile)
        try #require(FileManager.default.fileExists(atPath: profile.spacesFile.path))

        await catalog.remove(profile)

        #expect(!FileManager.default.fileExists(atPath: profile.spacesFile.path))
        #expect(SpaceStore.shared(for: profile) !== cached)
        SpaceStore.forget(profile.id)
    }

    // MARK: - Tabs and folders keep their space

    @Test func tabsAndFoldersKeepTheirSpaceAcrossARestart() throws {
        let database = AppDatabase.temporary()
        let home = UUID()
        let recipes = UUID()
        let window = BrowserModel(windowID: UUID(), database: database)
        let homeTab = window.newTab()
        homeTab.spaceID = home
        let filed = window.addPage("https://recipes.example/soup")
        let folder = window.createFolder(named: "Soups", containing: [filed])
        folder.spaceID = recipes
        filed.spaceID = recipes
        let unplaced = window.addPage("https://example.test/old")
        window.saveBlocking()

        let reopened = BrowserModel(windowID: window.windowID, database: database)
        reopened.restoreSession()

        #expect(reopened.tab(id: homeTab.id)?.spaceID == home)
        #expect(reopened.tab(id: filed.id)?.spaceID == recipes)
        #expect(reopened.folder(id: folder.id)?.spaceID == recipes)
        #expect(reopened.tab(id: unplaced.id)?.spaceID == nil)
        window.closeAllTabs(saving: false)
        reopened.closeAllTabs(saving: false)
    }

    @Test func anUpgradeAddsTheColumnsAndOldRowsHaveNoSpace() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpacesUpgrade-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let savedID = UUID()
        let before = AppDatabase(at: url)
        try before.writer.write { db in
            // The schema a build without spaces left behind.
            try db.execute(sql: "ALTER TABLE sessionTab DROP COLUMN spaceID")
            try db.execute(sql: "ALTER TABLE sessionFolder DROP COLUMN spaceID")
            try db.execute(
                sql: "INSERT INTO sessionTab (id, title, url, isActive) VALUES (?, ?, ?, ?)",
                arguments: [savedID, "Saved", "https://example.test/saved", true]
            )
            try db.execute(sql: "INSERT INTO sessionItem (position, tabID) VALUES (?, ?)", arguments: [0, savedID])
        }

        let upgraded = AppDatabase(at: url)
        try upgraded.writer.read { db throws in
            #expect(try db.columns(in: "sessionTab").contains { $0.name == "spaceID" })
            #expect(try db.columns(in: "sessionFolder").contains { $0.name == "spaceID" })
        }
        let model = BrowserModel(database: upgraded)
        defer { model.closeAllTabs(saving: false) }
        model.restoreSession()

        #expect(model.tab(id: savedID)?.spaceID == nil)
    }

    @Test func aReopenedTabReturnsToItsSpace() throws {
        let model = BrowserModel(database: .temporary())
        _ = model.newTab()
        let closing = model.newTab()
        let space = UUID()
        closing.spaceID = space

        model.close(closing)
        model.reopenLastClosedTab()

        #expect(model.tab(id: closing.id)?.spaceID == space)
        model.closeAllTabs(saving: false)
    }

    @Test func aDuplicateStaysInTheSameSpace() {
        let model = BrowserModel(database: .temporary())
        let original = model.newTab()
        let space = UUID()
        original.spaceID = space

        #expect(model.duplicate(original).spaceID == space)
        model.closeAllTabs(saving: false)
    }

    @Test func aTabMovedToAnotherWindowLeavesItsSpaceBehind() {
        let database = AppDatabase.temporary()
        let source = BrowserModel(windowID: UUID(), database: database)
        let destination = BrowserModel(windowID: UUID(), database: database)
        let tab = source.newTab()
        _ = source.newTab()
        tab.spaceID = UUID()

        #expect(destination.adoptTab(tab, from: source))

        #expect(tab.spaceID == nil)
        source.closeAllTabs(saving: false)
        destination.closeAllTabs(saving: false)
    }
}
