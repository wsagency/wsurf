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

    /// A fresh removal choice applies only to the signed-in account, including when the old receipt named no owner.
    func requestRemoval(_ key: VaultKey, confirmingAccount: String?) {
        guard let owner = state.accountUser, !owner.isEmpty, verifiedRemovals[key] == owner || confirmingAccount == owner,
              accountAvailable != false, let database = database(key.profileID),
              let engine, let checker = engine as? any VaultZoneChecking else { return }
        let session = token(key)
        enqueue(key) { [weak self] in
            guard let self else { return }
            do {
                try await verifyRemovalOwner(owner, key: key, session: session, engine: engine, checker: checker)
                let requested = try database.write { tx in
                    guard var row = try tx.vault(key.vaultID), !row.enabled else { return false }
                    let retry = row.status == .removalFailed && row.removalOwner == owner && verifiedRemovals[key] == owner
                    let freshChoice = row.status == .removalUnconfirmed && confirmingAccount == owner
                    guard retry || freshChoice else { return false }
                    row.approvedUser = owner
                    row.legacyRemovalUser = nil
                    row.status = .removalPending
                    try tx.save(row)
                    return true
                }
                if requested {
                    verifiedRemovals[key] = owner
                    engine.add([.deleteZone(key.zone)])
                    refresh(key)
                }
            } catch {
                // No deletion is queued when the account cannot be verified or the decision cannot be stored.
            }
        }
    }
}
