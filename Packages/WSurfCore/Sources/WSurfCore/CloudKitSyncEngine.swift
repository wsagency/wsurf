// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import os

/// The `SyncEngine` over `CKSyncEngine` and the account's private database. This is the only `CKContainer` in the code base.
///
/// Creating a container in a process whose signed entitlements lack the iCloud keys raises an Objective-C exception that Swift
/// cannot catch, so the owner creates this object only after `CloudSyncGate` has read the entitlements.
public final class CloudKitSyncEngine: SyncEngine, SyncAccountIdentity {
    let container: CKContainer
    private let bridge: Bridge
    private let engine: CKSyncEngine

    /// `state` is the bytes of the last `.state` event. A state that does not decode starts fresh, which fetches everything.
    public init(containerIdentifier: String, state: Data?, delegate: any SyncEngineDelegate) {
        let container = CKContainer(identifier: containerIdentifier)
        let bridge = Bridge(delegate: delegate, container: container)
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

    public func fetchAll(zone: String) async throws -> SyncZoneRead {
        let database = container.privateCloudDatabase
        var snapshot = CloudKitZoneSnapshot()
        var token: CKServerChangeToken?
        while true {
            let page = try await database.recordZoneChanges(
                inZoneWith: CloudKitMapping.zoneID(zone), since: token, desiredKeys: [CloudKitMapping.payloadKey, CloudKitMapping.schemaKey]
            )
            snapshot.applyPage(
                modified: page.modificationResultsByID.lazy.map { id, result in (id, (try? result.get())?.record) },
                deleted: page.deletions.lazy.map(\.recordID)
            )
            guard page.moreComing else {
                let read = snapshot.read
                if read.skipped > 0 {
                    SyncLog.logger.error("sync: \(read.skipped) records of a zone could not be read")
                }
                return read
            }
            token = page.changeToken
        }
    }

    public func accountIsAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    public func currentAccountUser() async throws -> String {
        try await container.userRecordID().recordName
    }
}

/// A record can change or disappear between pages of a full zone read.
nonisolated struct CloudKitZoneSnapshot {
    private var records: [CKRecord.ID: SyncRecord] = [:]
    private var unreadable: Set<CKRecord.ID> = []

    var read: SyncZoneRead {
        SyncZoneRead(records: Array(records.values), skipped: unreadable.count)
    }

    mutating func applyPage(modified: some Sequence<(CKRecord.ID, CKRecord?)>, deleted: some Sequence<CKRecord.ID>) {
        for (id, record) in modified {
            records[id] = record.flatMap(CloudKitMapping.syncRecord)
            if records[id] == nil && (record.map(CloudKitMapping.requiresCompleteRead) ?? true) {
                unreadable.insert(id)
            } else {
                unreadable.remove(id)
            }
        }
        for id in deleted {
            records[id] = nil
            unreadable.remove(id)
        }
    }
}

/// The engine's delegate. It is `Sendable`, so it holds the model-side delegate and never takes a main-actor conformance.
/// The strong cycle (model, adapter, bridge, model) is intended: the object lives for the app run.
private nonisolated final class Bridge: CKSyncEngineDelegate {
    let delegate: any SyncEngineDelegate
    let container: CKContainer

    init(delegate: any SyncEngineDelegate, container: CKContainer) {
        self.delegate = delegate
        self.container = container
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
            // A zone this Mac could not make because iCloud is full is not a zone that was removed: the vault says so.
            let full = sent.failedZoneSaves.filter { $0.error.code == .quotaExceeded }.map { $0.zone.zoneID.zoneName }.filter(SyncZone.isVault)
            if !full.isEmpty {
                await delegate.handle(.zoneSavesOverQuota(full.sorted()))
            }
            // A zone that is gone is a zone that is deleted, whether this delete did it or the zone was not there to delete.
            let gone = sent.deletedZoneIDs + sent.failedZoneDeletes.filter { $0.value.code == .zoneNotFound }.map(\.key)
            let removed = gone.map(\.zoneName).filter(SyncZone.isVault)
            if !removed.isEmpty {
                await delegate.handle(.zonesDeleted(Dictionary(removed.map { ($0, SyncZoneDeletionReason.deleted) }) { first, _ in first }))
            }
            let failed = sent.failedZoneDeletes.filter { $0.value.code != .zoneNotFound }.keys.map(\.zoneName).sorted()
            if !failed.isEmpty {
                await delegate.handle(.zoneDeletesFailed(failed))
            }
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        let enrolled = await (delegate as? any VaultZoneReading)?.enrolledVaultZones ?? []
        var options = context.options
        options.scope = CloudKitMapping.fetchScope(options.scope, pending: syncEngine.state.zoneIDsWithUnfetchedServerChanges, enrolled: enrolled)
        return options
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // CKSyncEngine sends pendingDatabaseChanges (zone creation and explicit zone removal) through its separate database path.
        return await CloudKitMapping.uploadBatch(pending, delegate: delegate, currentUser: { [container] in
            try await container.userRecordID().recordName
        }, discard: { syncEngine.state.remove(pendingRecordZoneChanges: [$0]) })
    }
}

extension CloudKitMapping {
    static func uploadBatch(
        _ pending: [CKSyncEngine.PendingRecordZoneChange], delegate: any SyncEngineDelegate,
        currentUser: @escaping @MainActor @Sendable () async throws -> String,
        discard: @escaping @Sendable (CKSyncEngine.PendingRecordZoneChange) -> Void
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !pending.isEmpty, await delegate.permitsUpload(using: currentUser) else { return nil }
        let approved = await MainActor.run {
            pending.filter { change in
                if case .deleteRecord(let id) = change, !delegate.wantsRecordDeletion(syncID(id)) {
                    discard(change)
                    return false
                }
                return true
            }
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: approved) { recordID in
            if let record = await delegate.record(for: syncID(recordID)) {
                return CloudKitMapping.ckRecord(record)
            }
            // A save that is no longer wanted must not come back on the next batch.
            discard(.saveRecord(recordID))
            return nil
        }
    }
}

nonisolated extension CloudKitMapping {
    /// CloudKit asks again between requests, including after it learns which zones have changes.
    static func fetchScope(
        _ scope: CKSyncEngine.FetchChangesOptions.Scope, pending: [CKRecordZone.ID], enrolled: Set<String>
    ) -> CKSyncEngine.FetchChangesOptions.Scope {
        func allowed(_ id: CKRecordZone.ID) -> Bool {
            !SyncZone.isVault(id.zoneName) || enrolled.contains(id.zoneName)
        }
        let denied = pending.filter { !allowed($0) }
        switch scope {
        case .all:
            return .allExcluding(denied)
        case .allExcluding(let excluded):
            return .allExcluding(Array(Set(excluded).union(denied)))
        case .zoneIDs(let selected):
            return .zoneIDs(selected.filter(allowed))
        @unknown default:
            return .zoneIDs(pending.filter { scope.contains($0) && allowed($0) })
        }
    }

    /// Readers that infer deletions from absence need to know if a row they mirror was unreadable.
    static func requiresCompleteRead(_ record: CKRecord) -> Bool {
        let zone = record.recordID.zoneID.zoneName
        let mirroredTabRow = (zone == SyncZone.devices && record.recordType == SyncRecordType.device.rawValue)
            || (SyncZone.profileID(zone) != nil && record.recordType == SyncRecordType.deviceSession.rawValue)
        return mirroredTabRow || zone.hasPrefix("mac-prefs-") || SharedCatalogCategory.allCases.contains { $0.zone == zone }
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
        case .quotaExceeded:
            failure = .quotaExceeded
        default:
            failure = .other
        }
        return SyncFailedSave(id: syncID(record.recordID), failure: failure, attempted: syncRecord(record))
    }
}
