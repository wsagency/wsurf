// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

/// Spec §7 verification V1-V5 of one source vault and its linked Trash, run on the caller's connection inside the caller's
/// deferred snapshot with `VerificationScratch`'s ledger tables attached. Every main-database read is a `SELECT`; every write
/// goes to `scratch.*`. Rows are streamed one at a time, so memory is one row plus SQLite's page cache.
///
/// The heads are the ones the caller already opened and authenticated (§6.8 steps 2 and 4, same snapshot): nothing here
/// re-opens a head, and `StoreSeal.openHead` has already enforced the §7 blocked-origin policy on them.
///
/// Any failure other than cancellation, including a SQLite error while streaming, is `integrityFailure` for the source vault.
nonisolated struct StoreVerifier: Sendable {
    typealias Vault = (id: UUID, key: SymmetricKey, head: VaultHead)

    let ids: StoreIDs

    private nonisolated struct Violation: Error {}

    private static func poll(_ isCancelled: () -> Bool) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }

    func verify(in db: Database, source: Vault, trash: Vault, isCancelled: () -> Bool) throws {
        do {
            try checkHeads(db, source: source, trash: trash)
            try checkLive(db, source, isCancelled)
            try checkLive(db, trash, isCancelled)
            try checkJournal(db, source, ledger: 0, isCancelled)
            try checkHistory(db, source, ledger: 0, isCancelled)
            try checkJournal(db, trash, ledger: 1, isCancelled)
            try checkHistory(db, trash, ledger: 1, isCancelled)
            try checkTransfers(db)
        } catch let error as CancellationError {
            throw error
        } catch {
            let ordinal = (try? StoreTables.vaultRows(db))?.first { $0.vaultID == source.id }?.ordinal
            throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)
        }
    }

    // MARK: V1

    private func checkHeads(_ db: Database, source: Vault, trash: Vault) throws {
        let rows = try StoreTables.vaultRows(db)
        for (vault, role) in [(source, VaultRole.active), (trash, VaultRole.trash)] {
            let head = vault.head
            guard head.ids == ids, head.vaultID == vault.id, head.role == role,
                rows.first(where: { $0.vaultID == vault.id })?.role == role,
                try StoreTables.head(db, vaultID: vault.id)?.revision == head.revision
            else { throw Violation() }
        }
        guard source.head.link.peerVaultID == trash.id, trash.head.link.peerVaultID == source.id,
            source.head.link.nonce == trash.head.link.nonce
        else { throw Violation() }
    }

    // MARK: V2

    private func checkLive(_ db: Database, _ vault: Vault, _ isCancelled: () -> Bool) throws {
        for entry in vault.head.liveCatalog {
            try Self.poll(isCancelled)
            guard let row = try StoreTables.record(db, vaultID: vault.id, recordID: entry.recordID),
                row.kind == .account, row.version == entry.version, StoreSeal.digest(row.sealed) == entry.digest
            else { throw Violation() }
            try open(row, vault)
        }
        guard try StoreTables.recordCount(db, vaultID: vault.id, kind: .account) == vault.head.liveCatalog.count else {
            throw Violation()
        }
    }

    /// Decrypts once and discards the plaintext: verifies the tag and the AAD fields (`kind`, `ownerID`, `subject`, `version`).
    private func open(_ row: StoreTables.RecordRow, _ vault: Vault) throws {
        let aad = RowAAD(
            ids: ids, vaultID: vault.id, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject,
            version: row.version
        )
        _ = try StoreSeal.openRow(row.sealed, key: vault.key, aad: aad)
    }

    // MARK: V3, V4 ledger, V5 collection

    /// `ledger` is the scratch `side`: 0 for the source vault, 1 for its Trash.
    private func checkJournal(_ db: Database, _ vault: Vault, ledger: Int, _ isCancelled: () -> Bool) throws {
        var count: UInt64 = 0
        var chain = Data(count: 32)
        var transfer: TransferHeader?  // the transfer group the previous journal row belongs to
        try StoreTables.forEachJournal(db, vaultID: vault.id) { seq, sealed in
            try Self.poll(isCancelled)
            guard seq == count + 1 else { throw Violation() }
            let row = try StoreSeal.openJournal(sealed, key: vault.key, ids: ids, vaultID: vault.id, seq: seq)
            guard row.seq == seq, row.prevChain == chain else { throw Violation() }
            chain = StoreSeal.chain(chain, sealed: sealed)
            count = seq

            if let header = row.transfer {
                if header == transfer {
                    // A group spans several rows only when it is chunked; an empty continuation moves nothing and is forged.
                    guard !row.ops.isEmpty else { throw Violation() }
                } else {
                    // A transferID that reappears later on the same side hits the primary key.
                    try db.cachedStatement(
                        sql: """
                            INSERT INTO scratch.transfers(transferID, side, direction, scope, ownerID, subject, liveRecordID, liveVersion, entryRecordID)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """
                    ).execute(arguments: [
                        header.transferID, ledger, Int(header.direction.rawValue), Int(header.scope.rawValue), header.ownerID,
                        Int(header.subject?.rawValue ?? 0), header.liveRecordID, try bind(header.liveVersion), header.entryRecordID,
                    ])
                }
            }
            transfer = row.transfer

            for op in row.ops {
                if let header = row.transfer {
                    // An `out` group only removes rows from this side, an `in` group only adds.
                    guard op.op == (header.direction == .out ? .remove : .add) else { throw Violation() }
                    try db.cachedStatement(
                        sql: """
                            INSERT INTO scratch.transferRows(transferID, side, recordID, kind, ownerID, subject, version)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """
                    ).execute(arguments: [
                        header.transferID, ledger, op.recordID, Int(op.kind.rawValue), op.ownerID, Int(op.subject.rawValue),
                        try bind(op.version),
                    ])
                }
                switch op.op {
                case .add:
                    try db.cachedStatement(
                        sql: """
                            INSERT INTO scratch.expected(side, recordID, kind, ownerID, subject, version, rowDigest)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """
                    ).execute(arguments: ledgerArguments(op, ledger))
                case .remove:
                    try db.cachedStatement(
                        sql: """
                            DELETE FROM scratch.expected
                            WHERE side = ? AND recordID = ? AND kind = ? AND ownerID = ? AND subject = ? AND version = ? AND rowDigest = ?
                            """
                    ).execute(arguments: ledgerArguments(op, ledger))
                    guard db.changesCount == 1 else { throw Violation() }
                }
            }
        }
        guard count == vault.head.journalSeq, chain == vault.head.chainTip else { throw Violation() }
    }

    private func ledgerArguments(_ op: JournalOp, _ ledger: Int) throws -> StatementArguments {
        [ledger, op.recordID, Int(op.kind.rawValue), op.ownerID, Int(op.subject.rawValue), try bind(op.version), op.rowDigest]
    }

    // MARK: V4 history

    private func checkHistory(_ db: Database, _ vault: Vault, ledger: Int, _ isCancelled: () -> Bool) throws {
        let mark = try db.cachedStatement(
            sql: """
                UPDATE scratch.expected SET seen = 1
                WHERE side = ? AND recordID = ? AND kind = ? AND ownerID = ? AND subject = ? AND version = ? AND rowDigest = ? AND seen = 0
                """
        )
        try StoreTables.forEachHistoryRecord(db, vaultID: vault.id) { row in
            try Self.poll(isCancelled)
            try mark.execute(arguments: [
                ledger, row.recordID, Int(row.kind.rawValue), row.ownerID, Int(row.subject.rawValue), try bind(row.version),
                StoreSeal.digest(row.sealed),
            ])
            guard db.changesCount == 1 else { throw Violation() }
            try open(row, vault)
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scratch.expected WHERE side = ? AND seen = 0", arguments: [ledger]) == 0 else {
            throw Violation()
        }
        let counts = vault.head.historyCounts
        for (kind, expected) in [(RecordKind.revision, counts.revision), (.trashEntry, counts.trashEntry), (.tombstone, counts.tombstone)] {
            let ledgerCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM scratch.expected WHERE side = ? AND kind = ?", arguments: [ledger, Int(kind.rawValue)]
            )
            guard ledgerCount == expected else { throw Violation() }
        }
    }

    // MARK: V5

    /// Historical only: compares the journalled transfer groups with each other, never with the current catalogs.
    private func checkTransfers(_ db: Database) throws {
        let entryKind: StatementArguments = ["kind": Int(RecordKind.trashEntry.rawValue)]
        // Exactly one `out` and one `in` group per transferID, one on each side, with identical headers.
        try expectNoRow(
            db,
            """
            SELECT 1 FROM scratch.transfers a LEFT JOIN scratch.transfers b ON b.transferID = a.transferID AND b.side = 1 - a.side
            WHERE b.transferID IS NULL OR a.direction = b.direction OR a.scope != b.scope OR a.ownerID != b.ownerID
               OR a.subject != b.subject OR a.liveRecordID != b.liveRecordID OR a.liveVersion != b.liveVersion
               OR a.entryRecordID != b.entryRecordID
            LIMIT 1
            """
        )
        // The moved set removed on one side equals the one added on the other, `trashEntry` excluded, digests never compared.
        try expectNoRow(
            db,
            """
            SELECT 1 FROM scratch.transferRows a WHERE a.kind != :kind AND NOT EXISTS (
                SELECT 1 FROM scratch.transferRows b
                WHERE b.transferID = a.transferID AND b.side = 1 - a.side AND b.recordID = a.recordID AND b.kind = a.kind
                  AND b.ownerID = a.ownerID AND b.subject = a.subject AND b.version = a.version)
            LIMIT 1
            """,
            entryKind
        )
        // The `trashEntry` row appears on the Trash side only, exactly once, and is the header's `entryRecordID`.
        try expectNoRow(
            db,
            """
            SELECT 1 FROM scratch.transfers t WHERE
                (SELECT COUNT(*) FROM scratch.transferRows r WHERE r.transferID = t.transferID AND r.side = 0 AND r.kind = :kind) != 0
             OR (SELECT COUNT(*) FROM scratch.transferRows r WHERE r.transferID = t.transferID AND r.side = 1 AND r.kind = :kind) != 1
             OR NOT EXISTS (SELECT 1 FROM scratch.transferRows r
                            WHERE r.transferID = t.transferID AND r.side = 1 AND r.kind = :kind AND r.recordID = t.entryRecordID)
            LIMIT 1
            """,
            entryKind
        )
    }

    private func expectNoRow(_ db: Database, _ sql: String, _ arguments: StatementArguments = StatementArguments()) throws {
        guard try Int.fetchOne(db, sql: sql, arguments: arguments) == nil else { throw Violation() }
    }

    private func bind(_ counter: UInt64) throws -> Int64 {
        guard let value = Int64(exactly: counter) else { throw Violation() }
        return value
    }
}
