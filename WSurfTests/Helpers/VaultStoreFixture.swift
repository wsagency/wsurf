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
/// - Both vaults have ordinal 1 and head revision 2. The wrappers of the source vault are the real binary property list of
///   `[CredentialVaultCrypto.wrap(dek, with: proof, ...)]` (`encodeWrapperList`); the Trash vault holds a real key wrap of
///   `trashDEK` under `dek`. Unless `stubAbsent`, `Credentials.vault` holds the v2 stub, and A3 is always set, so the open
///   state is `.provisional`. `secondVault` adds active vault B (ordinal 2, name "Second", same registry key) with its own
///   linked Trash, and the registry covers all four vaults.
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
    let stubAbsent: Bool
    let sharedProof: Bool
    /// `secondVault: true` only: active vault B (ordinal 2) and its linked Trash vault.
    let secondVaultID: UUID?
    let secondTrashID: UUID?
    let secondDEK: SymmetricKey?
    let secondTrashDEK: SymmetricKey?
    /// B's own proof; nil when B shares `proof` (`sharedProof`) or there is no B.
    let secondProof: VaultUnlockProof?
    let secondDigests: HeadDigests?
    let secondTrashDigests: HeadDigests?
    /// Every `ProfileVaultStore` made through `makeStore`/`unlocked` is registered here; `with` closes them all before cleanup.
    let tracker: StoreTracker
    /// The source vault's history rows exactly as first written, before the first of `moves` re-sealed them (empty without moves): real
    /// ciphertext that opens under the vault's key and each row's own AAD, but whose digest the journal no longer expects.
    let preMoveSourceHistory: [StoreTables.RecordRow]
    /// The Trash's history rows as the first move (a delete) wrote them: after a delete/undelete/delete the Trash holds the same
    /// `recordID`s re-sealed again, so these are real Trash ciphertext whose digest the Trash journal no longer expects.
    let firstDeleteTrashHistory: [StoreTables.RecordRow]
    /// The heads as currently stored: `editHead` keeps them in step with the file, raw tampering does not.
    private(set) var sourceHead: VaultHead
    private(set) var trashHead: VaultHead
    private(set) var secondHead: VaultHead?
    private(set) var secondTrashHead: VaultHead?

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
        vaultName: String = "Personal",
        stubAbsent: Bool = false,
        secondVault: Bool = false,
        sharedProof: Bool = false,
        secondAccounts: [CredentialAccount] = [],
        extraVaults: Int = 0,
        extraHistory: [FixtureHistoryRun] = []
    ) throws -> VaultStoreFixture {
        precondition(moves == 0 || !accounts.isEmpty, "a MOVE needs an account")
        let env = try VaultTestEnvironment.make()
        let ids = StoreIDs(storeID: UUID(), profileID: env.profileID)
        let storeURL = env.directory.appendingPathComponent("Credentials.store")
        let registryKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let proof = VaultFixtures.proof()
        let secondProof: VaultUnlockProof? = secondVault && !sharedProof ? VaultFixtures.proof(2) : nil
        let first = PairSeed(
            vaultID: UUID(), trashID: UUID(), dek: SymmetricKey(size: .bits256), trashDEK: SymmetricKey(size: .bits256),
            ordinal: 1, name: vaultName, proof: proof,
            load: PairLoad(accounts: accounts, blockedOrigins: blockedOrigins, historyRows: historyRows, moves: moves, extraHistory: extraHistory)
        )
        let second = secondVault
            ? PairSeed(
                vaultID: UUID(), trashID: UUID(), dek: SymmetricKey(size: .bits256), trashDEK: SymmetricKey(size: .bits256),
                ordinal: 2, name: "Second", proof: secondProof ?? proof,
                load: PairLoad(accounts: secondAccounts, blockedOrigins: [], historyRows: 0, moves: 0)
            )
            : nil
        // `extraVaults` more active vaults (ordinals after B's), each with its own linked Trash, same registry key, no content.
        let extras = (0..<extraVaults).map { index in
            PairSeed(
                vaultID: UUID(), trashID: UUID(), dek: SymmetricKey(size: .bits256), trashDEK: SymmetricKey(size: .bits256),
                ordinal: (secondVault ? 3 : 2) + index, name: "Extra \(index + 1)", proof: proof,
                load: PairLoad(accounts: [], blockedOrigins: [], historyRows: 0, moves: 0)
            )
        }

        let pool = try DatabasePool(path: storeURL.path)
        let pairs = try pool.write { db -> (first: PairResult, second: PairResult?) in
            try StoreTables.create(in: db, ids: ids)
            let firstPair = try writePair(first, in: db, ids: ids, registryKey: registryKey, rowBytes: historyRowBytes)
            let secondPair = try second.map {
                try writePair($0, in: db, ids: ids, registryKey: registryKey, rowBytes: historyRowBytes)
            }
            let extraPairs = try extras.map { try writePair($0, in: db, ids: ids, registryKey: registryKey, rowBytes: historyRowBytes) }
            let entries = firstPair.entries + (secondPair?.entries ?? []) + extraPairs.flatMap(\.entries)
            let catalog = RegistryCatalog(ids: ids, revision: 1, vaults: entries).encode()
            try StoreTables.putRegistry(db, revision: 1, catalog: catalog, mac: StoreSeal.registryMAC(rk: registryKey, catalog: catalog))
            return (firstPair, secondPair)
        }
        try pool.close()  // observed: GRDB's DatabasePool.close() leaves Credentials.store-wal/-shm on disk; tests compare sidecar sets to a baseline
        if !stubAbsent {
            try StoreAnchors.stubBytes(ids: ids).write(to: env.directory.appendingPathComponent("Credentials.vault"))
        }
        _ = StoreAnchors.setWitnessIfAbsent(ids.storeID, defaults: env.defaults)
        return VaultStoreFixture(
            env: env,
            ids: ids,
            storeURL: storeURL,
            vaultID: first.vaultID,
            trashID: first.trashID,
            dek: first.dek,
            trashDEK: first.trashDEK,
            registryKey: registryKey,
            proof: proof,
            accounts: accounts,
            sourceDigests: pairs.first.sourceDigests,
            trashDigests: pairs.first.trashDigests,
            stubAbsent: stubAbsent,
            sharedProof: sharedProof,
            secondVaultID: second?.vaultID,
            secondTrashID: second?.trashID,
            secondDEK: second?.dek,
            secondTrashDEK: second?.trashDEK,
            secondProof: secondProof,
            secondDigests: pairs.second?.sourceDigests,
            secondTrashDigests: pairs.second?.trashDigests,
            tracker: StoreTracker(),
            preMoveSourceHistory: pairs.first.preMoveSource,
            firstDeleteTrashHistory: pairs.first.firstDeleteTrash,
            sourceHead: pairs.first.sourceHead,
            trashHead: pairs.first.trashHead,
            secondHead: pairs.second?.sourceHead,
            secondTrashHead: pairs.second?.trashHead
        )
    }

    /// One vault with its linked Trash, written inside the caller's transaction: real wrapper list, trash key wrap, rows,
    /// journals, sealed heads. Returns the heads, the digests they were sealed under and the registry entries.
    private static func writePair(
        _ seed: PairSeed,
        in db: Database,
        ids: StoreIDs,
        registryKey: Data,
        rowBytes: Int
    ) throws -> PairResult {
        let created = Date(timeIntervalSinceReferenceDate: 1_000)
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let wrappers = try encodeWrapperList([
            CredentialVaultCrypto.wrap(seed.dek, with: seed.proof, profileID: ids.profileID, vaultID: seed.vaultID),
        ])
        let keyWrap = try StoreSeal.wrapTrashKey(seed.trashDEK, under: seed.dek, ids: ids, source: seed.vaultID, trash: seed.trashID, nonce: nonce)
        let sourceDigests = HeadDigests(wrappers: StoreSeal.digest(wrappers), keyWrap: StoreSeal.digestOrZero(nil))
        let trashDigests = HeadDigests(wrappers: StoreSeal.digestOrZero(nil), keyWrap: StoreSeal.digest(keyWrap))
        try StoreTables.insertVault(
            db, StoreTables.VaultRow(vaultID: seed.vaultID, role: .active, ordinal: seed.ordinal, createdAt: created, wrappers: wrappers, keyWrap: nil)
        )
        try StoreTables.insertVault(
            db, StoreTables.VaultRow(vaultID: seed.trashID, role: .trash, ordinal: seed.ordinal, createdAt: created, wrappers: nil, keyWrap: keyWrap)
        )
        let builder = Builder(
            db: db, ids: ids, rowBytes: rowBytes,
            sides: [Side(id: seed.vaultID, key: seed.dek), Side(id: seed.trashID, key: seed.trashDEK)]
        )
        for account in seed.load.accounts {
            try builder.putLive(account)
        }
        let owner = seed.load.accounts.first?.id ?? UUID()
        try builder.addHistory(count: seed.load.historyRows, owner: owner)
        for run in seed.load.extraHistory {
            try builder.addHistory(
                count: run.count, owner: seed.load.accounts[run.ownerIndex].id, subject: run.subject, plaintext: run.plaintext
            )
        }
        var preMoveSource: [StoreTables.RecordRow] = []
        var firstDeleteTrash: [StoreTables.RecordRow] = []
        if seed.load.moves > 0 {
            try StoreTables.forEachHistoryRecord(db, vaultID: seed.vaultID) { preMoveSource.append($0) }
        }
        for index in 0..<seed.load.moves {
            try builder.move(seed.load.accounts[0], delete: index % 2 == 0)
            if index == 0 {
                try StoreTables.forEachHistoryRecord(db, vaultID: seed.trashID) { firstDeleteTrash.append($0) }
            }
        }
        let source = builder.head(
            0, role: .active, name: seed.name, registryKey: registryKey, blockedOrigins: seed.load.blockedOrigins,
            link: VaultLink(peerVaultID: seed.trashID, nonce: nonce)
        )
        let trash = builder.head(
            1, role: .trash, name: "Trash", registryKey: nil, blockedOrigins: [], link: VaultLink(peerVaultID: seed.vaultID, nonce: nonce)
        )
        let sealedSource = try StoreSeal.sealHead(source, key: seed.dek, wrappersDigest: sourceDigests.wrappers, keyWrapDigest: sourceDigests.keyWrap)
        let sealedTrash = try StoreSeal.sealHead(trash, key: seed.trashDEK, wrappersDigest: trashDigests.wrappers, keyWrapDigest: trashDigests.keyWrap)
        try StoreTables.putHead(db, vaultID: seed.vaultID, revision: source.revision, sealed: sealedSource)
        try StoreTables.putHead(db, vaultID: seed.trashID, revision: trash.revision, sealed: sealedTrash)
        let entries = [
            RegistryEntry(
                vaultID: seed.vaultID, role: .active, ordinal: seed.ordinal, createdAt: created, wrappersDigest: sourceDigests.wrappers,
                keyWrapDigest: sourceDigests.keyWrap, headRevision: source.revision, headDigest: StoreSeal.digest(sealedSource)
            ),
            RegistryEntry(
                vaultID: seed.trashID, role: .trash, ordinal: seed.ordinal, createdAt: created, wrappersDigest: trashDigests.wrappers,
                keyWrapDigest: trashDigests.keyWrap, headRevision: trash.revision, headDigest: StoreSeal.digest(sealedTrash)
            ),
        ]
        return PairResult(
            sourceHead: source, trashHead: trash, sourceDigests: sourceDigests, trashDigests: trashDigests, entries: entries,
            preMoveSource: preMoveSource, firstDeleteTrash: firstDeleteTrash
        )
    }

    /// The stored form of a wrapper list: a binary property list of the wrappers in order (independent of the production codec).
    static func encodeWrapperList(_ wrappers: [CredentialKeyWrapper]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(wrappers)
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
        if vault == vaultID {
            return dek
        }
        if vault == secondVaultID, let secondDEK {
            return secondDEK
        }
        if vault == secondTrashID, let secondTrashDEK {
            return secondTrashDEK
        }
        return trashDEK
    }

    func head(of vault: UUID) -> VaultHead {
        if vault == vaultID {
            return sourceHead
        }
        if vault == secondVaultID, let secondHead {
            return secondHead
        }
        if vault == secondTrashID, let secondTrashHead {
            return secondTrashHead
        }
        return trashHead
    }

    func digests(of vault: UUID) -> HeadDigests {
        if vault == vaultID {
            return sourceDigests
        }
        if vault == secondVaultID, let secondDigests {
            return secondDigests
        }
        if vault == secondTrashID, let secondTrashDigests {
            return secondTrashDigests
        }
        return trashDigests
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
        } else if vault == secondVaultID {
            secondHead = edited
        } else if vault == secondTrashID {
            secondTrashHead = edited
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

// MARK: - Lifetime, store helpers, registry and readback

private nonisolated struct FixtureFailure: Error {
    let message: String
}

/// The synthetic content one pair is built with.
private nonisolated struct PairLoad {
    let accounts: [CredentialAccount]
    let blockedOrigins: [String]
    let historyRows: Int
    let moves: Int
    var extraHistory: [FixtureHistoryRun] = []
}

private nonisolated struct PairSeed {
    let vaultID: UUID
    let trashID: UUID
    let dek: SymmetricKey
    let trashDEK: SymmetricKey
    let ordinal: Int
    let name: String
    let proof: VaultUnlockProof
    let load: PairLoad
}

private nonisolated struct PairResult {
    let sourceHead: VaultHead
    let trashHead: VaultHead
    let sourceDigests: VaultStoreFixture.HeadDigests
    let trashDigests: VaultStoreFixture.HeadDigests
    let entries: [RegistryEntry]
    let preMoveSource: [StoreTables.RecordRow]
    let firstDeleteTrash: [StoreTables.RecordRow]
}

/// Owns every `ProfileVaultStore` a test creates, so each one is `await close()`d before its directory is removed (the
/// fixture is a value type; copies share this tracker).
nonisolated final class StoreTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [ProfileVaultStore] = []

    func makeStore(
        env: VaultTestEnvironment,
        fileOps: StoreFileOps = .live,
        lockWait: Duration = StoreFormat.lockWait,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) -> ProfileVaultStore {
        let store = ProfileVaultStore(
            profileID: env.profileID, directory: env.directory, defaults: env.defaults, fileOps: fileOps, lockWait: lockWait, now: now
        )
        lock.withLock { stores.append(store) }
        return store
    }

    /// Awaits `close()` on every registered store (idempotent on the store side), newest first.
    func closeAll() async {
        let all = lock.withLock { () -> [ProfileVaultStore] in
            defer { stores = [] }
            return stores
        }
        for store in all.reversed() {
            await store.close()
        }
    }
}

nonisolated extension VaultStoreFixture {
    /// Builds the fixture, runs `body`, then (success or throw) awaits `close()` on every store made through
    /// `makeStore`/`unlocked`, and only then removes the directory. Rethrows `body`'s error. Same parameters as `make`.
    static func with(
        accounts: [CredentialAccount] = [],
        blockedOrigins: [String] = [],
        historyRows: Int = 0,
        historyRowBytes: Int = 32,
        moves: Int = 0,
        vaultName: String = "Personal",
        stubAbsent: Bool = false,
        secondVault: Bool = false,
        sharedProof: Bool = false,
        secondAccounts: [CredentialAccount] = [],
        extraVaults: Int = 0,
        extraHistory: [FixtureHistoryRun] = [],
        isolation: isolated (any Actor)? = #isolation,
        _ body: (VaultStoreFixture) async throws -> Void
    ) async throws {
        let f = try make(
            accounts: accounts, blockedOrigins: blockedOrigins, historyRows: historyRows, historyRowBytes: historyRowBytes,
            moves: moves, vaultName: vaultName, stubAbsent: stubAbsent, secondVault: secondVault, sharedProof: sharedProof,
            secondAccounts: secondAccounts, extraVaults: extraVaults, extraHistory: extraHistory
        )
        do {
            try await body(f)
        } catch {
            await f.tracker.closeAll()
            f.env.cleanUp()
            throw error
        }
        await f.tracker.closeAll()
        f.env.cleanUp()
    }

    /// The same close-then-cleanup guarantee for tests that arrange a directory by hand (legacy, first-run, resume, v1 beside a
    /// store): stores come from `tracker.makeStore(env:)`.
    static func withEnvironment(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (VaultTestEnvironment, StoreTracker) async throws -> Void
    ) async throws {
        let env = try VaultTestEnvironment.make()
        let tracker = StoreTracker()
        do {
            try await body(env, tracker)
        } catch {
            await tracker.closeAll()
            env.cleanUp()
            throw error
        }
        await tracker.closeAll()
        env.cleanUp()
    }

    // MARK: Store helpers

    /// A store on this fixture's profile, directory and defaults, registered for closing by `with`.
    func makeStore(
        fileOps: StoreFileOps = .live,
        lockWait: Duration = StoreFormat.lockWait,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) -> ProfileVaultStore {
        tracker.makeStore(env: env, fileOps: fileOps, lockWait: lockWait, now: now)
    }

    func beginAccess(lifetime: Duration = .seconds(300)) -> VaultAccess {
        VaultAccess(profileID: env.profileID, epoch: 1, deadline: ContinuousClock().now.advanced(by: lifetime))
    }

    /// The proof that opens `vault`: `secondProof` for vault B unless B shares `proof`.
    func proof(for vault: UUID) -> VaultUnlockProof {
        if vault == secondVaultID, let secondProof {
            return secondProof
        }
        return proof
    }

    /// A fresh store unlocked on `vaultID` (default: vault A) through the public `unlockInitialized`.
    func unlocked(vaultID: UUID? = nil) async throws -> (ProfileVaultStore, VaultAccess) {
        let target = vaultID ?? self.vaultID
        let unlocking = proof(for: target)
        let store = makeStore()
        let access = beginAccess()
        try await store.unlockInitialized(
            vaultID: target, credentialID: unlocking.credentialID, prf: unlocking.prf, access: access, verifying: nil, scratchWarning: nil
        )
        return (store, access)
    }

    // MARK: Anchors

    var vaultFile: URL {
        directory.appendingPathComponent("Credentials.vault", isDirectory: false)
    }

    func evaluate() -> StoreOpenState {
        StoreAnchors.evaluate(directory: directory, profileID: env.profileID, defaults: env.defaults)
    }

    // MARK: Registry

    func storedRegistry() throws -> (revision: UInt64, catalog: RegistryCatalog, mac: Data) {
        guard let stored = try read({ try StoreTables.registry($0) }) else { throw FixtureFailure(message: "no registry row") }
        return (stored.revision, try RegistryCatalog.decode(stored.catalog), stored.mac)
    }

    /// `mac == nil` signs with `registryKey`; pass explicit bytes to forge. The row's revision column is `catalog.revision`.
    func putRegistry(_ catalog: RegistryCatalog, mac: Data?) throws {
        let encoded = catalog.encode()
        let signature = mac ?? StoreSeal.registryMAC(rk: registryKey, catalog: encoded)
        try mutate { try StoreTables.putRegistry($0, revision: catalog.revision, catalog: encoded, mac: signature) }
    }

    /// The catalog a correct writer would store for the CURRENT vault rows and heads (ordinal and createdAt from the rows).
    func rebuiltRegistry(revision: UInt64? = nil) throws -> RegistryCatalog {
        let storedRevision = try storedRegistry().revision
        let entries = try read { db -> [RegistryEntry] in
            try StoreTables.vaultRows(db).map { row in
                guard let head = try StoreTables.head(db, vaultID: row.vaultID) else {
                    throw FixtureFailure(message: "vault \(row.vaultID) has no head")
                }
                return RegistryEntry(
                    vaultID: row.vaultID,
                    role: row.role,
                    ordinal: row.ordinal,
                    createdAt: row.createdAt,
                    wrappersDigest: StoreSeal.digestOrZero(row.wrappers),
                    keyWrapDigest: StoreSeal.digestOrZero(row.keyWrap),
                    headRevision: head.revision,
                    headDigest: StoreSeal.digest(head.sealed)
                )
            }
        }
        return RegistryCatalog(ids: ids, revision: revision ?? storedRevision, vaults: entries)
    }

    // MARK: Readback

    /// Relative path → bytes of every regular file under `directory` (nothing excluded).
    func directoryImage() throws -> [String: Data] {
        try Self.directoryImage(of: directory)
    }

    static func directoryImage(of directory: URL) throws -> [String: Data] {
        let manager = FileManager.default
        var image: [String: Data] = [:]
        for relative in try manager.subpathsOfDirectory(atPath: directory.path) {
            let file = directory.appendingPathComponent(relative)
            let type = try manager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            if type == .typeRegular {
                image[relative] = try Data(contentsOf: file)
            }
        }
        return image
    }

    /// Every key the store keeps in the test suite's defaults with a textual form of its value. `dictionaryRepresentation()` also merges
    /// the process-wide domains, which other tests (any `NSWindow`) write to concurrently, so only the app's own keys are compared.
    func defaultsImage() -> [String: String] {
        Self.defaultsImage(of: env.defaults)
    }

    static func defaultsImage(of defaults: UserDefaults) -> [String: String] {
        defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("io.wsagency.") }.mapValues { String(describing: $0) }
    }

    func storedWrappersBytes(of vault: UUID) throws -> Data {
        let rows = try read { try StoreTables.vaultRows($0) }
        guard let bytes = rows.first(where: { $0.vaultID == vault })?.wrappers else {
            throw FixtureFailure(message: "vault \(vault) has no wrapper list")
        }
        return bytes
    }

    func wrapperRows(of vault: UUID) throws -> [CredentialKeyWrapper] {
        try PropertyListDecoder().decode([CredentialKeyWrapper].self, from: try storedWrappersBytes(of: vault))
    }

    func headRevision(of vault: UUID) throws -> UInt64 {
        guard let stored = try read({ try StoreTables.head($0, vaultID: vault) }) else {
            throw FixtureFailure(message: "vault \(vault) has no head")
        }
        return stored.revision
    }

    /// Every `record` and `journal` row serialised, keyed by table and identity: equal images mean no row changed.
    func recordAndJournalImage() throws -> [String: Data] {
        try read { db in
            var image: [String: Data] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT vaultID, recordID, kind, ownerID, subject, version, sealed FROM record") {
                let vault: String = row["vaultID"], record: String = row["recordID"], sealed: Data = row["sealed"]
                let kind: String = row["kind"], owner: String = row["ownerID"], subject: String = row["subject"], version: Int64 = row["version"]
                image["record/\(vault)/\(record)"] = Data("\(kind)|\(owner)|\(subject)|\(version)|".utf8) + sealed
            }
            for row in try Row.fetchAll(db, sql: "SELECT vaultID, seq, sealed FROM journal") {
                let vault: String = row["vaultID"], seq: Int64 = row["seq"], sealed: Data = row["sealed"]
                image["journal/\(vault)/\(seq)"] = sealed
            }
            return image
        }
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

    func addHistory(count: Int, owner: UUID, subject: RecordSubject = .password, plaintext: Data? = nil) throws {
        var ops: [JournalOp] = []
        for index in 0..<count {
            let row = HistoryRow(recordID: UUID(), kind: .revision, ownerID: owner, subject: subject, version: UInt64(index + 1))
            let bytes = plaintext ?? Data(repeating: UInt8(truncatingIfNeeded: index), count: rowBytes)
            ops.append(try putHistory(0, row, plaintext: bytes))
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
