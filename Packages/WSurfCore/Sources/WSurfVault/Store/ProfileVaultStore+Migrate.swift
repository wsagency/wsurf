// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

/// What re-opening a pending store reads back: its snapshot and the stored wrapper bytes of the selected vault.
private nonisolated struct PendingReadback {
    let snapshot: StoreSnapshot
    let wrappers: Data?
}

/// Spec §10: the one-way migration of the v1 vault into the v2 store, and the resume of an interrupted one. Everything here runs with
/// the EXCLUSIVE operation lock held by the caller; `afterMigrationStep` fires after each step (1-10) and, from step 4 to step 8,
/// a `-wal`/`-shm` beside the pending store aborts before anything is published.
extension ProfileVaultStore {
    /// Name of the migrated vault: the v1 file carries none.
    nonisolated static let migratedVaultName = "Personal"

    func seam(_ step: Int) throws {
        try fileOps.afterMigrationStep?(step)
        if (4...8).contains(step) {
            try PendingStore.requireNoSidecars(at: file(StoreAnchors.Names.migrating))
        }
    }

    // MARK: Shared steps

    func buildPending(ids: StoreIDs, registryKey: Data, vault: NewVault) throws {
        try PendingStore.build(at: file(StoreAnchors.Names.migrating), ids: ids, registryKey: registryKey, vault: vault, fileOps: fileOps)
    }

    /// Spec §10 step 5 and §8 item 1: reopen the closed pending file by the recipe, run §6.8 steps 2-5 with the supplied credential, close
    /// again by the recipe, then `F_FULLFSYNC` the file and fsync the directory.
    private func verifyPending(
        ids: StoreIDs, vaultID: UUID, credentialID: Data, prf: SymmetricKey, scratchWarning: (@Sendable (URL) -> Void)?
    ) throws -> PendingReadback {
        let pending = file(StoreAnchors.Names.migrating)
        let profile = profileID
        let access = VaultAccess(profileID: profile, epoch: 0, deadline: now().advanced(by: .seconds(300)))
        defer { access.revoke() }
        let readback = try PendingStore.verify(at: pending, supportDirectory: directory, cleanupFailed: { scratchWarning?($0) }) { db in
            let grant = try Self.verifyPair(
                db, ids: ids, profileID: profile, vaultID: vaultID, credentialID: credentialID, prf: prf, access: access,
                isCancelled: { Task.isCancelled }
            )
            return PendingReadback(
                snapshot: try Self.readSnapshot(db, grant: grant, vaultID: vaultID), wrappers: try Self.activeRow(vaultID, in: db).wrappers
            )
        }
        try fileOps.fullFsync(pending)
        try fileOps.fsyncDirectory(directory)
        return readback
    }

    /// First-vault bootstrap's verification step (nothing to compare with).
    func verifyBootstrapped(ids: StoreIDs, vaultID: UUID, proof: VaultUnlockProof) throws {
        _ = try verifyPending(ids: ids, vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, scratchWarning: nil)
    }

    /// The prepared stub into `Credentials.vault.swap` (never over an existing file), `F_FULLFSYNC`, fsync the directory.
    func writeStubToSwap(ids: StoreIDs) throws {
        let swap = file(StoreAnchors.Names.swap)
        let stub = StoreAnchors.stubBytes(ids: ids)
        guard !stub.isEmpty else { throw StoreFileError.io(EINVAL) }
        try stub.write(to: swap, options: .withoutOverwriting)
        try fileOps.fullFsync(swap)
        try fileOps.fsyncDirectory(directory)
    }

    /// Step 9: the pending store becomes `Credentials.store` (never over an existing one), then fsync the directory. The last sidecar check
    /// is the line before the rename, whatever ran since the file was verified (migration, resume and first-vault creation all land here).
    func publishPending() throws {
        try PendingStore.requireNoSidecars(at: file(StoreAnchors.Names.migrating))
        do {
            try fileOps.renameExclusive(file(StoreAnchors.Names.migrating), file(StoreAnchors.Names.store))
        } catch StoreFileError.exists {
            throw CredentialStoreError.migrationAborted(path: file(StoreAnchors.Names.store))
        }
        try fileOps.fsyncDirectory(directory)
    }

    func removeIfPresent(_ name: String) throws {
        let target = file(name)
        if StoreAnchors.exists(target) {
            try FileManager.default.removeItem(at: target)
        }
    }

    // MARK: Migration of a legacy vault

    /// Steps 1-10 for `.legacy(legacyID)`; the caller then runs the normal unlock under the same hold.
    func migrateLegacy(
        legacyID: UUID, vaultID: UUID, credentialID: Data, prf: SymmetricKey, scratchWarning: (@Sendable (URL) -> Void)?
    ) throws {
        guard vaultID == legacyID else { throw CredentialStoreError.noSuchVault }
        let vaultFile = file(StoreAnchors.Names.vault)

        // Step 1: B0 is read once; the DEK and the accounts come from B0 itself.
        let b0 = try LegacyVaultV1.readEnvelope(at: vaultFile)
        let opened = try LegacyVaultV1.open(b0, profileID: profileID, credentialID: credentialID, prf: prf)
        guard opened.vaultID == legacyID else { throw CredentialStoreError.stateChanged }
        try seam(1)

        // Step 2: the backup, a byte copy of B0.
        try ensureBackup(b0)
        try seam(2)

        // Step 3: v1 and the backup are verified, so derived leftovers go now; displaced evidence never does.
        try discardDerivedLeftovers()
        try seam(3)

        // Step 4: the pending store, same vault id and wrappers, one account row per account, fresh RK and linked Trash.
        let ids = StoreIDs(storeID: UUID(), profileID: profileID)
        let vault = NewVault(
            vaultID: legacyID, trashID: UUID(), dek: opened.dek, trashDEK: SymmetricKey(size: .bits256), ordinal: 1,
            name: Self.migratedVaultName, wrappers: opened.wrappers, createdAt: wall(),
            blockedOrigins: opened.payload.blockedPasswordOrigins.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
            accounts: opened.payload.accounts
        )
        try buildPending(ids: ids, registryKey: VaultBuild.randomBytes(32), vault: vault)
        try seam(4)

        // Step 5: verify the closed file against B0.
        let readback = try verifyPending(ids: ids, vaultID: legacyID, credentialID: credentialID, prf: prf, scratchWarning: scratchWarning)
        guard try Self.matches(readback, payload: opened.payload, wrappers: opened.wrappers) else {
            throw CredentialStoreError.migrationAborted(path: file(StoreAnchors.Names.migrating))
        }
        try seam(5)

        // Step 6: the stub.
        try writeStubToSwap(ids: ids)
        try seam(6)

        // Step 7: the commit point.
        do {
            try fileOps.renameSwap(file(StoreAnchors.Names.swap), vaultFile)
        } catch StoreFileError.unsupported {
            try? FileManager.default.removeItem(at: file(StoreAnchors.Names.swap))  // our own derived stub; v1 was never touched
            throw CredentialStoreError.renameSwapUnsupported
        }
        try fileOps.fsyncDirectory(directory)
        try seam(7)

        // Step 8: what the swap displaced.
        try settleDisplaced(reference: b0)
        try seam(8)

        // Steps 9-10.
        try publishPending()
        try seam(9)
        _ = StoreAnchors.setWitnessIfAbsent(ids.storeID, defaults: defaults)
        try seam(10)
    }

    /// Step 2: absent ⇒ temp file, `F_FULLFSYNC`, exclusive rename, fsync; present ⇒ byte-identical to B0 or abort with nothing changed.
    private func ensureBackup(_ b0: Data) throws {
        let backup = file(StoreAnchors.Names.preV2)
        if StoreAnchors.exists(backup) {
            try requireBackupEquals(b0)
            return
        }
        let temp = file("\(StoreAnchors.Names.preV2).tmp-\(UUID().uuidString)")
        try b0.write(to: temp, options: .withoutOverwriting)
        do {
            try fileOps.fullFsync(temp)
            try fileOps.renameExclusive(temp, backup)
        } catch StoreFileError.exists {
            try? FileManager.default.removeItem(at: temp)
            try requireBackupEquals(b0)  // another writer made it meanwhile: reusable only if identical
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try fileOps.fsyncDirectory(directory)
    }

    private func requireBackupEquals(_ b0: Data) throws {
        let backup = file(StoreAnchors.Names.preV2)
        guard let existing = try? LegacyVaultV1.readEnvelope(at: backup), existing == b0 else {
            throw CredentialStoreError.migrationAborted(path: backup)
        }
    }

    /// Step 3: a leftover pending store (with its sidecars) and a leftover `.swap` stub are derived data; a `.swap` that is anything
    /// else may be displaced v1 evidence and aborts the migration untouched.
    private func discardDerivedLeftovers() throws {
        let swap = file(StoreAnchors.Names.swap)
        if StoreAnchors.exists(swap) {
            guard let bytes = try? LegacyVaultV1.readEnvelope(at: swap), Self.isStub(bytes) else {
                throw CredentialStoreError.migrationAborted(path: swap)
            }
            try FileManager.default.removeItem(at: swap)
        }
        for name in [StoreAnchors.Names.migrating] + PendingStore.sidecars.map({ StoreAnchors.Names.migrating + $0 }) {
            try removeIfPresent(name)
        }
    }

    /// Step 8: `Credentials.vault.swap` holds whatever v1 file was at the legacy path at the swap. Equal to `reference` (B0, or the
    /// backup on a resume) ⇒ unlink. Anything else ⇒ `Credentials.vault.cutover-v1[-UUID]`, never overwritten, and fail closed.
    private func settleDisplaced(reference: Data?) throws {
        let swap = file(StoreAnchors.Names.swap)
        guard StoreAnchors.exists(swap) else { return }
        if let reference, let displaced = try? LegacyVaultV1.readEnvelope(at: swap), displaced == reference {
            try FileManager.default.removeItem(at: swap)
            try fileOps.fsyncDirectory(directory)
            return
        }
        do {
            try fileOps.renameExclusive(swap, file(StoreAnchors.Names.cutover))
        } catch StoreFileError.exists {
            try fileOps.renameExclusive(swap, file("\(StoreAnchors.Names.cutover)-\(UUID().uuidString)"))
        }
        try fileOps.fsyncDirectory(directory)
        try seam(8)
        switch openState() {
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        case .legacy, .firstRun, .provisional, .resumeMigration:
            throw CredentialStoreError.migrationAborted(path: file(StoreAnchors.Names.cutover))
        }
    }

    // MARK: Resume

    /// `.resumeMigration`: step 8 first, then the pending store is verified with the supplied credential (§6.8 steps 2-5) and only then
    /// renamed (step 9) and A3 set (step 10). A failed verification renames and discards nothing.
    func resumeMigration(
        storeID: UUID, vaultID: UUID, credentialID: Data, prf: SymmetricKey, scratchWarning: (@Sendable (URL) -> Void)?
    ) throws {
        let ids = StoreIDs(storeID: storeID, profileID: profileID)
        try settleDisplaced(reference: try? LegacyVaultV1.readEnvelope(at: file(StoreAnchors.Names.preV2)))
        try seam(8)
        _ = try verifyPending(ids: ids, vaultID: vaultID, credentialID: credentialID, prf: prf, scratchWarning: scratchWarning)
        try publishPending()
        try seam(9)
        _ = StoreAnchors.setWitnessIfAbsent(ids.storeID, defaults: defaults)
        try seam(10)
    }

    // MARK: Comparison

    /// A stub is a binary plist `{format: 2, profileID, storeID}` (`StoreAnchors.stubBytes`).
    nonisolated private static func isStub(_ bytes: Data) -> Bool {
        guard bytes.starts(with: Data("bplist00".utf8)),
            let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        else { return false }
        return plist["format"] as? Int == 2 && plist["profileID"] is String && plist["storeID"] is String
    }

    /// The verified pending store holds exactly B0's accounts (canonical JSON), blocked origins and wrapper list.
    nonisolated private static func matches(
        _ readback: PendingReadback, payload: CredentialVaultPayload, wrappers: [CredentialKeyWrapper]
    ) throws -> Bool {
        func canonical(_ accounts: [CredentialAccount]) throws -> [UUID: Data] {
            Dictionary(try accounts.map { ($0.id, try CredentialContent.canonicalJSON($0)) }) { first, _ in first }
        }
        let expected = try canonical(payload.accounts)
        let actual = try canonical(readback.snapshot.accounts)
        let storedWrappers = try VaultWrapperList.encode(wrappers)
        return expected.count == payload.accounts.count && expected == actual
            && readback.snapshot.accounts.count == payload.accounts.count
            && readback.snapshot.blockedPasswordOrigins == payload.blockedPasswordOrigins
            && readback.wrappers == storedWrappers
    }
}
