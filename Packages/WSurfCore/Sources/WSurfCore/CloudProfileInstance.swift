// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

/// Permanent evidence for one publication in one private database. Legacy vaults use their profile UUID.
nonisolated public struct CloudProfileInstance: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case vaults, shared }
    public let kind: Kind
    public let id: UUID
    public let owner: String

    public init(_ kind: Kind, id: UUID, owner: String) {
        self.kind = kind
        self.id = id
        self.owner = owner
    }

    /// Only released vault zones without a generation use the local UUID as the retirement identity.
    /// A new publication uses the same cloud identity for its vaults, settings and Shared Spaces.
    public static func vault(profile: UUID, instance: UUID?, owner: String) -> Self {
        Self(instance == nil ? .vaults : .shared, id: instance ?? profile, owner: owner)
    }

    public static let zone = "profile-retirements"
    public var recordID: SyncRecordID { .init(zone: Self.zone, name: kind.rawValue + "-" + id.uuidString) }

    @MainActor public func verify(using identity: any SyncAccountIdentity) async throws {
        guard !owner.isEmpty, owner != CKCurrentUserDefaultName, try await identity.currentAccountUser() == owner else {
            throw VaultSyncFailure.unavailable
        }
    }

    public func matches(_ record: SyncRecord) -> Bool {
        record.id == recordID && record.type == .vault && record.schema == 1 && (try? JSONDecoder().decode(Self.self, from: record.payload)) == self
    }
}

@MainActor
public protocol CloudProfileRetirementTransport: SyncAccountIdentity {
    func publishRetirement(_ instance: CloudProfileInstance) async throws
    func isRetired(_ instance: CloudProfileInstance) async throws -> Bool
    func retirements(for owner: String) async throws -> Set<CloudProfileInstance>
}

extension CloudKitSyncEngine: CloudProfileRetirementTransport {
    public func isRetired(_ instance: CloudProfileInstance) async throws -> Bool {
        try await instance.verify(using: self)
        let id = CloudKitMapping.recordID(instance.recordID, ownerName: instance.owner)
        let found: Bool
        do {
            let record = try await container.privateCloudDatabase.record(for: id)
            guard let result = CloudKitMapping.syncRecord(record), instance.matches(result) else { throw VaultSyncFailure.unavailable }
            found = true
        } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
            found = false
        }
        try await instance.verify(using: self)
        return found
    }

    public func retirements(for owner: String) async throws -> Set<CloudProfileInstance> {
        guard !owner.isEmpty, owner != CKCurrentUserDefaultName, try await currentAccountUser() == owner else { throw VaultSyncFailure.unavailable }
        let records: [SyncRecord]
        do {
            let read = try await fetchAll(zoneID: CloudKitMapping.zoneID(CloudProfileInstance.zone, ownerName: owner))
            guard read.skipped == 0 else { throw VaultSyncFailure.unavailable }
            records = read.records
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            records = []
        }
        guard try await currentAccountUser() == owner else { throw VaultSyncFailure.unavailable }
        return try Set(records.map { record in
            let copy = try JSONDecoder().decode(CloudProfileInstance.self, from: record.payload)
            guard copy.owner == owner, copy.matches(record) else { throw VaultSyncFailure.unavailable }
            return copy
        })
    }

    public func publishRetirement(_ instance: CloudProfileInstance) async throws {
        try await instance.verify(using: self)
        let database = container.privateCloudDatabase
        let id = CloudKitMapping.recordID(instance.recordID, ownerName: instance.owner)
        _ = try await database.save(CKRecordZone(zoneID: id.zoneID))
        try await instance.verify(using: self)
        let record = SyncRecord(id: instance.recordID, type: .vault, schema: 1, payload: try JSONEncoder().encode(instance))
        do {
            _ = try await database.save(CloudKitMapping.ckRecord(record, ownerName: instance.owner))
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard try await isRetired(instance) else { throw error }
        }
        try await instance.verify(using: self)
    }
}
