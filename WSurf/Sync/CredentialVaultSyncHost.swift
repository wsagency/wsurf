// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WSurfCore
import WSurfVault

/// What `VaultSync` asks of the app, answered by the profile's credential managers. It reaches only a manager that is unlocked now:
/// it never creates one, never unlocks, never prompts and never touches a lease. The private profile has none of this.
final class CredentialVaultSyncHost: VaultSyncHost {
    private let profiles: @MainActor () -> [Profile]
    private let manager: @MainActor (Profile, UUID) -> CredentialManager?
    private let directory: @MainActor (Profile) -> URL

    /// The closures are the seam two simulated Macs use in tests: each has its own profiles, managers and folder.
    init(
        profiles: @escaping @MainActor () -> [Profile] = { ProfileStore.shared.profiles },
        manager: @escaping @MainActor (Profile, UUID) -> CredentialManager? = { profile, vaultID in
            CredentialManager.unlockedManagers(for: profile).first { $0.vaultID == vaultID }
        },
        directory: @escaping @MainActor (Profile) -> URL = { $0.supportDirectory }
    ) {
        self.profiles = profiles
        self.manager = manager
        self.directory = directory
    }

    private func profile(_ id: UUID) -> Profile? {
        id == Profile.privateID ? nil : profiles().first { $0.id == id }
    }

    func profileIDs() -> [UUID] {
        profiles().filter { !$0.isPrivate }.map(\.id)
    }

    func syncDirectory(profileID: UUID) -> URL? {
        profile(profileID).map(directory)
    }

    func profileCard(profileID: UUID) -> VaultProfileCard? {
        profile(profileID).map { VaultProfileCard(name: $0.name, symbol: $0.symbol, color: $0.color.rawValue) }
    }

    func syncKey(profileID: UUID, vaultID: UUID) async -> VaultSyncKey? {
        guard let manager = profile(profileID).flatMap({ manager($0, vaultID) }), manager.isUnlocked else { return nil }
        return try? await manager.syncKey()
    }

    /// The vault as one moment: refused if the lease changed while it was read, so what is applied or sent is never a mix of two.
    func snapshot(profileID: UUID, vaultID: UUID) async throws -> VaultSyncSnapshot {
        guard let manager = profile(profileID).flatMap({ manager($0, vaultID) }), let lease = manager.authorizationEpoch else {
            throw CredentialVaultError.unauthorized
        }
        let snapshot = try await manager.snapshot()
        let removed = try await manager.removedIdentifiers()
        let state = try await manager.syncVaultState()
        guard manager.authorizationEpoch == lease else { throw CredentialVaultError.unauthorized }
        return VaultSyncSnapshot(
            lease: lease, revision: snapshot.revision, accounts: snapshot.accounts, stamps: snapshot.stamps, removed: removed,
            name: state.name, wrappers: state.wrappers
        )
    }

    func commit(
        profileID: UUID, vaultID: UUID, lease: UInt64, writes: [AccountWrite], removing: [UUID: AccountStamp]
    ) async throws -> UInt64 {
        guard let manager = profile(profileID).flatMap({ manager($0, vaultID) }) else { throw CredentialVaultError.unauthorized }
        let receipt = try await manager.commitAccounts(writes, removing: removing, authorizedEpoch: lease, cause: CredentialChangeCause.sync)
        manager.noteSyncedWrite()
        return receipt.revision
    }
}
