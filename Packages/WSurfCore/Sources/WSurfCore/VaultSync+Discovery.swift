// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension VaultSync {
    public func acceptsUploadAccount(_ user: String) -> Bool {
        state.accountUser == user || acceptDiscoveryAccount(user)
    }

    /// Loads the persisted enrollments before checking the signed-in account, including on a fresh process.
    public func acceptDiscoveryAccount(_ user: String) -> Bool {
        loadDatabases()
        let sameAccount = canRestoreAccount(user)
        applyAccount(sameAccount ? .signIn(user: user) : .switchAccounts(user: user))
        persist(state)
        return sameAccount
    }

    /// The account preserves discovery preferences. Each writer and removal must still pass its own per-vault approval check.
    func canRestoreAccount(_ user: String) -> Bool {
        if state.accountUser == user {
            return true
        }
        var priorEnrollment = false
        for profile in host.profileIDs() {
            guard let database = database(profile) else { continue }
            guard let rows = try? database.read({ try $0.vaults() }) else { return false }
            for row in rows where row.enabled || row.removalOwner != nil || row.status == .removalFailed || row.status == .removedDeleted || row.status == .removalUnconfirmed {
                priorEnrollment = true
                if row.approvedUser == user || row.removalOwner == user {
                    return true
                }
            }
        }
        return state.accountUser == nil && !priorEnrollment
    }

    public func refreshAvailableVaults(_ records: [SyncRecord], for user: String) {
        guard !user.isEmpty, user == state.accountUser else { return }
        catalogUser = user
        var cards: [String: RemoteVault] = [:]
        for record in records {
            guard record.type == .vault, record.id.name == Self.vaultRecordName, let ids = SyncZone.vaultIDs(record.id.zone),
                  !excluded.contains(ids.profileID), let payload = VaultRecordPayload.decode(record.payload) else { continue }
            cards[record.id.zone] = RemoteVault(profileID: ids.profileID, vaultID: ids.vaultID, payload: payload)
        }
        guard state.remote != cards else { return }
        state.remote = cards
        persist(state)
    }

    public func pauseDiscovery() {
        catalogUser = nil
        engine = nil
        let keys = Set(chains.keys).union(enabledKeys)
        let previouslyHalted = halted
        for key in keys {
            forget(key)
        }
        halted = previouslyHalted
        housekeeping.forEach { $0.cancel() }
        housekeeping = []
    }
}
