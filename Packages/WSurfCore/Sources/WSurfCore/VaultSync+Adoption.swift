// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension VaultSync {
    /// Bind the source account before the passkey can create a local vault. An interrupted Add leaves the switch off.
    public func addDiscoveredVault(_ remote: RemoteVault, create: () async throws -> UUID) async throws {
        let key = try checkedKey(remote.profileID, remote.vaultID)
        guard let engine else { throw VaultSyncFailure.unavailable }
        let session = token(key)
        let user: String
        if let verified = catalogUser, verified == state.accountUser {
            user = verified
        } else {
            // The legacy switch can deliver cards through its engine before the first account observation.
            user = try await enrollmentAccount(engine, key: key, session: session, expecting: state.accountUser)
            guard let reader = engine as? any VaultCatalogReading else { throw VaultSyncFailure.unavailable }
            let cards = try await reader.fetchVaultCards()
            _ = try await enrollmentAccount(engine, key: key, session: session, expecting: user)
            refreshAvailableVaults(cards, for: user)
        }
        guard !Task.isCancelled, self.engine === engine, token(key) == session, state.accountUser == user, accountAvailable != false, state.remote[key.zone] == remote,
              !addingVaults.contains(key), let database = database(key.profileID, create: true) else { throw VaultSyncFailure.unavailable }
        let pending = VaultRow(vaultID: key.vaultID, enabled: false, approvedUser: user)
        let previous = try database.write { tx in
            let previous = try tx.vault(key.vaultID)
            guard previous?.enabled != true else { throw VaultSyncFailure.unavailable }
            try tx.save(pending)
            return previous
        }
        addingVaults.insert(key)
        defer { addingVaults.remove(key) }
        refresh(key)
        do {
            guard try await create() == key.vaultID else { throw VaultSyncFailure.unavailable }
        } catch {
            try database.write { tx in
                guard try tx.vault(key.vaultID) == pending else { return }
                if let previous {
                    try tx.save(previous)
                } else {
                    try tx.remove(key.vaultID)
                }
            }
            refresh(key)
            throw error
        }
        guard !Task.isCancelled, self.engine === engine, token(key) == session, state.accountUser == user, accountAvailable != false else { return }
        await enrollAdopted(key, from: remote)
    }

    /// Held by Settings' local listing, off here, and present in the current account's verified catalog.
    /// Older interrupted adds have no row. The retry authenticates their remote header with the local key too.
    public func adoptionRetryAccount(profileID: UUID, vaultID: UUID) -> String? {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        guard engine != nil, let user = catalogUser, user == state.accountUser, accountAvailable == true, !excluded.contains(profileID),
              state.remote[key.zone] != nil, status(profileID: profileID, vaultID: vaultID) == .off else { return nil }
        if let pending = summaries[key]?.pendingAdoptionUser, pending != user {
            return nil
        }
        return user
    }

    /// An explicit retry for a held copy can only join the zone offered by the account the owner saw.
    public func retryAdoption(profileID: UUID, vaultID: UUID, account: String, unlock: () async throws -> Void) async throws {
        let key = try checkedKey(profileID, vaultID)
        let session = token(key)
        guard adoptionRetryAccount(profileID: profileID, vaultID: vaultID) == account else { throw VaultSyncFailure.unavailable }
        try await unlock()
        try Task.checkCancellation()
        try await serial(key) { [self] in
            guard token(key) == session, adoptionRetryAccount(profileID: profileID, vaultID: vaultID) == account else {
                throw VaultSyncFailure.unavailable
            }
            try Task.checkCancellation()
            try await enableNow(key, joiningFor: account)
        }
    }
}
