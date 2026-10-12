// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

extension ProfileVaultStore {
    /// THE public unlock. Routes on `openState()` with no lock held:
    /// `.provisional` goes to `unlockInitialized` (which owns its lock), `.failClosed` throws its error, `.firstRun` is `noSuchVault`,
    /// and `.legacy`/`.resumeMigration` need `confirmMigration` (else `migrationNeedsConfirmation`, before any lock or write). A state
    /// that changed between the route and the lock is re-routed once; a second change is `stateChanged`. `afterMigrationStep(0)` is the test
    /// seam for exactly that boundary: it fires after a route that will take the lock and before the lock is requested.
    func unlock(
        vaultID: UUID,
        credentialID: Data,
        prf: SymmetricKey,
        confirmMigration: Bool,
        access: VaultAccess,
        verifying: (@Sendable (Bool) -> Void)?,
        scratchWarning: (@Sendable (URL) -> Void)?
    ) async throws {
        guard access.profileID == profileID else { throw CredentialVaultError.unauthorized }
        var rerouted = false
        while true {
            do {
                switch openState() {
                case .provisional:
                    try fileOps.afterMigrationStep?(0)
                    try await unlockInitialized(
                        vaultID: vaultID, credentialID: credentialID, prf: prf, access: access, verifying: verifying, scratchWarning: scratchWarning
                    )
                case .failClosed(let closed):
                    throw CredentialStoreError.failClosed(closed)
                case .firstRun:
                    throw CredentialStoreError.noSuchVault
                case .legacy, .resumeMigration:
                    guard confirmMigration else { throw CredentialStoreError.migrationNeedsConfirmation }
                    try fileOps.afterMigrationStep?(0)
                    try await unlockMigrating(
                        vaultID: vaultID, credentialID: credentialID, prf: prf, access: access, verifying: verifying, scratchWarning: scratchWarning
                    )
                }
                return
            } catch CredentialStoreError.stateChanged where !rerouted {
                rerouted = true
            }
        }
    }

    /// The EXCLUSIVE lock taken once, the state re-read under it, the migration (or its resume) run, then the normal §6.8 unlock under the
    /// same hold. The lock is released when this returns or throws.
    private func unlockMigrating(
        vaultID: UUID,
        credentialID: Data,
        prf: SymmetricKey,
        access: VaultAccess,
        verifying: (@Sendable (Bool) -> Void)?,
        scratchWarning: (@Sendable (URL) -> Void)?
    ) async throws {
        try access.checkAuthorization(at: now())  // no migration for an access that is already dead
        let hold = try await OperationLock.acquire(in: directory, mode: .exclusive, wait: lockWait)
        defer { hold.release() }
        do {
            switch openState() {
            case .legacy(let legacyID):
                try migrateLegacy(legacyID: legacyID, vaultID: vaultID, credentialID: credentialID, prf: prf, scratchWarning: scratchWarning)
            case .resumeMigration(let storeID):
                try resumeMigration(storeID: storeID, vaultID: vaultID, credentialID: credentialID, prf: prf, scratchWarning: scratchWarning)
            case .failClosed(let closed):
                throw CredentialStoreError.failClosed(closed)
            case .provisional, .firstRun:
                throw CredentialStoreError.stateChanged
            }
            try unlockHeld(
                hold, mode: .exclusive, vaultID: vaultID, credentialID: credentialID, prf: prf, access: access,
                verifying: verifying, scratchWarning: scratchWarning
            )
        } catch let error as DatabaseError {
            throw storeError(error, ordinal: nil)
        }
    }
}
