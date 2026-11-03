// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AuthenticationServices
import CryptoKit
import Foundation
import WSurfCore
import WSurfVault

// iCloud vault sync (spec amendment 2026-10-22): the sync key a vault seals with, the state its `Vault` record publishes, and the one way
// another Mac's vault becomes one of this profile's. None of it unlocks anything: a key exists only under a grant, and adding a
// vault needs a fresh user-verified assertion of the synced unlock passkey.

extension CredentialManager {
    /// The vault's sync key under the current lease: HKDF of the vault's key, never the key itself. Only `VaultSync` asks for it.
    func syncKey() async throws -> VaultSyncKey {
        try await reading { access in try await store.syncKey(vaultID: vaultID, using: access) }
    }

    /// The vault's name and wrapper list as the store holds them now, for the `Vault` record.
    func syncVaultState() async throws -> (name: String, wrappers: [CredentialKeyWrapper]) {
        try await reading { access in try await store.syncVaultState(vaultID: vaultID, using: access) }
    }

    /// Sync wrote to this vault: pages that show it read it again.
    func noteSyncedWrite() {
        syncWrites &+= 1
    }

    /// Adds another Mac's vault to `profile`'s store, locked, with the same vault ID, key and unlock passkeys, and returns its ID.
    ///
    /// The vault belongs to the profile its zone names (`remote.profileID`): its wrapper binds that profile, so a store of any other
    /// profile could only report a key that differs. That is refused here, before any prompt, so a wrong profile is never mistaken
    /// for a different key. One user-verified assertion of the synced passkey opens the wrapper; the store then checks the vault's
    /// name against the sync key it derives and writes nothing at all if anything fails. The first vault of a profile needs no
    /// authority; a further one is authorized by an unlocked vault of the profile, or by a vault of the profile that enrolls the very
    /// passkey being asserted.
    static func adoptSyncedVault(
        profile: Profile,
        remote: RemoteVault,
        in anchor: @autoclosure () -> ASPresentationAnchor,
        native: VaultNativeUnlock? = nil
    ) async throws -> UUID {
        guard remote.profileID == profile.id, !profile.isPrivate else { throw CredentialManagerError.syncedVaultOfAnotherProfile }
        guard remote.payload.keyGeneration == VaultSyncCodec.generation else { throw VaultSyncError.unsupportedGeneration }
        let store = try store(for: profile)
        let wrappers = try VaultWrapperList.decode(remote.payload.wrappers)
        let seam = native ?? .native(PasskeyVaultUnlocker())
        let authority = try await adoptionAuthority(profile: profile, store: store, wrappers: wrappers)

        let creation = Creation(lease: authority.ownsLease ? authority.lease : nil, native: seam)
        creations[profile.id, default: []].append(creation)
        defer { creations[profile.id]?.removeAll { $0 === creation } }
        func requireLease() throws {
            guard !retiredProfiles.contains(profile.id) else { throw CredentialVaultError.unauthorized }
            try authority.lease.checkAuthorization(at: store.now())
        }
        try requireLease()
        let proof = try await seam.assert(wrappers.map(\.unlock), anchor)
        try requireLease()
        guard let wrapper = wrappers.first(where: { $0.credentialID == proof.credentialID }) else { throw CredentialVaultError.invalidData }
        let adoption = VaultAdoption(
            vaultID: remote.vaultID, wrappers: remote.payload.wrappers, sealed: remote.payload.sealed,
            generation: remote.payload.keyGeneration, credentialID: proof.credentialID, prf: proof.prf
        )
        do {
            return try await store.adoptVault(adoption, authorizedBy: authority.creation(for: wrapper, proof: proof)).vaultID
        } catch CredentialVaultError.authenticationFailed {
            throw CredentialManagerError.syncKeyDiffers(keyCheck: CredentialVaultCrypto.keyCheck(prf: proof.prf, credentialID: proof.credentialID))
        }
    }

    /// Who may authorize the new vault, decided before any prompt. A profile that has no authority says so without asking for a passkey.
    private struct AdoptionAuthority {
        enum Kind {
            case first
            case unlocked(CredentialManager)
            /// Vaults of the profile and the unlocks they enroll.
            case enrolled([(vault: UUID, unlock: VaultUnlock)])
        }

        let kind: Kind
        let lease: VaultAccess

        /// A lease the adoption owns (and a profile lock revokes), not an unlocked vault's own.
        var ownsLease: Bool {
            if case .unlocked = kind {
                false
            } else {
                true
            }
        }

        func creation(for wrapper: CredentialKeyWrapper, proof: VaultUnlockProof) throws -> VaultCreationAuthority {
            switch kind {
            case .first:
                return .firstVault(lease: lease)
            case .unlocked(let manager):
                return .unlockedVault(vaultID: manager.vaultID, access: lease)
            case .enrolled(let held):
                guard let source = held.first(where: { $0.unlock.credentialID == wrapper.credentialID && $0.unlock.prfInput == wrapper.prfInput })
                else { throw CredentialStoreError.noAuthority }
                return .existingPasskey(vaultID: source.vault, credentialID: proof.credentialID, prf: proof.prf, lease: lease)
            }
        }
    }

    private static func adoptionAuthority(
        profile: Profile, store: ProfileVaultStore, wrappers: [CredentialKeyWrapper]
    ) async throws -> AdoptionAuthority {
        func ownLease() -> VaultAccess {
            VaultAccess(profileID: profile.id, epoch: nextEpoch(), deadline: store.now().advanced(by: .seconds(300)))
        }
        switch await store.openState() {
        case .firstRun:
            return AdoptionAuthority(kind: .first, lease: ownLease())
        case .provisional:
            let listing = try await store.listing()
            guard listing.count < StoreFormat.activeVaultLimit else { throw CredentialStoreError.tooManyVaults }
            if let source = unlockedAuthorizer(in: listing, selected: nil, profile: profile) {
                return AdoptionAuthority(kind: .unlocked(source), lease: try source.currentAccess())
            }
            var held: [(vault: UUID, unlock: VaultUnlock)] = []
            for vault in listing {
                for unlock in try await store.discovery(vaultID: vault.vaultID).unlocks
                where wrappers.contains(where: { $0.credentialID == unlock.credentialID && $0.prfInput == unlock.prfInput }) {
                    held.append((vault.vaultID, unlock))
                }
            }
            guard !held.isEmpty else { throw CredentialStoreError.noAuthority }
            return AdoptionAuthority(kind: .enrolled(held), lease: ownLease())
        case .legacy, .resumeMigration:
            throw CredentialStoreError.noAuthority
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        }
    }
}
