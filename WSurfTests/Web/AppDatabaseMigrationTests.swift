// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing

@testable import WSurf

/// What opening a profile's database does to databases from earlier builds. The schema is defined by migrations, not on
/// every open, so every database an earlier build can have left must reach the schema of a new one in one migration, with
/// its rows untouched. Every database here is made in the test's own directory; no installed profile is read.
@MainActor
struct AppDatabaseMigrationTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppDatabaseMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - A temporary database (a private window's)

    private static func schema(of database: AppDatabase) throws -> [String] {
        try database.writer.read {
            try String.fetchAll($0, sql: "SELECT type || ' ' || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY 1")
        }
    }

    /// Each temporary database copies the migrated template: the same schema, its own rows, and migrations recorded.
    @Test func eachTemporaryDatabaseIsACopyOfTheMigratedTemplate() throws {
        #expect(AppDatabase.hasMigratedTemplate)
        let first = AppDatabase.temporary()
        let second = AppDatabase.temporary()
        let schema = try Self.schema(of: first)
        #expect(schema.count > 10)
        #expect(try Self.schema(of: second) == schema)
        #expect(try first.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") } ?? 0 > 0)
        try first.writer.write { try $0.execute(sql: "CREATE TABLE onlyInFirst (id INTEGER)") }
        #expect(try Self.schema(of: second) == schema)
        #expect(try Self.schema(of: AppDatabase.temporary()) == schema)
        #expect(try first.writer.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") } == 1)
    }

    /// What the signed 0.1.10 build did not define, and every build since has.
    private static let columnsAddedSince010: [(table: String, name: String)] = [
        ("historyVisit", "trail"), ("sessionTab", "lastVisit"), ("sessionTab", "visitTrail"), ("sessionTab", "microTabID"),
        ("sessionWindow", "kind"), ("sessionFolder", "customColor"), ("sessionFolder", "symbol"), ("sessionFolder", "tintsIcons"),
        ("profilePin", "customColor"),
    ]

    private static let indexesOfV4 = [
        "historyVisit_fromVisit", "sessionItem_tabID", "sessionItem_folderID", "sessionItem_parentID", "profilePin_parentID",
    ]

    // MARK: - From the oldest build the owner still runs (0.1.10)

    @Test func aDatabaseFrom010KeepsEveryRowAndGainsTheNewSchema() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WSurf.sqlite")
        let old = try Deployed0110DatabaseFixture.make(at: url)
        let seeded = try old.write { try Self.seedRealisticProfile(in: $0) }
        let columns = try Self.columns(in: old)
        let before = try old.read { try Self.rows(in: $0, columns: columns) }
        try old.read { db throws in
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
                == ["v1", "v2-folder-pinning", "v3-profile-pins"])
            #expect(try !db.columns(in: "historyVisit").contains { $0.name == "trail" })
            #expect(try !db.columns(in: "sessionTab").contains { $0.name == "microTabID" })
            #expect(try !db.columns(in: "sessionFolder").contains { $0.name == "customColor" })
        }
        try old.close()

        let database = AppDatabase(at: url)
        try #require(!database.isEphemeral)
        let after = try database.writer.write { db throws in
            #expect(try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
                == ["v1", "v2-folder-pinning", "v3-profile-pins", "v4-indexes"])
            #expect(try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"])
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try Set(Self.indexNames(in: db)).isSuperset(of: Self.indexesOfV4))
            for column in Self.columnsAddedSince010 {
                #expect(try db.columns(in: column.table).contains { $0.name == column.name }, "\(column.table).\(column.name)")
            }
            // The index still answers for the title it was built from, and a check against the table it stands for passes.
            try db.execute(sql: "INSERT INTO historyPage_ft(historyPage_ft) VALUES('integrity-check')")
            #expect(try String.fetchAll(db, sql: """
                SELECT url FROM historyPage_ft WHERE historyPage_ft MATCH 'sentinel'
                """) == [seeded.sentinelURL])
            return try Self.rows(in: db, columns: columns)
        }
        for (table, rows) in before {
            #expect(after[table] == rows, "The upgrade changed the rows of \(table)")
        }
        #expect(before.values.reduce(0) { $0 + $1.count } > seeded.pages, "the fixture holds a real-looking profile")

        let store = HistoryStore(database: database)
        #expect(store.entries.count == seeded.pages)
        #expect(store.search("sentinel").map(\.url) == [seeded.sentinelURL])
        store.clear()
        try database.writer.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyPage") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisit") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyPage_ft_docsize") == 0)
        }
    }

    /// The guard on the rule in `AppDatabase.migrator`: a change to `defineSchema` reaches a database that earlier
    /// migrations recorded only through a migration of its own. This fails, naming the difference, until the change has one.
    @Test func anUpgradedDatabaseHasTheSchemaOfANewOne() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("Old.sqlite")
        try Deployed0110DatabaseFixture.make(at: oldURL).close()
        let upgraded = AppDatabase(at: oldURL)
        let fresh = AppDatabase(at: directory.appendingPathComponent("New.sqlite"))
        try #require(!upgraded.isEphemeral && !fresh.isEphemeral)

        let upgradedSchema = try upgraded.writer.read { try Self.schemaSummary(in: $0) }
        let freshSchema = try fresh.writer.read { try Self.schemaSummary(in: $0) }

        #expect(Set(upgradedSchema).subtracting(freshSchema).sorted() == [], "only in the upgraded database")
        #expect(Set(freshSchema).subtracting(upgradedSchema).sorted() == [], "only in a new one: add a migration")
    }

    // MARK: - From the build before this one (0.1.14)

    /// 0.1.14 defines the whole schema on every open and has no `v4-indexes`. Its database has the late columns already; the
    /// migration adds the indexes and the narrower trigger and touches nothing else.
    @Test func aDatabaseFrom0114KeepsEveryRowAndGainsTheIndexes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WSurf.sqlite")
        let created = AppDatabase(at: url)
        try created.writer.write { db in
            try Self.dropV4(in: db)
            _ = try Self.seedRealisticProfile(in: db)
        }
        try created.writer.close()
        let queue = try DatabaseQueue(path: url.path)
        let columns = try Self.columns(in: queue)
        let before = try queue.read { try Self.rows(in: $0, columns: columns) }
        try queue.read { db throws in
            #expect(try Self.indexNames(in: db).filter { Self.indexesOfV4.contains($0) }.isEmpty)
            #expect(try Self.triggerSQL(in: db).contains("AFTER UPDATE ON"))
        }
        try queue.close()

        let database = AppDatabase(at: url)
        try #require(!database.isEphemeral)
        let after = try database.writer.write { db throws in
            #expect(try Set(Self.indexNames(in: db)).isSuperset(of: Self.indexesOfV4))
            #expect(try Self.triggerSQL(in: db).contains("WHEN old.\"url\" IS NOT new.\"url\""))
            #expect(try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"])
            try db.execute(sql: "INSERT INTO historyPage_ft(historyPage_ft) VALUES('integrity-check')")
            return try Self.rows(in: db, columns: columns)
        }
        for (table, rows) in before {
            #expect(after[table] == rows, "The migration changed the rows of \(table)")
        }
    }

    /// Defining the schema rebuilds the full-text index from the pages, which cost 0.17 s for 50,000 pages at every open. A row
    /// that only that rebuild would remove is left alone by an open of a database whose schema has not changed.
    @Test func aDatabaseWhoseSchemaHasNotChangedIsNotDefinedAgain() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WSurf.sqlite")
        let first = AppDatabase(at: url)
        try first.writer.write { db in
            try db.execute(sql: "INSERT INTO historyPage_ft(rowid, url, title) VALUES (999999, 'phantom.example', 'phantom')")
        }
        try first.writer.close()

        let database = AppDatabase(at: url)

        try database.writer.read { db throws in
            #expect(try Int.fetchAll(db, sql: "SELECT rowid FROM historyPage_ft WHERE historyPage_ft MATCH 'phantom'") == [999999])
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == Int.fetchOne(db, sql: "PRAGMA schema_version"))
        }
    }

    /// Every open used to repair what went missing, because every open defined the schema. One that finds the schema changed
    /// since it was last defined still does, and defines it once.
    @Test func aDatabaseWhoseSchemaChangedBehindTheAppIsDefinedAgain() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WSurf.sqlite")
        let first = AppDatabase(at: url)
        try first.writer.write { db in
            try db.execute(sql: "ALTER TABLE sessionTab DROP COLUMN spaceID")
            try db.execute(sql: "DROP INDEX historyVisit_trail")
            try db.execute(sql: "DROP TABLE sessionSplitTree")
        }
        try first.writer.close()

        let database = AppDatabase(at: url)

        try database.writer.read { db throws in
            #expect(try db.columns(in: "sessionTab").contains { $0.name == "spaceID" })
            #expect(try Self.indexNames(in: db).contains("historyVisit_trail"))
            #expect(try db.tableExists("sessionSplitTree"))
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == Int.fetchOne(db, sql: "PRAGMA schema_version"))
        }
    }

    /// Every open until `v4-indexes` accepted a database that holds a row naming a parent that is gone. A migration that
    /// checked foreign keys over the whole database would refuse it, and the app would run on a temporary database.
    @Test func aStrayRowDoesNotKeepADatabaseFromOpening() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WSurf.sqlite")
        let created = AppDatabase(at: url)
        try created.writer.write { try Self.dropV4(in: $0) }
        try created.writer.close()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO sessionItem (position, tabID) VALUES (?, ?)",
                arguments: [7, UUID()]
            )
        }
        try queue.close()

        let database = AppDatabase(at: url)

        try #require(!database.isEphemeral)
        try database.writer.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessionItem WHERE position = 7") == 1)
            #expect(try Set(Self.indexNames(in: db)).isSuperset(of: Self.indexesOfV4))
        }
    }

    @Test func aNewDatabaseIsMigratedOnce() throws {
        let database = AppDatabase.temporary()
        try database.writer.read { db throws in
            #expect(try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
                == ["v1", "v2-folder-pinning", "v3-profile-pins", "v4-indexes"])
            #expect(try Set(Self.indexNames(in: db)).isSuperset(of: Self.indexesOfV4))
        }
    }

    // MARK: - The full-text trigger

    /// A visit changes `visitCount` and `lastVisit`, which the index does not hold. GRDB's trigger re-indexed the page for it;
    /// this one leaves the index alone unless `url` or `title` changes, and then keeps it exact.
    @Test func aVisitDoesNotTouchTheFullTextIndexButATitleDoes() throws {
        let database = AppDatabase.temporary()
        try database.writer.write { db throws in
            try db.execute(sql: """
                INSERT INTO historyPage (url, title, visitCount, lastVisit) VALUES ('https://zebra.example/', 'Zebra crossing', 1, 1)
                """)
            let upsert = """
                INSERT INTO historyPage (url, title, visitCount, lastVisit) VALUES ('https://zebra.example/', ?, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = excluded.title, visitCount = visitCount + 1, lastVisit = excluded.lastVisit
                """

            // The full-text index writes what the insert gave it at the next write, and that is not what is measured.
            try db.execute(sql: "UPDATE historyPage SET lastVisit = 1")

            var changes = db.totalChangesCount
            try db.execute(sql: upsert, arguments: ["Zebra crossing", 2.0])
            #expect(db.totalChangesCount - changes == 1, "a revisit with the same title writes the page and nothing else")

            changes = db.totalChangesCount
            try db.execute(sql: "UPDATE historyPage SET visitCount = visitCount + 1, lastVisit = 3")
            #expect(db.totalChangesCount - changes == 1)

            changes = db.totalChangesCount
            try db.execute(sql: upsert, arguments: ["Giraffe crossing", 4.0])
            #expect(db.totalChangesCount - changes > 1, "a new title is indexed")
            #expect(try String.fetchAll(db, sql: "SELECT url FROM historyPage_ft WHERE historyPage_ft MATCH 'giraffe'")
                == ["https://zebra.example/"])
            #expect(try String.fetchAll(db, sql: "SELECT url FROM historyPage_ft WHERE historyPage_ft MATCH 'zebra'")
                == ["https://zebra.example/"], "the address is still indexed")
            #expect(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM historyPage_ft WHERE historyPage_ft MATCH 'title:crossing AND title:zebra'
                """) == 0, "and the old title is not")
            try db.execute(sql: "INSERT INTO historyPage_ft(historyPage_ft) VALUES('integrity-check')")

            try db.execute(sql: "UPDATE historyPage SET url = 'https://giraffe.example/'")
            #expect(try String.fetchAll(db, sql: "SELECT url FROM historyPage_ft WHERE historyPage_ft MATCH 'giraffe'")
                == ["https://giraffe.example/"])
            try db.execute(sql: "DELETE FROM historyPage")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyPage_ft WHERE historyPage_ft MATCH 'giraffe'") == 0)
            try db.execute(sql: "INSERT INTO historyPage_ft(historyPage_ft) VALUES('integrity-check')")
        }
    }

    // MARK: - Helpers

    /// GRDB's own trigger, as 0.1.14 and every earlier build left it, and no `v4-indexes`.
    private nonisolated static func dropV4(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM grdb_migrations WHERE identifier = 'v4-indexes';
            DROP INDEX historyVisit_fromVisit;
            DROP INDEX sessionItem_tabID;
            DROP INDEX sessionItem_folderID;
            DROP INDEX sessionItem_parentID;
            DROP INDEX profilePin_parentID;
            DROP TRIGGER "__historyPage_ft_au";
            CREATE TRIGGER "__historyPage_ft_au" AFTER UPDATE ON "historyPage" BEGIN
                INSERT INTO "historyPage_ft"("historyPage_ft", "rowid", "url", "title") VALUES('delete', old."rowid", old."url", old."title");
                INSERT INTO "historyPage_ft"("rowid", "url", "title") VALUES (new."rowid", new."url", new."title");
            END;
            """)
    }

    private nonisolated static func indexNames(in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
    }

    private nonisolated static func triggerSQL(in db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = '__historyPage_ft_au'") ?? ""
    }

    /// Tables, columns, foreign keys, indexes and triggers as sorted words. Column order is left out: a column added to a
    /// table after it was made comes last, and in a new one it comes where `defineSchema` puts it.
    private nonisolated static func schemaSummary(in db: Database) throws -> [String] {
        var lines: [String] = []
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'historyPage_ft_%'
            """)
        for table in tables {
            for row in try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")") {
                let name: String = row["name"]
                let type: String = row["type"]
                let notNull: Int = row["notnull"]
                let primaryKey: Int = row["pk"]
                let initial: String? = row["dflt_value"]
                lines.append("column \(table).\(name) \(type) notnull=\(notNull) pk=\(primaryKey) default=\(initial ?? "-")")
            }
            for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\"\(table)\")") {
                let from: String = row["from"]
                let parent: String = row["table"]
                let to: String? = row["to"]
                let onDelete: String = row["on_delete"]
                lines.append("foreignkey \(table).\(from) -> \(parent).\(to ?? "-") on delete \(onDelete)")
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL") {
            let name: String = row["name"]
            let table: String = row["tbl_name"]
            var columns: [String] = []
            for column in try Row.fetchAll(db, sql: "PRAGMA index_info(\"\(name)\")") {
                let columnName: String? = column["name"]
                columns.append(columnName ?? "-")
            }
            lines.append("index \(name) on \(table)(\(columns.joined(separator: ",")))")
        }
        for row in try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'") {
            let name: String = row["name"]
            let sql: String = row["sql"]
            lines.append("trigger \(name) \(sql.split(whereSeparator: \.isWhitespace).joined(separator: " "))")
        }
        return lines.sorted()
    }

    /// Every table and its columns, as the database has them now.
    private nonisolated static func columns(in database: DatabaseQueue) throws -> [String: [String]] {
        try database.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                    AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'historyPage_ft_%' AND name != 'grdb_migrations'
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

    /// A profile after weeks of use: a long history with referrers, two windows with tabs, folders, pins, archived tabs, notes
    /// the assistant keeps and a conversation. Only columns that the 0.1.10 schema has.
    private nonisolated static func seedRealisticProfile(in db: Database) throws -> (pages: Int, sentinelURL: String) {
        let hosts = ["news", "docs", "github", "wiki", "video", "maps", "store", "mail", "forum", "weather"]
        let words = ["Release", "Notes", "Pricing", "Guide", "Dashboard", "Inbox", "Search", "Settings", "Pull", "Request"]
        let now = Date.now.timeIntervalSinceReferenceDate
        let pages = 1_500
        var previous: Int64?
        for index in 0..<pages {
            let host = hosts[index % hosts.count]
            let url = "https://www.\(host).example/\(words[index % words.count].lowercased())/\(index)"
            let title = index == 42 ? "Sentinel page" : "\(words[index % words.count]) \(index) - \(host.capitalized)"
            let visits = index % 4 + 1
            let last = now - Double(index) * 600
            try db.execute(
                sql: "INSERT INTO historyPage (url, title, visitCount, lastVisit) VALUES (?, ?, ?, ?)",
                arguments: [url, title, visits, last]
            )
            for visit in 0..<visits {
                try db.execute(
                    sql: "INSERT INTO historyVisit (url, visitedAt, transition, fromVisit) VALUES (?, ?, ?, ?)",
                    arguments: [url, last - Double(visit) * 90, visit == 0 ? "typed" : "link", visit == 0 ? nil : previous]
                )
                previous = db.lastInsertedRowID
            }
        }
        let sentinelURL = "https://www.\(hosts[42 % hosts.count]).example/\(words[42 % words.count].lowercased())/42"

        let windows = [UUID(), UUID()]
        for window in windows {
            try db.execute(
                sql: "INSERT INTO sessionWindow (id, lastActiveAt, revision) VALUES (?, ?, ?)",
                arguments: [window, Date.now, 3]
            )
        }
        for (number, window) in windows.enumerated() {
            let folder = UUID()
            try db.execute(
                sql: """
                    INSERT INTO sessionFolder (id, position, name, color, isExpanded, isPinned, windowID)
                    VALUES (?, 0, ?, 'blue', 1, 0, ?)
                    """,
                arguments: [folder, "Folder \(number)", window]
            )
            for tab in 0..<5 {
                let id = UUID()
                try db.execute(
                    sql: """
                        INSERT INTO sessionTab (id, title, url, state, isActive, isFavorite, windowID)
                        VALUES (?, ?, ?, ?, ?, 0, ?)
                        """,
                    arguments: [
                        id, "Tab \(number).\(tab)", "https://www.news.example/\(tab)",
                        Data(repeating: UInt8(tab), count: 2_048), tab == 0, window,
                    ]
                )
                try db.execute(
                    sql: "INSERT INTO sessionItem (windowID, position, tabID, folderID, parentID) VALUES (?, ?, ?, NULL, ?)",
                    arguments: [window, tab, id, tab < 3 ? folder : nil]
                )
            }
        }
        let root = UUID()
        try db.execute(
            sql: "INSERT INTO profilePin (id, orderKey, kind, title) VALUES (?, 'a', 'folder', 'Work')",
            arguments: [root]
        )
        for (position, title) in ["Mail", "Calendar"].enumerated() {
            try db.execute(
                sql: "INSERT INTO profilePin (id, parentID, orderKey, kind, url, title) VALUES (?, ?, ?, 'tab', ?, ?)",
                arguments: [UUID(), root, "b\(position)", "https://\(title.lowercased()).example/", title]
            )
        }
        for index in 0..<8 {
            try db.execute(
                sql: "INSERT INTO archivedTab (id, title, url, archivedAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID(), "Archived \(index)", "https://old.example/\(index)", Date.now]
            )
        }
        for subject in ["name", "city", "work"] {
            try db.execute(
                sql: "INSERT INTO assistantFact (id, subject, value, source, savedAt) VALUES (?, ?, ?, 'chat', ?)",
                arguments: [UUID(), subject, "value of \(subject)", Date.now]
            )
        }
        let trace = UUID()
        try db.execute(
            sql: """
                INSERT INTO agentTrace (id, tabID, prompt, startedAt, response, state)
                VALUES (?, ?, 'Find the release notes', ?, 'Here they are.', 'finished')
                """,
            arguments: [trace, UUID(), Date.now]
        )
        for step in 0..<3 {
            try db.execute(
                sql: """
                    INSERT INTO agentStep (id, traceID, position, kind, title, startedAt, links, state)
                    VALUES (?, ?, ?, 'tool', ?, ?, '[]', 'finished')
                    """,
                arguments: [UUID(), trace, step, "Step \(step)", Date.now]
            )
        }
        return (pages, sentinelURL)
    }
}
