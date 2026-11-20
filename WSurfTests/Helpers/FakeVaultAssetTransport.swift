// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore
import WSurfVault

extension FakeSyncEngine: VaultCatalogReading, VaultAssetTransport {
    func fetchVaultCards() async throws -> [SyncRecord] {
        _ = try await currentAccountUser()
        return cloud.zones.compactMap { zone, records in
            guard SyncZone.vaultIDs(zone) != nil, let card = records[VaultSync.vaultRecordName]?.record, card.type == .vault else { return nil }
            return card
        }
    }

    func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String) async throws {
        guard try await currentAccountUser() == user, cloud.zones[zone] != nil else { throw VaultSyncFailure.unavailable }
        try await beforeVaultUpload?(reference.name)
        guard try await currentAccountUser() == user else { throw VaultSyncFailure.unavailable }
        let data = try Data(contentsOf: source)
        guard reference.matches(data) else { throw VaultSyncError.authenticationFailed }
        let id = SyncRecordID(zone: zone, name: reference.name)
        if let existing = cloud.encryptedVaultAssets[id], existing != data {
            throw VaultSyncError.authenticationFailed
        }
        cloud.encryptedVaultAssets[id] = data
    }

    func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> Data {
        try await beforeVaultDownload?(reference.name)
        guard try await currentAccountUser() == user, let data = cloud.encryptedVaultAssets[SyncRecordID(zone: zone, name: reference.name)],
              reference.matches(data) else { throw VaultSyncFailure.unavailable }
        return data
    }
}
