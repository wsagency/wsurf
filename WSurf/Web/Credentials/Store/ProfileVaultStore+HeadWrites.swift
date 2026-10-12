// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

/// What an edit changes in one vault: the new head body (the revision is set by the commit) and, when the wrapper list changes,
/// the new list.
nonisolated struct HeadChange: Sendable {
    var head: VaultHead
    var wrappers: [CredentialKeyWrapper]?
}

/// Head writes of an unlocked vault: wrapper list and password-save policy. Each is one `BEGIN IMMEDIATE` transaction on the pool's
/// writer that re-reads the registry, checks the session still matches it, and rewrites only this vault's head, wrapper list and
/// registry entry. `record` and `journal` are never touched.
extension ProfileVaultStore {
    func addUnlock(vaultID: UUID, _ proof: VaultUnlockProof, using access: VaultAccess) async throws -> VaultCommitReceipt {
        let grant = try authorizedGrant(vaultID, access)
        try CredentialVaultCrypto.validateProof(proof)
        let profile = profileID
        return try await commitHead(vaultID: vaultID, access: access) { head, wrappers in
            guard !wrappers.contains(where: { $0.credentialID == proof.credentialID }) else { throw CredentialVaultError.duplicateIdentifier }
            guard wrappers.count < CredentialVaultLimits.wrappers else { throw CredentialStoreError.limit(.wrappers) }
            let wrapper = try CredentialVaultCrypto.wrap(grant.dek, with: proof, profileID: profile, vaultID: vaultID)
            return HeadChange(head: head, wrappers: wrappers + [wrapper])
        }
    }

    func removeUnlock(
        vaultID: UUID, credentialID: Data, verifiedRemaining: VaultUnlockProof, using access: VaultAccess
    ) async throws -> VaultCommitReceipt {
        let grant = try authorizedGrant(vaultID, access)
        try CredentialVaultCrypto.validateProof(verifiedRemaining)
        guard credentialID != verifiedRemaining.credentialID else { throw CredentialVaultError.noUnlocks }
        let profile = profileID
        let receipt = try await commitHead(vaultID: vaultID, access: access) { head, wrappers in
            guard wrappers.count > 1 else { throw CredentialVaultError.noUnlocks }
            guard let verifiedWrapper = wrappers.first(where: { $0.credentialID == verifiedRemaining.credentialID }),
                let verifiedKey = try? CredentialVaultCrypto.unwrap(
                    verifiedWrapper, prf: verifiedRemaining.prf, profileID: profile, vaultID: vaultID
                ),
                verifiedKey == grant.dek.withUnsafeBytes({ Data($0) })
            else { throw CredentialVaultError.authenticationFailed }
            guard wrappers.contains(where: { $0.credentialID == credentialID }) else { throw CredentialVaultError.invalidData }
            let remaining = wrappers.filter { $0.credentialID != credentialID }
            guard !remaining.isEmpty else { throw CredentialVaultError.noUnlocks }
            return HeadChange(head: head, wrappers: remaining)
        }
        // The grant that was unlocked with the removed credential ends with it (its access is revoked).
        if grants[vaultID]?.credentialID == credentialID {
            lock(vaultID: vaultID)
        }
        return receipt
    }

    func updatePasswordSavePolicy(
        vaultID: UUID, _ blocked: Set<String>, expectedRevision: UInt64, using access: VaultAccess
    ) async throws -> VaultCommitReceipt {
        _ = try authorizedGrant(vaultID, access)
        guard blocked.count <= StoreFormat.blockedOriginLimit else { throw CredentialStoreError.limit(.blockedOrigins) }
        for origin in blocked {
            guard let url = URL(string: origin), CredentialAccount.origin(for: url) == origin else { throw CredentialStoreError.malformed }
        }
        let origins = blocked.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return try await commitHead(vaultID: vaultID, access: access) { head, _ in
            guard expectedRevision == head.revision else { throw CredentialVaultError.staleRevision }
            guard head.blockedOrigins != origins else { return nil }  // an equal set is a no-op: nothing is written
            var next = head
            next.blockedOrigins = origins
            return HeadChange(head: next, wrappers: nil)
        }
    }

    /// Runs `edit` on the freshly read head and wrapper list inside the write transaction; `nil` commits nothing.
    private func commitHead(
        vaultID: UUID,
        access: VaultAccess,
        edit: (_ head: VaultHead, _ wrappers: [CredentialKeyWrapper]) throws -> HeadChange?
    ) async throws -> VaultCommitReceipt {
        let clock = now
        let (receipt, entry) = try await withOperation { pool in
            let grant = try authorizedGrant(vaultID, access)  // re-checked after the lock wait
            var committed: (receipt: VaultCommitReceipt, entry: RegistryEntry?)?
            try pool.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    committed = try Self.applyHeadChange(db, grant: grant, vaultID: vaultID, access: access, now: clock, edit: edit)
                    return committed?.entry == nil ? .rollback : .commit
                }
            }
            guard let committed else { throw CredentialStoreError.integrityFailure(vaultOrdinal: grant.ordinal) }
            return (committed.receipt, committed.entry)
        }
        if let entry, grants[vaultID]?.access === access {
            grants[vaultID]?.entry = entry
        }
        return receipt
    }

    nonisolated private static func applyHeadChange(
        _ db: Database,
        grant: VaultGrant,
        vaultID: UUID,
        access: VaultAccess,
        now: @Sendable () -> ContinuousClock.Instant,
        edit: (VaultHead, [CredentialKeyWrapper]) throws -> HeadChange?
    ) throws -> (receipt: VaultCommitReceipt, entry: RegistryEntry?) {
        try access.checkAuthorization(at: now())
        let ordinal = grant.ordinal
        let integrity = CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)

        // The registry as it is now: authenticated, and still the entries this session verified.
        let catalog = try mapIntegrity(nil) { () throws -> RegistryCatalog in
            guard let stored = try StoreTables.registry(db), StoreSeal.verifyRegistryMAC(rk: grant.registryKey, catalog: stored.catalog, mac: stored.mac) else {
                throw CredentialStoreError.malformed
            }
            let catalog = try RegistryCatalog.decode(stored.catalog)
            guard catalog.ids == grant.ids, catalog.revision == stored.revision else { throw CredentialStoreError.malformed }
            return catalog
        }
        guard let entry = catalog.vaults.first(where: { $0.vaultID == vaultID }),
            let trashEntry = catalog.vaults.first(where: { $0.vaultID == grant.trashID })
        else { throw integrity }
        guard entry == grant.entry, trashEntry == grant.trashEntry else { throw CredentialVaultError.staleRevision }

        // The stored vault and head are what that entry says; then the head opens under the session's key.
        let row = try activeRow(vaultID, in: db)
        guard let storedHead = try mapIntegrity(ordinal, { try StoreTables.head(db, vaultID: vaultID) }),
            StoreSeal.digestOrZero(row.wrappers) == entry.wrappersDigest, StoreSeal.digestOrZero(row.keyWrap) == entry.keyWrapDigest,
            storedHead.revision == entry.headRevision, StoreSeal.digest(storedHead.sealed) == entry.headDigest
        else { throw integrity }
        let (head, wrappers) = try mapIntegrity(ordinal) { () throws -> (VaultHead, [CredentialKeyWrapper]) in
            let head = try StoreSeal.openHead(
                storedHead.sealed, key: grant.dek, ids: grant.ids, vaultID: vaultID, revision: storedHead.revision,
                wrappersDigest: entry.wrappersDigest, keyWrapDigest: entry.keyWrapDigest
            )
            return (head, try VaultWrapperList.decode(row.wrappers))
        }

        guard let change = try edit(head, wrappers) else { return (VaultCommitReceipt(revision: head.revision), nil) }

        guard head.revision < UInt64(Int64.max), catalog.revision < UInt64(Int64.max) else { throw CredentialVaultError.invalidData }
        var next = change.head
        next.revision = head.revision + 1
        var nextEntry = entry
        if let changed = change.wrappers {
            let bytes = try VaultWrapperList.encode(changed)
            nextEntry.wrappersDigest = StoreSeal.digest(bytes)
            try db.execute(sql: "UPDATE vault SET wrappers = ? WHERE vaultID = ?", arguments: [bytes, vaultID.uuidString.lowercased()])
            guard db.changesCount == 1 else { throw integrity }
        }
        let sealed = try StoreSeal.sealHead(next, key: grant.dek, wrappersDigest: nextEntry.wrappersDigest, keyWrapDigest: entry.keyWrapDigest)
        try StoreTables.putHead(db, vaultID: vaultID, revision: next.revision, sealed: sealed)
        nextEntry.headRevision = next.revision
        nextEntry.headDigest = StoreSeal.digest(sealed)

        var nextCatalog = catalog
        nextCatalog.revision += 1
        nextCatalog.vaults = catalog.vaults.map { $0.vaultID == vaultID ? nextEntry : $0 }
        let encoded = nextCatalog.encode()
        try StoreTables.putRegistry(
            db, revision: nextCatalog.revision, catalog: encoded, mac: StoreSeal.registryMAC(rk: grant.registryKey, catalog: encoded)
        )
        return (VaultCommitReceipt(revision: next.revision), nextEntry)
    }
}
