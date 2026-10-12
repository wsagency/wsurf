// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import WSurf

extension Testing.Tag {  // qualified: the app module declares its own `struct Tag: View` (Settings/SettingsPrimitives.swift)
    /// Slow, Pro-only measurements. Also gated by `WSURF_VAULT_BENCHMARK=1` (pass it as `TEST_RUNNER_WSURF_VAULT_BENCHMARK=1`).
    @Testing.Tag static var benchmark: Self
}

nonisolated extension UUID {
    /// The canonical lower-case spelling the store writes into SQL text columns (raw SQL in tests must use it).
    var lowerText: String {
        uuidString.lowercased()
    }
}

/// A complete, valid §5 store written through the Task 3 layers only (`StoreTables`, `StoreSeal`, the record types), with a
/// real source vault and its linked Trash vault: sealed live rows, history rows, sealed heads, hash-chained journals that
/// reproduce every history row and every MOVE pair, and the registry. Nothing here uses the code under test.
///
/// Layout (the tamper tests rely on it):
/// - Both vaults have ordinal 1 and head revision 2. The wrappers of the source vault are opaque bytes (Task 5 never opens
///   them), the Trash vault holds a real key wrap of `trashDEK` under `dek`.
/// - `accounts` are live rows (`recordID == account.id`, version `accountVersion`).
/// - `historyRows` are `.revision` rows owned by `accounts[0]` (subject `.password`, version `index + 1`), journalled in
///   the source journal (chunks of at most 1,000 ops, no transfer header).
/// - Each of `moves` alternates delete (source → Trash) and undelete (Trash → source) of `accounts[0]`, moving every
///   `.revision` row it owns: re-sealed under the other DEK and vault id, same `recordID`, `ownerID`, `subject` and origin
///   `version`, a `trashEntry` row on the Trash side, and one `transfer` header per journal row on both sides (a group
///   larger than 1,000 ops spans several rows that carry the same header).
nonisolated struct VaultStoreFixture {
    nonisolated struct HeadDigests {
        let wrappers: Data
        let keyWrap: Data
    }

    static let accountVersion: UInt64 = 2

    let env: VaultTestEnvironment
    let ids: StoreIDs
    let storeURL: URL
    let vaultID: UUID
    let trashID: UUID
    let dek: SymmetricKey
    let trashDEK: SymmetricKey
    let registryKey: Data
    let proof: VaultUnlockProof
    let accounts: [CredentialAccount]
    let sourceDigests: HeadDigests
    let trashDigests: HeadDigests
    /// The heads as currently stored: `editHead` keeps them in step with the file, raw tampering does not.
    private(set) var sourceHead: VaultHead
    private(set) var trashHead: VaultHead

    var directory: URL {
        env.directory
    }

    // MARK: Build

    static func make(
        accounts: [CredentialAccount] = [],
        blockedOrigins: [String] = [],
        historyRows: Int = 0,
        historyRowBytes: Int = 32,
        moves: Int = 0,
        vaultName: String = "Personal"
    ) throws -> VaultStoreFixture {
        precondition(moves == 0 || !accounts.isEmpty, "a MOVE needs an account")
        let env = try VaultTestEnvironment.make()
        let ids = StoreIDs(storeID: UUID(), profileID: env.profile.id)
        let storeURL = env.directory.appendingPathComponent("Credentials.store")
        let vaultID = UUID(), trashID = UUID()
        let dek = SymmetricKey(size: .bits256), trashDEK = SymmetricKey(size: .bits256)
        let registryKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let wrappers = Data("fixture wrapper list".utf8)
        let keyWrap = try StoreSeal.wrapTrashKey(trashDEK, under: dek, ids: ids, source: vaultID, trash: trashID, nonce: nonce)
        let sourceDigests = HeadDigests(wrappers: StoreSeal.digest(wrappers), keyWrap: StoreSeal.digestOrZero(nil))
        let trashDigests = HeadDigests(wrappers: StoreSeal.digestOrZero(nil), keyWrap: StoreSeal.digest(keyWrap))
        let created = Date(timeIntervalSinceReferenceDate: 1_000)

        let pool = try DatabasePool(path: storeURL.path)
        let heads = try pool.write { db -> (VaultHead, VaultHead) in
            try StoreTables.create(in: db, ids: ids)
            try StoreTables.insertVault(
                db, StoreTables.VaultRow(vaultID: vaultID, role: .active, ordinal: 1, createdAt: created, wrappers: wrappers, keyWrap: nil)
            )
            try StoreTables.insertVault(
                db, StoreTables.VaultRow(vaultID: trashID, role: .trash, ordinal: 1, createdAt: created, wrappers: nil, keyWrap: keyWrap)
            )
            let builder = Builder(
                db: db, ids: ids, rowBytes: historyRowBytes, sides: [Side(id: vaultID, key: dek), Side(id: trashID, key: trashDEK)]
            )
            for account in accounts {
                try builder.putLive(account)
            }
            try builder.addHistory(count: historyRows, owner: accounts.first?.id ?? UUID())
            for index in 0..<moves {
                try builder.move(accounts[0], delete: index % 2 == 0)
            }
            let link = VaultLink(peerVaultID: trashID, nonce: nonce)
            let source = builder.head(
                0, role: .active, name: vaultName, registryKey: registryKey, blockedOrigins: blockedOrigins, link: link
            )
            let trash = builder.head(
                1, role: .trash, name: "Trash", registryKey: nil, blockedOrigins: [], link: VaultLink(peerVaultID: vaultID, nonce: nonce)
            )
            let sealedSource = try StoreSeal.sealHead(source, key: dek, wrappersDigest: sourceDigests.wrappers, keyWrapDigest: sourceDigests.keyWrap)
            let sealedTrash = try StoreSeal.sealHead(trash, key: trashDEK, wrappersDigest: trashDigests.wrappers, keyWrapDigest: trashDigests.keyWrap)
            try StoreTables.putHead(db, vaultID: vaultID, revision: source.revision, sealed: sealedSource)
            try StoreTables.putHead(db, vaultID: trashID, revision: trash.revision, sealed: sealedTrash)
            let catalog = RegistryCatalog(
                ids: ids,
                revision: 1,
                vaults: [
                    RegistryEntry(
                        vaultID: vaultID, role: .active, ordinal: 1, createdAt: created, wrappersDigest: sourceDigests.wrappers,
                        keyWrapDigest: sourceDigests.keyWrap, headRevision: source.revision, headDigest: StoreSeal.digest(sealedSource)
                    ),
                    RegistryEntry(
                        vaultID: trashID, role: .trash, ordinal: 1, createdAt: created, wrappersDigest: trashDigests.wrappers,
                        keyWrapDigest: trashDigests.keyWrap, headRevision: trash.revision, headDigest: StoreSeal.digest(sealedTrash)
                    ),
                ]
            ).encode()
            try StoreTables.putRegistry(db, revision: 1, catalog: catalog, mac: StoreSeal.registryMAC(rk: registryKey, catalog: catalog))
            return (source, trash)
        }
        return VaultStoreFixture(
            env: env,
            ids: ids,
            storeURL: storeURL,
            vaultID: vaultID,
            trashID: trashID,
            dek: dek,
            trashDEK: trashDEK,
            registryKey: registryKey,
            proof: VaultFixtures.proof(),
            accounts: accounts,
            sourceDigests: sourceDigests,
            trashDigests: trashDigests,
            sourceHead: heads.0,
            trashHead: heads.1
        )
    }

    // MARK: Raw access

    /// Raw tamper access on a short-lived connection (one write transaction).
    func mutate(_ body: (Database) throws -> Void) throws {
        try DatabaseQueue(path: storeURL.path).write(body)
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try DatabaseQueue(path: storeURL.path).read(body)
    }

    /// A pool on the store file: the "serialized synchronous connection" `VerificationScratch.run` is handed.
    func openWriter() throws -> DatabasePool {
        try DatabasePool(path: storeURL.path)
    }

    func key(of vault: UUID) -> SymmetricKey {
        vault == vaultID ? dek : trashDEK
    }

    func head(of vault: UUID) -> VaultHead {
        vault == vaultID ? sourceHead : trashHead
    }

    func digests(of vault: UUID) -> HeadDigests {
        vault == vaultID ? sourceDigests : trashDigests
    }

    func storedRecord(_ vault: UUID, _ recordID: UUID) throws -> StoreTables.RecordRow {
        try #require(try read { try StoreTables.record($0, vaultID: vault, recordID: recordID) })
    }

    func recordIDs(of vault: UUID, kind: RecordKind) throws -> [UUID] {
        try read { db in
            try String.fetchAll(
                db,
                sql: "SELECT recordID FROM record WHERE vaultID = ? AND kind = ? ORDER BY recordID",
                arguments: [vault.lowerText, kind.sqlName]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    func journalRows(of vault: UUID) throws -> [JournalRow] {
        let stored = try read { db in
            try Row.fetchAll(db, sql: "SELECT seq, sealed FROM journal WHERE vaultID = ? ORDER BY seq", arguments: [vault.lowerText]).map { row -> (Int64, Data) in
                let seq: Int64 = row["seq"]
                let sealed: Data = row["sealed"]
                return (seq, sealed)
            }
        }
        return try stored.map { try StoreSeal.openJournal($0.1, key: key(of: vault), ids: ids, vaultID: vault, seq: UInt64($0.0)) }
    }

    // MARK: Heads and journals

    /// Seals `plaintext` as this vault's head for `revision`: validly authenticated, no policy check.
    func sealHeadPlaintext(_ plaintext: Data, vault: UUID, revision: UInt64) throws -> Data {
        try StoreSeal.sealHeadPlaintext(
            plaintext,
            key: key(of: vault),
            ids: ids,
            vaultID: vault,
            revision: revision,
            wrappersDigest: digests(of: vault).wrappers,
            keyWrapDigest: digests(of: vault).keyWrap
        )
    }

    func putHead(_ sealed: Data, vault: UUID, revision: UInt64) throws {
        try mutate { try StoreTables.putHead($0, vaultID: vault, revision: revision, sealed: sealed) }
    }

    /// A legitimately re-sealed head (policy checked) stored under its own revision. The registry is deliberately left as
    /// built (Task 5 does not read it).
    mutating func editHead(_ vault: UUID, _ edit: (inout VaultHead) -> Void) throws {
        var edited = head(of: vault)
        edit(&edited)
        let sealed = try StoreSeal.sealHead(
            edited, key: key(of: vault), wrappersDigest: digests(of: vault).wrappers, keyWrapDigest: digests(of: vault).keyWrap
        )
        try putHead(sealed, vault: vault, revision: edited.revision)
        if vault == vaultID {
            sourceHead = edited
        } else {
            trashHead = edited
        }
    }

    /// Decrypts the vault's journal, applies `transform`, then renumbers, re-chains and re-seals every row, stores them and
    /// updates the head's `journalSeq`/`chainTip`: a journal that is internally consistent but says something false.
    mutating func rewriteJournal(of vault: UUID, _ transform: (inout [JournalRow]) -> Void) throws {
        var rows = try journalRows(of: vault)
        transform(&rows)
        var chain = Data(count: 32)
        var sealedRows: [Data] = []
        for index in rows.indices {
            rows[index].seq = UInt64(index + 1)
            rows[index].prevChain = chain
            let sealed = try StoreSeal.sealJournal(rows[index], key: key(of: vault), ids: ids, vaultID: vault)
            sealedRows.append(sealed)
            chain = StoreSeal.chain(chain, sealed: sealed)
        }
        try mutate { db in
            try db.execute(sql: "DELETE FROM journal WHERE vaultID = ?", arguments: [vault.lowerText])
            for (index, sealed) in sealedRows.enumerated() {
                try StoreTables.putJournal(db, vaultID: vault, seq: UInt64(index + 1), sealed: sealed)
            }
        }
        let tip = chain, count = UInt64(rows.count)
        try editHead(vault) {
            $0.journalSeq = count
            $0.chainTip = tip
        }
    }

    // MARK: Verification

    /// What Task 6 does at §6.8 steps 2 and 4: loads each stored head inside the snapshot and opens it with the real
    /// `StoreSeal.openHead` (AAD revision = the stored column), so the verifier receives authenticated heads. A head that
    /// does not open (AEAD or decode failure) throws that error here: that class belongs to the Task 3 seal tests and Task 6's
    /// public unlock tests, not to the verifier.
    func openStoredHeads(in db: Database) throws -> (source: VaultHead, trash: VaultHead) {
        func open(_ vault: UUID) throws -> VaultHead {
            let stored = try #require(try StoreTables.head(db, vaultID: vault))
            return try StoreSeal.openHead(
                stored.sealed,
                key: key(of: vault),
                ids: ids,
                vaultID: vault,
                revision: stored.revision,
                wrappersDigest: digests(of: vault).wrappers,
                keyWrapDigest: digests(of: vault).keyWrap
            )
        }
        return (try open(vaultID), try open(trashID))
    }

    /// V1-V5 for the fixture's pair inside the caller's snapshot (`db` is the connection `VerificationScratch.run` hands to `body`).
    func verify(in db: Database, isCancelled: () -> Bool = { false }) throws {
        let heads = try openStoredHeads(in: db)
        try StoreVerifier(ids: ids).verify(
            in: db,
            source: (id: vaultID, key: dek, head: heads.source),
            trash: (id: trashID, key: trashDEK, head: heads.trash),
            isCancelled: isCancelled
        )
    }

    /// The whole lifecycle: a fresh writer, scratch created, verified, removed.
    func verify(isCancelled: () -> Bool = { false }) throws {
        let writer = try openWriter()
        try VerificationScratch.run(on: writer, supportDirectory: directory, cleanupFailed: { _ in }) { db in
            try verify(in: db, isCancelled: isCancelled)
        }
    }

    // MARK: Sealing helpers

    static func sealAccount(_ account: CredentialAccount, ids: StoreIDs, vaultID: UUID, key: SymmetricKey, version: UInt64 = accountVersion) throws -> Data {
        try StoreSeal.sealRow(
            try VaultFixtures.sortedJSON(account),
            key: key,
            aad: RowAAD(ids: ids, vaultID: vaultID, recordID: account.id, kind: .account, ownerID: account.id, subject: .account, version: version)
        )
    }

    static func sealHistory(_ row: StoreTables.RecordRow, ids: StoreIDs, key: SymmetricKey, plaintext: Data = Data(repeating: 0x5A, count: 32)) throws -> Data {
        try StoreSeal.sealRow(
            plaintext,
            key: key,
            aad: RowAAD(ids: ids, vaultID: row.vaultID, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject, version: row.version)
        )
    }

    static func flipped(_ data: Data) -> Data {
        var copy = data
        copy[copy.endIndex - 1] ^= 0x01
        return copy
    }
}

// MARK: - Builder

private nonisolated struct HistoryRow {
    var recordID: UUID
    var kind: RecordKind
    var ownerID: UUID
    var subject: RecordSubject
    var version: UInt64
}

private nonisolated struct Side {
    let id: UUID
    let key: SymmetricKey
    var seq: UInt64 = 0
    var chain = Data(count: 32)
    var live: [UUID: LiveEntry] = [:]
    var history: [HistoryRow] = []
    var counts = HistoryCounts()
}

/// Writes rows, journal rows and counters in step, one side (0 = source, 1 = Trash) at a time.
private nonisolated final class Builder {
    let db: Database
    let ids: StoreIDs
    let rowBytes: Int
    var sides: [Side]
    var entries: [UUID: UUID] = [:]  // account id -> its current trashEntry record id

    init(db: Database, ids: StoreIDs, rowBytes: Int, sides: [Side]) {
        self.db = db
        self.ids = ids
        self.rowBytes = rowBytes
        self.sides = sides
    }

    func aad(_ side: Int, _ row: HistoryRow) -> RowAAD {
        RowAAD(ids: ids, vaultID: sides[side].id, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject, version: row.version)
    }

    func adjust(_ side: Int, _ kind: RecordKind, by delta: Int) {
        switch kind {
        case .revision:
            sides[side].counts.revision += delta
        case .trashEntry:
            sides[side].counts.trashEntry += delta
        case .tombstone:
            sides[side].counts.tombstone += delta
        case .account:
            break
        }
    }

    func op(_ kind: JournalOpKind, _ row: HistoryRow, sealed: Data) -> JournalOp {
        JournalOp(op: kind, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject, version: row.version, rowDigest: StoreSeal.digest(sealed))
    }

    func putLive(_ account: CredentialAccount) throws {
        let sealed = try VaultStoreFixture.sealAccount(account, ids: ids, vaultID: sides[0].id, key: sides[0].key)
        try StoreTables.putRecord(
            db,
            StoreTables.RecordRow(
                vaultID: sides[0].id, recordID: account.id, kind: .account, ownerID: account.id, subject: .account,
                version: VaultStoreFixture.accountVersion, sealed: sealed
            )
        )
        sides[0].live[account.id] = LiveEntry(recordID: account.id, version: VaultStoreFixture.accountVersion, digest: StoreSeal.digest(sealed))
    }

    /// Seals, stores and counts one history row; returns its `add` op.
    func putHistory(_ side: Int, _ row: HistoryRow, plaintext: Data) throws -> JournalOp {
        let sealed = try StoreSeal.sealRow(plaintext, key: sides[side].key, aad: aad(side, row))
        try StoreTables.putRecord(
            db,
            StoreTables.RecordRow(
                vaultID: sides[side].id, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject,
                version: row.version, sealed: sealed
            )
        )
        sides[side].history.append(row)
        adjust(side, row.kind, by: 1)
        return op(.add, row, sealed: sealed)
    }

    /// Removes one history row from `side`; returns its `remove` op (digest of the stored bytes) and its plaintext.
    func removeHistory(_ side: Int, _ row: HistoryRow) throws -> (op: JournalOp, plaintext: Data) {
        let stored = try #require(try StoreTables.record(db, vaultID: sides[side].id, recordID: row.recordID))
        let plaintext = try StoreSeal.openRow(stored.sealed, key: sides[side].key, aad: aad(side, row))
        try StoreTables.deleteRecord(db, vaultID: sides[side].id, recordID: row.recordID)
        sides[side].history.removeAll { $0.recordID == row.recordID }
        adjust(side, row.kind, by: -1)
        return (op(.remove, row, sealed: stored.sealed), plaintext)
    }

    /// Appends the ops as journal rows of at most 1,000 ops each, every row carrying the same transfer header. A transfer
    /// with no ops still writes one row; a plain commit with no ops writes none.
    func journal(_ side: Int, transfer: TransferHeader?, ops: [JournalOp]) throws {
        if transfer == nil && ops.isEmpty {
            return
        }
        let size = StoreFormat.journalOpsPerRow
        let chunks: [[JournalOp]] = ops.isEmpty ? [[]] : stride(from: 0, to: ops.count, by: size).map { Array(ops[$0..<min($0 + size, ops.count)]) }
        for chunk in chunks {
            let row = JournalRow(seq: sides[side].seq + 1, prevChain: sides[side].chain, transfer: transfer, ops: chunk)
            let sealed = try StoreSeal.sealJournal(row, key: sides[side].key, ids: ids, vaultID: sides[side].id)
            try StoreTables.putJournal(db, vaultID: sides[side].id, seq: row.seq, sealed: sealed)
            sides[side].seq = row.seq
            sides[side].chain = StoreSeal.chain(sides[side].chain, sealed: sealed)
        }
    }

    func addHistory(count: Int, owner: UUID) throws {
        var ops: [JournalOp] = []
        for index in 0..<count {
            let row = HistoryRow(recordID: UUID(), kind: .revision, ownerID: owner, subject: .password, version: UInt64(index + 1))
            let plaintext = Data(repeating: UInt8(truncatingIfNeeded: index), count: rowBytes)
            ops.append(try putHistory(0, row, plaintext: plaintext))
        }
        try journal(0, transfer: nil, ops: ops)
    }

    /// delete: source → Trash (live row leaves, `trashEntry` appears); undelete: Trash → source.
    func move(_ account: CredentialAccount, delete: Bool) throws {
        let from = delete ? 0 : 1, to = delete ? 1 : 0
        let moved = sides[from].history.filter { $0.ownerID == account.id && $0.kind == .revision }
        let entryID: UUID
        if delete {
            entryID = UUID()
            entries[account.id] = entryID
        } else {
            let removedEntry = entries.removeValue(forKey: account.id)
            entryID = try #require(removedEntry)
        }
        let transferID = UUID()
        var outOps: [JournalOp] = [], inOps: [JournalOp] = []
        for row in moved {
            let removed = try removeHistory(from, row)
            outOps.append(removed.op)
            inOps.append(try putHistory(to, row, plaintext: removed.plaintext))
        }
        let entry = HistoryRow(recordID: entryID, kind: .trashEntry, ownerID: account.id, subject: .account, version: 1)
        if delete {
            inOps.append(try putHistory(1, entry, plaintext: Data("trash entry".utf8)))
            try StoreTables.deleteRecord(db, vaultID: sides[0].id, recordID: account.id)
            sides[0].live[account.id] = nil
        } else {
            outOps.append(try removeHistory(1, entry).op)
            try putLive(account)
        }
        func header(_ direction: TransferDirection) -> TransferHeader {
            TransferHeader(
                transferID: transferID, direction: direction, scope: .account, ownerID: account.id, subject: nil,
                liveRecordID: account.id, liveVersion: VaultStoreFixture.accountVersion, entryRecordID: entryID
            )
        }
        try journal(from, transfer: header(.out), ops: outOps)
        try journal(to, transfer: header(.in), ops: inOps)
    }

    func head(_ side: Int, role: VaultRole, name: String, registryKey: Data?, blockedOrigins: [String], link: VaultLink) -> VaultHead {
        VaultHead(
            ids: ids,
            vaultID: sides[side].id,
            role: role,
            revision: 2,
            name: name,
            registryKey: registryKey,
            blockedOrigins: blockedOrigins,
            link: link,
            liveCatalog: sides[side].live.values.sorted { $0.recordID.uuidString < $1.recordID.uuidString },
            journalSeq: sides[side].seq,
            chainTip: sides[side].chain,
            historyCounts: sides[side].counts
        )
    }
}
