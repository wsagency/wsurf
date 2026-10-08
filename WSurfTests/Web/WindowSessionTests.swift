// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import GRDB
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct WindowSessionTests {
    private func reopen(_ model: BrowserModel) -> BrowserModel {
        let restored = BrowserModel(windowID: model.windowID, database: model.database)
        restored.restoreSession()
        return restored
    }

    @Test func anUntouchedProfileHasNoWindowToRestore() {
        #expect(BrowserModel.savedWindows(in: .temporary(), includeClosed: true).isEmpty)
    }

    @Test func windowsSaveTheirOwnTabsFoldersAndSplits() throws {
        let database = AppDatabase.temporary()
        let first = BrowserModel(windowID: UUID(), database: database)
        let second = BrowserModel(windowID: UUID(), database: database)
        let left = first.newTab()
        let right = first.newTab()
        let folder = first.createFolder(named: "Work", containing: [left, right])
        first.split(left, with: right, axis: .sideBySide)
        let other = second.newTab()
        _ = second.createFolder(named: "Personal", containing: [other])
        first.saveBlocking()
        second.saveBlocking()
        first.saveBlocking()

        let restoredFirst = reopen(first)
        let restoredSecond = reopen(second)
        #expect(restoredFirst.tabs.map(\.id) == first.tabs.map(\.id))
        #expect(restoredFirst.folders.first?.name == folder.name)
        #expect(restoredFirst.activeSplit?.tabs == [left.id, right.id])
        #expect(restoredSecond.tabs.map(\.id) == [other.id])
        #expect(restoredSecond.folders.first?.name == "Personal")
        #expect(Set(BrowserModel.savedWindows(in: database).map(\.id)) == [first.windowID, second.windowID])
    }

    @Test func anOlderQueuedWriteCannotReopenAClosedWindow() async {
        let database = AppDatabase.temporary()
        let model = BrowserModel(windowID: UUID(), database: database)
        let tab = model.newTab()
        model.saveNow()
        model.markSessionClosed()
        await model.saveChain?.value

        #expect(BrowserModel.savedWindows(in: database).isEmpty)
        #expect(BrowserModel.savedWindows(in: database, includeClosed: true).first?.closedAt != nil)
        let restored = reopen(model)
        #expect(restored.activeTab?.id == tab.id)
        #expect(BrowserModel.savedWindows(in: database).first?.id == model.windowID)
    }

    @Test func anOlderQueuedWriteCannotUndoTheFinalSnapshot() async {
        let database = AppDatabase.temporary()
        let model = BrowserModel(windowID: UUID(), database: database)
        _ = model.newTab()
        model.saveNow()
        _ = model.newTab()
        model.saveBlocking()
        await model.saveChain?.value
        #expect(reopen(model).tabs.count == 2)
    }

    @Test func movingATabPreservesItsPageAndChangesTheOwningCallbacks() async {
        let database = AppDatabase.temporary()
        let source = BrowserModel(windowID: UUID(), database: database)
        let destination = BrowserModel(windowID: UUID(), database: database)
        let tab = source.newTab()
        let view = tab.page
        _ = source.newTab()
        var transferred = false
        var closed = false
        source.onTabClosed = { _ in closed = true }
        destination.onTabTransferredIn = { moved, oldOwner, oldIndex in
            transferred = moved === tab && oldOwner === source && oldIndex == 1
        }
        source.saveNow()
        destination.saveNow()

        #expect(destination.adoptTab(tab, from: source))
        #expect(destination.activeTab === tab)
        #expect(destination.activeTab?.page === view)
        #expect(!tab.isClosed)
        #expect(transferred)
        #expect(!closed)
        await destination.saveChain?.value
        #expect(reopen(source).tabs.count == 1)
        #expect(reopen(destination).tabs.map(\.id) == [tab.id])

        tab.onCloseRequested?()
        #expect(destination.tabs.isEmpty)
        #expect(source.tabs.count == 1)
        #expect(!closed)
    }

    @Test func closingTheDestinationBeforeOldQueuedSavesFinishKeepsTheMovedTab() async {
        let database = AppDatabase.temporary()
        let source = BrowserModel(windowID: UUID(), database: database)
        let destination = BrowserModel(windowID: UUID(), database: database)
        let tab = source.newTab()
        source.saveNow()
        destination.saveNow()
        #expect(destination.adoptTab(tab, from: source))
        destination.markSessionClosed()
        await source.saveChain?.value
        await destination.saveChain?.value

        #expect(reopen(source).tabs.isEmpty)
        #expect(reopen(destination).tabs.map(\.id) == [tab.id])
    }

    @Test func aStaleCloseRequestCannotCloseATabTransferredToAnotherWindow() {
        let database = AppDatabase.temporary()
        let source = BrowserModel(windowID: UUID(), database: database)
        let destination = BrowserModel(windowID: UUID(), database: database)
        let tab = source.newTab()
        #expect(destination.adoptTab(tab, from: source))

        source.close(tab)

        #expect(destination.activeTab === tab)
        #expect(!tab.isClosed)
        #expect(source.closedTabs.isEmpty)
        #expect(!source.hasPendingSave)
        #expect(reopen(destination).tabs.map(\.id) == [tab.id])
    }

    @Test func movingATabRequiresOpenSourceAndDestinationSessions() {
        let database = AppDatabase.temporary()
        let source = BrowserModel(windowID: UUID(), database: database)
        let destination = BrowserModel(windowID: UUID(), database: database)
        let sourceTab = source.newTab()
        let destinationTab = destination.newTab()
        destination.markSessionClosed()

        #expect(!destination.adoptTab(sourceTab, from: source))
        #expect(!source.adoptTab(destinationTab, from: destination))
        #expect(source.activeTab === sourceTab)
        #expect(destination.activeTab === destinationTab)
        #expect(!sourceTab.isClosed)
        #expect(!destinationTab.isClosed)
        #expect(reopen(destination).tabs.map(\.id) == [destinationTab.id])
    }

    @Test func movingATabRequiresTheSameProfileDatabase() {
        let source = BrowserModel(windowID: UUID(), database: .temporary())
        let destination = BrowserModel(windowID: UUID(), database: .temporary())
        let tab = source.newTab()
        #expect(!destination.adoptTab(tab, from: source))
        #expect(source.tabs.first === tab)
        #expect(destination.tabs.isEmpty)
    }

    @Test func aQueuedSaveCannotRestoreTheOldWindowIDAfterRemapping() async {
        let database = AppDatabase.temporary()
        let original = BrowserModel(windowID: UUID(), database: database)
        let tab = original.newTab()
        original.saveNow()
        original.markSessionClosed()
        let renamedID = UUID()
        #expect(BrowserModel.remapSavedWindow(in: database, from: original.windowID, to: renamedID))
        await original.saveChain?.value

        #expect(BrowserModel.savedWindows(in: database).isEmpty)
        #expect(BrowserModel.savedWindows(in: database, includeClosed: true).map(\.id) == [renamedID])
        let restored = BrowserModel(windowID: renamedID, database: database)
        restored.restoreSession()
        #expect(restored.tabs.map(\.id) == [tab.id])

        // The original native window may later switch back to this profile with its same ID.
        let reused = BrowserModel(windowID: original.windowID, database: database)
        let newTab = reused.newTab()
        reused.saveBlocking()
        #expect(reopen(reused).tabs.map(\.id) == [newTab.id])
        #expect(reopen(restored).tabs.map(\.id) == [tab.id])
    }

    @Test func remappingRequiresAnExistingSourceAndAnUnusedDestination() {
        let database = AppDatabase.temporary()
        let original = BrowserModel(windowID: UUID(), database: database)
        let other = BrowserModel(windowID: UUID(), database: database)
        let originalTab = original.newTab()
        let otherTab = other.newTab()
        original.saveBlocking()
        other.saveBlocking()

        #expect(!BrowserModel.remapSavedWindow(in: database, from: UUID(), to: UUID()))
        #expect(!BrowserModel.remapSavedWindow(in: database, from: original.windowID, to: other.windowID))
        #expect(reopen(original).tabs.map(\.id) == [originalTab.id])
        #expect(reopen(other).tabs.map(\.id) == [otherTab.id])
        let newID = UUID()
        #expect(BrowserModel.remapSavedWindow(in: database, from: original.windowID, to: newID))
        #expect(!BrowserModel.remapSavedWindow(in: database, from: other.windowID, to: original.windowID))
        #expect(reopen(other).tabs.map(\.id) == [otherTab.id])
        #expect(Set(BrowserModel.savedWindows(in: database).map(\.id)) == [newID, other.windowID])
    }

    @Test func upgradingAnOldSessionKeepsItsTabsInTheFirstWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WindowMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WSurf.sqlite")
        let seed = DeployedSessionSeed()
        let tabID = seed.tabID
        let rightID = seed.rightID
        let downloadsTabID = seed.downloadsTabID
        let backgroundID = seed.backgroundID
        let backgroundState = seed.backgroundState
        // These are the deployed v1/v2 migrations, not a subset of their DDL
        // and not a database that has already passed through the new schema.
        let old = try DeployedWindowSessionFixture.make(at: url)
        try seed.insert(into: old)
        let columns = try Self.deployedColumns(in: old)
        let before = try old.read { try Self.rows(in: $0, columns: columns) }
        let unrelatedSchemaSQL = """
            SELECT type, name, tbl_name, sql FROM sqlite_master
            WHERE tbl_name NOT LIKE 'session%' AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """
        let unrelatedSchema = try old.read { try Row.fetchAll($0, sql: unrelatedSchemaSQL) }
        try old.close()

        // Deployed downloads live beside SQLite, in StoredDownload's JSON format.
        let downloadID = UUID()
        let downloadFile = directory.appendingPathComponent("report.txt")
        let downloadBytes = Data("synthetic downloaded report".utf8)
        try downloadBytes.write(to: downloadFile)
        let downloadsFile = directory.appendingPathComponent("Downloads.json")
        let downloadsJSON = Data("""
            [{"id":"\(downloadID)","filename":"report.txt","source":"downloads.example",
              "sourceOrigin":"https://downloads.example","sourceTabID":"\(tabID)",
              "destination":"\(downloadFile.absoluteString)","bytesReceived":27,"bytesExpected":27,
              "outcome":"finished","started":12345}]
            """.utf8)
        try downloadsJSON.write(to: downloadsFile)

        let database = AppDatabase(at: url)
        try #require(!database.isEphemeral)
        let after = try database.writer.read { db in
            #expect(try Row.fetchAll(db, sql: unrelatedSchemaSQL) == unrelatedSchema)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(Set(migrations).isSuperset(of: ["v1", "v2-folder-pinning"]))
            #expect(try String.fetchAll(db, sql: """
                SELECT url FROM historyPage_ft WHERE historyPage_ft MATCH 'sentinel'
                """) == ["https://history.example/"])
            for table in ["sessionTab", "sessionFolder", "sessionItem", "sessionSplitTree", "sessionSplitPane"] {
                #expect(try UUID.fetchAll(db, sql: "SELECT DISTINCT windowID FROM \(table)") == [BrowserModel.legacyWindowID])
            }
            #expect(try Int.fetchOne(db, sql: "SELECT revision FROM sessionWindow") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessionWindow WHERE closedAt IS NULL AND lastActiveAt IS NOT NULL") == 1)
            return try Self.rows(in: db, columns: columns)
        }
        for (table, rows) in before {
            #expect(after[table] == rows, "Migration changed deployed \(table) data")
        }
        let metadata = try database.writer.read {
            try Row.fetchAll($0, sql: "SELECT lastActiveAt, closedAt, revision FROM sessionWindow")
        }
        #expect(BrowserModel.savedWindows(in: database).map(\.id) == [BrowserModel.legacyWindowID])
        let migratedID = UUID()
        #expect(BrowserModel.remapSavedWindow(in: database, from: BrowserModel.legacyWindowID, to: migratedID))
        #expect(BrowserModel.savedWindows(in: database).map(\.id) == [migratedID])
        try database.writer.read { db throws in
            #expect(try Self.rows(in: db, columns: columns) == before)
            #expect(try Row.fetchAll(db, sql: "SELECT lastActiveAt, closedAt, revision FROM sessionWindow") == metadata)
            for table in ["sessionTab", "sessionFolder", "sessionItem", "sessionSplitTree", "sessionSplitPane"] {
                #expect(try UUID.fetchAll(db, sql: "SELECT DISTINCT windowID FROM \(table)") == [migratedID])
            }
        }
        let model = BrowserModel(windowID: migratedID, database: database)
        model.restoreSession()
        #expect(model.tabs.map(\.id) == [tabID, rightID, downloadsTabID, backgroundID])
        #expect(model.activeTabID == tabID)
        let favorite = try #require(model.tabs.first { $0.id == tabID })
        #expect(favorite.isFavorite)
        #expect(favorite.customTitle == "Favorite alias")
        #expect(favorite.pinnedURL?.absoluteString == "https://favorite.example/")
        #expect(favorite.pinnedTitle == "Pinned favorite")
        let background = try #require(model.tabs.first { $0.id == backgroundID })
        #expect(background.isDeferred)
        #expect(background.sessionState == backgroundState)
        #expect(model.tabs.first { $0.id == downloadsTabID }?.internalPage == .downloads)
        let outer = try #require(model.folders.first { $0.name == "Outer" })
        let inner = try #require(model.folders.first { $0.name == "Inner" })
        let empty = try #require(model.folders.first { $0.name == "Empty" })
        #expect(model.folders.count == 3)
        #expect(outer.isPinned && outer.isExpanded && outer.color == .teal)
        #expect(!inner.isPinned && !inner.isExpanded && inner.color == .blue)
        #expect(empty.isPinned && !empty.isExpanded && empty.color == .purple)
        #expect(model.folder(containing: inner) === outer)
        #expect(model.folder(containing: empty) === outer)
        #expect(model.sidebarTree.rows(in: inner.id) == [.tab(tabID), .tab(rightID)])
        #expect(model.allTabs(in: empty).isEmpty)
        #expect(model.activeSplit?.tabs == [tabID, rightID])
        #expect(model.activeSplit?.root.axis == .sideBySide)
        #expect(model.activeSplit?.root.children.map(\.share) == [0.3, 0.7])
        let additional = BrowserModel(windowID: UUID(), database: database)
        additional.restoreSession()
        #expect(additional.tabs.isEmpty)
        #expect(additional.folders.isEmpty)
        #expect(additional.splits.isEmpty)
        #expect(try Data(contentsOf: downloadsFile) == downloadsJSON)
        #expect(try Data(contentsOf: downloadFile) == downloadBytes)
        let downloads = DownloadManager(file: downloadsFile)
        #expect(downloads.items.count == 1)
        let download = try #require(downloads.items.first)
        #expect(download.id == downloadID)
        #expect(download.sourceTabID == tabID)
        #expect(download.filename == "report.txt")
        #expect(download.sourceOrigin == "https://downloads.example")
        #expect(download.destination == downloadFile)
        #expect(download.bytesReceived == 27 && download.bytesExpected == 27)
        #expect(download.state == .finished)
        #expect(download.started == Date(timeIntervalSinceReferenceDate: 12345))
    }

    @Test func aFailedWindowRemapRollsBackBothOwnersAndTheirData() throws {
        let database = AppDatabase.temporary()
        let original = BrowserModel(windowID: UUID(), database: database)
        let other = BrowserModel(windowID: UUID(), database: database)
        let left = original.newTab()
        let right = original.newTab()
        _ = original.createFolder(named: "Original", containing: [left, right])
        original.split(left, with: right, axis: .sideBySide)
        let otherTab = other.newTab()
        _ = other.createFolder(named: "Other", containing: [otherTab])
        original.saveBlocking()
        other.saveBlocking()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessionSplitPane
                    (tabID, windowID, splitID, rowIndex, columnIndex, rowFraction, columnFraction)
                VALUES (?, ?, ?, 0, 0, 0.4, 0.3), (?, ?, ?, 0, 1, 0.4, 0.3);
                """, arguments: [
                    left.id, original.windowID, left.id,
                    right.id, original.windowID, left.id,
                ])
        }
        let tables = [
            "sessionWindow", "sessionWindowRetirement", "sessionTab", "sessionFolder",
            "sessionItem", "sessionSplitTree", "sessionSplitPane",
        ]
        let columns = try database.writer.read { db in
            try Dictionary(uniqueKeysWithValues: tables.map { ($0, try db.columns(in: $0).map(\.name)) })
        }
        let before = try database.writer.read { try Self.rows(in: $0, columns: columns) }
        try database.writer.write { db in
            // Remapping has already retired the old ID and rewritten every child
            // table when this final update fails. All of it must roll back.
            try db.execute(sql: """
                CREATE TRIGGER reject_window_remap BEFORE UPDATE OF id ON sessionWindow
                BEGIN SELECT RAISE(ABORT, 'injected final window update failure'); END
                """)
        }
        let destinationID = UUID()
        #expect(!BrowserModel.remapSavedWindow(in: database, from: original.windowID, to: destinationID))
        let after = try database.writer.read { try Self.rows(in: $0, columns: columns) }
        for table in tables {
            #expect(after[table] == before[table], "Failed remap partially changed \(table)")
        }
        #expect(Set(BrowserModel.savedWindows(in: database).map(\.id)) == [original.windowID, other.windowID])
        let restoredOriginal = reopen(original)
        #expect(restoredOriginal.tabs.map(\.id) == [left.id, right.id])
        #expect(restoredOriginal.folders.first?.name == "Original")
        #expect(restoredOriginal.activeSplit?.tabs == [left.id, right.id])
        let restoredOther = reopen(other)
        #expect(restoredOther.tabs.map(\.id) == [otherTab.id])
        #expect(restoredOther.folders.first?.name == "Other")
        try database.writer.write { try $0.execute(sql: "DROP TRIGGER reject_window_remap") }
        #expect(BrowserModel.remapSavedWindow(in: database, from: original.windowID, to: destinationID))
        #expect(Set(BrowserModel.savedWindows(in: database).map(\.id)) == [destinationID, other.windowID])
    }

    private nonisolated static func deployedColumns(in old: DatabaseQueue) throws -> [String: [String]] {
        try old.read { db in
            #expect(try !db.tableExists("sessionWindow"))
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
                == ["v1", "v2-folder-pinning"])
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                    AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'historyPage_ft_%'
                    AND name != 'grdb_migrations'
                """)
            return try Dictionary(uniqueKeysWithValues: tables.map { table in
                (table, try db.columns(in: table).map(\.name))
            })
        }
    }

    private nonisolated static func rows(in db: Database, columns: [String: [String]]) throws -> [String: [Row]] {
        try Dictionary(uniqueKeysWithValues: columns.map { table, names in
            let selection = names.map { "\"\($0)\"" }.joined(separator: ", ")
            let ordering = names.indices.map { String($0 + 1) }.joined(separator: ", ")
            return (table, try Row.fetchAll(db, sql: "SELECT \(selection) FROM \"\(table)\" ORDER BY \(ordering)"))
        })
    }
}

private nonisolated struct DeployedSessionSeed {
    let tabID = UUID()
    let rightID = UUID()
    let downloadsTabID = UUID()
    let backgroundID = UUID()
    let outerID = UUID()
    let innerID = UUID()
    let emptyID = UUID()
    let traceID = UUID()
    let backgroundState = Data("deployed-back-forward-state".utf8)

    func insert(into old: DatabaseQueue) throws {
        let tree = """
            {"content":{"group":{"axis":"sideBySide","children":[\
            {"content":{"page":{"_0":"\(tabID)"}},"share":0.3},\
            {"content":{"page":{"_0":"\(rightID)"}},"share":0.7}]}},"share":1}
            """
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO sessionTab
                    (id, title, customTitle, url, state, pinnedURL, pinnedTitle, internalPage, isActive, isFavorite)
                VALUES
                    (?, 'Saved', 'Favorite alias', 'about:blank', NULL, 'https://favorite.example/', 'Pinned favorite', NULL, 1, 1),
                    (?, 'Right', NULL, 'about:blank', NULL, NULL, NULL, NULL, 0, 0),
                    (?, 'Downloads', NULL, '', NULL, NULL, NULL, 'downloads', 0, 0),
                    (?, 'Sleeping', 'Background alias', 'about:blank', ?, NULL, NULL, NULL, 0, 0);
                """, arguments: [tabID, rightID, downloadsTabID, backgroundID, backgroundState])
            try db.execute(sql: """
                INSERT INTO sessionFolder (id, position, name, color, isExpanded, isPinned) VALUES
                    (?, 0, 'Outer', 'teal', 1, 1),
                    (?, 1, 'Inner', 'blue', 0, 0),
                    (?, 2, 'Empty', 'purple', 0, 1);
                """, arguments: [outerID, innerID, emptyID])
            try db.execute(sql: """
                INSERT INTO sessionItem (position, tabID, folderID, parentID) VALUES
                    (0, NULL, ?, NULL), (1, NULL, ?, ?),
                    (2, ?, NULL, ?), (3, ?, NULL, ?), (4, NULL, ?, ?),
                    (5, ?, NULL, NULL), (6, ?, NULL, NULL);
                """, arguments: [
                    outerID, innerID, outerID, tabID, innerID, rightID, innerID,
                    emptyID, outerID, downloadsTabID, backgroundID,
                ])
            try db.execute(
                sql: "INSERT INTO sessionSplitTree (id, position, tree) VALUES (?, 0, ?)",
                arguments: [tabID, tree]
            )
            try db.execute(sql: """
                INSERT INTO sessionSplitPane
                    (tabID, splitID, rowIndex, columnIndex, rowFraction, columnFraction) VALUES
                    (?, ?, 0, 0, 0.4, 0.3), (?, ?, 0, 1, 0.4, 0.3);
                """, arguments: [tabID, tabID, rightID, tabID])
            try db.execute(sql: """
                INSERT INTO historyPage (url, title, visitCount, lastVisit)
                    VALUES ('https://history.example/', 'Migration sentinel', 7, 123456.5);
                INSERT INTO historyVisit (id, url, visitedAt, transition, fromVisit) VALUES
                    (1, 'https://history.example/', 123455, 'typed', NULL),
                    (2, 'https://history.example/', 123456.5, 'link', 1);
                """)
            try db.execute(sql: """
                INSERT INTO agentTrace
                    (id, tabID, prompt, startedAt, response, state, finishedAt, providerID, stopReason, diagnostics)
                VALUES (?, ?, 'Keep my conversation', '2026-10-01 10:00:00',
                    'Saved answer', 'completed', '2026-10-01 10:00:01', 'fixture-provider', 'complete', X'010203');
                INSERT INTO agentAttachments (traceID, payload, textOnly) VALUES (?, X'040506', 1);
                INSERT INTO agentConversationMemory (traceID, payload) VALUES (?, X'070809');
                INSERT INTO agentStep
                    (id, traceID, position, kind, title, toolName, startedAt, detail, links, state)
                VALUES (?, ?, 0, 'tool', 'Saved step', 'readPage', '2026-10-01 10:00:00',
                    'Saved detail', '[]', 'completed');
                INSERT INTO agentUsage
                    (tabID, requestCount, inputTokens, cachedTokens, outputTokens, estimatedContextTokens)
                VALUES (?, 3, 120, 40, 25, 145);
                """, arguments: [traceID, tabID, traceID, traceID, UUID(), traceID, tabID])
        }
    }
}
