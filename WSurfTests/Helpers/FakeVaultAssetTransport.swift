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

    // A repair gets a new server revision even when it restores the original bytes.
    private func assetTag(_ ref: VaultAssetRef, id: SyncRecordID) -> String {
        "\(ref.name)-\(cloud.vaultAssetWrites[id, default: 0])"
    }

    func vaultAssetVersionsMatch(_ tags: [VaultAssetRef: String], zone: String, user: String) async throws -> Bool {
        guard try await currentAccountUser() == user, cloud.zones[zone] != nil else { throw VaultSyncFailure.unavailable }
        return try tags.allSatisfy { ref, tag in
            let id = SyncRecordID(zone: zone, name: ref.name)
            guard let data = cloud.encryptedVaultAssets[id] else { return false }
            return try assetTag(VaultAssetRef(data), id: id) == tag
        }
    }

    func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String, acknowledged: String?) async throws -> String {
        guard try await currentAccountUser() == user, cloud.zones[zone] != nil else { throw VaultSyncFailure.unavailable }
        let id = SyncRecordID(zone: zone, name: reference.name)
        let previous = cloud.encryptedVaultAssets[id]
        let writes = cloud.vaultAssetWrites[id, default: 0]
        if let acknowledged, let previous {
            let tag = try assetTag(VaultAssetRef(previous), id: id)
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
        guard cloud.zones[zone] != nil, cloud.encryptedVaultAssets[id] == previous, cloud.vaultAssetWrites[id, default: 0] == writes else { throw VaultSyncFailure.unavailable }
        cloud.encryptedVaultAssets[id] = data
        cloud.vaultAssetWrites[id, default: 0] += 1
        return assetTag(reference, id: id)
    }

    func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> (data: Data, tag: String) {
        try await beforeVaultDownload?(reference.name)
        let id = SyncRecordID(zone: zone, name: reference.name)
        guard try await currentAccountUser() == user, let data = cloud.encryptedVaultAssets[id],
              reference.matches(data) else { throw VaultSyncFailure.unavailable }
        return (data, assetTag(reference, id: id))
    }
}
