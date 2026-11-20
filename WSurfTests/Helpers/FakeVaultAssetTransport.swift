// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
@testable import WSurfCore
import WSurfVault

extension FakeSyncEngine: VaultCatalogReading, VaultAssetTransport, VaultZoneChecking {
    func vaultZoneExists(_ zone: String) async throws -> Bool {
        _ = try await currentAccountUser()
        return cloud.zones[zone] != nil
    }

    func fetchVaultCards() async throws -> [SyncRecord] {
        _ = try await currentAccountUser()
        return cloud.zones.compactMap { zone, records in
            guard SyncZone.vaultIDs(zone) != nil, let card = records[VaultSync.vaultRecordName]?.record, card.type == .vault else { return nil }
            return card
        }
    }

    func vaultAssetVersionsMatch(_ tags: [VaultAssetRef: String], zone: String, user: String) async throws -> Bool {
        guard try await currentAccountUser() == user, cloud.zones[zone] != nil else { throw VaultSyncFailure.unavailable }
        return try tags.allSatisfy { ref, tag in
            guard let data = cloud.encryptedVaultAssets[SyncRecordID(zone: zone, name: ref.name)] else { return false }
            return try VaultAssetRef(data).name == tag
        }
    }

    func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String, acknowledged: String?) async throws -> String {
        guard try await currentAccountUser() == user, cloud.zones[zone] != nil else { throw VaultSyncFailure.unavailable }
        let id = SyncRecordID(zone: zone, name: reference.name)
        let previous = cloud.encryptedVaultAssets[id]
        if let acknowledged, let previous {
            let tag = try VaultAssetRef(previous).name
            if tag == acknowledged {
                return tag
            }
            try await beforeVaultDownload?(reference.name)
            guard try await currentAccountUser() == user else { throw VaultSyncFailure.unavailable }
            if reference.matches(previous) {
                return tag
            }
        }
        try await beforeVaultUpload?(reference.name)
        guard try await currentAccountUser() == user else { throw VaultSyncFailure.unavailable }
        let data = try Data(contentsOf: source)
        guard reference.matches(data) else { throw VaultSyncError.authenticationFailed }
        guard cloud.zones[zone] != nil, cloud.encryptedVaultAssets[id] == previous else { throw VaultSyncFailure.unavailable }
        cloud.encryptedVaultAssets[id] = data
        return reference.name
    }

    func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> (data: Data, tag: String) {
        try await beforeVaultDownload?(reference.name)
        guard try await currentAccountUser() == user, let data = cloud.encryptedVaultAssets[SyncRecordID(zone: zone, name: reference.name)],
              reference.matches(data) else { throw VaultSyncFailure.unavailable }
        return (data, reference.name)
    }
}
