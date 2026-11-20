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
        let sameAccount = state.accountUser.map { $0 == user } ?? enabledKeys.isEmpty
        applyAccount(sameAccount ? .signIn(user: user) : .switchAccounts(user: user))
        persist(state)
        return sameAccount
    }

    public func refreshAvailableVaults(_ records: [SyncRecord]) {
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
        engine = nil
        let keys = Set(chains.keys).union(enabledKeys)
        for key in keys {
            forget(key)
        }
        halted.formUnion(keys)
        housekeeping.forEach { $0.cancel() }
        housekeeping = []
    }
}
