// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB

@testable import WSurf

/// The database as the signed 0.1.10 build left it: the migrations v1 to v3 and the `defineSchema` that build ran on every
/// open, verbatim from WSurf/Support/AppDatabase.swift at c1db97b8022c3148df2bffbdb241e8572ea4e8d7. Never replace them with the
/// current `AppDatabase`: the point is a database the current code did not make. (`ProfilePinMigration` is the app's own, as
/// it was called then, and finds no row to move.) Generate only a fresh scratch database; no installed profile is read.
enum Deployed0110DatabaseFixture {
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
        // The pins and Favorites of every window, open or closed, become the profile's, once and in one transaction.
        migrator.registerMigration("v3-profile-pins") { db in
            try defineSchema(in: db)
            try ProfilePinMigration.run(in: db)
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
        // The size factor of the folder's own row. NULL (every row saved before sizes) is normal.
        if try !db.columns(in: "sessionFolder").contains(where: { $0.name == "sizeFactor" }) {
            try db.alter(table: "sessionFolder") { t in
                t.add(column: "sizeFactor", .double)
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
        if !traceColumns.contains("openedTabIDs") {
            try db.alter(table: "agentTrace") { t in
                t.add(column: "openedTabIDs", .text)
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

        try defineWindowSessions(in: db)
        try defineProfilePins(in: db)
        try defineTabArchive(in: db)
        try defineAssistantFacts(in: db)
    }

    /// Notes the assistant keeps about the person, one per subject. History-class data in the profile's database; not
    /// `agentConversationMemory`, which holds one conversation's payload.
    private nonisolated static func defineAssistantFacts(in db: Database) throws {
        try db.create(table: "assistantFact", options: .ifNotExists) { t in
            t.primaryKey("id", .blob)
            t.column("subject", .text).notNull().unique()
            t.column("value", .text).notNull()
            t.column("source", .text).notNull()
            t.column("savedAt", .datetime).notNull().indexed()
        }
    }

    /// Tabs closed for sitting unused. They are history-class data and live in the profile's database next to the
    /// history.
    private nonisolated static func defineTabArchive(in db: Database) throws {
        try db.create(table: "archivedTab", options: .ifNotExists) { t in
            t.primaryKey("id", .blob)
            t.column("title", .text).notNull()
            t.column("url", .text).notNull().indexed()
            t.column("archivedAt", .datetime).notNull().indexed()
        }
    }

    /// Pins, pinned folders and Favorites belong to the profile, not to a window. A window's tab and folder rows
    /// keep a `pinID` for the profile row they stand for.
    private nonisolated static func defineProfilePins(in db: Database) throws {
        try db.create(table: "profilePin", options: .ifNotExists) { t in
            t.primaryKey("id", .blob)
            t.column("parentID", .blob).references("profilePin", onDelete: .cascade)
            t.column("orderKey", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("url", .text).notNull().defaults(to: "")
            t.column("title", .text).notNull().defaults(to: "")
            t.column("customTitle", .text)
            t.column("pinnedURL", .text)
            t.column("pinnedTitle", .text)
            t.column("isFavorite", .boolean).notNull().defaults(to: false)
            t.column("color", .text)
            t.column("isExpanded", .boolean).notNull().defaults(to: true)
            t.column("isPinned", .boolean).notNull().defaults(to: false)
        }
        for table in ["sessionTab", "sessionFolder"] {
            guard try !db.columns(in: table).contains(where: { $0.name == "pinID" }) else { continue }
            try db.alter(table: table) { t in
                t.add(column: "pinID", .blob)
            }
        }
        if try !db.columns(in: "profilePin").contains(where: { $0.name == "sizeFactor" }) {
            try db.alter(table: "profilePin") { t in
                t.add(column: "sizeFactor", .double)
            }
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
            t.column("lastActiveAt", .datetime)
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

        // A NULL means no use was recorded: the tab reads as used when the window restores.
        if try !db.columns(in: "sessionTab").contains(where: { $0.name == "lastActiveAt" }) {
            try db.alter(table: "sessionTab") { t in
                t.add(column: "lastActiveAt", .datetime)
            }
        }

        // The space a window shows a row in. NULL (rows saved before spaces, pins) joins the space on screen.
        for table in ["sessionTab", "sessionFolder"] {
            guard try !db.columns(in: table).contains(where: { $0.name == "spaceID" }) else { continue }
            try db.alter(table: table) { t in
                t.add(column: "spaceID", .blob)
            }
        }

        try db.create(table: "sessionItem", options: .ifNotExists) { t in
            t.primaryKey("position", .integer)
            t.column("tabID", .blob).references("sessionTab", onDelete: .cascade)
            t.column("folderID", .blob).references("sessionFolder", onDelete: .cascade)
            t.column("parentID", .blob).references("sessionFolder", onDelete: .cascade)
        }
    }

    private nonisolated static func defineWindowSessions(in db: Database) throws {
        let legacyID = Data(repeating: 0, count: 16)
        try db.create(table: "sessionWindow", options: .ifNotExists) { t in
            t.primaryKey("id", .blob)
            t.column("lastActiveAt", .datetime).notNull()
            t.column("closedAt", .datetime)
            t.column("revision", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "sessionWindowRetirement", options: .ifNotExists) { t in
            t.primaryKey("id", .blob)
            t.column("revision", .integer).notNull()
        }
        for table in ["sessionTab", "sessionFolder", "sessionSplitTree", "sessionSplitPane"] {
            guard try !db.columns(in: table).contains(where: { $0.name == "windowID" }) else { continue }
            try db.alter(table: table) { t in
                t.add(column: "windowID", .blob).notNull().defaults(to: legacyID).indexed()
            }
        }
        if try !db.columns(in: "sessionItem").contains(where: { $0.name == "windowID" }) {
            try db.create(table: "sessionWindowItem") { t in
                t.column("windowID", .blob).notNull().defaults(to: legacyID)
                t.column("position", .integer).notNull()
                t.column("tabID", .blob).references("sessionTab", onDelete: .cascade)
                t.column("folderID", .blob).references("sessionFolder", onDelete: .cascade)
                t.column("parentID", .blob).references("sessionFolder", onDelete: .cascade)
                t.primaryKey(["windowID", "position"])
            }
            try db.execute(sql: """
                INSERT INTO sessionWindowItem (position, tabID, folderID, parentID)
                    SELECT position, tabID, folderID, parentID FROM sessionItem;
                DROP TABLE sessionItem;
                ALTER TABLE sessionWindowItem RENAME TO sessionItem;
                """)
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO sessionWindow (id, lastActiveAt, revision)
                SELECT windowID, ?, 0 FROM (
                    SELECT windowID FROM sessionTab
                    UNION SELECT windowID FROM sessionFolder
                )
            """, arguments: [Date()])
    }
}
