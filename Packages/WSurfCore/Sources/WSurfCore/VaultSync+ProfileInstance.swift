// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension VaultSync {
    func localKey(profileID: UUID, vaultID: UUID) -> VaultKey {
        let instance = state.accountUser.flatMap { profileInstance?(profileID, $0) }
        return VaultKey(profileID: profileID, vaultID: vaultID, instanceID: instance)
    }

    func isAvailable(_ remote: RemoteVault) -> Bool {
        guard let user = state.accountUser else { return isRetired == nil }
        let instance = CloudProfileInstance.vault(profile: remote.profileID, instance: remote.instanceID, owner: user)
        return isRetired?(instance) != true
    }

    func permits(_ key: VaultKey) -> Bool {
        guard !erased.contains(key.profileID), !excluded.contains(key.profileID), key == localKey(profileID: key.profileID, vaultID: key.vaultID) else { return false }
        return permitsProfile?(key.profileID) != false
    }

    public func permitsZoneCreation(_ zone: String) -> Bool {
        guard let ids = SyncZone.vaultIDs(zone), let (database, row) = runningRow(VaultKey(ids)) else { return false }
        return firstUploadPending(VaultKey(ids), database: database, row: row)
    }

    public func boundOwner(of zone: String, deleting: Bool) -> String? {
        guard let ids = SyncZone.vaultIDs(zone), permits(VaultKey(ids)), let owner = state.accountUser,
              let row = try? database(ids.profileID)?.read({ try $0.vault(ids.vaultID) }), row.instanceID == ids.instanceID else { return nil }
        if deleting {
            return row.removalOwner == owner || (row.enabled && row.approvedUser == owner) ? owner : nil
        }
        return row.enabled && row.approvedUser == owner ? owner : nil
    }

    /// Only rows backed by an explicit account choice can identify a local copy of a retired profile.
    public func enrolledProfileInstances(owner: String) -> [UUID: CloudProfileInstance] {
        var result: [UUID: CloudProfileInstance] = [:]
        for id in host.profileIDs() {
            guard let rows = try? database(id)?.read({ try $0.vaults() }),
                  let row = rows.first(where: { $0.approvedUser == owner && ($0.enabled || $0.status == .removedDeleted) }) else { continue }
            result[id] = .vault(profile: id, instance: profileInstance?(id, owner) ?? row.instanceID, owner: owner)
        }
        return result
    }

    public func invalidateProfileSession(_ profile: UUID) {
        for key in Set(summaries.keys).union(chains.keys).union(sessions.keys) where key.profileID == profile {
            forget(key)
            summaries[key] = nil
            checkedAtAttach.remove(key)
        }
        loadDatabases()
    }

    /// A durable explicit choice authorizes only the still-enabled vaults of its account. Locked vaults retry on unlock.
    func publishNewInstances() {
        guard let user = state.accountUser, let engine else { return }
        for key in enabledKeys where key.instanceID != nil && permits(key) && host.currentLease(profileID: key.profileID, vaultID: key.vaultID) != nil {
            guard let row = try? database(key.profileID)?.read({ try $0.vault(key.vaultID) }), row.enabled, row.approvedUser == user,
                  row.instanceID != key.instanceID, publishingInstances.insert(key).inserted else { continue }
            enqueue(key) { [weak self] in
                guard let self else { return }
                defer { publishingInstances.remove(key) }
                guard self.engine === engine, permits(key), state.accountUser == user, let current = try? database(key.profileID)?.read({ try $0.vault(key.vaultID) }),
                      current.enabled, current.approvedUser == user, current.instanceID != key.instanceID else { return }
                try? await enableNow(key)
            }
        }
    }
}
