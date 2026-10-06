// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

@MainActor
struct SidebarFavoritesTests {
    @Test(.boundedWebViews) func favoriteSurvivesSessionRestoreWithoutDuplicatingSidebarRows() throws {
        let database = AppDatabase.temporary()
        let model = BrowserModel(database: database)
        defer { model.closeAllTabs(saving: false) }
        let tab = model.newTab()
        tab.urlString = "https://example.test/"
        tab.pageTitle = "Example"
        model.addFavorite(tab)
        model.addFavorite(tab)
        #expect(model.favorites.map(\.id) == [tab.id])
        #expect(!model.sidebarItems.contains(.tab(tab.id)))
        #expect(!model.rows(in: nil).contains(.tab(tab.id)))
        model.saveBlocking()

        let restored = BrowserModel(database: database)
        defer { restored.closeAllTabs(saving: false) }
        restored.restoreSession()
        let favorite = try #require(restored.favorites.first)
        #expect(favorite.id == tab.id)
        #expect(favorite.pinnedURL == URL(string: "https://example.test/"))
        #expect(!restored.sidebarItems.contains(.tab(tab.id)))
        #expect(restored.tabs.filter { $0.id == tab.id }.count == 1)
    }

    @Test(.boundedWebViews) func removingFavoriteKeepsItsPinAndCanBeUndone() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let tab = model.newTab()
        tab.urlString = "https://example.test/"
        model.addFavorite(tab)

        model.removeFavorite(tab)
        #expect(model.favorites.isEmpty)
        #expect(model.tab(id: tab.id) === tab)
        #expect(tab.pinnedURL == URL(string: "https://example.test/"))
        #expect(model.sidebarItems.contains(.tab(tab.id)))
        model.sidebarUndoManager.undo()
        #expect(model.favorites.map(\.id) == [tab.id])
        #expect(!model.sidebarItems.contains(.tab(tab.id)))
        model.sidebarUndoManager.redo()
        #expect(model.favorites.isEmpty)
    }

    @Test(.boundedWebViews) func favoriteUndoPreservesOrderAndManualUnloadAcrossClosingTheTab() throws {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let favorites = (0..<3).map { index in
            let tab = model.newTab()
            tab.urlString = "https://example.test/\(index)"
            model.addFavorite(tab)
            return tab
        }
        let first = try #require(favorites.first)
        let order = model.favorites.map(\.id)
        let tree = model.sidebarTree
        #expect(model.unload(first))
        model.removeFavorite(first)
        model.sidebarUndoManager.undo()
        #expect(model.favorites.map(\.id) == order)
        #expect(model.sidebarTree == tree)
        #expect(first.isDeferred)
        model.sidebarUndoManager.redo()
        model.close(first)
        model.sidebarUndoManager.undo()
        let restored = try #require(model.tab(id: first.id))
        model.sidebarUndoManager.undo()
        #expect(restored.isFavorite)
        #expect(restored.isDeferred)
        #expect(model.favorites.map(\.id) == order)
        #expect(model.sidebarTree == tree)
        model.sidebarUndoManager.redo()
        #expect(!restored.isFavorite)
        model.sidebarUndoManager.redo()
        #expect(model.tab(id: first.id) == nil)
    }

    @Test(.boundedWebViews) func splittingAFavoriteKeepsTheWholeGroupReachable() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let favorite = model.newTab()
        favorite.urlString = "https://example.test/"
        model.addFavorite(favorite)
        let other = model.newTab()
        model.split(favorite, with: other, axis: .sideBySide)
        #expect(!favorite.isFavorite)
        #expect(favorite.pinnedURL != nil)
        #expect(model.sidebarItems.contains(.tab(favorite.id)))
        #expect(model.splitFollowers(of: favorite)?.map(\.id) == [other.id])
    }

    @Test(.boundedWebViews) func blankTabsCannotBecomeFavorites() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let tab = model.newTab()
        model.addFavorite(tab)
        #expect(!tab.isFavorite)
        #expect(tab.pinnedURL == nil)
        #expect(model.sidebarItems.contains(.tab(tab.id)))
    }

    @Test(.boundedWebViews) func favoritesResistAutomaticSleepButAllowManualUnload() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let favorite = model.newTab()
        favorite.urlString = "https://example.test/"
        model.addFavorite(favorite)
        _ = model.newTab()

        model.discardBackgroundTabs()
        #expect(!favorite.isDeferred)
        #expect(model.unload(favorite))
        #expect(favorite.isDeferred)
        #expect(model.favorites.map(\.id) == [favorite.id])
        #expect(!model.sidebarItems.contains(.tab(favorite.id)))
    }

    @Test(.boundedWebViews) func oldSessionsWithoutFavoritesColumnStillOpen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FavoritesMigration-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = AppDatabase(at: url)
        let id = UUID()
        try database.writer.write { db in
            try db.execute(sql: "ALTER TABLE sessionTab DROP COLUMN isFavorite")
            try db.execute(
                sql: "INSERT INTO sessionTab (id, title, url) VALUES (?, ?, ?)",
                arguments: [id, "Saved", "https://example.test/"]
            )
            try db.execute(sql: "INSERT INTO sessionItem (position, tabID) VALUES (0, ?)", arguments: [id])
        }
        let model = BrowserModel(database: AppDatabase(at: url))
        defer { model.closeAllTabs(saving: false) }
        model.restoreSession()
        let restored = try #require(model.tab(id: id))
        #expect(restored.title == "Saved")
        #expect(restored.urlString == "https://example.test/")
        #expect(!restored.isFavorite)
        #expect(model.sidebarItems == [.tab(id)])
    }
}
