// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB

/// Delete Vault, the second way credentials leave the store besides a profile erase. Like a purge it is a logical row deletion, not
/// secure erasure, and it needs a fresh assertion of a passkey enrolled in THIS vault on top of the unlock: a cached lease alone, or
/// another vault's passkey, never deletes. The one exception is a vault that holds nothing (`deleteEmptyVault`). One
/// `BEGIN IMMEDIATE` transaction removes every row of the vault and of its linked Trash and rewrites the registry without them; a
/// failure or cancellation before the commit leaves the store as it was. The other vaults' rows and wrappers, the registry key
/// (sealed in every active head), the stub, the A3 witness and every other file are not touched.
extension ProfileVaultStore {
    func deleteVault(vaultID: UUID, authorization: FreshAuthorization, using access: VaultAccess) async throws {
        try await authorize(vaultID: vaultID, authorization, using: access)
        try await commitDeletion(vaultID: vaultID, using: access, requireEmpty: false)
    }

    /// A vault that holds nothing at all goes with the unlock alone: nothing can be lost, so there is no assertion to ask for. The
    /// store decides what "nothing" is, inside the same transaction that deletes (`vaultNotEmpty` otherwise, with nothing written),
    /// so a credential saved a moment earlier can never be deleted this way. Every other rule is `deleteVault`'s.
    func deleteEmptyVault(vaultID: UUID, using access: VaultAccess) async throws {
        _ = try authorizedGrant(vaultID, access)
        try await commitDeletion(vaultID: vaultID, using: access, requireEmpty: true)
    }

    private func commitDeletion(vaultID: UUID, using access: VaultAccess, requireEmpty: Bool) async throws {
        let clock = now
        try await withOperation { pool in
            let grant = try authorizedGrant(vaultID, access)  // re-checked after the lock wait
            try pool.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    try Self.deleting(db, grant: grant, vaultID: vaultID, access: access, now: clock, requireEmpty: requireEmpty)
                    return .commit
                }
            }
            try? pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        }
        // Committed: nothing below throws. The grant goes with the vault, and so do the preferences keyed by its id.
        lock(vaultID: vaultID)
        verified.remove(vaultID)
        CredentialAutoLock.forget(for: vaultID, in: defaults)
        if defaultVaultID() == vaultID {
            setDefaultVault(nil)
        }
    }

    /// The write transaction's body. The last vault is refused here, against the registry as it is now.
    nonisolated static func deleting(
        _ db: Database, grant: VaultGrant, vaultID: UUID, access: VaultAccess, now: @Sendable () -> ContinuousClock.Instant,
        requireEmpty: Bool = false
    ) throws {
        let opened = try openVault(db, grant: grant, vaultID: vaultID, access: access, now: now)
        guard opened.catalog.vaults.lazy.filter({ $0.role == .active }).count > 1 else { throw CredentialStoreError.lastVault }
        if requireEmpty, try !holdsNothing(db, head: opened.head, trashID: grant.trashID) {
            throw CredentialStoreError.vaultNotEmpty
        }
        guard opened.catalog.revision < UInt64(Int64.max) else { throw CredentialVaultError.invalidData }
        for id in [vaultID, grant.trashID] {
            try erase(db, vaultID: id, ordinal: grant.ordinal)
        }
        var next = opened.catalog
        next.revision += 1
        next.vaults.removeAll { $0.vaultID == vaultID || $0.vaultID == grant.trashID }
        try VaultBuild.putRegistry(db, catalog: next, registryKey: grant.registryKey)
        try Task.checkCancellation()  // last poll before the commit: a cancel here still rolls everything back
    }

    /// Nothing stored at all, read from the rows and not from any counter: no record row of any kind (live account, earlier version,
    /// Trash entry, tombstone) and no journal row in the vault or its Trash, and no website blocked from saving. A vault that was
    /// ever used leaves at least one of them, even after its Trash was emptied.
    private nonisolated static func holdsNothing(_ db: Database, head: VaultHead, trashID: UUID) throws -> Bool {
        guard head.blockedOrigins.isEmpty, head.liveCatalog.isEmpty else { return false }
        let ids = [head.vaultID, trashID].map { $0.uuidString.lowercased() }
        for table in ["record", "journal"] {
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE vaultID IN (?, ?)", arguments: [ids[0], ids[1]])
            if rows != 0 {
                return false
            }
        }
        return true
    }

    /// Every row of one vault id. The head goes before the vault row it references.
    private nonisolated static func erase(_ db: Database, vaultID: UUID, ordinal: Int) throws {
        let id = vaultID.uuidString.lowercased()
        for table in ["record", "journal", "head"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE vaultID = ?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM vault WHERE vaultID = ?", arguments: [id])
        guard db.changesCount == 1 else { throw CredentialStoreError.integrityFailure(vaultOrdinal: ordinal) }
    }
}
