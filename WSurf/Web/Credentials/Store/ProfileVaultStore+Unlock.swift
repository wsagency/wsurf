// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

/// Spec §6.8: the unlock pipeline. A grant is published only after the whole pair (selected vault, registry, linked Trash) verified in
/// one read snapshot, the stub is repaired and A3 is set, and the access is still valid, all under the operation lock.
extension ProfileVaultStore {
    // MARK: Step 0: lock

    /// The stub state read-only: `stubMissing` for `.provisional`, the fail-closed error, or `stateChanged` for any other state.
    private func provisionalStubMissing() throws -> Bool {
        switch openState() {
        case .provisional(_, let stubMissing):
            return stubMissing
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        case .legacy, .firstRun, .resumeMigration:
            throw CredentialStoreError.stateChanged
        }
    }

    /// EXCLUSIVE is needed when `Credentials.scratch` holds any entry or exists but cannot be inspected: a leftover may be another
    /// process's live scratch file, and only EXCLUSIVE proves nobody is verifying.
    private func scratchNeedsExclusive() -> Bool {
        let scratch = VerificationScratch.directory(in: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: scratch.path) else { return StoreAnchors.exists(scratch) }
        return !names.isEmpty
    }

    /// Takes the operation lock in the mode the state needs (never upgrading: a wrong guess releases and restarts), then runs
    /// `unlockHeld`. The lock is held until the grant is published or the unlock fails.
    func unlockInitialized(
        vaultID: UUID,
        credentialID: Data,
        prf: SymmetricKey,
        access: VaultAccess,
        verifying: (@Sendable (Bool) -> Void)?,
        scratchWarning: (@Sendable (URL) -> Void)?
    ) async throws {
        guard access.profileID == profileID else { throw CredentialVaultError.unauthorized }
        while true {
            // The routing read: a non-provisional or fail-closed state takes no lock and touches nothing.
            let routedMissing = try provisionalStubMissing()
            let mode: OperationLock.Mode = routedMissing || scratchNeedsExclusive() ? .exclusive : .shared
            let hold = try await acquireOperation(mode: mode)
            defer { hold.release() }
            let missing = try provisionalStubMissing()
            if mode == .shared, missing || scratchNeedsExclusive() {
                continue
            }
            do {
                try unlockHeld(
                    hold, mode: mode, vaultID: vaultID, credentialID: credentialID, prf: prf, access: access,
                    verifying: verifying, scratchWarning: scratchWarning
                )
            } catch let error as DatabaseError {
                throw storeError(error, ordinal: nil)
            }
            return
        }
    }

    // MARK: Steps 1-8

    /// The unlock with the operation lock already held in `mode` by the caller, who releases it afterwards: steps 1-7 (`verifyHeld`),
    /// then step 8, the only publish.
    func unlockHeld(
        _ held: OperationLockHold,
        mode: OperationLock.Mode,
        vaultID: UUID,
        credentialID: Data,
        prf: SymmetricKey,
        access: VaultAccess,
        verifying: (@Sendable (Bool) -> Void)?,
        scratchWarning: (@Sendable (URL) -> Void)?
    ) throws {
        let verifiedGrant = try verifyHeld(
            held, mode: mode, vaultID: vaultID, credentialID: credentialID, prf: prf, access: access,
            verifying: verifying, scratchWarning: scratchWarning
        )
        // Step 8: publish, last, only for a still-valid access.
        try access.withAuthorization(now: now) {
            if let previous = grants[vaultID], previous.access !== access {
                previous.access.revoke()
            }
            grants[vaultID] = verifiedGrant
            verified.insert(vaultID)
        }
    }

    /// Steps 1-7 with the operation lock `held` (taken in `mode` by the caller, who keeps it for the whole call and releases it):
    /// the verified grant, which this function never publishes. This function neither acquires, upgrades nor releases the hold.
    func verifyHeld(
        _ held: OperationLockHold,
        mode: OperationLock.Mode,
        vaultID: UUID,
        credentialID: Data,
        prf: SymmetricKey,
        access: VaultAccess,
        verifying: (@Sendable (Bool) -> Void)?,
        scratchWarning: (@Sendable (URL) -> Void)?
    ) throws -> VaultGrant {
        guard access.profileID == profileID else { throw CredentialVaultError.unauthorized }
        // Leftover scratch goes only under EXCLUSIVE and before the anchors are re-checked or anything is granted.
        if mode == .exclusive {
            for undeleted in VerificationScratch.cleanLeftovers(in: directory) {
                scratchWarning?(undeleted)
            }
        }
        let ids: StoreIDs
        let stubMissing: Bool
        switch openState() {
        case .provisional(let storeID, let missing):
            ids = StoreIDs(storeID: storeID, profileID: profileID)
            stubMissing = missing
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        case .legacy, .firstRun, .resumeMigration:
            throw CredentialStoreError.stateChanged
        }

        // Steps 2-5 in one read snapshot with the scratch attached; both are gone, and the pool is closed, before steps 6-7.
        let clock = now
        let profile = profileID
        let verifiedGrant = try withPool { pool in
            let started = clock()
            var verifyingFired = false
            defer {
                if verifyingFired {
                    verifying?(false)
                }
            }
            let isCancelled: () -> Bool = {
                if !verifyingFired, started.duration(to: clock()) >= StoreFormat.verifyingThreshold {
                    verifyingFired = true
                    verifying?(true)
                }
                return Task.isCancelled
            }
            return try VerificationScratch.run(
                on: pool, supportDirectory: directory, cleanupFailed: { scratchWarning?($0) }
            ) { db in
                try Self.verifyPair(
                    db, ids: ids, profileID: profile, vaultID: vaultID, credentialID: credentialID, prf: prf, access: access,
                    isCancelled: isCancelled
                )
            }
        }

        // Step 6: stub repair. An old build's v1 file that appeared meanwhile is never overwritten.
        if stubMissing, mode == .exclusive {
            do {
                try StoreAnchors.writeStubIfAbsent(directory: directory, ids: ids, fileOps: fileOps)
            } catch StoreFileError.exists {
                switch openState() {
                case .failClosed(let closed):
                    throw CredentialStoreError.failClosed(closed)
                case .provisional(_, false):
                    break  // a stub of this store appeared: nothing to repair
                case .provisional, .legacy, .firstRun, .resumeMigration:
                    throw CredentialStoreError.stateChanged
                }
            }
        }
        // Step 7: A3 only if absent.
        _ = StoreAnchors.setWitnessIfAbsent(ids.storeID, defaults: defaults)

        return verifiedGrant
    }

    // MARK: Steps 2-5

    /// Authenticates the selected vault's head (step 2), the registry and its agreement with every stored row and head (step 3),
    /// the linked Trash (step 4) and the V1-V5 verification (step 5). Runs inside the caller's read snapshot.
    nonisolated static func verifyPair(
        _ db: Database,
        ids: StoreIDs,
        profileID: UUID,
        vaultID: UUID,
        credentialID: Data,
        prf: SymmetricKey,
        access: VaultAccess,
        isCancelled: () -> Bool
    ) throws -> VaultGrant {
        if isCancelled() {
            throw CancellationError()
        }
        let row = try activeRow(vaultID, in: db)
        let ordinal = row.ordinal

        // Step 2: the selected vault's head.
        let wrappers = try mapIntegrity(ordinal) { try VaultWrapperList.decode(row.wrappers) }
        guard let wrapper = wrappers.first(where: { $0.credentialID == credentialID }),
            let keyBytes = try? CredentialVaultCrypto.unwrap(wrapper, prf: prf, profileID: profileID, vaultID: vaultID)
        else { throw CredentialVaultError.authenticationFailed }
        let dek = SymmetricKey(data: keyBytes)
        let head = try openStoredHead(db, row: row, key: dek, ids: ids, ordinal: ordinal)
        guard head.role == .active, let registryKey = head.registryKey else { throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal) }

        // Step 3: the registry.
        let rows = try mapIntegrity(nil) { try StoreTables.vaultRows(db) }
        let catalog = try verifiedCatalog(db, rows: rows, registryKey: registryKey, ids: ids)
        guard let entry = catalog.vaults.first(where: { $0.vaultID == vaultID }),
            let trashEntry = catalog.vaults.first(where: { $0.vaultID == head.link.peerVaultID && $0.role == .trash })
        else { throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal) }

        // Step 4: the linked Trash.
        guard let trashRow = rows.first(where: { $0.vaultID == trashEntry.vaultID && $0.role == .trash }), let keyWrap = trashRow.keyWrap else {
            throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)
        }
        let trashKey = try mapIntegrity(ordinal) {
            try StoreSeal.unwrapTrashKey(keyWrap, under: dek, ids: ids, source: vaultID, trash: trashRow.vaultID, nonce: head.link.nonce)
        }
        let trashHead = try openStoredHead(db, row: trashRow, key: trashKey, ids: ids, ordinal: ordinal)
        guard trashHead.role == .trash, trashHead.link.peerVaultID == vaultID, trashHead.link.nonce == head.link.nonce else {
            throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)
        }

        // Step 5: V1-V5.
        try StoreVerifier(ids: ids).verify(
            in: db,
            source: (id: vaultID, key: dek, head: head),
            trash: (id: trashRow.vaultID, key: trashKey, head: trashHead),
            isCancelled: isCancelled
        )
        return VaultGrant(
            access: access, credentialID: credentialID, dek: dek, registryKey: registryKey, ids: ids, ordinal: ordinal,
            name: head.name, trashID: trashRow.vaultID, entry: entry, trashEntry: trashEntry
        )
    }

    /// Opens one stored head against its row's wrappers and key wrap and the stored revision; every failure names `ordinal`.
    nonisolated private static func openStoredHead(
        _ db: Database, row: StoreTables.VaultRow, key: SymmetricKey, ids: StoreIDs, ordinal: Int
    ) throws -> VaultHead {
        try mapIntegrity(ordinal) {
            guard let stored = try StoreTables.head(db, vaultID: row.vaultID) else { throw CredentialStoreError.malformed }
            let head = try StoreSeal.openHead(
                stored.sealed, key: key, ids: ids, vaultID: row.vaultID, revision: stored.revision,
                wrappersDigest: StoreSeal.digestOrZero(row.wrappers), keyWrapDigest: StoreSeal.digestOrZero(row.keyWrap)
            )
            guard head.ids == ids, head.vaultID == row.vaultID, head.role == row.role, head.revision == stored.revision else {
                throw CredentialStoreError.malformed
            }
            return head
        }
    }

    /// The registry row authenticated with `registryKey`, decoded, and compared with every stored vault row and head. A missing vault
    /// or Trash row (or head) names its ordinal; every other difference names none. Either way the failure is store-wide.
    nonisolated static func verifiedCatalog(
        _ db: Database, rows: [StoreTables.VaultRow], registryKey: Data, ids: StoreIDs
    ) throws -> RegistryCatalog {
        let catalog = try mapIntegrity(nil) { () throws -> RegistryCatalog in
            guard let stored = try StoreTables.registry(db),
                StoreSeal.verifyRegistryMAC(rk: registryKey, catalog: stored.catalog, mac: stored.mac)
            else { throw CredentialStoreError.malformed }
            let catalog = try RegistryCatalog.decode(stored.catalog)
            guard catalog.ids == ids, catalog.revision == stored.revision else { throw CredentialStoreError.malformed }
            return catalog
        }
        var heads: [UUID: (revision: UInt64, sealed: Data)] = [:]
        for entry in catalog.vaults {
            guard rows.contains(where: { $0.vaultID == entry.vaultID }),
                let head = try mapIntegrity(nil, { try StoreTables.head(db, vaultID: entry.vaultID) })
            else { throw CredentialStoreError.integrityFailure(vaultOrdinal: entry.ordinal) }
            heads[entry.vaultID] = head
        }
        guard rows.count == catalog.vaults.count else { throw CredentialStoreError.integrityFailure(vaultOrdinal: nil) }
        for entry in catalog.vaults {
            guard let row = rows.first(where: { $0.vaultID == entry.vaultID }), let head = heads[entry.vaultID],
                row.role == entry.role, row.ordinal == entry.ordinal, row.createdAt == entry.createdAt,
                StoreSeal.digestOrZero(row.wrappers) == entry.wrappersDigest, StoreSeal.digestOrZero(row.keyWrap) == entry.keyWrapDigest,
                head.revision == entry.headRevision, StoreSeal.digest(head.sealed) == entry.headDigest
            else { throw CredentialStoreError.integrityFailure(vaultOrdinal: nil) }
        }
        return catalog
    }

    // MARK: Snapshot

    /// The live accounts of one unlocked vault, read from the file and checked against the head's `liveCatalog`.
    func snapshot(vaultID: UUID, using access: VaultAccess) async throws -> StoreSnapshot {
        _ = try authorizedGrant(vaultID, access)
        return try await withOperation { pool in
            let grant = try authorizedGrant(vaultID, access)
            return try pool.read { (db: Database) throws in try Self.readSnapshot(db, grant: grant, vaultID: vaultID) }
        }
    }

    nonisolated static func readSnapshot(_ db: Database, grant: VaultGrant, vaultID: UUID) throws -> StoreSnapshot {
        let row = try activeRow(vaultID, in: db)
        let head = try openStoredHead(db, row: row, key: grant.dek, ids: grant.ids, ordinal: grant.ordinal)
        return try mapIntegrity(grant.ordinal) {
            var accounts: [CredentialAccount] = []
            var stamps: [UUID: AccountStamp] = [:]
            for entry in head.liveCatalog {
                guard let record = try StoreTables.record(db, vaultID: vaultID, recordID: entry.recordID),
                    record.kind == .account, record.version == entry.version, StoreSeal.digest(record.sealed) == entry.digest
                else { throw CredentialStoreError.malformed }
                let aad = RowAAD(
                    ids: grant.ids, vaultID: vaultID, recordID: record.recordID, kind: record.kind, ownerID: record.ownerID,
                    subject: record.subject, version: record.version
                )
                let account = try JSONDecoder().decode(CredentialAccount.self, from: StoreSeal.openRow(record.sealed, key: grant.dek, aad: aad))
                guard account.id == entry.recordID else { throw CredentialStoreError.malformed }
                accounts.append(account)
                stamps[entry.recordID] = AccountStamp(version: entry.version, digest: entry.digest)
            }
            guard try StoreTables.recordCount(db, vaultID: vaultID, kind: .account) == head.liveCatalog.count else {
                throw CredentialStoreError.malformed
            }
            return StoreSnapshot(
                vaultID: vaultID, revision: head.revision, accounts: accounts, blockedPasswordOrigins: Set(head.blockedOrigins), stamps: stamps
            )
        }
    }
}
