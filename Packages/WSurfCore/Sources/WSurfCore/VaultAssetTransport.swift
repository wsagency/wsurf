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
    func vaultAssetVersionsMatch(_ tags: [VaultAssetRef: String], zone: String, user: String) async throws -> Bool
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
        return VaultAssetRequests(currentUser: currentAccountUser, fetch: { ids, keys in
            let results = try await db.records(for: ids, desiredKeys: keys)
            return results.mapValues { item in
                Result {
                    let record = try item.get()
                    guard let tag = record.recordChangeTag else { throw VaultSyncError.malformed }
                    return (record: record, tag: tag)
                }
            }
        }, save: { record in
            let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            guard let saved = try result.saveResults[record.recordID]?.get(), saved.recordID == record.recordID,
                  saved.recordType == record.recordType, let tag = saved.recordChangeTag else { throw VaultSyncFailure.unavailable }
            return tag
        })
    }

    public func vaultAssetVersionsMatch(_ tags: [VaultAssetRef: String], zone: String, user: String) async throws -> Bool {
        try await assetRequests.versionsMatch(tags, zone: zone, user: user)
    }

    public func uploadVaultAsset(_ reference: VaultAssetRef, from source: URL, zone: String, user: String, acknowledged: String?) async throws -> String {
        try await assetRequests.upload(reference, from: source, zone: zone, user: user, acknowledged: acknowledged)
    }

    public func downloadVaultAsset(_ reference: VaultAssetRef, zone: String, user: String) async throws -> (data: Data, tag: String) {
        try await assetRequests.download(reference, zone: zone, user: user)
    }
}

struct VaultAssetRequests {
    typealias Version = (record: CKRecord, tag: String)
    typealias Results = [CKRecord.ID: Result<Version, any Error>]

    let currentUser: () async throws -> String
    let fetch: ([CKRecord.ID], [CKRecord.FieldKey]?) async throws -> Results
    let save: (CKRecord) async throws -> String

    /// Confirm all dependencies of this pending Item without fetching their ciphertext.
    func versionsMatch(_ tags: [VaultAssetRef: String], zone: String, user: String) async throws -> Bool {
        guard !tags.isEmpty else { return false }
        let expected = try tags.map { (try assetID($0.key, zone: zone, user: user), $0.value) }
        do {
            for start in stride(from: 0, to: expected.count, by: 200) {
                let batch = expected[start..<min(start + 200, expected.count)]
                let values = try await fields(batch.map(\.0), keys: [], user: user)
                for (id, tag) in batch where try version(in: values, id: id).tag != tag {
                    return false
                }
            }
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
        return true
    }

    func upload(_ ref: VaultAssetRef, from source: URL, zone: String, user: String, acknowledged: String?) async throws -> String {
        let id = try assetID(ref, zone: zone, user: user)
        if let acknowledged {
            do {
                let metadata = try version(in: await fields([id], keys: [], user: user), id: id)
                if metadata.tag == acknowledged {
                    return acknowledged
                }
                return try await verifyOrRepair(ref, id: id, source: source, user: user)
            } catch let error as CKError where error.code == .unknownItem {
                // The receipt can outlive the record. A fresh conditional create still detects another writer.
            }
        }
        let record = CKRecord(recordType: "VaultAsset", recordID: id)
        do {
            return try await store(record, ref: ref, from: source, user: user)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return try await verifyOrRepair(ref, id: id, source: source, user: user)
        }
    }

    func download(_ ref: VaultAssetRef, zone: String, user: String) async throws -> (data: Data, tag: String) {
        let id = try assetID(ref, zone: zone, user: user)
        let remote = try version(in: await fields([id], keys: ["ciphertext"], user: user), id: id)
        guard let data = try verifiedBytes(ref, at: assetFile(remote.record)) else { throw VaultSyncError.authenticationFailed }
        return (data, remote.tag)
    }

    private func verifyOrRepair(_ ref: VaultAssetRef, id: CKRecord.ID, source: URL, user: String) async throws -> String {
        // Keep all server fields and the actual change tag on the fetched record used for the conditional repair.
        let remote = try version(in: await fields([id], keys: nil, user: user), id: id)
        if try verifiedBytes(ref, at: assetFile(remote.record)) != nil {
            return remote.tag
        }

        return try await store(remote.record, ref: ref, from: source, user: user)
    }

    private func store(_ record: CKRecord, ref: VaultAssetRef, from source: URL, user: String) async throws -> String {
        // CKAsset reads its URL asynchronously. Keep the exact bytes whose SHA-256 names this record until the conditional save returns.
        let data = try localBytes(ref, at: source)
        let folder = source.deletingLastPathComponent().appending(path: "upload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: ref.name)
        try data.write(to: file, options: .withoutOverwriting)
        record["ciphertext"] = CKAsset(fileURL: file)
        try await check(user)
        let tag = try await save(record)
        try await check(user)
        return tag
    }

    private func fields(_ ids: [CKRecord.ID], keys: [CKRecord.FieldKey]?, user: String) async throws -> Results {
        try await check(user)
        let result = try await fetch(ids, keys)
        try await check(user)
        return result
    }

    private func version(in results: Results, id: CKRecord.ID) throws -> Version {
        guard let value = try results[id]?.get() else { throw VaultSyncFailure.unavailable }
        guard value.record.recordID == id, value.record.recordType == "VaultAsset" else { throw VaultSyncError.malformed }
        return value
    }

    private func assetFile(_ record: CKRecord) throws -> URL {
        guard let file = (record["ciphertext"] as? CKAsset)?.fileURL else { throw VaultSyncError.malformed }
        return file
    }

    private func verifiedBytes(_ ref: VaultAssetRef, at file: URL) throws -> Data? {
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == ref.size else { return nil }
        let data = try Data(contentsOf: file)
        return ref.matches(data) ? data : nil
    }

    private func localBytes(_ ref: VaultAssetRef, at source: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: source.path) else { throw VaultFileError.missing }
        guard let bytes = try verifiedBytes(ref, at: source) else { throw VaultSyncError.authenticationFailed }
        return bytes
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
