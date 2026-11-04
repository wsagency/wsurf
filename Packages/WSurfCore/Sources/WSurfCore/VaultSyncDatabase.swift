// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import WSurfVault

/// One vault's row in `Credentials.sync`: whether this Mac syncs it, how that stands, and what was last uploaded.
nonisolated struct VaultRow: Equatable {
    var vaultID: UUID
    var enabled: Bool
    var status: VaultSyncStatus.Stored
    /// `VaultSyncCodec.vaultMark` of the name and wrapper list last uploaded. Nil right after this Mac added or rejoined the vault.
    var uploadedMark: Data?
    /// The `Vault` record's payload waiting to go up, and the mark it stands for.
    var pendingVault: Data?
    var pendingMark: Data?
    /// A change was held back because its record was on its way; produce again after the `.sent`.
    var dirty = false
    /// The zone was joined or added and a full read of it did not finish yet.
    var needsFetch = false
    /// The highest head revision this Mac has seen of the vault's store. A lower one means the store was restored from a backup.
    var lastHeadRevision: UInt64 = 0
    /// The last full read of the zone skipped records the server could not return: one more read is owed. Unlike `needsFetch`, it holds
    /// nothing back.
    var rereadOwed = false

    init(vaultID: UUID, enabled: Bool = true, status: VaultSyncStatus.Stored = .active, needsFetch: Bool = false) {
        self.vaultID = vaultID
        self.enabled = enabled
        self.status = status
        self.needsFetch = needsFetch
    }
}

/// How many rows of a vault wait in each table; review counts only the conflicts that need a choice.
nonisolated struct VaultCounts: Equatable {
    var outbox: Int
    var inbox: Int
    var review: Int
    /// Inbox rows parked because a newer WSurf wrote them (version 0).
    var parked: Int
}

/// An account's sync base: the version and sealed parts the Mac and iCloud last agreed on (`VaultSyncCodec.sealParts`).
nonisolated struct BaseRow: Equatable {
    var accountID: UUID
    var version: UInt64
    var parts: Data
}

/// An envelope sealed and waiting to go up, with the sealed parts that become the base once the server confirms it.
nonisolated struct OutboxRow: Equatable {
    var accountID: UUID
    var version: UInt64
    var envelope: Data
    var parts: Data
}

/// A fetched envelope not yet applied: the highest version of the account. Version 0 parks a record in a format this build cannot
/// read: it is kept as it came, no pass takes it in, and nothing is sent over it, until a build that reads it reads the zone again.
nonisolated struct InboxRow: Equatable {
    var accountID: UUID
    var version: UInt64
    var envelope: Data
}

/// An envelope that waits for the person (or is only information), with the reason.
nonisolated struct ConflictRow: Equatable {
    var accountID: UUID
    var version: UInt64
    var kind: SyncConflictKind
    var envelope: Data
}

/// `Credentials.sync` in the profile's own folder (spec amendment 2026-10-22): the per-profile state of the vault sync, in one SQLite
/// file. It holds ciphertext, versions, counts, change tags and HMACs, and nothing a reader could use without the vault's key; sync
/// bases are sealed because they are SHA-256 of secrets. It is removed with the profile's folder.
nonisolated final class VaultSyncDatabase: Sendable {
    static let fileName = "Credentials.sync"

    private let queue: DatabaseQueue

    private static let schema = """
        CREATE TABLE vault(
            vaultID TEXT PRIMARY KEY, enabled INTEGER NOT NULL, status TEXT NOT NULL, uploadedMark BLOB,
            pendingVaultPayload BLOB, pendingMark BLOB, dirty INTEGER NOT NULL DEFAULT 0,
            needsFetch INTEGER NOT NULL DEFAULT 0, lastHeadRevision INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE base(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, parts BLOB NOT NULL,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE outbox(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, envelope BLOB NOT NULL, parts BLOB NOT NULL,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE inbox(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, envelope BLOB NOT NULL,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE conflict(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, kind TEXT NOT NULL, envelope BLOB NOT NULL,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE record(
            vaultID TEXT NOT NULL, name TEXT NOT NULL, systemFields BLOB NOT NULL, PRIMARY KEY(vaultID, name));
        """

    private static let tables = ["base", "outbox", "inbox", "conflict", "record"]

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// The database in `directory`, created when `create` is set. Nil when there is none and none is wanted.
    static func open(directory: URL, create: Bool) throws -> VaultSyncDatabase? {
        let url = directory.appending(path: fileName, directoryHint: .notDirectory)
        guard create || FileManager.default.fileExists(atPath: url.path) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { (db: Database) throws in
            try db.execute(sql: schema)
        }
        migrator.registerMigration("v2") { (db: Database) throws in
            try db.execute(sql: "ALTER TABLE vault ADD COLUMN rereadOwed INTEGER NOT NULL DEFAULT 0")
        }
        try migrator.migrate(queue)
        return VaultSyncDatabase(queue: queue)
    }

    func read<T>(_ body: (Transaction) throws -> T) throws -> T {
        try queue.read { (db: Database) throws -> T in
            try body(Transaction(db: db))
        }
    }

    func write<T>(_ body: (Transaction) throws -> T) throws -> T {
        try queue.write { (db: Database) throws -> T in
            try body(Transaction(db: db))
        }
    }

    /// The statements of one transaction. Every UUID is its canonical lower-case text, as in the store.
    nonisolated struct Transaction {
        let db: Database

        // MARK: Vault

        func vaults() throws -> [VaultRow] {
            try Row.fetchAll(db, sql: "SELECT * FROM vault ORDER BY vaultID").compactMap(Self.vaultRow)
        }

        func vault(_ id: UUID) throws -> VaultRow? {
            try Row.fetchOne(db, sql: "SELECT * FROM vault WHERE vaultID = ?", arguments: [id.sqlText]).flatMap(Self.vaultRow)
        }

        func save(_ row: VaultRow) throws {
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO vault(vaultID, enabled, status, uploadedMark, pendingVaultPayload, pendingMark, dirty,
                        needsFetch, lastHeadRevision, rereadOwed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    row.vaultID.sqlText, row.enabled, row.status.rawValue, row.uploadedMark, row.pendingVault, row.pendingMark,
                    row.dirty, row.needsFetch, Int64(clamping: row.lastHeadRevision), row.rereadOwed,
                ]
            )
        }

        /// Every row of the vault but the vault row itself.
        func clear(_ id: UUID) throws {
            for table in VaultSyncDatabase.tables {
                try db.execute(sql: "DELETE FROM \(table) WHERE vaultID = ?", arguments: [id.sqlText])
            }
        }

        func remove(_ id: UUID) throws {
            try clear(id)
            try db.execute(sql: "DELETE FROM vault WHERE vaultID = ?", arguments: [id.sqlText])
        }

        private static func vaultRow(_ row: Row) -> VaultRow? {
            guard let id = UUID(uuidString: row["vaultID"]), let status = VaultSyncStatus.Stored(rawValue: row["status"]) else { return nil }
            var result = VaultRow(vaultID: id, enabled: row["enabled"], status: status)
            result.uploadedMark = row["uploadedMark"]
            result.pendingVault = row["pendingVaultPayload"]
            result.pendingMark = row["pendingMark"]
            result.dirty = row["dirty"]
            result.needsFetch = row["needsFetch"]
            result.lastHeadRevision = UInt64(clamping: row["lastHeadRevision"] as Int64)
            result.rereadOwed = row["rereadOwed"]
            return result
        }

        // MARK: Bases

        func bases(_ vault: UUID) throws -> [BaseRow] {
            try Row.fetchAll(db, sql: "SELECT accountID, version, parts FROM base WHERE vaultID = ?", arguments: [vault.sqlText])
                .compactMap { row in
                    UUID(uuidString: row["accountID"]).map { BaseRow(accountID: $0, version: Self.version(row), parts: row["parts"]) }
                }
        }

        func base(_ vault: UUID, _ account: UUID) throws -> BaseRow? {
            try Row.fetchOne(
                db, sql: "SELECT version, parts FROM base WHERE vaultID = ? AND accountID = ?", arguments: [vault.sqlText, account.sqlText]
            ).map { BaseRow(accountID: account, version: Self.version($0), parts: $0["parts"]) }
        }

        func baseVersions(_ vault: UUID) throws -> [UUID: UInt64] {
            try versions("base", vault)
        }

        func baseVersion(_ vault: UUID, _ account: UUID) throws -> UInt64? {
            try version("base", vault, account)
        }

        /// The version of one row of `table`, or nil when the account has none.
        private func version(_ table: String, _ vault: UUID, _ account: UUID) throws -> UInt64? {
            try Int64.fetchOne(
                db, sql: "SELECT version FROM \(table) WHERE vaultID = ? AND accountID = ?", arguments: [vault.sqlText, account.sqlText]
            ).map { UInt64(clamping: $0) }
        }

        /// The accounts that have a row in `table`, without their sealed bytes.
        private func accountIDs(_ table: String, _ vault: UUID) throws -> Set<UUID> {
            Set(try String.fetchAll(db, sql: "SELECT accountID FROM \(table) WHERE vaultID = ?", arguments: [vault.sqlText])
                .compactMap { UUID(uuidString: $0) })
        }

        func outboxAccounts(_ vault: UUID) throws -> Set<UUID> {
            try accountIDs("outbox", vault)
        }

        func conflictAccounts(_ vault: UUID) throws -> Set<UUID> {
            try accountIDs("conflict", vault)
        }

        /// The accounts whose record this Mac has seen: a change tag is stored for each.
        func recordedAccounts(_ vault: UUID) throws -> Set<UUID> {
            Set(try String.fetchAll(db, sql: "SELECT name FROM record WHERE vaultID = ?", arguments: [vault.sqlText])
                .compactMap { UUID(uuidString: $0) })
        }

        /// The version of every row of `table` for the vault, without the sealed bytes.
        private func versions(_ table: String, _ vault: UUID) throws -> [UUID: UInt64] {
            var found: [UUID: UInt64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT accountID, version FROM \(table) WHERE vaultID = ?", arguments: [vault.sqlText]) {
                if let id = UUID(uuidString: row["accountID"]) {
                    found[id] = Self.version(row)
                }
            }
            return found
        }

        func save(_ base: BaseRow, vault: UUID) throws {
            try db.execute(
                sql: "INSERT OR REPLACE INTO base(vaultID, accountID, version, parts) VALUES (?, ?, ?, ?)",
                arguments: [vault.sqlText, base.accountID.sqlText, Int64(clamping: base.version), base.parts]
            )
        }

        // MARK: Outbox

        func outbox(_ vault: UUID) throws -> [OutboxRow] {
            try Row.fetchAll(db, sql: "SELECT accountID, version, envelope, parts FROM outbox WHERE vaultID = ? ORDER BY accountID", arguments: [vault.sqlText])
                .compactMap { row in
                    UUID(uuidString: row["accountID"]).map {
                        OutboxRow(accountID: $0, version: Self.version(row), envelope: row["envelope"], parts: row["parts"])
                    }
                }
        }

        func outbox(_ vault: UUID, _ account: UUID) throws -> OutboxRow? {
            try Row.fetchOne(
                db, sql: "SELECT version, envelope, parts FROM outbox WHERE vaultID = ? AND accountID = ?",
                arguments: [vault.sqlText, account.sqlText]
            ).map { OutboxRow(accountID: account, version: Self.version($0), envelope: $0["envelope"], parts: $0["parts"]) }
        }

        func save(_ row: OutboxRow, vault: UUID) throws {
            try db.execute(
                sql: "INSERT OR REPLACE INTO outbox(vaultID, accountID, version, envelope, parts) VALUES (?, ?, ?, ?, ?)",
                arguments: [vault.sqlText, row.accountID.sqlText, Int64(clamping: row.version), row.envelope, row.parts]
            )
        }

        func deleteOutbox(_ vault: UUID, _ account: UUID) throws {
            try db.execute(sql: "DELETE FROM outbox WHERE vaultID = ? AND accountID = ?", arguments: [vault.sqlText, account.sqlText])
        }

        // MARK: Inbox

        /// The oldest `limit` rows by account id: a stable order, so a batch that goes round again meets the same rows. Parked rows
        /// (version 0) are not in it.
        func inbox(_ vault: UUID, limit: Int, excluding: Set<UUID> = []) throws -> [InboxRow] {
            // ponytail: the excluded rows are read and dropped here; a drain with thousands of them waiting pays for that each batch.
            let rows = try Row.fetchAll(
                db, sql: "SELECT accountID, version, envelope FROM inbox WHERE vaultID = ? AND version > 0 ORDER BY accountID LIMIT ?",
                arguments: [vault.sqlText, limit + excluding.count]
            ).compactMap { row in
                UUID(uuidString: row["accountID"]).map { InboxRow(accountID: $0, version: Self.version(row), envelope: row["envelope"]) }
            }
            return Array(rows.filter { !excluding.contains($0.accountID) }.prefix(limit))
        }

        /// The accounts whose newer-format record is parked.
        func parkedAccounts(_ vault: UUID) throws -> Set<UUID> {
            Set(try String.fetchAll(
                db, sql: "SELECT accountID FROM inbox WHERE vaultID = ? AND version = 0", arguments: [vault.sqlText]
            ).compactMap { UUID(uuidString: $0) })
        }

        /// The version waiting in the inbox for one account (0: parked), or nil when none waits.
        func inboxVersion(_ vault: UUID, _ account: UUID) throws -> UInt64? {
            try version("inbox", vault, account)
        }

        func save(_ row: InboxRow, vault: UUID) throws {
            try db.execute(
                sql: "INSERT OR REPLACE INTO inbox(vaultID, accountID, version, envelope) VALUES (?, ?, ?, ?)",
                arguments: [vault.sqlText, row.accountID.sqlText, Int64(clamping: row.version), row.envelope]
            )
        }

        /// Deletes the account's row unless a newer version arrived since `version` was read.
        func deleteInbox(_ vault: UUID, _ account: UUID, upTo version: UInt64) throws {
            try db.execute(
                sql: "DELETE FROM inbox WHERE vaultID = ? AND accountID = ? AND version <= ?",
                arguments: [vault.sqlText, account.sqlText, Int64(clamping: version)]
            )
        }

        // MARK: Conflicts

        func conflicts(_ vault: UUID) throws -> [ConflictRow] {
            try Row.fetchAll(
                db, sql: "SELECT accountID, version, kind, envelope FROM conflict WHERE vaultID = ? ORDER BY accountID", arguments: [vault.sqlText]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["accountID"]), let kind = SyncConflictKind(rawValue: row["kind"]) else { return nil }
                return ConflictRow(accountID: id, version: Self.version(row), kind: kind, envelope: row["envelope"])
            }
        }

        /// The rows of one kind.
        func conflicts(_ vault: UUID, kind: SyncConflictKind) throws -> [ConflictRow] {
            try conflicts(vault).filter { $0.kind == kind }
        }

        func conflictVersion(_ vault: UUID, _ account: UUID) throws -> UInt64? {
            try version("conflict", vault, account)
        }

        func save(_ row: ConflictRow, vault: UUID) throws {
            try db.execute(
                sql: "INSERT OR REPLACE INTO conflict(vaultID, accountID, version, kind, envelope) VALUES (?, ?, ?, ?, ?)",
                arguments: [vault.sqlText, row.accountID.sqlText, Int64(clamping: row.version), row.kind.rawValue, row.envelope]
            )
        }

        func deleteConflict(_ vault: UUID, _ account: UUID) throws {
            try db.execute(sql: "DELETE FROM conflict WHERE vaultID = ? AND accountID = ?", arguments: [vault.sqlText, account.sqlText])
        }

        // MARK: Change tags

        func systemFields(_ vault: UUID, _ name: String) throws -> Data? {
            try Data.fetchOne(db, sql: "SELECT systemFields FROM record WHERE vaultID = ? AND name = ?", arguments: [vault.sqlText, name])
        }

        func setSystemFields(_ fields: Data?, vault: UUID, name: String) throws {
            guard let fields else { return }
            try db.execute(
                sql: "INSERT OR REPLACE INTO record(vaultID, name, systemFields) VALUES (?, ?, ?)", arguments: [vault.sqlText, name, fields]
            )
        }

        func deleteSystemFields(_ vault: UUID, _ name: String) throws {
            try db.execute(sql: "DELETE FROM record WHERE vaultID = ? AND name = ?", arguments: [vault.sqlText, name])
        }

        // MARK: Counts

        /// The vault row with the counts the status is derived from.
        func summary(_ vault: UUID) throws -> (row: VaultRow, counts: VaultCounts)? {
            guard let row = try self.vault(vault) else { return nil }
            let parked = try parkedAccounts(vault).count
            return (row, VaultCounts(
                outbox: try count("outbox", vault), inbox: try count("inbox", vault) - parked, review: try reviewCount(vault),
                parked: parked
            ))
        }

        func count(_ table: String, _ vault: UUID) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE vaultID = ?", arguments: [vault.sqlText]) ?? 0
        }

        /// Rows that wait for the person, information-only kinds included: none of them lets its entry sync.
        func reviewCount(_ vault: UUID) throws -> Int {
            try count("conflict", vault)
        }

        private static func version(_ row: Row) -> UInt64 {
            UInt64(clamping: row["version"] as Int64)
        }
    }
}

extension UUID {
    /// The store's spelling: canonical lower case.
    nonisolated var sqlText: String {
        uuidString.lowercased()
    }
}
