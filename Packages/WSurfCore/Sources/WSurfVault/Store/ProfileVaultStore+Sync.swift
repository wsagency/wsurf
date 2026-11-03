// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import GRDB

/// A vault another Mac synced, as the `Vault` record holds it, and the passkey that opens it on this Mac: what `adoptVault` needs to
/// add the vault to this Mac's store. `wrappers` are the exact bytes of the record's wrapper list (`VaultWrapperList.encode`) and
/// `sealed` is the vault name sealed with them (`VaultSyncCodec.sealVault`). `credentialID` names the wrapper that `prf` opens.
public nonisolated struct VaultAdoption: Sendable {
    public let vaultID: UUID
    public let wrappers: Data
    public let sealed: Data
    public let generation: UInt64
    public let credentialID: Data
    public let prf: SymmetricKey

    public init(vaultID: UUID, wrappers: Data, sealed: Data, generation: UInt64, credentialID: Data, prf: SymmetricKey) {
        self.vaultID = vaultID
        self.wrappers = wrappers
        self.sealed = sealed
        self.generation = generation
        self.credentialID = credentialID
        self.prf = prf
    }
}

/// What iCloud sync asks of the store (spec amendment 2026-10-22): a key to seal with, the vault's name and wrapper list to publish,
/// and the way another Mac's vault becomes one of this store's. Nothing here reads, copies or writes a store row of another Mac, and no
/// key leaves except the sync subkey.
extension ProfileVaultStore {
    /// The sync key of `vaultID` under its current grant: HKDF-SHA256 of the vault's key, bound to the profile, the vault and the key
    /// generation. Only this subkey leaves the store, never the vault's key; it is never persisted. A locked, revoked or expired access
    /// is `unauthorized` or `expired`.
    public func syncKey(vaultID: UUID, using access: VaultAccess) throws -> VaultSyncKey {
        let grant = try authorizedGrant(vaultID, access)
        return VaultSyncKey.derive(dek: grant.dek, profileID: profileID, vaultID: vaultID)
    }

    /// The vault's name and wrapper list as the store holds them now, both authenticated (the registry under its key, the head under
    /// the vault's key), for the `Vault` record. Only an unlocked vault gives them.
    public func syncVaultState(vaultID: UUID, using access: VaultAccess) async throws -> (name: String, wrappers: [CredentialKeyWrapper]) {
        _ = try authorizedGrant(vaultID, access)
        let clock = now
        return try await withOperation { pool in
            let grant = try authorizedGrant(vaultID, access)  // re-checked after the lock wait
            return try pool.read { (db: Database) throws in
                let opened = try Self.openVault(db, grant: grant, vaultID: vaultID, access: access, now: clock)
                return (opened.head.name, opened.wrappers)
            }
        }
    }

    /// Adds another Mac's vault to this store as a new vault pair with the same vault id, the same key and the same wrappers, its name
    /// as the other Mac sealed it, a fresh Trash and Trash key, the next local ordinal and this store's own ids and registry key. It
    /// publishes no grant, like `createVault`: the vault is locked until it is unlocked with the passkey.
    ///
    /// The adoption opens the wrapper `adoption.credentialID` names with `adoption.prf`, with the same wrapping key and AAD as an
    /// unlock, then the sealed name under the derived sync key, which also authenticates the wrapper list. All of it runs before the
    /// operation lock is taken, so a PRF output that differs on this Mac (`CredentialVaultError.authenticationFailed`), a tampered
    /// list or name (`VaultSyncError.authenticationFailed`), or a generation this build does not know writes nothing and touches no
    /// file. `authorizedBy` is the rule of `createVault`: the first vault, an unlocked vault, or an enrolled passkey. A vault id this
    /// store holds is `alreadyExists`.
    public func adoptVault(_ adoption: VaultAdoption, authorizedBy: VaultCreationAuthority) async throws -> (vaultID: UUID, name: String) {
        guard adoption.generation == VaultSyncCodec.generation else { throw VaultSyncError.unsupportedGeneration }
        let wrappers = try VaultWrapperList.decode(adoption.wrappers)
        guard let wrapper = wrappers.first(where: { $0.credentialID == adoption.credentialID }) else { throw CredentialVaultError.invalidData }
        let proof = VaultUnlockProof(credentialID: wrapper.credentialID, prfInput: wrapper.prfInput, prf: adoption.prf)
        try CredentialVaultCrypto.validateProof(proof)
        let dek = SymmetricKey(
            data: try CredentialVaultCrypto.unwrap(wrapper, prf: adoption.prf, profileID: profileID, vaultID: adoption.vaultID)
        )
        let key = VaultSyncKey.derive(dek: dek, profileID: profileID, vaultID: adoption.vaultID, generation: adoption.generation)
        let name = try VaultSyncCodec.openVault(adoption.sealed, wrappers: adoption.wrappers, key: key)
        let vaultID = adoption.vaultID
        let created = try await create(proof: proof, authorizedBy: authorizedBy) { ordinal, createdAt in
            NewVault(
                vaultID: vaultID, trashID: UUID(), dek: dek, trashDEK: SymmetricKey(size: .bits256), ordinal: ordinal, name: name,
                wrappers: wrappers, createdAt: createdAt
            )
        }
        return (created, name)
    }
}
