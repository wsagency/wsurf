// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import WSurfVault

/// Consulted before each native zone fetch. A card-only participant never asks CloudKit for the vault's Item or CKAsset changes.
protocol VaultZoneReading: AnyObject, Sendable {
    var enrolledVaultZones: Set<String> { get }
}

extension VaultSync: VaultZoneReading {
    var enrolledVaultZones: Set<String> {
        Set(enabledKeys.map(\.zone))
    }
}

public protocol VaultCatalogReading: AnyObject {
    func fetchVaultCards() async throws -> [SyncRecord]
}

/// Available only through the private database of an explicitly participating vault. Assets contain ciphertext, including filenames and file keys.
public protocol VaultAssetTransport: AnyObject {
    func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String) async throws
    func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> Data
}

extension CloudKitSyncEngine: VaultCatalogReading, VaultAssetTransport {
    public func fetchVaultCards() async throws -> [SyncRecord] {
        let db = container.privateCloudDatabase
        let zones = try await db.allRecordZones().map(\.zoneID).filter { SyncZone.vaultIDs($0.zoneName) != nil }
        var cards: [SyncRecord] = []
        for start in stride(from: 0, to: zones.count, by: 200) {
            let ids = zones[start..<min(start + 200, zones.count)].map { CKRecord.ID(recordName: VaultSync.vaultRecordName, zoneID: $0) }
            let result = try await db.records(for: ids, desiredKeys: [CloudKitMapping.payloadKey, CloudKitMapping.schemaKey])
            for id in ids {
                guard let item = result[id] else { throw VaultSyncFailure.unavailable }
                do {
                    let record = try item.get()
                    if record.recordType == SyncRecordType.vault.rawValue, let card = CloudKitMapping.syncRecord(record) {
                        cards.append(card)
                    }
                } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                    continue
                }
            }
        }
        return cards
    }

    public func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String) async throws {
        guard reference.valid, try source.resourceValues(forKeys: [.fileSizeKey]).fileSize == reference.size,
              reference.matches(try Data(contentsOf: source)) else { throw VaultSyncError.authenticationFailed }
        let id = try await assetID(reference, zone: zone, user: user)
        let record = CKRecord(recordType: "VaultAsset", recordID: id)
        record["ciphertext"] = CKAsset(fileURL: source)
        do {
            let result = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            guard let saved = result.saveResults[id] else { throw VaultSyncFailure.unavailable }
            _ = try saved.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
            // A retry or a second Mac can have uploaded these ciphertext bytes. Verify them before acknowledging that upload.
            _ = try await downloadVaultAsset(reference, zone: zone, user: user)
        }
        guard try await currentAccountUser() == user else { throw VaultSyncFailure.unavailable }
    }

    public func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> Data {
        let id = try await assetID(reference, zone: zone, user: user)
        let record = try await container.privateCloudDatabase.record(for: id)
        guard record.recordType == "VaultAsset", let url = (record["ciphertext"] as? CKAsset)?.fileURL,
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == reference.size else { throw VaultSyncError.malformed }
        let data = try Data(contentsOf: url)
        guard reference.matches(data), try await currentAccountUser() == user else { throw VaultSyncError.authenticationFailed }
        return data
    }

    private func assetID(_ reference: VaultAssetRef, zone: String, user: String) async throws -> CKRecord.ID {
        guard reference.valid, SyncZone.vaultIDs(zone) != nil, !user.isEmpty, try await currentAccountUser() == user else {
            throw VaultSyncFailure.unavailable
        }
        return CKRecord.ID(recordName: reference.name, zoneID: CloudKitMapping.zoneID(zone))
    }
}
