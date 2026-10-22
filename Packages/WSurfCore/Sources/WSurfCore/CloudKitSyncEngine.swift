// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CloudKit
import Foundation
import os

/// The `SyncEngine` over `CKSyncEngine` and the account's private database. This is the only `CKContainer` in the code base.
///
/// Creating a container in a process whose signed entitlements lack the iCloud keys raises an Objective-C exception that Swift
/// cannot catch, so the owner creates this object only after `CloudTabsGate` has read the entitlements.
public final class CloudKitSyncEngine: SyncEngine {
    private let container: CKContainer
    private let bridge: Bridge
    private let engine: CKSyncEngine

    /// `state` is the bytes of the last `.state` event. A state that does not decode starts fresh, which fetches everything.
    public init(containerIdentifier: String, state: Data?, delegate: any SyncEngineDelegate) {
        let container = CKContainer(identifier: containerIdentifier)
        let bridge = Bridge(delegate: delegate)
        let restored = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        self.container = container
        self.bridge = bridge
        engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: restored,
            delegate: bridge
        ))
    }

    public func add(_ changes: [SyncChange]) {
        var zones: [CKSyncEngine.PendingDatabaseChange] = []
        var records: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in changes {
            switch change {
            case .saveZone(let zone):
                zones.append(.saveZone(CKRecordZone(zoneID: CloudKitMapping.zoneID(zone))))
            case .deleteZone(let zone):
                zones.append(.deleteZone(CloudKitMapping.zoneID(zone)))
            case .saveRecord(let id):
                records.append(.saveRecord(CloudKitMapping.recordID(id)))
            case .deleteRecord(let id):
                records.append(.deleteRecord(CloudKitMapping.recordID(id)))
            }
        }
        if !zones.isEmpty {
            engine.state.add(pendingDatabaseChanges: zones)
        }
        if !records.isEmpty {
            engine.state.add(pendingRecordZoneChanges: records)
        }
    }

    public func sendNow() async throws {
        try await engine.sendChanges()
    }

    public func fetchNow() async throws {
        try await engine.fetchChanges()
    }

    public func accountIsAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }
}

/// The engine's delegate. It is `Sendable`, so it holds the model-side delegate and never takes a main-actor conformance.
/// The strong cycle (model, adapter, bridge, model) is intended: the object lives for the app run.
private nonisolated final class Bridge: CKSyncEngineDelegate {
    let delegate: any SyncEngineDelegate

    init(delegate: any SyncEngineDelegate) {
        self.delegate = delegate
    }

    // The engine waits for each event, so a model that stays busy here holds up the next one. `sendChanges` and `fetchChanges`
    // must never be called from inside; `state.add` may.
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else {
                SyncLog.logger.error("sync: engine state could not be encoded")
                return
            }
            await delegate.handle(.state(data))
        case .accountChange(let change):
            await delegate.handle(.account(CloudKitMapping.accountChange(change.changeType)))
        case .fetchedDatabaseChanges(let changes):
            guard !changes.deletions.isEmpty else { return }
            let zones = changes.deletions.map { ($0.zoneID.zoneName, CloudKitMapping.reason($0.reason)) }
            await delegate.handle(.zonesDeleted(Dictionary(zones, uniquingKeysWith: { first, _ in first })))
        case .fetchedRecordZoneChanges(let changes):
            let modified = changes.modifications.compactMap { CloudKitMapping.syncRecord($0.record) }
            let deleted = changes.deletions
                .filter { SyncRecordType(rawValue: $0.recordType) != nil }
                .map { CloudKitMapping.syncID($0.recordID) }
            guard !modified.isEmpty || !deleted.isEmpty else { return }
            await delegate.handle(.fetched(modified: modified, deleted: deleted))
        case .sentRecordZoneChanges(let sent):
            if !sent.failedRecordDeletes.isEmpty {
                SyncLog.logger.error("sync: \(sent.failedRecordDeletes.count) record deletes failed")
            }
            await delegate.handle(.sent(
                saved: sent.savedRecords.compactMap { CloudKitMapping.syncRecord($0) },
                deleted: sent.deletedRecordIDs.map { CloudKitMapping.syncID($0) },
                failed: sent.failedRecordSaves.map { CloudKitMapping.failedSave($0.record, $0.error) }
            ))
        case .sentDatabaseChanges(let sent):
            if !sent.failedZoneSaves.isEmpty || !sent.failedZoneDeletes.isEmpty {
                SyncLog.logger.error("sync: \(sent.failedZoneSaves.count + sent.failedZoneDeletes.count) zone changes failed")
            }
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            if let record = await self.delegate.record(for: CloudKitMapping.syncID(recordID)) {
                return CloudKitMapping.ckRecord(record)
            }
            // A save that is no longer wanted must not come back on the next batch.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }
}

/// The two-way mapping between sync types and CloudKit types. `syncRecord` is the allowlist boundary: a record of another type,
/// or one without the encrypted `payload`, never reaches the model.
private nonisolated enum CloudKitMapping {
    static let payloadKey = "payload"
    static let schemaKey = "schemaVersion"

    static func zoneID(_ zone: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(_ id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.name, zoneID: zoneID(id.zone))
    }

    static func syncID(_ id: CKRecord.ID) -> SyncRecordID {
        SyncRecordID(zone: id.zoneID.zoneName, name: id.recordName)
    }

    static func syncRecord(_ record: CKRecord) -> SyncRecord? {
        guard let type = SyncRecordType(rawValue: record.recordType),
              let payload = record.encryptedValues[payloadKey] as? Data
        else { return nil }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return SyncRecord(
            id: syncID(record.recordID),
            type: type,
            schema: (record[schemaKey] as? Int) ?? 1,
            payload: payload,
            systemFields: archiver.encodedData,
            modifiedAt: record.modificationDate
        )
    }

    static func ckRecord(_ record: SyncRecord) -> CKRecord {
        let id = recordID(record.id)
        let result = restoredRecord(from: record.systemFields, matching: id, type: record.type)
            ?? CKRecord(recordType: record.type.rawValue, recordID: id)
        result[schemaKey] = record.schema as NSNumber
        result.encryptedValues[payloadKey] = record.payload
        return result
    }

    private static func restoredRecord(from fields: Data?, matching id: CKRecord.ID, type: SyncRecordType) -> CKRecord? {
        guard let fields, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: fields) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let restored = CKRecord(coder: unarchiver), restored.recordID == id, restored.recordType == type.rawValue
        else { return nil }
        return restored
    }

    static func accountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) -> SyncAccountChange {
        switch change {
        case .signIn(let user):
            .signIn(user: user.recordName)
        case .signOut:
            .signOut
        case .switchAccounts(_, let user):
            .switchAccounts(user: user.recordName)
        @unknown default:
            // Unknown means ending sharing, which is the safe side.
            .switchAccounts(user: "")
        }
    }

    static func reason(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) -> SyncZoneDeletionReason {
        switch reason {
        case .deleted:
            .deleted
        case .purged:
            .purged
        case .encryptedDataReset:
            .encryptedDataReset
        @unknown default:
            .deleted
        }
    }

    static func failedSave(_ record: CKRecord, _ error: CKError) -> SyncFailedSave {
        let failure: SyncSaveFailure
        switch error.code {
        case .serverRecordChanged:
            failure = error.serverRecord.flatMap(syncRecord).map(SyncSaveFailure.serverRecordChanged) ?? .other
        case .zoneNotFound:
            failure = .zoneNotFound
        case .unknownItem:
            failure = .unknownItem
        default:
            failure = .other
        }
        return SyncFailedSave(id: syncID(record.recordID), failure: failure)
    }
}
