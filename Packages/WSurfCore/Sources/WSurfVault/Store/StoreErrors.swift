// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// A live limit a write is refused over, named for the caller. Held in memory only; nothing persists it.
public nonisolated enum StoreLimit: Equatable, Sendable { case accounts, accountBytes, payloadBytes, fieldBytes, wrappers, historyRow, blockedOrigins }

public nonisolated enum UndeleteBlock: Equatable, Sendable {
    case ownerMissing, idCollision, exchangeIDCollision, originUsernameOverlap, passkeyCollision
    case slotOccupied(RecordSubject), passkeyIdentityConflict
}

public nonisolated enum StoreFailCause: Equatable, Sendable {
    case foreignStore, v1AfterMigration, storeMissing, leftoversWithoutAuthority, unreadableVault, unreadableStore
    case cutoverV1Present, witnessMismatch, wrongProfile, migrationLeftover
    /// The store says a newer format than this build knows (`StoreFormat.fileSchema`): a newer WSurf saved it.
    case newerVersion
}

public nonisolated struct StoreFailClosed: Equatable, Sendable {
    public let cause: StoreFailCause
    public let paths: [URL]  // absolute (§6.4)
    public let preMigrationBackup: URL?
}

public nonisolated enum CredentialStoreError: Error, Equatable, Sendable {
    case failClosed(StoreFailClosed), storeBusy, integrityFailure(vaultOrdinal: Int?), limit(StoreLimit), diskFull
    case malformed, noAuthority, passkeyUnusable, migrationNeedsConfirmation, migrationAborted(path: URL?)
    case renameSwapUnsupported
    case stateChanged  // the open state read under the lock is not the one the caller routed on
    case undeleteBlocked(UndeleteBlock), metadataUndecodable, invalidVaultName, tooManyVaults, noSuchVault
    case lastVault  // a profile keeps at least one vault: the store needs an active head to hold the registry key
    case vaultNotEmpty  // deleting without an assertion is for a vault that holds nothing
}
