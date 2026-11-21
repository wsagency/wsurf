// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

/// Check one disabled vault without reading any records or fetching the account's other zones.
protocol VaultZoneChecking: SyncAccountIdentity {
    func vaultZoneExists(_ zone: String) async throws -> Bool
}

extension CloudKitSyncEngine: VaultZoneChecking {
    func vaultZoneExists(_ zone: String) async throws -> Bool {
        do {
            _ = try await container.privateCloudDatabase.recordZone(for: CloudKitMapping.zoneID(zone))
            return true
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return false
        }
    }
}

extension VaultSync {
    func scheduleRemovalChecks() {
        guard !launchCheck, accountAvailable != false, let engine, let checker = engine as? any VaultZoneChecking else { return }
        for (key, summary) in summaries {
            guard let owner = summary.removalToCheck, verifiedRemovals[key] != owner, state.accountUser == nil || state.accountUser == owner,
                  checkingRemovals.insert(key).inserted else { continue }
            let session = token(key)
            enqueue(key) { [weak self] in
                guard let self else { return }
                defer { checkingRemovals.remove(key) }
                do {
                    try await verifyRemovalOwner(owner, key: key, session: session, engine: engine, checker: checker)
                    let exists = try await checker.vaultZoneExists(key.zone)
                    try await verifyRemovalOwner(owner, key: key, session: session, engine: engine, checker: checker)
                    guard let database = database(key.profileID) else { return }
                    try database.write { tx in
                        guard var row = try tx.vault(key.vaultID), row.removalOwner == owner,
                              row.status == .removalPending || row.status == .removalFailed else { return }
                        row.status = exists ? .removalFailed : .removedDeleted
                        try tx.save(row)
                    }
                    verifiedRemovals[key] = owner
                    refresh(key)
                } catch {
                    // The heartbeat retries when the account and zone are available.
                }
            }
        }
    }

    private func verifyRemovalOwner(_ owner: String, key: VaultKey, session: Int, engine: any SyncEngine, checker: any VaultZoneChecking) async throws {
        let actual = try await checker.currentAccountUser()
        guard self.engine === engine, token(key) == session, accountAvailable != false else { throw VaultSyncFailure.unavailable }
        if actual != state.accountUser {
            _ = acceptDiscoveryAccount(actual)
        }
        guard actual == owner, state.accountUser == owner, token(key) == session else { throw VaultSyncFailure.unavailable }
    }

    /// Only the selected zone is inspected. The result describes the currently verified account.
    public func checkCloudCopy(profileID: UUID, vaultID: UUID, for user: String) async throws -> Bool {
        let key = try checkedKey(profileID, vaultID), session = token(key)
        return try await serial(key) { [self] in
            guard canManageCloudCopy(profileID: profileID, vaultID: vaultID), connectedAccount == user,
                  let engine, let checker = engine as? any VaultZoneChecking else { throw VaultSyncFailure.unavailable }
            try await verifyRemovalOwner(user, key: key, session: session, engine: engine, checker: checker)
            let exists = try await checker.vaultZoneExists(key.zone)
            try await verifyRemovalOwner(user, key: key, session: session, engine: engine, checker: checker)
            return exists
        }
    }

    /// Settings waits for the confirmed target to be recorded or receives an error it can show.
    public func removeFromICloud(profileID: UUID, vaultID: UUID, confirmingAccount user: String) async throws {
        let key = try checkedKey(profileID, vaultID), session = token(key)
        try await serial(key) { [self] in
            try await requestRemovalNow(key, session: session, owner: user, explicitlyConfirmed: true)
        }
    }

    func retryRemoval(_ key: VaultKey) {
        guard let owner = state.accountUser, verifiedRemovals[key] == owner else { return }
        let session = token(key)
        enqueue(key) { [weak self] in
            try? await self?.requestRemovalNow(key, session: session, owner: owner, explicitlyConfirmed: false)
        }
    }

    private func requestRemovalNow(_ key: VaultKey, session: Int, owner: String, explicitlyConfirmed: Bool) async throws {
        guard !owner.isEmpty, connectedAccount == owner, let database = database(key.profileID),
              let engine, let checker = engine as? any VaultZoneChecking else { throw VaultSyncFailure.unavailable }
        try await verifyRemovalOwner(owner, key: key, session: session, engine: engine, checker: checker)
        if explicitlyConfirmed, enabledRow(key) != nil {
            deleteZone(key)
            guard !halted.contains(key) else { throw VaultSyncFailure.unavailable }
            return
        }
        try database.write { tx in
            guard var row = try tx.vault(key.vaultID), !row.enabled else { throw VaultSyncFailure.unavailable }
            let retry = row.status == .removalFailed && row.removalOwner == owner && verifiedRemovals[key] == owner
            guard retry || (explicitlyConfirmed && row.canManageCloudCopy) else { throw VaultSyncFailure.unavailable }
            row.approvedUser = owner
            row.legacyRemovalUser = nil
            row.status = .removalPending
            try tx.save(row)
        }
        verifiedRemovals[key] = owner
        engine.add([.deleteZone(key.zone)])
        refresh(key)
    }
}
