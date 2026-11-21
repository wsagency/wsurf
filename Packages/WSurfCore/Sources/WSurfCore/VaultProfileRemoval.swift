// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

/// The explicit per-vault consent that a confirmed profile deletion withdraws, even after Credentials.sync is gone.
nonisolated public struct VaultProfileRemoval: Codable, Hashable, Sendable {
    public let profileID: UUID
    public let vaultID: UUID
    let owner: String

    public static func approved(in directory: URL, profileID: UUID) throws -> Set<Self> {
        let file = directory.appending(path: VaultSyncDatabase.fileName)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        guard let database = try VaultSyncDatabase.open(directory: directory, create: false) else { throw CocoaError(.fileReadUnknown) }
        return try database.read { tx in
            Set(try tx.vaults().compactMap { row in
                guard row.enabled, let owner = row.approvedUser, !owner.isEmpty, owner != CKCurrentUserDefaultName else { return nil }
                return Self(profileID: profileID, vaultID: row.vaultID, owner: owner)
            })
        }
    }

    /// The explicit zone owner keeps even an account change during dispatch from redirecting the operation.
    @MainActor
    func delete(currentUser: () async throws -> String, remove: (CKRecordZone.ID) async throws -> Void) async throws {
        guard !owner.isEmpty, owner != CKCurrentUserDefaultName, try await currentUser() == owner else { throw VaultSyncFailure.unavailable }
        let zone = SyncZone.vault(profileID: profileID, vaultID: vaultID)
        do {
            try await remove(CloudKitMapping.zoneID(zone, ownerName: owner))
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // A previous attempt may have succeeded before its receipt was saved.
        }
        guard try await currentUser() == owner else { throw VaultSyncFailure.unavailable }
    }
}

@MainActor
public protocol VaultProfileZoneDeleting: AnyObject {
    func deleteVaultZone(_ removal: VaultProfileRemoval) async throws
}

extension CloudKitSyncEngine: VaultProfileZoneDeleting {
    public func deleteVaultZone(_ removal: VaultProfileRemoval) async throws {
        try await removal.delete(currentUser: currentAccountUser) { id in
            _ = try await self.container.privateCloudDatabase.deleteRecordZone(withID: id)
        }
    }
}
