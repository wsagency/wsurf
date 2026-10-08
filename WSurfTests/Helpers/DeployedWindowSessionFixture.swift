// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import GRDB

/// Frozen deployed migrations from WSurf/Support/AppDatabase.swift at
/// 4d33cb93ed22a92ffa2db0d5fc8109b5e4a78557. The migration/schema methods below
/// are verbatim: never replace them with the current AppDatabase initializer.
/// Generate only a fresh scratch database; no installed profile is read.
enum DeployedWindowSessionFixture {
    static func make(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try migrator.migrate(queue)
        try queue.write { try defineSchema(in: $0) }
        return queue
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in try defineSchema(in: db) }
        migrator.registerMigration("v2-folder-pinning") { db in
            let hadPinnedColumn = try db.tableExists("sessionFolder")
                && db.columns(in: "sessionFolder").contains { $0.name == "isPinned" }
            try defineSchema(in: db)
            guard !hadPinnedColumn else { return }
            try db.execute(sql: """
                WITH RECURSIVE descendants(rootID, folderID) AS (
                    SELECT id, id FROM sessionFolder
                    UNION
                    SELECT d.rootID, i.folderID
                    FROM descendants d
                    JOIN sessionItem i ON i.parentID = d.folderID
                    WHERE i.folderID IS NOT NULL
                )
                UPDATE sessionFolder
                SET isPinned = 1
                WHERE id IN (
                    SELECT d.rootID
                    FROM descendants d
                    JOIN sessionItem i ON i.parentID = d.folderID
                    JOIN sessionTab t ON t.id = i.tabID
                    GROUP BY d.rootID
                    HAVING MAX(t.pinnedURL IS NULL) = 0
                )
                """)
        }
        return migrator
    }

    private nonisolated static func defineSessionFolders(in db: Database) throws {
        try db.create(table: "sessionFolder", options: .ifNotExists) {  t in
            t.primaryKey("id", .blob)
            t.column("position", .integer).notNull()
            t.column("name", .text).notNull()
            t.column("color", .text).notNull()
            t.column("isExpanded", .boolean).notNull()
            t.column("isPinned", .boolean).notNull().defaults(to: false)
        }

        if try !db.columns(in: "sessionFolder").contains(where: { $0.name == "isPinned" }) {
            try db.alter(table: "sessionFolder") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
        }
    }

    private nonisolated static func defineSchema(in db: Database) throws {
        try db.create(table: "historyPage", options: .ifNotExists) {  t in
            t.primaryKey("url", .text)
            t.column("title", .text).notNull()
            t.column("visitCount", .integer).notNull().defaults(to: 1)
            t.column("lastVisit", .double).notNull().indexed()
        }

        try db.create(virtualTable: "historyPage_ft", options: .ifNotExists, using: FTS5()) { t in
            t.synchronize(withTable: "historyPage")
            t.tokenizer = .unicode61()
            t.prefixes = [2, 3]
            t.column("url")
            t.column("title")
        }

        try defineSessionSchema(in: db)

        try db.create(table: "agentTrace", options: .ifNotExists) {  t in
            t.primaryKey("id", .blob)
            t.column("tabID", .blob).notNull().indexed()
            t.column("prompt", .text).notNull()
            t.column("startedAt", .datetime).notNull()
            t.column("response", .text).notNull()
            t.column("state", .text).notNull()
            t.column("finishedAt", .datetime)
            t.column("providerID", .text)
        }

        if try !db.columns(in: "agentTrace").contains(where: { $0.name == "providerID" }) {
            try db.alter(table: "agentTrace") { t in
                t.add(column: "providerID", .text)
            }
        }

        try db.create(table: "agentAttachments", options: .ifNotExists) { t in
            t.primaryKey("traceID", .blob).references("agentTrace", onDelete: .cascade)
            t.column("payload", .blob).notNull()
            t.column("textOnly", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "agentStep", options: .ifNotExists) {  t in
            t.primaryKey("id", .blob)
            t.column("traceID", .blob)
                .notNull()
                .indexed()
                .references("agentTrace", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("title", .text).notNull()
            t.column("toolName", .text)
            t.column("startedAt", .datetime).notNull()
            t.column("detail", .text)
            t.column("links", .text).notNull()
            t.column("state", .text).notNull()
        }

        let traceColumns = try db.columns(in: "agentTrace").map(\.name)
        if !traceColumns.contains("stopReason") {
            try db.alter(table: "agentTrace") { t in
                t.add(column: "stopReason", .text)
                t.add(column: "diagnostics", .blob)
            }
        }
        try db.create(table: "agentConversationMemory", options: .ifNotExists) { t in
            t.primaryKey("traceID", .blob).references("agentTrace", onDelete: .cascade)
            t.column("payload", .blob).notNull()
        }

        try db.create(table: "agentUsage", options: .ifNotExists) {  t in
            t.primaryKey("tabID", .blob)
            t.column("requestCount", .integer).notNull()
            t.column("inputTokens", .integer).notNull()
            t.column("cachedTokens", .integer).notNull()
            t.column("outputTokens", .integer).notNull()
            t.column("estimatedContextTokens", .integer).notNull()
        }

        try db.create(table: "historyVisit", options: .ifNotExists) {  t in
            t.autoIncrementedPrimaryKey("id")
            t.column("url", .text)
                .notNull()
                .indexed()
                .references("historyPage", onDelete: .cascade)
            t.column("visitedAt", .double).notNull().indexed()
            t.column("transition", .text).notNull()
            t.column("fromVisit", .integer).references("historyVisit", onDelete: .setNull)
        }

        try db.create(table: "sessionSplitTree", options: .ifNotExists) { t in
            t.primaryKey("id", .blob)
            t.column("position", .integer).notNull()
            t.column("tree", .text).notNull()
        }

        try db.create(table: "sessionSplitPane", options: .ifNotExists) {  t in
            t.primaryKey("tabID", .blob)
                .references("sessionTab", onDelete: .cascade)
            t.column("splitID", .blob).notNull().indexed()
            t.column("rowIndex", .integer).notNull()
            t.column("columnIndex", .integer).notNull()
            t.column("rowFraction", .double).notNull()
            t.column("columnFraction", .double).notNull()
        }
    }

    private nonisolated static func defineSessionSchema(in db: Database) throws {
        try defineSessionFolders(in: db)
        try db.create(table: "sessionTab", options: .ifNotExists) { t in
            t.primaryKey("id", .blob)
            t.column("title", .text).notNull()
            t.column("customTitle", .text)
            t.column("url", .text).notNull()
            t.column("state", .blob)
            t.column("pinnedURL", .text)
            t.column("pinnedTitle", .text)
            t.column("internalPage", .text)
            t.column("isActive", .boolean).notNull().defaults(to: false)
            t.column("isFavorite", .boolean).notNull().defaults(to: false)
        }

        if try !db.columns(in: "sessionTab").contains(where: { $0.name == "customTitle" }) {
            try db.alter(table: "sessionTab") { t in
                t.add(column: "customTitle", .text)
            }
        }

        if try !db.columns(in: "sessionTab").contains(where: { $0.name == "isFavorite" }) {
            try db.alter(table: "sessionTab") { t in
                t.add(column: "isFavorite", .boolean).notNull().defaults(to: false)
            }
        }

        try db.create(table: "sessionItem", options: .ifNotExists) { t in
            t.primaryKey("position", .integer)
            t.column("tabID", .blob).references("sessionTab", onDelete: .cascade)
            t.column("folderID", .blob).references("sessionFolder", onDelete: .cascade)
            t.column("parentID", .blob).references("sessionFolder", onDelete: .cascade)
        }
    }
}
