// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// The sync log. Event kinds and counts only: never a URL, a title, a device name, a zone name or a user ID.
nonisolated enum SyncLog {
    static let logger = Logger(subsystem: "io.wsagency.wsurf", category: "sync")
}

/// Zone names. `devices` holds one `Device` record per install; `p-<profile UUID>` holds one `DeviceSession` per install.
nonisolated public enum SyncZone {
    public static let devices = "devices"
    private static let profilePrefix = "p-"

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
}

/// The model side of an engine. Both requirements run on the main actor; an engine hops there.
/// `Sendable` because the engine's own delegate object holds it and is itself `Sendable`.
public protocol SyncEngineDelegate: AnyObject, Sendable {
    func handle(_ event: SyncEvent) async
    /// The record to send for `id`, or nil when it is no longer wanted.
    func record(for id: SyncRecordID) -> SyncRecord?
}

/// A sync engine for one private database. The CloudKit adapter is the only conformance outside tests.
public protocol SyncEngine: AnyObject {
    func add(_ changes: [SyncChange])
    func sendNow() async throws
    func fetchNow() async throws
    func accountIsAvailable() async -> Bool
}
