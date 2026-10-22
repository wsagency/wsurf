// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB

/// The §5 SQL layer. The store file is untrusted input: values are decoded from their exact SQLite storage class
/// (`DatabaseValue.storage`), never through GRDB's trapping `row[...]` subscripts or its coercing numeric decoders, and
/// counters are bound only after an exact `0...Int64.max` check. Anything else is `CredentialStoreError.malformed`.
nonisolated enum StoreTables {
    nonisolated struct VaultRow: Equatable, Sendable {
        var vaultID: UUID
        var role: VaultRole
        var ordinal: Int
        var createdAt: Date
        var wrappers: Data?
        var keyWrap: Data?
    }

    nonisolated struct RecordRow: Equatable, Sendable {
        var vaultID: UUID
        var recordID: UUID
        var kind: RecordKind
        var ownerID: UUID
        var subject: RecordSubject
        var version: UInt64
        var sealed: Data
    }

    /// §5 DDL and the single `store_meta` row. Throws if the tables already exist.
    static func create(in db: Database, ids: StoreIDs) throws {
        try db.execute(sql: """
            CREATE TABLE store_meta(
                id INTEGER PRIMARY KEY CHECK(id = 1), schema INTEGER NOT NULL, storeID TEXT NOT NULL, profileID TEXT NOT NULL);
            CREATE TABLE vault(
                vaultID TEXT PRIMARY KEY, role TEXT NOT NULL CHECK(role IN ('active', 'trash')), ordinal INTEGER NOT NULL,
                createdAt REAL NOT NULL, wrappers BLOB, keyWrap BLOB);
            CREATE TABLE head(
                vaultID TEXT PRIMARY KEY REFERENCES vault(vaultID), revision INTEGER NOT NULL, sealed BLOB NOT NULL);
            CREATE TABLE record(
                vaultID TEXT NOT NULL, recordID TEXT NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('account', 'revision', 'trashEntry', 'tombstone')),
                ownerID TEXT NOT NULL, subject TEXT NOT NULL, version INTEGER NOT NULL, sealed BLOB NOT NULL,
                PRIMARY KEY(vaultID, recordID));
            CREATE TABLE journal(
                vaultID TEXT NOT NULL, seq INTEGER NOT NULL, sealed BLOB NOT NULL, PRIMARY KEY(vaultID, seq));
            CREATE TABLE registry(
                id INTEGER PRIMARY KEY CHECK(id = 1), revision INTEGER NOT NULL, catalog BLOB NOT NULL, mac BLOB NOT NULL);
            """)
        try db.execute(
            sql: "INSERT INTO store_meta(id, schema, storeID, profileID) VALUES (1, ?, ?, ?)",
            arguments: [StoreFormat.schema, ids.storeID.sqlText, ids.profileID.sqlText]
        )
    }

    static func storeMeta(_ db: Database) throws -> (schema: Int, ids: StoreIDs)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT schema, storeID, profileID FROM store_meta") else { return nil }
        return (try Stored.int(row[0]), StoreIDs(storeID: try Stored.uuid(row[1]), profileID: try Stored.uuid(row[2])))
    }

    // MARK: Vaults

    static func insertVault(_ db: Database, _ row: VaultRow) throws {
        try db.execute(
            sql: "INSERT INTO vault(vaultID, role, ordinal, createdAt, wrappers, keyWrap) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [row.vaultID.sqlText, row.role.sqlName, row.ordinal, row.createdAt.timeIntervalSinceReferenceDate, row.wrappers, row.keyWrap]
        )
    }

    static func vaultRows(_ db: Database) throws -> [VaultRow] {
        try Row.fetchAll(db, sql: "SELECT vaultID, role, ordinal, createdAt, wrappers, keyWrap FROM vault ORDER BY vaultID").map { row in
            VaultRow(
                vaultID: try Stored.uuid(row[0]),
                role: try Stored.role(row[1]),
                ordinal: try Stored.int(row[2]),
                createdAt: try Stored.date(row[3]),
                wrappers: try Stored.optionalBlob(row[4]),
                keyWrap: try Stored.optionalBlob(row[5])
            )
        }
    }

    // MARK: Heads

    static func putHead(_ db: Database, vaultID: UUID, revision: UInt64, sealed: Data) throws {
        try db.execute(
            sql: """
                INSERT INTO head(vaultID, revision, sealed) VALUES (?, ?, ?)
                ON CONFLICT(vaultID) DO UPDATE SET revision = excluded.revision, sealed = excluded.sealed
                """,
            arguments: [vaultID.sqlText, try Stored.bind(revision), sealed]
        )
    }

    static func head(_ db: Database, vaultID: UUID) throws -> (revision: UInt64, sealed: Data)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT revision, sealed FROM head WHERE vaultID = ?", arguments: [vaultID.sqlText]) else { return nil }
        return (try Stored.counter(row[0]), try Stored.blob(row[1]))
    }

    // MARK: Records

    /// Insert or replace by `(vaultID, recordID)`.
    static func putRecord(_ db: Database, _ row: RecordRow) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO record(vaultID, recordID, kind, ownerID, subject, version, sealed)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                row.vaultID.sqlText, row.recordID.sqlText, row.kind.sqlName, row.ownerID.sqlText, row.subject.sqlName,
                try Stored.bind(row.version), row.sealed,
            ]
        )
    }

    static func deleteRecord(_ db: Database, vaultID: UUID, recordID: UUID) throws {
        try db.execute(sql: "DELETE FROM record WHERE vaultID = ? AND recordID = ?", arguments: [vaultID.sqlText, recordID.sqlText])
    }

    /// Compiled once per connection: a snapshot, a commit and an unlock each read every live row through here.
    static func record(_ db: Database, vaultID: UUID, recordID: UUID) throws -> RecordRow? {
        let statement = try db.cachedStatement(
            sql: "SELECT vaultID, recordID, kind, ownerID, subject, version, sealed FROM record WHERE vaultID = ? AND recordID = ?"
        )
        guard let row = try Row.fetchOne(statement, arguments: [vaultID.sqlText, recordID.sqlText]) else { return nil }
        return try recordRow(row)
    }

    static func recordCount(_ db: Database, vaultID: UUID, kind: RecordKind) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM record WHERE vaultID = ? AND kind = ?", arguments: [vaultID.sqlText, kind.sqlName]
        ) ?? 0
    }

    /// Streams every non-account (history) row of one vault, one row in memory at a time.
    static func forEachHistoryRecord(_ db: Database, vaultID: UUID, _ body: (RecordRow) throws -> Void) throws {
        let sql = "SELECT vaultID, recordID, kind, ownerID, subject, version, sealed FROM record WHERE vaultID = ? AND kind != ?"
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: [vaultID.sqlText, RecordKind.account.sqlName])
        while let row = try cursor.next() {
            try body(try recordRow(row))
        }
    }

    /// The next `revision` row of one vault owned by `ownerID` (and of `subject`, when given) after `previous` in `recordID` order, or
    /// `nil`. One statement, one row, finished before it returns: a MOVE writes and deletes between calls, never under an open
    /// cursor, and the keyset (`recordID > previous`) walks the primary key forward, so the rows it already moved are never
    /// revisited and none is skipped. Memory is one row.
    ///
    /// `ownerID`, `subject` and `kind` are clear columns that only the AEAD's AAD authenticates. The caller must already have run
    /// `StoreVerifier.verifyHistories` in this transaction, which binds every stored row's columns and ciphertext to its vault's journal.
    static func nextOwnedRevision(
        _ db: Database, vaultID: UUID, ownerID: UUID, subject: RecordSubject?, after previous: UUID?
    ) throws -> RecordRow? {
        var sql = """
            SELECT vaultID, recordID, kind, ownerID, subject, version, sealed FROM record
            WHERE vaultID = ? AND kind = ? AND ownerID = ? AND recordID > ?
            """
        var arguments: StatementArguments = [vaultID.sqlText, RecordKind.revision.sqlName, ownerID.sqlText, previous?.sqlText ?? ""]
        if let subject {
            sql += " AND subject = ?"
            arguments += [subject.sqlName]
        }
        return try Row.fetchOne(db, sql: sql + " ORDER BY recordID LIMIT 1", arguments: arguments).map(recordRow)
    }

    /// The ids of the `trashEntry` rows of one vault owned by `ownerID` with `subject` (`.account` for a whole account), newest first.
    /// The clear columns are authenticated only by the AEAD's AAD, so the caller opens each row it takes, which checks them.
    static func trashEntryIDs(_ db: Database, vaultID: UUID, ownerID: UUID, subject: RecordSubject) throws -> [UUID] {
        let sql = "SELECT recordID FROM record WHERE vaultID = ? AND kind = ? AND ownerID = ? AND subject = ? ORDER BY rowid DESC"
        let arguments: StatementArguments = [vaultID.sqlText, RecordKind.trashEntry.sqlName, ownerID.sqlText, subject.sqlName]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { try Stored.uuid($0[0] as DatabaseValue) }
    }

    private static func recordRow(_ row: Row) throws -> RecordRow {
        RecordRow(
            vaultID: try Stored.uuid(row[0]),
            recordID: try Stored.uuid(row[1]),
            kind: try Stored.kind(row[2]),
            ownerID: try Stored.uuid(row[3]),
            subject: try Stored.subject(row[4]),
            version: try Stored.counter(row[5]),
            sealed: try Stored.blob(row[6])
        )
    }

    // MARK: Journal and registry

    /// Journal rows are append-only: a repeated `(vaultID, seq)` throws.
    static func putJournal(_ db: Database, vaultID: UUID, seq: UInt64, sealed: Data) throws {
        try db.execute(
            sql: "INSERT INTO journal(vaultID, seq, sealed) VALUES (?, ?, ?)",
            arguments: [vaultID.sqlText, try Stored.bind(seq), sealed]
        )
    }

    /// Streams one vault's journal rows in `seq` order, one row in memory at a time.
    static func forEachJournal(_ db: Database, vaultID: UUID, _ body: (_ seq: UInt64, _ sealed: Data) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT seq, sealed FROM journal WHERE vaultID = ? ORDER BY seq", arguments: [vaultID.sqlText])
        while let row = try cursor.next() {
            try body(try Stored.counter(row[0]), try Stored.blob(row[1]))
        }
    }

    static func putRegistry(_ db: Database, revision: UInt64, catalog: Data, mac: Data) throws {
        try db.execute(
            sql: """
                INSERT INTO registry(id, revision, catalog, mac) VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, catalog = excluded.catalog, mac = excluded.mac
                """,
            arguments: [try Stored.bind(revision), catalog, mac]
        )
    }

    static func registry(_ db: Database) throws -> (revision: UInt64, catalog: Data, mac: Data)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT revision, catalog, mac FROM registry") else { return nil }
        return (try Stored.counter(row[0]), try Stored.blob(row[1]), try Stored.blob(row[2]))
    }
}

/// Exact-storage-class decoding of one result cell; `row[i]` as `DatabaseValue` never traps or coerces.
private nonisolated enum Stored {
    /// A counter becomes a SQLite INTEGER only when it fits: no wrap, no `bitPattern`, no GRDB trap.
    static func bind(_ counter: UInt64) throws -> Int64 {
        guard let value = Int64(exactly: counter) else { throw CredentialStoreError.malformed }
        return value
    }

    static func counter(_ cell: DatabaseValue) throws -> UInt64 {
        guard case .int64(let value) = cell.storage, let counter = UInt64(exactly: value) else { throw CredentialStoreError.malformed }
        return counter
    }

    static func int(_ cell: DatabaseValue) throws -> Int {
        guard let value = Int(exactly: try counter(cell)) else { throw CredentialStoreError.malformed }
        return value
    }

    static func text(_ cell: DatabaseValue) throws -> String {
        guard case .string(let value) = cell.storage else { throw CredentialStoreError.malformed }
        return value
    }

    static func blob(_ cell: DatabaseValue) throws -> Data {
        guard case .blob(let value) = cell.storage else { throw CredentialStoreError.malformed }
        return value
    }

    static func optionalBlob(_ cell: DatabaseValue) throws -> Data? {
        if case .null = cell.storage {
            return nil
        }
        return try blob(cell)
    }

    static func date(_ cell: DatabaseValue) throws -> Date {
        guard case .double(let value) = cell.storage, value.isFinite else { throw CredentialStoreError.malformed }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    /// Only the canonical lower-case spelling this layer writes.
    static func uuid(_ cell: DatabaseValue) throws -> UUID {
        let value = try text(cell)
        guard let uuid = UUID(uuidString: value), uuid.sqlText == value else { throw CredentialStoreError.malformed }
        return uuid
    }

    static func role(_ cell: DatabaseValue) throws -> VaultRole {
        guard let role = VaultRole(sqlName: try text(cell)) else { throw CredentialStoreError.malformed }
        return role
    }

    static func kind(_ cell: DatabaseValue) throws -> RecordKind {
        guard let kind = RecordKind(sqlName: try text(cell)) else { throw CredentialStoreError.malformed }
        return kind
    }

    static func subject(_ cell: DatabaseValue) throws -> RecordSubject {
        guard let subject = RecordSubject(sqlName: try text(cell)) else { throw CredentialStoreError.malformed }
        return subject
    }
}

private nonisolated extension UUID {
    /// The canonical lower-case spelling stored in SQL text columns.
    var sqlText: String {
        uuidString.lowercased()
    }
}
