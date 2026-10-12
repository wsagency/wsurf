// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB

nonisolated struct PurgeReceipt: Equatable, Sendable {
    let removedEntries: Int
    let revision: UInt64
}

/// §11.4: a logical row purge, not secure erasure. Explicit only, and only on a fresh assertion of an enrolled credential: a cached
/// grant alone never purges. One store transaction (never the ordinary commit, never the wrappers): each selected Trash entry and its
/// revision rows are deleted and replaced by non-secret tombstones, journalled `remove`/`add`. Logical capacity never blocks it.
extension ProfileVaultStore {
    /// `emptyAll` purges every entry (`entryIDs` is then ignored). An unknown id is `invalidData` with nothing written; nothing to
    /// purge writes nothing. `.diskFull` leaves the logical state unchanged.
    func purge(
        vaultID: UUID, entryIDs: [UUID], emptyAll: Bool, authorization: FreshAuthorization, using access: VaultAccess
    ) async throws -> PurgeReceipt {
        try await authorize(vaultID: vaultID, authorization, using: access)
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: nil, cause: nil, isCommit: false)
        var seen = Set<UUID>()
        let requested = emptyAll ? nil : entryIDs.filter { seen.insert($0).inserted }
        var removed = 0
        let outcome = try await run(intent, ledgerOnDemand: false, checkpoint: true) { db, request, _ in
            let result = try Self.purging(db, request, requested: requested)
            removed = result.removed
            return result.outcome
        }
        return PurgeReceipt(removedEntries: removed, revision: outcome.receipt.revision)
    }

    /// The write transaction's body (`ledgerAttached` is always true: a purge removes history). Nothing purged writes nothing.
    nonisolated static func purging(
        _ db: Database, _ request: CommitRequest, requested: [UUID]?
    ) throws -> (outcome: CommitOutcome, removed: Int) {
        let (transaction, _) = try begin(db, request)
        try transaction.verifyHistories()
        let removed = try transaction.purge(requested)
        guard removed > 0 else {
            return (CommitOutcome(receipt: VaultCommitReceipt(revision: transaction.opened.head.revision), entry: nil, trashEntry: nil), 0)
        }
        return (try transaction.finish(), removed)
    }
}

nonisolated extension CommitTransaction {
    /// Purges `requested` entries, or every entry when `nil`; returns how many. Runs after `verifyHistories`, so the clear columns the
    /// revision walk selects by are the ones the Trash journal expects.
    func purge(_ requested: [UUID]?) throws -> Int {
        guard var trashState = trash else { throw integrity }
        var group = JournalGroup(transfer: nil)
        var purged = 0
        if let requested {
            for id in requested {
                try Task.checkCancellation()
                try purgeEntry(try trashEntry(id), state: &trashState, group: &group)
                purged += 1
            }
        } else {
            var after: UUID?
            while let id = try nextEntryID(in: trashState.side.vaultID, after: after) {
                try Task.checkCancellation()
                after = id
                try purgeEntry(try trashEntry(id), state: &trashState, group: &group)
                purged += 1
            }
        }
        try group.finish(&trashState.side, db: db, ids: ids)
        trash = trashState
        return purged
    }

    private func purgeEntry(_ entry: StoredTrashEntry, state: inout TrashState, group: inout JournalGroup) throws {
        let vaultID = state.side.vaultID
        let body = entry.body
        for tombstone in Self.tombstones(of: body, entryID: entry.row.recordID, at: wall) {
            let aad = RowAAD(
                ids: ids, vaultID: vaultID, recordID: UUID(), kind: .tombstone, ownerID: body.ownerID, subject: body.subject ?? .account, version: 1
            )
            let plaintext = try CredentialContent.canonicalJSON(tombstone)
            guard plaintext.count <= StoreFormat.historyRowBytes else { throw CredentialStoreError.limit(.historyRow) }
            try group.add(try putSealed(plaintext, aad: aad, key: state.side.key), to: &state.side, db: db, ids: ids)
            state.side.counts.tombstone += 1
        }

        let entryAAD = RowAAD(
            ids: ids, vaultID: vaultID, recordID: entry.row.recordID, kind: .trashEntry, ownerID: entry.row.ownerID, subject: entry.row.subject,
            version: entry.row.version
        )
        try StoreTables.deleteRecord(db, vaultID: vaultID, recordID: entry.row.recordID)
        state.side.counts.trashEntry -= 1
        try group.add(JournalOp(entryAAD, op: .remove, rowDigest: StoreSeal.digest(entry.row.sealed)), to: &state.side, db: db, ids: ids)

        var after: UUID?
        while let row = try mapIntegrity(grant.ordinal, {
            try StoreTables.nextOwnedRevision(db, vaultID: vaultID, ownerID: body.ownerID, subject: body.subject, after: after)
        }) {
            try Task.checkCancellation()
            after = row.recordID
            let aad = RowAAD(
                ids: ids, vaultID: vaultID, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject, version: row.version
            )
            try StoreTables.deleteRecord(db, vaultID: vaultID, recordID: row.recordID)
            state.side.counts.revision -= 1
            try group.add(JournalOp(aad, op: .remove, rowDigest: StoreSeal.digest(row.sealed)), to: &state.side, db: db, ids: ids)
        }
    }

    /// What survives: identity only. A whole account leaves one account-level tombstone and one per passkey (each carries one
    /// `credentialID`); a credential leaves one. No password, TOTP seed or key material is copied.
    private static func tombstones(of body: TrashEntryBody, entryID: UUID, at date: Date) -> [TombstoneBody] {
        func tombstone(accountID: Data?, itemID: Data?, passkey: WebsitePasskey?) -> TombstoneBody {
            TombstoneBody(
                entryID: entryID, purgedAt: date, scope: body.scope, ownerID: body.ownerID, subject: body.subject,
                passkeyCredentialID: passkey?.credentialID, rpID: passkey?.rpID, exchangeAccountID: accountID, exchangeItemID: itemID
            )
        }
        if let snapshot = body.snapshot {
            let ids = (snapshot.exchangeAccountID, snapshot.exchangeItemID)
            return [tombstone(accountID: ids.0, itemID: ids.1, passkey: nil)]
                + snapshot.passkeys.map { tombstone(accountID: ids.0, itemID: ids.1, passkey: $0) }
        }
        let passkey = body.subject == .passkey ? body.credentialValue.flatMap { try? JSONDecoder().decode(WebsitePasskey.self, from: $0) } : nil
        return [tombstone(accountID: body.exchangeAccountID, itemID: body.exchangeItemID, passkey: passkey)]
    }

    /// The next `trashEntry` id after `previous` in `recordID` order: one statement, finished before the caller deletes.
    private func nextEntryID(in vaultID: UUID, after previous: UUID?) throws -> UUID? {
        try mapIntegrity(grant.ordinal) {
            let sql = "SELECT recordID FROM record WHERE vaultID = ? AND kind = ? AND recordID > ? ORDER BY recordID LIMIT 1"
            let arguments: StatementArguments = [vaultID.uuidString.lowercased(), RecordKind.trashEntry.sqlName, previous?.uuidString.lowercased() ?? ""]
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
            guard case .string(let text) = (row[0] as DatabaseValue).storage, let id = UUID(uuidString: text), id.uuidString.lowercased() == text else {
                throw CredentialStoreError.malformed
            }
            return id
        }
    }
}
