// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// The sync log. Event kinds and counts only: never a URL, a title, a device name, a zone name or a user ID.
nonisolated enum SyncLog {
    static let logger = Logger(subsystem: "io.wsagency.wsurf", category: "sync")
}

/// Zone names. `devices` holds one `Device` record per install; `p-<profile UUID>` holds one `DeviceSession` per install;
/// `v-<profile UUID>-<vault UUID>` holds one synced vault: its `Vault` record and one `Item` per account.
nonisolated public enum SyncZone {
    public static let devices = "devices"
    private static let profilePrefix = "p-"
    private static let vaultPrefix = "v-"

    public static func profile(_ id: UUID) -> String {
        profilePrefix + id.uuidString
    }

    /// The profile of a `p-<UUID>` zone, or nil for any other name, including a lower-case spelling of a UUID.
    public static func profileID(_ zone: String) -> UUID? {
        guard zone.hasPrefix(profilePrefix),
              let id = UUID(uuidString: String(zone.dropFirst(profilePrefix.count))),
              profile(id) == zone
        else { return nil }
        return id
    }

    public static func vault(profileID: UUID, vaultID: UUID) -> String {
        vaultPrefix + profileID.uuidString + "-" + vaultID.uuidString
    }

    /// The profile and vault of a `v-<UUID>-<UUID>` zone, or nil for any other name, including a lower-case spelling of a UUID.
    public static func vaultIDs(_ zone: String) -> (profileID: UUID, vaultID: UUID)? {
        let ids = zone.dropFirst(vaultPrefix.count)
        guard zone.hasPrefix(vaultPrefix), ids.count == 73, ids[ids.index(ids.startIndex, offsetBy: 36)] == "-",
              let profileID = UUID(uuidString: String(ids.prefix(36))),
              let vaultID = UUID(uuidString: String(ids.suffix(36))),
              vault(profileID: profileID, vaultID: vaultID) == zone
        else { return nil }
        return (profileID, vaultID)
    }

    /// Whether the name is in the vault namespace, whatever follows the prefix.
    public static func isVault(_ zone: String) -> Bool {
        zone.hasPrefix(vaultPrefix)
    }
}

nonisolated public struct SyncRecordID: Hashable, Codable, Sendable {
    public var zone: String
    public var name: String

    public init(zone: String, name: String) {
        self.zone = zone
        self.name = name
    }
}

/// Adding a case is a reviewed change: `NeverSyncTests` pins this list.
nonisolated public enum SyncRecordType: String, CaseIterable, Codable, Sendable {
    case device = "Device"
    case deviceSession = "DeviceSession"
    case vault = "Vault"
    case item = "Item"
}

nonisolated public struct SyncRecord: Equatable, Sendable {
    public var id: SyncRecordID
    public var type: SyncRecordType
    public var schema: Int
    /// What the engine stores in the one encrypted field. The engine never looks inside.
    public var payload: Data
    /// The engine's change tag and ID of this record, opaque to everything above it.
    public var systemFields: Data?
    /// The server's modification date. No client clock is ever written.
    public var modifiedAt: Date?

    public init(
        id: SyncRecordID,
        type: SyncRecordType,
        schema: Int,
        payload: Data,
        systemFields: Data? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.schema = schema
        self.payload = payload
        self.systemFields = systemFields
        self.modifiedAt = modifiedAt
    }
}

nonisolated public enum SyncChange: Hashable, Sendable {
    case saveZone(String)
    case deleteZone(String)
    case saveRecord(SyncRecordID)
    case deleteRecord(SyncRecordID)
}

nonisolated public enum SyncZoneDeletionReason: CaseIterable, Sendable {
    case deleted
    case purged
    case encryptedDataReset
}

/// `user` is the `recordName` of the account's user record: opaque, and different in every container.
nonisolated public enum SyncAccountChange: Equatable, Sendable {
    case signIn(user: String)
    case signOut
    case switchAccounts(user: String)
}

nonisolated public enum SyncSaveFailure: Sendable {
    case serverRecordChanged(SyncRecord)
    case zoneNotFound
    case unknownItem
    /// The account's iCloud storage is full: the change stays queued and goes up when there is room.
    case quotaExceeded
    case other
}

nonisolated public struct SyncFailedSave: Sendable {
    public var id: SyncRecordID
    public var failure: SyncSaveFailure

    public init(id: SyncRecordID, failure: SyncSaveFailure) {
        self.id = id
        self.failure = failure
    }
}

nonisolated public enum SyncEvent: Sendable {
    /// The encoded engine state. Opaque to `TabSync`, which only stores it.
    case state(Data)
    case account(SyncAccountChange)
    case zonesDeleted([String: SyncZoneDeletionReason])
    case fetched(modified: [SyncRecord], deleted: [SyncRecordID])
    case sent(saved: [SyncRecord], deleted: [SyncRecordID], failed: [SyncFailedSave])
    /// The engine could not delete these zones.
    case zoneDeletesFailed([String])
}

/// The model side of an engine. Both requirements run on the main actor; an engine hops there.
/// `Sendable` because the engine's own delegate object holds it and is itself `Sendable`.
public protocol SyncEngineDelegate: AnyObject, Sendable {
    func handle(_ event: SyncEvent) async
    /// The record to send for `id`, or nil when it is no longer wanted.
    func record(for id: SyncRecordID) -> SyncRecord?
}

/// What a full read of one zone returned.
nonisolated public struct SyncZoneRead: Sendable {
    public var records: [SyncRecord]
    /// Records the server could not return.
    public var skipped: Int

    public init(records: [SyncRecord], skipped: Int = 0) {
        self.records = records
        self.skipped = skipped
    }
}

/// A sync engine for one private database. The CloudKit adapter is the only conformance outside tests.
public protocol SyncEngine: AnyObject {
    func add(_ changes: [SyncChange])
    func sendNow() async throws
    func fetchNow() async throws
    /// One full read of one zone, for a Mac that adds or rejoins a vault and so missed the records the engine fetched before. It
    /// goes through the same allowlist as an engine fetch. A record the server could not return is skipped and counted, so one bad
    /// record never fails the read. Never call it from inside `handle`.
    func fetchAll(zone: String) async throws -> SyncZoneRead
    func accountIsAvailable() async -> Bool
}
