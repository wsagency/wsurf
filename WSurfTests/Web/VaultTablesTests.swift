// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

private nonisolated enum TableFixtures {
    static func id(_ first: UInt8, _ last: UInt8 = 0) -> UUID {
        UUID(uuid: (first, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }

    static let ids = StoreIDs(storeID: id(0x01), profileID: id(0x02))
    static let activeID = id(0x10)
    static let trashID = id(0x11)
    static let otherActiveID = id(0x12)
    static let tooLarge = UInt64(Int64.max) + 1
    static let wrappers = Data([0x00, 0x01, 0x02, 0xFF, 0x00])
    static let keyWrap = Data([0xFF, 0x00, 0xFE, 0x01])

    static func active(_ vaultID: UUID = activeID, ordinal: Int = 1) -> StoreTables.VaultRow {
        StoreTables.VaultRow(
            vaultID: vaultID, role: .active, ordinal: ordinal, createdAt: Date(timeIntervalSinceReferenceDate: 1234.5), wrappers: wrappers, keyWrap: nil
        )
    }

    static func trash(_ vaultID: UUID = trashID, ordinal: Int = 1) -> StoreTables.VaultRow {
        StoreTables.VaultRow(
            vaultID: vaultID, role: .trash, ordinal: ordinal, createdAt: Date(timeIntervalSinceReferenceDate: 5678.25), wrappers: nil, keyWrap: keyWrap
        )
    }

    static func record(
        vault: UUID = activeID,
        record: UInt8 = 0x20,
        kind: RecordKind = .account,
        subject: RecordSubject = .account,
        version: UInt64 = 1,
        sealed: [UInt8] = [0x00, 0xFF, 0x10]
    ) -> StoreTables.RecordRow {
        StoreTables.RecordRow(
            vaultID: vault, recordID: id(record), kind: kind, ownerID: id(0x30), subject: subject, version: version, sealed: Data(sealed)
        )
    }

    static func makeQueue(vaults: [StoreTables.VaultRow] = [active(), trash(), active(otherActiveID, ordinal: 2)]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try StoreTables.create(in: db, ids: ids)
            for vault in vaults {
                try StoreTables.insertVault(db, vault)
            }
        }
        return queue
    }

    /// A raw record insert with arbitrary spellings, for constraint and untrusted-value checks.
    static func rawRecord(
        _ db: Database,
        record: String = id(0x40).uuidString.lowercased(),
        owner: String = id(0x30).uuidString.lowercased(),
        kind: String = "account",
        subject: String = "account",
        version: Int64 = 1
    ) throws {
        try db.execute(
            sql: "INSERT INTO record(vaultID, recordID, kind, ownerID, subject, version, sealed) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [activeID.uuidString.lowercased(), record, kind, owner, subject, version, Data([1])]
        )
    }
}

struct VaultTablesTests {
    // MARK: Schema

    @Test func createBuildsSchemaAndSingleMetaRow() throws {
        let ids = TableFixtures.ids
        let queue = try DatabaseQueue()
        try queue.write { db in
            try StoreTables.create(in: db, ids: ids)
        }
        try queue.read { db throws in
            let meta = try #require(try StoreTables.storeMeta(db))
            #expect(meta.schema == 2)
            #expect(meta.ids == ids)
            for table in ["store_meta", "vault", "head", "record", "journal", "registry"] {
                #expect(try db.tableExists(table), "\(table)")
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM store_meta") == 1)
            #expect(try String.fetchOne(db, sql: "SELECT storeID FROM store_meta") == ids.storeID.uuidString.lowercased())
            #expect(try String.fetchOne(db, sql: "SELECT profileID FROM store_meta") == ids.profileID.uuidString.lowercased())
        }

        let other = StoreIDs(storeID: TableFixtures.id(0x61), profileID: TableFixtures.id(0x62))
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try StoreTables.create(in: db, ids: other)
            }
        }
        try queue.read { db throws in
            #expect(try StoreTables.storeMeta(db)?.ids == ids)
        }

        // The single-row tables are enforced by the schema, not only by `create`.
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO store_meta(id, schema, storeID, profileID) VALUES (2, 2, 'a', 'b')")
            }
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO registry(id, revision, catalog, mac) VALUES (2, 1, x'00', x'00')")
            }
        }
    }

    @Test func roleAndKindConstraintsRejectUnknownValues() throws {
        let queue = try TableFixtures.makeQueue()
        // The same statements with documented spellings succeed, so only the value differs below.
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO vault(vaultID, role, ordinal, createdAt, wrappers, keyWrap) VALUES (?, 'active', 3, 0.0, NULL, NULL)",
                arguments: [TableFixtures.id(0x13).uuidString.lowercased()]
            )
            try TableFixtures.rawRecord(db)
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vault(vaultID, role, ordinal, createdAt, wrappers, keyWrap) VALUES (?, 'x', 4, 0.0, NULL, NULL)",
                    arguments: [TableFixtures.id(0x14).uuidString.lowercased()]
                )
            }
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try TableFixtures.rawRecord(db, record: TableFixtures.id(0x41).uuidString.lowercased(), kind: "y")
            }
        }
    }

    @Test func headRequiresItsVault() throws {
        let queue = try TableFixtures.makeQueue()
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try StoreTables.putHead(db, vaultID: TableFixtures.id(0x7F), revision: 1, sealed: Data([1]))
            }
        }
    }

    // MARK: Rows

    @Test func vaultRowsReturnWrappersAndKeyWrapExactlyAsStored() throws {
        let active = TableFixtures.active()
        let trash = TableFixtures.trash()
        let queue = try TableFixtures.makeQueue(vaults: [trash, active])
        try queue.read { db in
            let rows = try StoreTables.vaultRows(db).sorted { $0.role.rawValue < $1.role.rawValue }
            #expect(rows == [active, trash])
            #expect(rows[0].wrappers == TableFixtures.wrappers)
            #expect(rows[0].keyWrap == nil)
            #expect(rows[1].wrappers == nil)
            #expect(rows[1].keyWrap == TableFixtures.keyWrap)

            // Spec §5: canonical lower-case ids, the frozen role spellings, ordinal INTEGER, createdAt REAL.
            let raw = try Row.fetchAll(db, sql: "SELECT vaultID, role, typeof(ordinal) AS ordinalType, typeof(createdAt) AS createdType FROM vault ORDER BY role")
            #expect(raw.map { $0["vaultID"] as String } == [TableFixtures.activeID, TableFixtures.trashID].map { $0.uuidString.lowercased() })
            #expect(raw.map { $0["role"] as String } == ["active", "trash"])
            #expect(raw.map { $0["ordinalType"] as String } == ["integer", "integer"])
            #expect(raw.map { $0["createdType"] as String } == ["real", "real"])
        }
    }

    @Test func recordsRoundTripAndReplaceByPrimaryKey() throws {
        let queue = try TableFixtures.makeQueue()
        let first = TableFixtures.record(version: 1)
        let sibling = TableFixtures.record(record: 0x21, kind: .revision, subject: .password, version: 2)
        let otherVault = TableFixtures.record(vault: TableFixtures.otherActiveID, version: 9, sealed: [0x09])
        let replacement = TableFixtures.record(kind: .tombstone, subject: .totp, version: (1 << 40) + 1, sealed: [0xFF, 0x00, 0xFF, 0x00])
        try queue.write { db in
            for row in [first, sibling, otherVault] {
                try StoreTables.putRecord(db, row)
            }
        }
        try queue.read { db throws in
            #expect(try StoreTables.record(db, vaultID: first.vaultID, recordID: first.recordID) == first)
            #expect(try StoreTables.record(db, vaultID: sibling.vaultID, recordID: sibling.recordID) == sibling)
            #expect(try StoreTables.record(db, vaultID: otherVault.vaultID, recordID: otherVault.recordID) == otherVault)
            #expect(try StoreTables.record(db, vaultID: first.vaultID, recordID: TableFixtures.id(0x7E)) == nil)

            let sql = "SELECT vaultID, recordID, kind, ownerID, subject FROM record WHERE recordID = ? AND vaultID = ?"
            let raw = try Row.fetchOne(db, sql: sql, arguments: [sibling.recordID.uuidString.lowercased(), sibling.vaultID.uuidString.lowercased()])
            let row = try #require(raw)
            #expect(row["vaultID"] as String == sibling.vaultID.uuidString.lowercased())
            #expect(row["kind"] as String == "revision")
            #expect(row["ownerID"] as String == sibling.ownerID.uuidString.lowercased())
            #expect(row["subject"] as String == "password")
        }

        try queue.write { db in
            try StoreTables.putRecord(db, replacement)
        }
        try queue.read { db throws in
            #expect(try StoreTables.record(db, vaultID: replacement.vaultID, recordID: replacement.recordID) == replacement)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record WHERE vaultID = ?", arguments: [first.vaultID.uuidString.lowercased()]) == 2)
            #expect(try StoreTables.record(db, vaultID: sibling.vaultID, recordID: sibling.recordID) == sibling)
            #expect(try StoreTables.record(db, vaultID: otherVault.vaultID, recordID: otherVault.recordID) == otherVault)
        }
    }

    @Test func deleteRecordRemovesOnlyThatRow() throws {
        let queue = try TableFixtures.makeQueue()
        let target = TableFixtures.record(record: 0x20)
        let sameVault = TableFixtures.record(record: 0x21)
        let sameIDOtherVault = TableFixtures.record(vault: TableFixtures.otherActiveID, record: 0x20)
        try queue.write { db in
            for row in [target, sameVault, sameIDOtherVault] {
                try StoreTables.putRecord(db, row)
            }
            try StoreTables.deleteRecord(db, vaultID: target.vaultID, recordID: target.recordID)
        }
        try queue.read { db throws in
            #expect(try StoreTables.record(db, vaultID: target.vaultID, recordID: target.recordID) == nil)
            #expect(try StoreTables.record(db, vaultID: sameVault.vaultID, recordID: sameVault.recordID) == sameVault)
            #expect(try StoreTables.record(db, vaultID: sameIDOtherVault.vaultID, recordID: sameIDOtherVault.recordID) == sameIDOtherVault)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record") == 2)
        }
    }

    @Test func headRegistryAndJournalRoundTripExactBytes() throws {
        let queue = try TableFixtures.makeQueue()
        let vaultKey = TableFixtures.activeID.uuidString.lowercased()
        let sealedHead = Data([0x00, 0xFF, 0x00, 0x7F])
        let sealedJournal = Data([0xFF, 0x00, 0x01])
        let catalog = Data([0x00, 0x01, 0x00, 0xFE])
        let mac = Data(repeating: 0xAB, count: 32)
        try queue.write { db in
            try StoreTables.putHead(db, vaultID: TableFixtures.activeID, revision: 5, sealed: sealedHead)
            try StoreTables.putJournal(db, vaultID: TableFixtures.activeID, seq: 1, sealed: sealedJournal)
            try StoreTables.putJournal(db, vaultID: TableFixtures.activeID, seq: 2, sealed: Data([2]))
            try StoreTables.putRegistry(db, revision: 3, catalog: catalog, mac: mac)
        }
        try queue.read { db throws in
            let head = try #require(try StoreTables.head(db, vaultID: TableFixtures.activeID))
            #expect(head.revision == 5)
            #expect(head.sealed == sealedHead)
            #expect(try StoreTables.head(db, vaultID: TableFixtures.trashID) == nil)

            // `journal` has no reader in this layer; the stored bytes are checked directly.
            #expect(try Data.fetchOne(db, sql: "SELECT sealed FROM journal WHERE vaultID = ? AND seq = 1", arguments: [vaultKey]) == sealedJournal)
            #expect(try Data.fetchOne(db, sql: "SELECT sealed FROM journal WHERE vaultID = ? AND seq = 2", arguments: [vaultKey]) == Data([2]))

            let registry = try #require(try StoreTables.registry(db))
            #expect(registry.revision == 3)
            #expect(registry.catalog == catalog)
            #expect(registry.mac == mac)
        }

        // Commits rewrite the head and the registry row in place.
        let nextHead = Data([0x09])
        let nextCatalog = Data([0x08, 0x00])
        try queue.write { db in
            try StoreTables.putHead(db, vaultID: TableFixtures.activeID, revision: 6, sealed: nextHead)
            try StoreTables.putRegistry(db, revision: 4, catalog: nextCatalog, mac: Data(repeating: 0xCD, count: 32))
        }
        try queue.read { db throws in
            let head = try #require(try StoreTables.head(db, vaultID: TableFixtures.activeID))
            #expect(head.revision == 6)
            #expect(head.sealed == nextHead)
            let registry = try #require(try StoreTables.registry(db))
            #expect(registry.revision == 4)
            #expect(registry.catalog == nextCatalog)
            #expect(registry.mac == Data(repeating: 0xCD, count: 32))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM head") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM registry") == 1)
        }
    }

    // MARK: Untrusted-store boundary: neither direction may trap or wrap

    @Test func counterValuesBeyondSQLiteIntegerRangeAreRefusedNotWrapped() throws {
        let queue = try TableFixtures.makeQueue()
        let tooLarge = TableFixtures.tooLarge
        let largest = UInt64(Int64.max)
        let accepted = TableFixtures.record(record: 0x22, version: largest)
        try queue.write { db in
            try StoreTables.putRecord(db, accepted)
            try StoreTables.putHead(db, vaultID: TableFixtures.activeID, revision: largest, sealed: Data([1]))
        }
        try queue.read { db throws in
            #expect(try StoreTables.record(db, vaultID: accepted.vaultID, recordID: accepted.recordID) == accepted)
            #expect(try StoreTables.head(db, vaultID: TableFixtures.activeID)?.revision == largest)
        }

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try StoreTables.putRecord(db, TableFixtures.record(record: 0x23, version: tooLarge))
            }
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try StoreTables.putHead(db, vaultID: TableFixtures.activeID, revision: tooLarge, sealed: Data([2]))
            }
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try StoreTables.putJournal(db, vaultID: TableFixtures.activeID, seq: tooLarge, sealed: Data([3]))
            }
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try StoreTables.putRegistry(db, revision: tooLarge, catalog: Data([4]), mac: Data([5]))
            }
        }
        try queue.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record WHERE version < 0") == 0)
            #expect(try StoreTables.head(db, vaultID: TableFixtures.activeID)?.revision == largest)
            #expect(try StoreTables.registry(db) == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal") == 0)
        }
    }

    @Test func undecodableStoredValuesThrowOnReadInsteadOfTrapping() throws {
        let queue = try TableFixtures.makeQueue()
        let badSubject = TableFixtures.id(0x41)
        let badOwner = TableFixtures.id(0x42)
        let negativeVersion = TableFixtures.id(0x43)
        try queue.write { db in
            try TableFixtures.rawRecord(db, record: badSubject.uuidString.lowercased(), subject: "zzz")
            try TableFixtures.rawRecord(db, record: badOwner.uuidString.lowercased(), owner: "not-a-uuid")
            try TableFixtures.rawRecord(db, record: negativeVersion.uuidString.lowercased(), version: -1)
            try db.execute(sql: "INSERT INTO head(vaultID, revision, sealed) VALUES (?, -1, x'00')", arguments: [TableFixtures.trashID.uuidString.lowercased()])
        }
        try queue.read { db in
            for recordID in [badSubject, badOwner, negativeVersion] {
                #expect(throws: (any Error).self) {
                    try StoreTables.record(db, vaultID: TableFixtures.activeID, recordID: recordID)
                }
            }
            #expect(throws: (any Error).self) {
                try StoreTables.head(db, vaultID: TableFixtures.trashID)
            }
        }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO vault(vaultID, role, ordinal, createdAt, wrappers, keyWrap) VALUES ('not-a-uuid', 'active', 9, 0.0, NULL, NULL)")
        }
        try queue.read { db in
            #expect(throws: (any Error).self) {
                try StoreTables.vaultRows(db)
            }
        }
    }

    /// SQLite stores whatever class it is given when the value cannot convert losslessly, so a hostile file can hold TEXT or a
    /// fractional REAL in an INTEGER column. Such values must throw, not be coerced to 0 or truncated to 1.
    @Test func wrongStorageClassesThrowInsteadOfBeingCoerced() throws {
        let queue = try TableFixtures.makeQueue()
        let textVersion = TableFixtures.id(0x44)
        let realVersion = TableFixtures.id(0x45)
        let vaultKey = TableFixtures.activeID.uuidString.lowercased()
        try queue.write { db in
            try db.execute(sql: "UPDATE vault SET createdAt = 'abc' WHERE vaultID = ?", arguments: [TableFixtures.trashID.uuidString.lowercased()])
            try TableFixtures.rawRecord(db, record: textVersion.uuidString.lowercased())
            try db.execute(sql: "UPDATE record SET version = 'abc' WHERE recordID = ?", arguments: [textVersion.uuidString.lowercased()])
            try TableFixtures.rawRecord(db, record: realVersion.uuidString.lowercased())
            try db.execute(sql: "UPDATE record SET version = 1.5 WHERE recordID = ?", arguments: [realVersion.uuidString.lowercased()])
            try db.execute(sql: "INSERT INTO head(vaultID, revision, sealed) VALUES (?, 1.5, x'00')", arguments: [vaultKey])
            try db.execute(sql: "INSERT INTO registry(id, revision, catalog, mac) VALUES (1, 'abc', x'00', x'00')")
        }
        try queue.read { db throws in
            #expect(try String.fetchOne(db, sql: "SELECT typeof(version) FROM record WHERE recordID = ?", arguments: [textVersion.uuidString.lowercased()]) == "text")
            #expect(try String.fetchOne(db, sql: "SELECT typeof(version) FROM record WHERE recordID = ?", arguments: [realVersion.uuidString.lowercased()]) == "real")
            #expect(try String.fetchOne(db, sql: "SELECT typeof(revision) FROM head") == "real")
            #expect(try String.fetchOne(db, sql: "SELECT typeof(revision) FROM registry") == "text")
            #expect(try String.fetchOne(db, sql: "SELECT typeof(createdAt) FROM vault WHERE role = 'trash'") == "text")

            for recordID in [textVersion, realVersion] {
                #expect(throws: CredentialStoreError.malformed) {
                    try StoreTables.record(db, vaultID: TableFixtures.activeID, recordID: recordID)
                }
            }
            #expect(throws: CredentialStoreError.malformed) {
                try StoreTables.head(db, vaultID: TableFixtures.activeID)
            }
            #expect(throws: CredentialStoreError.malformed) {
                try StoreTables.registry(db)
            }
            #expect(throws: CredentialStoreError.malformed) {
                try StoreTables.vaultRows(db)
            }
        }
    }
}
