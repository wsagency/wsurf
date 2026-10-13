// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

/// What a successful unlock publishes for one vault: the verified keys and the registry entries the session read. Every head
/// write compares the stored registry's entries for this vault and its Trash with these (else `staleRevision`).
nonisolated struct VaultGrant: Sendable {
    let access: VaultAccess
    let credentialID: Data
    let dek: SymmetricKey
    let registryKey: Data
    let ids: StoreIDs
    let ordinal: Int
    let name: String
    let trashID: UUID
    var entry: RegistryEntry
    var trashEntry: RegistryEntry
}

/// The stored form of a vault's wrapper list: a binary property list of `[CredentialKeyWrapper]` in insertion order, 1...32
/// entries with unique credential ids. Its digest is the SHA-256 of the stored bytes (`StoreSeal.digest`).
nonisolated enum VaultWrapperList {
    private static let maximumBytes = 256 * 1_024

    private nonisolated struct Bounded: Decodable {
        let wrappers: [CredentialKeyWrapper]

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            guard let count = values.count, count <= CredentialVaultLimits.wrappers else { throw CredentialStoreError.malformed }
            var decoded: [CredentialKeyWrapper] = []
            decoded.reserveCapacity(count)
            while !values.isAtEnd {
                decoded.append(try values.decode(CredentialKeyWrapper.self))
            }
            wrappers = decoded
        }
    }

    static func encode(_ wrappers: [CredentialKeyWrapper]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(wrappers)
    }

    static func decode(_ stored: Data?) throws -> [CredentialKeyWrapper] {
        guard let stored, stored.count <= maximumBytes, stored.starts(with: Data("bplist00".utf8)) else { throw CredentialStoreError.malformed }
        let wrappers = try PropertyListDecoder().decode(Bounded.self, from: stored).wrappers
        guard !wrappers.isEmpty, Set(wrappers.map(\.credentialID)).count == wrappers.count else { throw CredentialStoreError.malformed }
        return wrappers
    }
}

/// Runs `body`; any failure other than cancellation or an `integrityFailure` that already names its vault becomes
/// `integrityFailure(vaultOrdinal: ordinal)`, except a database failure that is operational (`storeError`). The stored file is untrusted
/// input, so a decode or crypto error is an integrity failure; a full disk or a busy database is not.
nonisolated func mapIntegrity<T>(_ ordinal: Int?, _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as CancellationError {
        throw error
    } catch let error as CredentialStoreError {
        if case .integrityFailure = error {
            throw error
        }
        throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)
    } catch let error as DatabaseError {
        throw storeError(error, ordinal: ordinal)
    } catch {
        throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)
    }
}

/// A SQLite failure as the store reports it. A full disk is `diskFull`, a busy or locked database `storeBusy`. Only the codes that say
/// the file's content or schema is wrong (corrupt, not a database, SQL error such as a missing table, schema change, constraint,
/// type mismatch) are an `integrityFailure`. Everything else (I/O, cannot open, read-only, permission, memory, interrupt, abort,
/// lock protocol, large-file limit, misuse, ...) is operational and stays the `DatabaseError`.
nonisolated func storeError(_ error: DatabaseError, ordinal: Int?) -> any Error {
    switch error.resultCode {
    case .SQLITE_FULL:
        CredentialStoreError.diskFull
    case .SQLITE_BUSY, .SQLITE_LOCKED:
        CredentialStoreError.storeBusy
    case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_ERROR, .SQLITE_SCHEMA, .SQLITE_CONSTRAINT, .SQLITE_MISMATCH:
        CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)
    default:
        error
    }
}

/// The profile's v2 credential store (spec §5-§7): unlock pipeline, grants, wrapper and password-save-policy writes. Every database
/// operation (spec §15) takes the operation lock, re-reads the anchors under it, opens its own pool, runs, and closes the pool while
/// still holding the lock. Only grants and keys outlive an operation, never a connection.
actor ProfileVaultStore {
    let profileID: UUID
    let directory: URL
    let defaults: UserDefaults
    let fileOps: StoreFileOps
    let lockWait: Duration
    let now: @Sendable () -> ContinuousClock.Instant
    let wall: @Sendable () -> Date

    /// At most one grant per vault: a later unlock of the same vault replaces it and revokes the previous access.
    var grants: [UUID: VaultGrant] = [:]
    /// Vaults whose verification succeeded in this session (stays true after `lock`).
    var verified: Set<UUID> = []

    init(
        profileID: UUID,
        directory: URL,
        defaults: UserDefaults,
        fileOps: StoreFileOps = .live,
        lockWait: Duration = StoreFormat.lockWait,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        wall: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profileID = profileID
        self.directory = directory
        self.defaults = defaults
        self.fileOps = fileOps
        self.lockWait = lockWait
        self.now = now
        self.wall = wall
    }

    // MARK: State

    /// `StoreAnchors.evaluate`; never writes.
    func openState() -> StoreOpenState {
        StoreAnchors.evaluate(directory: directory, profileID: profileID, defaults: defaults)
    }

    /// A new pool for one operation, which the caller closes before releasing the operation lock: WAL (GRDB's default for a pool),
    /// `foreign_keys=ON` (GRDB's default), `secure_delete=ON`, `synchronous=FULL`, a 5 s busy timeout, and the default locking mode;
    /// the persist-WAL setting is left alone (a closed pool was observed to leave `-wal`/`-shm` behind). Spec §8's exclusive/no-persist
    /// recipe is for pending connections only. GRDB's `DatabasePool.init` sets the writer
    /// to `synchronous=NORMAL` after `prepareDatabase`, and its readers get a 10 s busy timeout of their own (`readonlyBusyMode` is not
    /// public), so FULL is set on the writer again after the pool is up and the timeout is set by pragma on every connection.
    func openPool() throws -> DatabasePool {
        var configuration = Configuration()
        configuration.busyMode = .timeout(Double(StoreFormat.busyTimeoutMS) / 1000)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = \(StoreFormat.busyTimeoutMS)")
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        let pool = try DatabasePool(path: directory.appendingPathComponent("Credentials.store", isDirectory: false).path, configuration: configuration)
        do {
            try pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous = FULL") }
        } catch {
            try? pool.close()
            throw error
        }
        return pool
    }

    /// Runs `body` on a pool opened for it and closes the pool before returning, so nothing is published or returned past a failed
    /// close. After a failed `body` the close is best effort and `body`'s error stays the outcome. A connection `close()` could not
    /// close is released by GRDB when the pool is deallocated, which happens here, before the caller releases the operation lock.
    func withPool<T>(_ body: (DatabasePool) throws -> T) throws -> T {
        let pool = try openPool()
        let result: T
        do {
            result = try body(pool)
        } catch {
            try? pool.close()
            throw error
        }
        try pool.close()
        return result
    }

    /// Spec §15: take the operation lock (SHARED: SQLite's own write lock serializes writers), re-read the anchors under it, run `body` on
    /// a pool opened for this operation, and close that pool before the lock is released. A state other than `.provisional` is
    /// `stateChanged` (the caller routed on an earlier read) and a closed one its `failClosed` error, both before any database is
    /// opened.
    func withOperation<T>(_ body: (DatabasePool) throws -> T) async throws -> T {
        let hold = try await OperationLock.acquire(in: directory, mode: .shared, wait: lockWait)
        defer { hold.release() }
        switch openState() {
        case .provisional:
            break
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        case .legacy, .firstRun, .resumeMigration:
            throw CredentialStoreError.stateChanged
        }
        do {
            return try withPool(body)
        } catch let error as DatabaseError {
            throw storeError(error, ordinal: nil)
        }
    }

    /// A vault of a directory that has no v2 store yet, as the pre-unlock list shows it: the wrapper plaintext only, never a grant.
    private struct LockedVault {
        let vaultID: UUID
        let ordinal: Int
        let wrappers: [CredentialKeyWrapper]
    }

    /// The read-only preflight of `listing` and `discovery`. `nil` = a v2 store exists (`.provisional`; the caller reads it under
    /// `withOperation`), the fail-closed error for a closed state, `[]` for a first run, and for `.legacy`/`.resumeMigration` the one
    /// vault the v1 file or the pending store holds, read under a SHARED lock with the state re-read under it (a changed state is
    /// `stateChanged`). It changes no credential or pending-store byte (the operation lock file may be created empty) and recovers,
    /// deletes and checkpoints nothing; it takes no grant: unlocking still needs the confirmed migration.
    private func lockedVaults() async throws -> [LockedVault]? {
        switch openState() {
        case .provisional:
            return nil
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        case .firstRun:
            return []
        case .legacy, .resumeMigration:
            let hold = try await OperationLock.acquire(in: directory, mode: .shared, wait: lockWait)
            defer { hold.release() }
            switch openState() {
            case .legacy:
                let envelope = try CredentialVaultCrypto.decodeEnvelope(
                    try LegacyVaultV1.readEnvelope(at: file(StoreAnchors.Names.vault)), profileID: profileID
                )
                return [LockedVault(vaultID: envelope.vaultID, ordinal: 1, wrappers: envelope.wrappers)]
            case .resumeMigration:
                return try pendingVaults()
            case .failClosed(let closed):
                throw CredentialStoreError.failClosed(closed)
            case .provisional, .firstRun:
                throw CredentialStoreError.stateChanged
            }
        }
    }

    /// The active vaults of the closed pending store, through a read-only `immutable=1` connection (the `StoreAnchors` pattern: no
    /// `-wal`/`-shm`, nothing written). A sidecar means the file is not in its closed state: refused, and left for the resume to judge.
    private func pendingVaults() throws -> [LockedVault] {
        let pending = file(StoreAnchors.Names.migrating)
        try PendingStore.requireNoSidecars(at: pending)
        var configuration = Configuration()
        configuration.readonly = true
        let rows: [StoreTables.VaultRow]
        do {
            let queue = try DatabaseQueue(path: pending.absoluteString + "?immutable=1", configuration: configuration)
            do {
                rows = try queue.read { (db: Database) throws in try mapIntegrity(nil) { try StoreTables.vaultRows(db) } }
            } catch {
                try? queue.close()
                throw error
            }
            try queue.close()
        } catch let error as DatabaseError {
            throw storeError(error, ordinal: nil)
        }
        // A valid pending recipe (legacy migration or first-vault bootstrap) holds exactly one active vault; anything else is corrupt.
        let active = rows.filter { $0.role == .active }
        guard active.count == 1, let row = active.first else { throw CredentialStoreError.integrityFailure(vaultOrdinal: nil) }
        return [LockedVault(vaultID: row.vaultID, ordinal: row.ordinal, wrappers: try mapIntegrity(row.ordinal) { try VaultWrapperList.decode(row.wrappers) })]
    }

    /// A state that changed between the preflight and the lock is read again once, like `unlock`; a second change is `stateChanged`.
    private func rerouting<T>(_ read: () async throws -> T) async throws -> T {
        do {
            return try await read()
        } catch CredentialStoreError.stateChanged {
            return try await read()
        }
    }

    /// The vault's active row; a Trash id or an unknown id is `noSuchVault`. Static so pool closures never capture the actor.
    nonisolated static func activeRow(_ vaultID: UUID, in db: Database) throws -> StoreTables.VaultRow {
        let rows = try mapIntegrity(nil) { try StoreTables.vaultRows(db) }
        guard let row = rows.first(where: { $0.vaultID == vaultID && $0.role == .active }) else { throw CredentialStoreError.noSuchVault }
        return row
    }

    /// The grant `access` holds on `vaultID`, still authorized at `now()`.
    func authorizedGrant(_ vaultID: UUID, _ access: VaultAccess) throws -> VaultGrant {
        guard access.profileID == profileID, let grant = grants[vaultID], grant.access === access else {
            throw CredentialVaultError.unauthorized
        }
        try access.checkAuthorization(at: now())
        return grant
    }

    // MARK: Listing and discovery

    /// Ordinals of the active vaults; the name only once that vault is unlocked. A v1 file or an interrupted migration lists its one
    /// vault, locked.
    func listing() async throws -> [VaultListing] {
        try await rerouting {
            if let locked = try await lockedVaults() {
                return locked.map { VaultListing(vaultID: $0.vaultID, ordinal: $0.ordinal, name: nil, isUnlocked: false, isVerified: false) }
            }
            let rows = try await withOperation { pool in
                try pool.read { (db: Database) throws in try mapIntegrity(nil) { try StoreTables.vaultRows(db) } }
            }
            return rows.filter { $0.role == .active }.sorted { $0.ordinal < $1.ordinal }.map { row in
                let grant = authorizedGrantIfAny(row.vaultID)
                return VaultListing(
                    vaultID: row.vaultID,
                    ordinal: row.ordinal,
                    name: grant?.name,
                    isUnlocked: grant != nil,
                    isVerified: verified.contains(row.vaultID)
                )
            }
        }
    }

    /// The grant on `vaultID` whose access is still valid at `now()`: a revoked or expired one shows nothing.
    private func authorizedGrantIfAny(_ vaultID: UUID) -> VaultGrant? {
        guard let grant = grants[vaultID], (try? grant.access.checkAuthorization(at: now())) != nil else { return nil }
        return grant
    }

    /// The wrapper plaintext (credential id, PRF input) of one active vault, in stored order; no secret and no grant needed.
    func discovery(vaultID: UUID) async throws -> VaultDiscovery {
        try await rerouting {
            if let locked = try await lockedVaults() {
                guard let vault = locked.first(where: { $0.vaultID == vaultID }) else { throw CredentialStoreError.noSuchVault }
                return VaultDiscovery(vaultID: vaultID, unlocks: vault.wrappers.map(\.unlock))
            }
            let row = try await withOperation { pool in
                try pool.read { (db: Database) throws in try Self.activeRow(vaultID, in: db) }
            }
            let wrappers = try mapIntegrity(row.ordinal) { try VaultWrapperList.decode(row.wrappers) }
            return VaultDiscovery(vaultID: vaultID, unlocks: wrappers.map(\.unlock))
        }
    }

    // MARK: Grants

    func lock(vaultID: UUID) {
        grants.removeValue(forKey: vaultID)?.access.revoke()
    }

    func lock(ifUsing access: VaultAccess) {
        for (vaultID, grant) in grants where grant.access === access {
            lock(vaultID: vaultID)
        }
    }

    func lockAll() {
        for vaultID in Array(grants.keys) {
            lock(vaultID: vaultID)
        }
    }

    /// Drops every grant; idempotent. No connection outlives an operation, so there is nothing else to release.
    func close() {
        lockAll()
    }

    // MARK: Fresh assertion

    /// Fresh-assertion check (purge): the credential must be enrolled on the vault and open its key with `prf`; `access` must hold the
    /// grant. Publishes and writes nothing.
    func authorize(vaultID: UUID, _ authorization: FreshAuthorization, using access: VaultAccess) async throws {
        _ = try authorizedGrant(vaultID, access)
        let (grant, row) = try await withOperation { pool -> (VaultGrant, StoreTables.VaultRow) in
            let grant = try authorizedGrant(vaultID, access)
            return (grant, try pool.read { (db: Database) throws in try Self.activeRow(vaultID, in: db) })
        }
        let wrappers = try mapIntegrity(row.ordinal) { try VaultWrapperList.decode(row.wrappers) }
        guard let wrapper = wrappers.first(where: { $0.credentialID == authorization.credentialID }),
            let key = try? CredentialVaultCrypto.unwrap(wrapper, prf: authorization.prf, profileID: profileID, vaultID: vaultID),
            key == grant.dek.withUnsafeBytes({ Data($0) })
        else { throw CredentialVaultError.authenticationFailed }
    }
}
