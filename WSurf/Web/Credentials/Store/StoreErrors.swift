// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A live limit a write is refused over, named for the caller. Held in memory only; nothing persists it.
nonisolated enum StoreLimit: Equatable, Sendable { case accounts, accountBytes, payloadBytes, fieldBytes, wrappers, historyRow, blockedOrigins }

nonisolated enum UndeleteBlock: Equatable, Sendable {
    case ownerMissing, idCollision, exchangeIDCollision, originUsernameOverlap, passkeyCollision
    case slotOccupied(RecordSubject), passkeyIdentityConflict
}

nonisolated enum StoreFailCause: Equatable, Sendable {
    case foreignStore, v1AfterMigration, storeMissing, leftoversWithoutAuthority, unreadableVault, unreadableStore
    case cutoverV1Present, witnessMismatch, wrongProfile, migrationLeftover
}

nonisolated struct StoreFailClosed: Equatable, Sendable {
    let cause: StoreFailCause
    let paths: [URL]  // absolute (§6.4)
    let preMigrationBackup: URL?
}

nonisolated enum CredentialStoreError: Error, Equatable, Sendable {
    case failClosed(StoreFailClosed), storeBusy, integrityFailure(vaultOrdinal: Int?), limit(StoreLimit), diskFull
    case malformed, noAuthority, passkeyUnusable, migrationNeedsConfirmation, migrationAborted(path: URL?)
    case renameSwapUnsupported
    case stateChanged  // the open state read under the lock is not the one the caller routed on
    case undeleteBlocked(UndeleteBlock), metadataUndecodable, invalidVaultName, tooManyVaults, noSuchVault
}
