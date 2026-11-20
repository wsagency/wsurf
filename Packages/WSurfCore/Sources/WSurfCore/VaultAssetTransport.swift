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
    func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String, acknowledged: String?) async throws -> String
    func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> (data: Data, tag: String)
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

    private var assetRequests: VaultAssetRequests {
        let db = container.privateCloudDatabase
        return VaultAssetRequests(currentUser: currentAccountUser, fetch: { id, keys in
            let results = try await db.records(for: [id], desiredKeys: keys)
            guard let result = results[id] else { throw VaultSyncFailure.unavailable }
            let record = try result.get()
            guard record.recordType == "VaultAsset", let tag = record.recordChangeTag else { throw VaultSyncError.malformed }
            return (tag, (record["ciphertext"] as? CKAsset)?.fileURL)
        }, save: { record in
            let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            guard let saved = result.saveResults[record.recordID], let tag = try saved.get().recordChangeTag else {
                throw VaultSyncFailure.unavailable
            }
            return tag
        })
    }

    public func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String, acknowledged: String?) async throws -> String {
        try await assetRequests.upload(reference, from: source, zone: zone, user: user, acknowledged: acknowledged)
    }

    public func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> (data: Data, tag: String) {
        try await assetRequests.download(reference, zone: zone, user: user)
    }
}

struct VaultAssetRequests {
    let currentUser: () async throws -> String
    let fetch: (CKRecord.ID, [CKRecord.FieldKey]) async throws -> (tag: String, file: URL?)
    let save: (CKRecord) async throws -> String

    func upload(_ ref: VaultAssetRef, from source: URL, zone: String, user: String, acknowledged: String?) async throws -> String {
        let id = try assetID(ref, zone: zone, user: user)
        if let acknowledged {
            do {
                let metadata = try await fields(id, keys: [], user: user)
                if metadata.tag == acknowledged {
                    return acknowledged
                }
                return try await verified(ref, id: id, user: user).tag
            } catch let error as CKError where error.code == .unknownItem {
                // A receipt can outlive its record when the zone is recreated.
            }
        }
        guard FileManager.default.fileExists(atPath: source.path) else { throw VaultFileError.missing }
        guard try source.resourceValues(forKeys: [.fileSizeKey]).fileSize == ref.size,
              ref.matches(try Data(contentsOf: source)) else { throw VaultSyncError.authenticationFailed }
        try await check(user)
        let record = CKRecord(recordType: "VaultAsset", recordID: id)
        record["ciphertext"] = CKAsset(fileURL: source)
        do {
            let tag = try await save(record)
            try await check(user)
            return tag
        } catch let error as CKError where error.code == .serverRecordChanged {
            // A lost save reply or another Mac can account for the existing record.
            return try await verified(ref, id: id, user: user).tag
        }
    }

    func download(_ ref: VaultAssetRef, zone: String, user: String) async throws -> (data: Data, tag: String) {
        try await verified(ref, id: assetID(ref, zone: zone, user: user), user: user)
    }

    private func verified(_ ref: VaultAssetRef, id: CKRecord.ID, user: String) async throws -> (data: Data, tag: String) {
        let result = try await fields(id, keys: ["ciphertext"], user: user)
        guard let file = result.file, try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == ref.size else {
            throw VaultSyncError.malformed
        }
        let data = try Data(contentsOf: file)
        guard ref.matches(data) else { throw VaultSyncError.authenticationFailed }
        return (data, result.tag)
    }

    private func fields(_ id: CKRecord.ID, keys: [CKRecord.FieldKey], user: String) async throws -> (tag: String, file: URL?) {
        try await check(user)
        let result = try await fetch(id, keys)
        try await check(user)
        return result
    }

    private func check(_ user: String) async throws {
        guard try await currentUser() == user else { throw VaultSyncFailure.unavailable }
    }

    private func assetID(_ ref: VaultAssetRef, zone: String, user: String) throws -> CKRecord.ID {
        guard ref.valid, SyncZone.vaultIDs(zone) != nil, !user.isEmpty, user != CKCurrentUserDefaultName else { throw VaultSyncFailure.unavailable }
        // CKContainer.userRecordID supplies the zone owner's concrete name. The default alias would follow a switch at dispatch.
        return CKRecord.ID(recordName: ref.name, zoneID: CKRecordZone.ID(zoneName: zone, ownerName: user))
    }
}
