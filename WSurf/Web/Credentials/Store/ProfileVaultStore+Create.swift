// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import SQLite3

/// Who authorizes creating a vault (spec §8): nobody for the very first one, a vault already unlocked in this session, or a passkey
/// enrolled in an existing vault whose assertion is verified internally (§6.8 steps 1-7) and never published as a grant.
enum VaultCreationAuthority: Sendable {
    case firstVault
    case unlockedVault(vaultID: UUID, access: VaultAccess)
    case existingPasskey(vaultID: UUID, credentialID: Data, prf: SymmetricKey)
}

/// Everything one new vault and its linked Trash are built from.
nonisolated struct NewVault {
    let vaultID: UUID
    let trashID: UUID
    let dek: SymmetricKey
    let trashDEK: SymmetricKey
    let ordinal: Int
    let name: String
    let wrappers: [CredentialKeyWrapper]
    let createdAt: Date
    var blockedOrigins: [String] = []
    var accounts: [CredentialAccount] = []

    /// A new empty vault with a random DEK, wrapped for `proof`.
    static func fresh(ordinal: Int, name: String, proof: VaultUnlockProof, profileID: UUID, createdAt: Date) throws -> NewVault {
        let vaultID = UUID()
        let dek = SymmetricKey(size: .bits256)
        return NewVault(
            vaultID: vaultID, trashID: UUID(), dek: dek, trashDEK: SymmetricKey(size: .bits256), ordinal: ordinal, name: name,
            wrappers: [try CredentialVaultCrypto.wrap(dek, with: proof, profileID: profileID, vaultID: vaultID)], createdAt: createdAt
        )
    }
}

/// Writes of a vault pair and the registry (spec §5, §7, §8); callers own the transaction.
nonisolated enum VaultBuild {
    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// The active vault and its linked Trash: both vault rows, the account rows, both sealed heads (revision 1, empty journals).
    /// Returns the two registry entries.
    static func writePair(_ db: Database, ids: StoreIDs, registryKey: Data, vault: NewVault) throws -> [RegistryEntry] {
        let nonce = randomBytes(16)
        let wrappers = try VaultWrapperList.encode(vault.wrappers)
        let keyWrap = try StoreSeal.wrapTrashKey(
            vault.trashDEK, under: vault.dek, ids: ids, source: vault.vaultID, trash: vault.trashID, nonce: nonce
        )
        let sourceWrappersDigest = StoreSeal.digest(wrappers), trashKeyWrapDigest = StoreSeal.digest(keyWrap), zero = StoreSeal.digestOrZero(nil)
        try StoreTables.insertVault(
            db,
            StoreTables.VaultRow(vaultID: vault.vaultID, role: .active, ordinal: vault.ordinal, createdAt: vault.createdAt, wrappers: wrappers, keyWrap: nil)
        )
        try StoreTables.insertVault(
            db,
            StoreTables.VaultRow(vaultID: vault.trashID, role: .trash, ordinal: vault.ordinal, createdAt: vault.createdAt, wrappers: nil, keyWrap: keyWrap)
        )
        var live: [LiveEntry] = []
        for account in vault.accounts {
            let sealed = try StoreSeal.sealRow(
                try CredentialContent.canonicalJSON(account),
                key: vault.dek,
                aad: RowAAD(ids: ids, vaultID: vault.vaultID, recordID: account.id, kind: .account, ownerID: account.id, subject: .account, version: 1)
            )
            try StoreTables.putRecord(
                db,
                StoreTables.RecordRow(
                    vaultID: vault.vaultID, recordID: account.id, kind: .account, ownerID: account.id, subject: .account, version: 1, sealed: sealed
                )
            )
            live.append(LiveEntry(recordID: account.id, version: 1, digest: StoreSeal.digest(sealed)))
        }
        live.sort { $0.recordID.uuidString < $1.recordID.uuidString }

        func head(_ id: UUID, role: VaultRole, name: String, key: Data?, blocked: [String], peer: UUID, live: [LiveEntry]) -> VaultHead {
            VaultHead(
                ids: ids, vaultID: id, role: role, revision: 1, name: name, registryKey: key, blockedOrigins: blocked,
                link: VaultLink(peerVaultID: peer, nonce: nonce), liveCatalog: live, journalSeq: 0, chainTip: zero, historyCounts: HistoryCounts()
            )
        }
        let source = head(
            vault.vaultID, role: .active, name: vault.name, key: registryKey, blocked: vault.blockedOrigins, peer: vault.trashID, live: live
        )
        let trash = head(vault.trashID, role: .trash, name: "Trash", key: nil, blocked: [], peer: vault.vaultID, live: [])
        let sealedSource = try StoreSeal.sealHead(source, key: vault.dek, wrappersDigest: sourceWrappersDigest, keyWrapDigest: zero)
        let sealedTrash = try StoreSeal.sealHead(trash, key: vault.trashDEK, wrappersDigest: zero, keyWrapDigest: trashKeyWrapDigest)
        try StoreTables.putHead(db, vaultID: vault.vaultID, revision: 1, sealed: sealedSource)
        try StoreTables.putHead(db, vaultID: vault.trashID, revision: 1, sealed: sealedTrash)
        return [
            RegistryEntry(
                vaultID: vault.vaultID, role: .active, ordinal: vault.ordinal, createdAt: vault.createdAt, wrappersDigest: sourceWrappersDigest,
                keyWrapDigest: zero, headRevision: 1, headDigest: StoreSeal.digest(sealedSource)
            ),
            RegistryEntry(
                vaultID: vault.trashID, role: .trash, ordinal: vault.ordinal, createdAt: vault.createdAt, wrappersDigest: zero,
                keyWrapDigest: trashKeyWrapDigest, headRevision: 1, headDigest: StoreSeal.digest(sealedTrash)
            ),
        ]
    }

    static func putRegistry(_ db: Database, catalog: RegistryCatalog, registryKey: Data) throws {
        let encoded = catalog.encode()
        try StoreTables.putRegistry(db, revision: catalog.revision, catalog: encoded, mac: StoreSeal.registryMAC(rk: registryKey, catalog: encoded))
    }
}

/// The pending-connection recipe (spec §8 item 1): every connection on a pending store is private to one operation under the EXCLUSIVE
/// operation lock, uses `locking_mode=EXCLUSIVE` before its first `journal_mode=WAL` and `SQLITE_FCNTL_PERSIST_WAL=0`, so closing the
/// last connection removes `-wal`/`-shm` itself. A sidecar that survives means the recipe failed and is never unlinked by hand.
nonisolated enum PendingStore {
    static let sidecars = ["-wal", "-shm"]

    static func open(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { (db: Database) throws in
            guard try String.fetchOne(db, sql: "PRAGMA locking_mode = EXCLUSIVE")?.lowercased() == "exclusive" else {
                throw CredentialStoreError.migrationAborted(path: url)
            }
            var zero: Int32 = 0
            guard sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_PERSIST_WAL, &zero) == SQLITE_OK else {
                throw CredentialStoreError.migrationAborted(path: url)
            }
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        do {
            let mode = try queue.writeWithoutTransaction { (db: Database) throws in try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL") }
            guard mode?.lowercased() == "wal" else { throw CredentialStoreError.migrationAborted(path: url) }
        } catch {
            try? queue.close()
            throw error
        }
        return queue
    }

    /// `wal_checkpoint(TRUNCATE)` with `busy == 0`, close, and no `-wal`/`-shm` left.
    static func finish(_ queue: DatabaseQueue, at url: URL) throws {
        do {
            let busy = try queue.writeWithoutTransaction { (db: Database) throws -> Int? in
                let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                return row?[0]
            }
            guard busy == 0 else { throw CredentialStoreError.migrationAborted(path: url) }
        } catch {
            try? queue.close()
            throw error
        }
        try queue.close()
        try requireNoSidecars(at: url)
    }

    static func requireNoSidecars(at url: URL) throws {
        for suffix in sidecars {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if StoreAnchors.exists(sidecar) {
                throw CredentialStoreError.migrationAborted(path: sidecar)
            }
        }
    }

    /// Creates the file with one vault pair and registry revision 1, closes it by the recipe, `F_FULLFSYNC`s it and fsyncs the directory.
    static func build(at url: URL, ids: StoreIDs, registryKey: Data, vault: NewVault, fileOps: StoreFileOps) throws {
        guard !StoreAnchors.exists(url) else { throw CredentialStoreError.migrationAborted(path: url) }
        let queue = try open(at: url)
        do {
            try queue.write { (db: Database) throws in
                try StoreTables.create(in: db, ids: ids)
                let entries = try VaultBuild.writePair(db, ids: ids, registryKey: registryKey, vault: vault)
                try VaultBuild.putRegistry(db, catalog: RegistryCatalog(ids: ids, revision: 1, vaults: entries), registryKey: registryKey)
            }
        } catch {
            try? queue.close()
            throw error
        }
        try finish(queue, at: url)
        try fileOps.fullFsync(url)
        try fileOps.fsyncDirectory(url.deletingLastPathComponent())
    }

    /// Reopens by the recipe, runs `body` in a rolled-back read transaction with the scratch attached, then closes again by the
    /// recipe (the pending file is renamed only after that close).
    static func verify<T>(
        at url: URL, supportDirectory: URL, cleanupFailed: @Sendable (URL) -> Void, _ body: (Database) throws -> T
    ) throws -> T {
        let queue = try open(at: url)
        let result: T
        do {
            result = try VerificationScratch.run(on: queue, supportDirectory: supportDirectory, cleanupFailed: cleanupFailed, body)
        } catch {
            try? queue.close()
            throw error
        }
        try finish(queue, at: url)
        return result
    }
}

extension ProfileVaultStore {
    nonisolated static let defaultVaultKey = "io.wsagency.wsurf.credentialVault.defaultVault"

    nonisolated func file(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: Default vault

    /// A plaintext non-secret preference (spec §8 item 6); it may name a locked vault and is not validated against the store.
    func setDefaultVault(_ vaultID: UUID?) {
        if let vaultID {
            defaults.set(vaultID.uuidString, forKey: Self.defaultVaultKey)
        } else {
            defaults.removeObject(forKey: Self.defaultVaultKey)
        }
    }

    func defaultVaultID() -> UUID? {
        defaults.string(forKey: Self.defaultVaultKey).flatMap { UUID(uuidString: $0) }
    }

    // MARK: Creation

    /// Spec §8. The new vault's id; no grant is published for it or for the authorizing vault.
    func createVault(name: String, unlock proof: VaultUnlockProof, authorizedBy: VaultCreationAuthority) async throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= StoreFormat.nameLimit else { throw CredentialStoreError.invalidVaultName }
        try CredentialVaultCrypto.validateProof(proof)
        do {
            switch authorizedBy {
            case .firstVault:
                return try await bootstrapFirstVault(name: trimmed, proof: proof)
            case .unlockedVault(let sourceID, let access):
                return try await createWithUnlockedVault(sourceID, access: access, name: trimmed, proof: proof)
            case .existingPasskey(let sourceID, let credentialID, let prf):
                return try await createWithExistingPasskey(sourceID, credentialID: credentialID, prf: prf, name: trimmed, proof: proof)
            }
        } catch let error as DatabaseError {
            throw storeError(error, ordinal: nil)
        }
    }

    private func createWithUnlockedVault(_ sourceID: UUID, access: VaultAccess, name: String, proof: VaultUnlockProof) async throws -> UUID {
        func grant() throws -> VaultGrant {
            do {
                return try authorizedGrant(sourceID, access)
            } catch is CredentialVaultError {
                throw CredentialStoreError.noAuthority
            }
        }
        _ = try grant()
        let clock = now
        let createdAt = wall()
        return try await withOperation { pool in
            let authorized = try grant()  // re-checked after the lock wait
            return try Self.insertNewVault(pool, grant: authorized, access: access, name: name, proof: proof, now: clock, createdAt: createdAt)
        }
    }

    /// §6.8 steps 1-7 on the source vault under EXCLUSIVE, with an operation-scoped access that is revoked at the end and never
    /// published; the creation transaction runs under the same hold. `proof` must describe the very passkey that just opened the source
    /// vault: same credential id, same PRF output, and the PRF input the source vault stored for that credential. Anything else would wrap
    /// the new vault under a combination the chosen passkey cannot reproduce.
    private func createWithExistingPasskey(
        _ sourceID: UUID, credentialID: Data, prf: SymmetricKey, name: String, proof: VaultUnlockProof
    ) async throws -> UUID {
        guard proof.credentialID == credentialID, proof.prf.withUnsafeBytes({ Data($0) }) == prf.withUnsafeBytes({ Data($0) }) else {
            throw CredentialStoreError.passkeyUnusable
        }
        let hold = try await OperationLock.acquire(in: directory, mode: .exclusive, wait: lockWait)
        defer { hold.release() }
        let clock = now
        let access = VaultAccess(profileID: profileID, epoch: 0, deadline: clock().advanced(by: .seconds(300)))
        defer { access.revoke() }
        let grant: VaultGrant
        do {
            grant = try verifyHeld(
                hold, mode: .exclusive, vaultID: sourceID, credentialID: credentialID, prf: prf, access: access,
                verifying: nil, scratchWarning: nil
            )
        } catch CredentialVaultError.authenticationFailed {
            throw CredentialStoreError.passkeyUnusable
        }
        let createdAt = wall()
        return try withPool { pool in
            let stored = try pool.read { (db: Database) throws in
                try mapIntegrity(grant.ordinal) { try VaultWrapperList.decode(Self.activeRow(sourceID, in: db).wrappers) }
            }
            guard stored.first(where: { $0.credentialID == credentialID })?.prfInput == proof.prfInput else {
                throw CredentialStoreError.passkeyUnusable
            }
            return try Self.insertNewVault(pool, grant: grant, access: access, name: name, proof: proof, now: clock, createdAt: createdAt)
        }
    }

    /// One `BEGIN IMMEDIATE` transaction (spec §8 item 5): the registry re-read and verified with RK, both new vault rows and heads, the
    /// registry rewritten with the two new entries and revision + 1. No other vault's rows are read or written.
    nonisolated private static func insertNewVault(
        _ pool: DatabasePool, grant: VaultGrant, access: VaultAccess, name: String, proof: VaultUnlockProof,
        now: @Sendable () -> ContinuousClock.Instant, createdAt: Date
    ) throws -> UUID {
        try pool.writeWithoutTransaction { (db: Database) throws -> UUID in
            var created: UUID?
            try db.inTransaction(.immediate) {
                let opened = try openVault(db, grant: grant, vaultID: grant.entry.vaultID, access: access, now: now)
                let active = opened.catalog.vaults.filter { $0.role == .active }
                guard active.count < StoreFormat.activeVaultLimit else { throw CredentialStoreError.tooManyVaults }
                guard opened.catalog.revision < UInt64(Int64.max) else { throw CredentialVaultError.invalidData }
                let vault = try NewVault.fresh(
                    ordinal: (active.map(\.ordinal).max() ?? 0) + 1, name: name, proof: proof, profileID: grant.ids.profileID, createdAt: createdAt
                )
                let entries = try VaultBuild.writePair(db, ids: grant.ids, registryKey: grant.registryKey, vault: vault)
                var next = opened.catalog
                next.revision += 1
                next.vaults += entries
                try VaultBuild.putRegistry(db, catalog: next, registryKey: grant.registryKey)
                created = vault.vaultID
                return .commit
            }
            guard let created else { throw CredentialStoreError.integrityFailure(vaultOrdinal: grant.ordinal) }
            return created
        }
    }

    // MARK: First vault (state row 10)

    /// Spec §8 item 1 under EXCLUSIVE: build and verify the pending store, write the stub to `.swap`, create `Credentials.vault` with
    /// `RENAME_EXCL`, rename the pending store, set A3. The seam numbers are the migration's steps 4-7, 9 and 10. Publishes no grant.
    private func bootstrapFirstVault(name: String, proof: VaultUnlockProof) async throws -> UUID {
        let hold = try await OperationLock.acquire(in: directory, mode: .exclusive, wait: lockWait)
        defer { hold.release() }
        switch openState() {
        case .firstRun:
            break
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        case .legacy, .provisional, .resumeMigration:
            throw CredentialStoreError.noAuthority
        }
        let ids = StoreIDs(storeID: UUID(), profileID: profileID)
        let registryKey = VaultBuild.randomBytes(32)
        let vault = try NewVault.fresh(ordinal: 1, name: name, proof: proof, profileID: profileID, createdAt: wall())
        try buildPending(ids: ids, registryKey: registryKey, vault: vault)
        try seam(4)
        try verifyBootstrapped(ids: ids, vaultID: vault.vaultID, proof: proof)
        try seam(5)
        try writeStubToSwap(ids: ids)
        try seam(6)
        do {
            try fileOps.renameExclusive(file(StoreAnchors.Names.swap), file(StoreAnchors.Names.vault))
        } catch StoreFileError.exists {
            // A v1 file appeared meanwhile: nothing was overwritten, and the §6.3 state applies.
            if case .failClosed(let closed) = openState() {
                throw CredentialStoreError.failClosed(closed)
            }
            throw CredentialStoreError.stateChanged
        }
        try fileOps.fsyncDirectory(directory)
        try seam(7)
        try publishPending()
        try seam(9)
        _ = StoreAnchors.setWitnessIfAbsent(ids.storeID, defaults: defaults)
        try seam(10)
        return vault.vaultID
    }
}
