// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import GRDB

/// The explicit per-vault consent that a confirmed profile deletion withdraws, even after Credentials.sync is gone.
nonisolated public struct VaultProfileRemoval: Codable, Hashable, Sendable {
    public let profileID: UUID
    public let vaultID: UUID
    let owner: String
    private struct Request: Codable, Hashable, Sendable {
        var id: UUID
        var marked = false
    }
    private var request: Request?

    init(profileID: UUID, vaultID: UUID, owner: String) {
        self.profileID = profileID
        self.vaultID = vaultID
        self.owner = owner
    }

    public func scheduled() -> Self {
        var next = self
        next.request = Request(id: UUID())
        return next
    }

    public static func approved(in directory: URL, profileID: UUID, localVaults: Set<UUID>, requireEnrollmentFile: Bool = false) throws -> Set<Self> {
        let file = directory.appending(path: VaultSyncDatabase.fileName)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch CocoaError.fileReadNoSuchFile where !requireEnrollmentFile {
            return []
        }
        // Inspect the consent recorded by this checkpoint without migrating it.
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: file.path, configuration: config)
        return try queue.read { db in
            let migrations = try DatabaseMigrator().appliedIdentifiers(db)
            guard migrations.contains("v1") else { throw CocoaError(.fileReadCorruptFile) }
            guard migrations.contains("vaultExplicitConsent") else {
                // Older enabled rows never recorded a confirmed owner. They cannot revoke a previously shown approval either.
                let columns = Set(try db.columns(in: "vault").map(\.name))
                guard !requireEnrollmentFile, !columns.contains("consentUser"), columns.isSuperset(of: ["vaultID", "enabled", "status"]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return []
            }
            let rows = try Row.fetchAll(db, sql: "SELECT vaultID, enabled, status, consentUser FROM vault")
            return try Set(rows.compactMap { row in
                let id = try row.decode(UUID.self, forColumn: "vaultID")
                guard localVaults.contains(id) else { return nil }
                let status = try row.decode(String.self, forColumn: "status")
                guard VaultSyncStatus.Stored(rawValue: status) != nil else { throw CocoaError(.fileReadCorruptFile) }
                guard try VaultRow.readEnabled(from: row), let owner = try row.decode(String?.self, forColumn: "consentUser"),
                      !owner.isEmpty, owner != CKCurrentUserDefaultName else { return nil }
                return Self(profileID: profileID, vaultID: id, owner: owner)
            })
        }
    }

    /// Each returned phase must reach disk before the next call. Deleting the zone also deletes its unique marker.
    /// A replacement zone cannot contain that marker, even if another Mac publishes the same vault ID and contents.
    @MainActor
    public func advance(using transport: any VaultProfileZoneDeleting) async throws -> Self? {
        var next: Self?
        try await withOwnedZone(currentUser: transport.currentAccountUser) { zone in
            guard var request else {
                // A checkpoint from before request IDs might already have deleted a previous zone with this name.
                try await transport.requireVaultZoneAbsence(zone)
                return
            }
            let id = CKRecord.ID(recordName: "withdrawal-\(request.id.uuidString)", zoneID: zone)
            if request.marked {
                guard try await transport.hasVaultRemovalMarker(id) else { return }
                guard try await transport.currentAccountUser() == owner else { throw VaultSyncFailure.unavailable }
                try await transport.deleteProfileVaultZone(zone)
            } else {
                try await transport.placeVaultRemovalMarker(id)
                request.marked = true
                next = self
                next?.request = request
            }
        }
        return next
    }

    /// The explicit zone owner keeps even an account change during dispatch from redirecting the operation.
    @MainActor
    func withOwnedZone(currentUser: () async throws -> String, operation: (CKRecordZone.ID) async throws -> Void) async throws {
        guard !owner.isEmpty, owner != CKCurrentUserDefaultName, try await currentUser() == owner else { throw VaultSyncFailure.unavailable }
        let zone = SyncZone.vault(profileID: profileID, vaultID: vaultID)
        do {
            try await operation(CloudKitMapping.zoneID(zone, ownerName: owner))
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // A previous attempt may have succeeded before its receipt was saved.
        }
        guard try await currentUser() == owner else { throw VaultSyncFailure.unavailable }
    }
}

@MainActor
public protocol VaultProfileZoneDeleting: SyncAccountIdentity {
    func requireVaultZoneAbsence(_ id: CKRecordZone.ID) async throws
    func placeVaultRemovalMarker(_ id: CKRecord.ID) async throws
    func hasVaultRemovalMarker(_ id: CKRecord.ID) async throws -> Bool
    func deleteProfileVaultZone(_ id: CKRecordZone.ID) async throws
}

extension CloudKitSyncEngine: VaultProfileZoneDeleting {
    public func requireVaultZoneAbsence(_ id: CKRecordZone.ID) async throws {
        _ = try await container.privateCloudDatabase.recordZone(for: id)
        throw VaultSyncFailure.unavailable
    }

    public func placeVaultRemovalMarker(_ id: CKRecord.ID) async throws {
        // Reuse the Vault record type. Only the well-known "vault" record is a header on participating Macs.
        let record = CKRecord(recordType: SyncRecordType.vault.rawValue, recordID: id)
        record.encryptedValues[CloudKitMapping.payloadKey] = Data()
        do {
            _ = try await container.privateCloudDatabase.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let saved = error.serverRecord, saved.recordID == id, saved.recordType == record.recordType else { throw error }
        }
    }

    public func hasVaultRemovalMarker(_ id: CKRecord.ID) async throws -> Bool {
        do {
            let record = try await container.privateCloudDatabase.record(for: id)
            guard record.recordType == SyncRecordType.vault.rawValue else { throw VaultSyncFailure.unavailable }
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
    }

    public func deleteProfileVaultZone(_ id: CKRecordZone.ID) async throws {
        _ = try await container.privateCloudDatabase.deleteRecordZone(withID: id)
    }
}
