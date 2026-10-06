// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import GRDB
import Testing

@testable import WSurf

@MainActor
struct FolderPinTests {
    @Test(arguments: [false, true])
    func reorderingFolderChildrenPreservesTheirOwnBookmarks(folderIsPinned: Bool) {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        let anchor = browser.newTab(url: URL(string: "https://anchor.example/"), activate: false)
        let bookmarked = browser.newTab(url: URL(string: "https://bookmarked.example/current"), activate: false)
        let loose = browser.newTab(url: URL(string: "https://loose.example/"), activate: false)
        browser.setPin(URL(string: "https://bookmarked.example/saved")!, title: "Saved", for: bookmarked)
        browser.move(
            [.tab(anchor.id), .tab(bookmarked.id), .tab(loose.id)],
            into: folder,
            settlingPins: false
        )
        browser.pin(folder)
        if !folderIsPinned {
            browser.unpin(folder)
        }
        let drag = SidebarDrag(
            items: [.tab(bookmarked.id), .tab(loose.id)],
            lead: .tab(bookmarked.id),
            origin: .zero,
            tree: browser.sidebarTree,
            keepsSection: false,
            wasKept: true
        )

        browser.move(drag.items, into: folder, before: .tab(anchor.id), settlingPins: false)
        drag.settlePins(folder.isPinned, in: browser)

        #expect(browser.rows(in: folder) == [.tab(bookmarked.id), .tab(loose.id), .tab(anchor.id)])
        #expect(bookmarked.pinnedURL?.absoluteString == "https://bookmarked.example/saved")
        #expect(bookmarked.pinnedTitle == "Saved")
        #expect(loose.pinnedURL == nil && loose.pinnedTitle.isEmpty)
        #expect(folder.isPinned == folderIsPinned)
    }

    @Test(arguments: [false, true])
    func leavingTheOriginalFolderStillSettlesTheDraggedBookmark(intoFolder: Bool) {
        let browser = BrowserModel(database: .temporary())
        let origin = browser.createFolder(named: "Origin")
        let destination = intoFolder ? browser.createFolder(named: "Destination") : nil
        let tab = browser.newTab(url: URL(string: "https://bookmarked.example/"), activate: false)
        browser.setPin(URL(string: "https://bookmarked.example/")!, title: "Saved", for: tab)
        browser.move([.tab(tab.id)], into: origin, settlingPins: false)
        let drag = SidebarDrag(
            items: [.tab(tab.id)],
            lead: .tab(tab.id),
            origin: .zero,
            tree: browser.sidebarTree,
            keepsSection: false,
            wasKept: true
        )

        browser.move(drag.items, into: destination, settlingPins: false)
        drag.settlePins(false, in: browser)

        #expect(browser.folder(containing: tab)?.id == destination?.id)
        #expect(tab.pinnedURL == nil && tab.pinnedTitle.isEmpty)
    }

    @Test(arguments: [false, true])
    func releasingFolderChildrenPreservesTheRootPinBoundary(moveOut: Bool) {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        let first = browser.newTab(url: URL(string: "https://first.example/"), activate: false)
        let bookmarked = browser.newTab(url: URL(string: "https://bookmarked.example/current"), activate: false)
        let last = browser.newTab(url: URL(string: "https://last.example/"), activate: false)
        browser.setPin(URL(string: "https://bookmarked.example/saved")!, title: "Saved", for: bookmarked)
        let children: [SidebarItem] = [.tab(first.id), .tab(bookmarked.id), .tab(last.id)]
        browser.move(children, into: folder, settlingPins: false)
        browser.pin(folder)
        let kept = browser.newTab(url: URL(string: "https://kept.example/"), activate: false)
        browser.pin(kept)
        let loose = browser.newTab(url: URL(string: "https://loose.example/"), activate: false)

        if moveOut {
            browser.moveOut(children)
            #expect(browser.sidebarItems == [
                .folder(folder.id), .tab(bookmarked.id), .tab(kept.id),
                .tab(first.id), .tab(last.id), .tab(loose.id),
            ])
            #expect(browser.keptRunAtTop() == [.folder(folder.id), .tab(bookmarked.id), .tab(kept.id)])
        } else {
            browser.deleteFolder(folder)
            #expect(browser.sidebarItems == [
                .tab(bookmarked.id), .tab(kept.id), .tab(first.id), .tab(last.id), .tab(loose.id),
            ])
            #expect(browser.keptRunAtTop() == [.tab(bookmarked.id), .tab(kept.id)])
        }
        #expect(bookmarked.pinnedURL?.absoluteString == "https://bookmarked.example/saved")
        #expect(bookmarked.pinnedTitle == "Saved")
        #expect(first.pinnedURL == nil && last.pinnedURL == nil)
        #expect(kept.pinnedURL?.absoluteString == "https://kept.example/")
    }
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
