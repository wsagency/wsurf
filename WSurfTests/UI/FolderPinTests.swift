// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

@MainActor
struct FolderPinTests {
    @Test func folderPinsKeepOrderAcrossRestartWithoutChangingChildBookmarks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderPin-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let database = AppDatabase(at: url)
        let browser = BrowserModel(database: database)
        let tab = browser.newTab(url: URL(string: "https://example.com/"))
        let populated = browser.createFolder(named: "Work")
        browser.pin(tab)
        browser.move([.tab(tab.id)], into: populated, settlingPins: false)
        let pinnedURL = tab.pinnedURL
        let pinnedTitle = tab.pinnedTitle
        let empty = browser.createFolder(named: "Empty")

        browser.pin(empty)
        browser.pin(populated)
        let loose = browser.newTab(url: URL(string: "https://example.org/"))

        #expect(populated.isPinned)
        #expect(empty.isPinned)
        #expect(tab.pinnedURL == pinnedURL)
        #expect(tab.pinnedTitle == pinnedTitle)
        #expect(browser.folder(containing: loose) == nil)
        #expect(browser.sidebarItems == [.folder(empty.id), .folder(populated.id), .tab(loose.id)])

        browser.unpin(empty)
        #expect(browser.sidebarItems == [.folder(populated.id), .folder(empty.id), .tab(loose.id)])

        browser.saveBlocking()
        let restored = BrowserModel(database: AppDatabase(at: url))
        restored.restoreSession()
        let restoredWork = try #require(restored.folders.first { $0.name == "Work" })
        let restoredEmpty = try #require(restored.folders.first { $0.name == "Empty" })
        let restoredTab = try #require(restored.allTabs(in: restoredWork).first)

        #expect(restoredWork.isPinned)
        #expect(!restoredEmpty.isPinned)
        #expect(restored.sidebarItems == [.folder(restoredWork.id), .folder(restoredEmpty.id), .tab(loose.id)])
        #expect(restoredTab.pinnedURL == pinnedURL)
        #expect(restoredTab.pinnedTitle == pinnedTitle)
    }

    @Test func anEmptyPinnedFolderSurvivesWithoutAnyTabs() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyFolderPin-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let browser = BrowserModel(database: AppDatabase(at: url))
        let empty = browser.createFolder(named: "Empty")
        browser.pin(empty)
        browser.saveBlocking()

        let restored = BrowserModel(database: AppDatabase(at: url))
        restored.restoreSession()
        let folder = try #require(restored.folders.first)
        #expect(folder.name == "Empty" && folder.isPinned)
        #expect(restored.sidebarItems == [.folder(folder.id)])
        #expect(restored.tabs.isEmpty && restored.activeTabID == nil)
        restored.restoreSession()
        #expect(restored.sidebarItems == [.folder(folder.id)])
    }

    @Test func legacyNestedPinsMigrateOnceWithoutPinningMixedOrEmptyFolders() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyFolderPin-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = AppDatabase(at: url)
        let browser = BrowserModel(database: database)
        let inner = browser.createFolder(named: "Inner")
        let outer = browser.createFolder(named: "Outer")
        let mixed = browser.createFolder(named: "Mixed")
        _ = browser.createFolder(named: "Empty")
        let nested = browser.newTab(url: URL(string: "https://nested.example/"), activate: false)
        let bookmark = browser.newTab(url: URL(string: "https://bookmark.example/"), activate: false)
        let loose = browser.newTab(url: URL(string: "https://loose.example/"), activate: false)
        browser.pin(nested)
        browser.pin(bookmark)
        browser.move([.tab(nested.id)], into: inner, settlingPins: false)
        browser.move([.folder(inner.id)], into: outer, settlingPins: false)
        browser.move([.tab(bookmark.id), .tab(loose.id)], into: mixed, settlingPins: false)
        browser.saveBlocking()
        try database.writer.write { db in
            try db.execute(sql: "ALTER TABLE sessionFolder DROP COLUMN isPinned")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v2-folder-pinning"]
            )
        }

        let migrated = AppDatabase(at: url)
        #expect(!migrated.isEphemeral)
        let restored = BrowserModel(database: migrated)
        restored.restoreSession()
        let byName = Dictionary(uniqueKeysWithValues: restored.folders.map { ($0.name, $0) })
        #expect(byName["Inner"]?.isPinned == true)
        #expect(byName["Outer"]?.isPinned == true)
        #expect(byName["Mixed"]?.isPinned == false)
        #expect(byName["Empty"]?.isPinned == false)
        #expect(restored.tab(id: nested.id)?.pinnedURL == nested.pinnedURL)
        #expect(restored.tab(id: bookmark.id)?.pinnedURL == bookmark.pinnedURL)

        let restoredOuter = try #require(byName["Outer"])
        restored.unpin(restoredOuter)
        restored.saveBlocking()
        let reopened = BrowserModel(database: AppDatabase(at: url))
        reopened.restoreSession()
        #expect(reopened.folders.first { $0.name == "Outer" }?.isPinned == false)
    }
}
