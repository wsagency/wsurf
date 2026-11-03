// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import Testing

@testable import WSurf

@MainActor
struct FolderSizeTests {
    @Test func aStoredFactorThatIsMissingOrUnknownReadsAsNormal() {
        #expect(TabFolderSize.stored(nil) == .normal)
        #expect(TabFolderSize.stored(1) == .normal)
        #expect(TabFolderSize.stored(1.7) == .normal)
        #expect(TabFolderSize.allCases.map(\.factor) == [1, 1.5, 2, 2.5])
        for size in TabFolderSize.allCases {
            #expect(TabFolderSize.stored(size.storedFactor) == size)
        }
        #expect(TabFolderSize.normal.storedFactor == nil)
    }

    @Test func theSizeMenuChecksTheCurrentSizeAndEachChoiceIsOneUndoStep() throws {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        let menu = FolderContextMenu.sizeMenu(for: folder, browser: browser)
        #expect(menu.items.count == TabFolderSize.allCases.count)
        #expect(menu.items.map(\.state) == [.on, .off, .off, .off])
        menu.performActionForItem(at: 0)
        #expect(!browser.sidebarUndoManager.canUndo, "choosing the size a folder has is not a step")

        menu.performActionForItem(at: 3)
        #expect(folder.size == .largest)
        #expect(FolderContextMenu.sizeMenu(for: folder, browser: browser).items.map(\.state) == [.off, .off, .off, .on])
        menu.performActionForItem(at: 3)
        menu.performActionForItem(at: 1)
        #expect(folder.size == .large)

        browser.sidebarUndoManager.undo()
        #expect(folder.size == .largest)
        browser.sidebarUndoManager.undo()
        #expect(folder.size == .normal)
        #expect(!browser.sidebarUndoManager.canUndo)
        browser.sidebarUndoManager.redo()
        #expect(folder.size == .largest)
    }

    @Test func aFolderSizeSurvivesARestartAndRowsSavedWithoutOneReadNormal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderSize-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = AppDatabase(at: url)
        let browser = BrowserModel(database: database)
        let pinned = browser.createFolder(named: "Pinned")
        browser.pin(pinned)
        let loose = browser.createFolder(named: "Loose")
        browser.setFolderSize(.larger, for: pinned)
        browser.setFolderSize(.largest, for: loose)
        browser.saveBlocking()

        let restored = BrowserModel(database: AppDatabase(at: url))
        restored.restoreSession()
        #expect(restored.folder(id: pinned.id)?.size == .larger, "a pinned folder keeps it with the profile's pins")
        #expect(restored.folder(id: loose.id)?.size == .largest, "any other folder keeps it with its window")

        try database.writer.write { db in
            try db.execute(sql: "ALTER TABLE sessionFolder DROP COLUMN sizeFactor")
            try db.execute(sql: "ALTER TABLE profilePin DROP COLUMN sizeFactor")
        }
        let older = BrowserModel(database: AppDatabase(at: url))
        older.restoreSession()
        #expect(older.folders.count == 2)
        #expect(older.folders.allSatisfy { $0.size == .normal })
    }

    @Test func aLargerFolderRowIsTallerAndAGrownRowKeepsItsIcon() {
        let settings = BrowserSettings.application
        let normal = SidebarMetrics.rowHeight(settings: settings)
        #expect(SidebarMetrics.rowHeight(settings: settings, scale: 1) == normal)
        var last = normal
        for size in TabFolderSize.allCases.dropFirst() {
            let height = SidebarMetrics.rowHeight(settings: settings, scale: size.factor)
            #expect(height > last, "\(size) is taller than the size before it")
            #expect(height >= SidebarMetrics.rowIconSize * size.factor + 8, "\(size) holds its icon with 4 pt around")
            last = height
        }
    }
}
