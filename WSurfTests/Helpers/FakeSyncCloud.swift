// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import WSurfCore

/// One account's private database, in memory. Engines of several devices share it, each with its own idea of what it has fetched.
/// It keeps the rules of the real one that sync relies on: a save carries the change tag it read, a stale tag fails with the
/// server's record, a record needs its zone, and a tag for a record that is gone fails as unknown.
@MainActor
final class FakeSyncCloud {
    struct Stored {
        var record: SyncRecord
        var tag: Int
        var changedAt: Int
    }

    enum SaveResult {
        case saved(SyncRecord)
        case failed(SyncSaveFailure)
    }

    struct Changes {
        var zones: [String: SyncZoneDeletionReason] = [:]
        var modified: [SyncRecord] = []
        var deleted: [SyncRecordID] = []
    }

    private struct ZoneDeletion {
        var at: Int
        var zone: String
        var reason: SyncZoneDeletionReason
    }

    private struct RecordDeletion {
        var at: Int
        var id: SyncRecordID
    }

    /// Zone name to record name to what the server holds.
    private(set) var zones: [String: [String: Stored]] = [:]
    private(set) var user: String
    /// How many records were written. It does not move when a save fails or is dropped.
    private(set) var writeCount = 0
    private(set) var clock = 0
    var now: () -> Date

    private var zoneDeletions: [ZoneDeletion] = []
    private var recordDeletions: [RecordDeletion] = []

    init(user: String = "user-1", now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }) {
        self.user = user
        self.now = now
    }

    // MARK: - What a test reads

    func record(_ id: SyncRecordID) -> SyncRecord? {
        zones[id.zone]?[id.name]?.record
    }

    func tag(of id: SyncRecordID) -> Int? {
        zones[id.zone]?[id.name]?.tag
    }

    /// The names of the records in a zone, sorted.
    func names(in zone: String) -> [String] {
        (zones[zone]?.keys).map { $0.sorted() } ?? []
    }

    var recordCount: Int {
        zones.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - What another party does

    /// Another writer saved the record: the tag moves, the content stays.
    func bump(_ id: SyncRecordID) {
        guard var held = zones[id.zone]?[id.name] else { return }
        clock += 1
        held.tag += 1
        held.changedAt = clock
        held.record.systemFields = Self.fields(for: held.tag)
        held.record.modifiedAt = now()
        zones[id.zone]?[id.name] = held
    }

    /// Another writer replaced the payload.
    func overwrite(_ id: SyncRecordID, payload: Data) {
        guard var held = zones[id.zone]?[id.name] else { return }
        held.record.payload = payload
        zones[id.zone]?[id.name] = held
        bump(id)
    }

    func deleteZone(_ zone: String, reason: SyncZoneDeletionReason) {
        clock += 1
        zones[zone] = nil
        zoneDeletions.append(ZoneDeletion(at: clock, zone: zone, reason: reason))
    }

    /// The zone is gone and nobody was told.
    func removeZoneSilently(_ zone: String) {
        zones[zone] = nil
    }

    func deleteRecord(_ id: SyncRecordID) {
        _ = remove(id)
    }

    /// A different Apple Account: another database, empty.
    func switchUser(_ user: String) {
        self.user = user
        zones = [:]
        zoneDeletions = []
        recordDeletions = []
    }

    // MARK: - What an engine does

    func createZone(_ zone: String) {
        if zones[zone] == nil {
            zones[zone] = [:]
        }
    }

    func save(_ record: SyncRecord) -> SaveResult {
        guard zones[record.id.zone] != nil else { return .failed(.zoneNotFound) }
        let held = Self.tag(in: record.systemFields)
        if let existing = zones[record.id.zone]?[record.id.name] {
            guard held == existing.tag else { return .failed(.serverRecordChanged(existing.record)) }
            return .saved(store(record, tag: existing.tag + 1))
        }
        guard held == nil else { return .failed(.unknownItem) }
        return .saved(store(record, tag: 1))
    }

    /// True when the record was there. A delete of a missing record is not an error.
    @discardableResult
    func remove(_ id: SyncRecordID) -> Bool {
        guard zones[id.zone]?[id.name] != nil else { return false }
        clock += 1
        zones[id.zone]?[id.name] = nil
        recordDeletions.append(RecordDeletion(at: clock, id: id))
        return true
    }

    func changes(since mark: Int) -> Changes {
        var result = Changes()
        for deletion in zoneDeletions where deletion.at > mark {
            result.zones[deletion.zone] = deletion.reason
        }
        for zone in zones.keys.sorted() {
            let changed = (zones[zone] ?? [:]).values.filter { $0.changedAt > mark }
            result.modified += changed.sorted { $0.record.id.name < $1.record.id.name }.map(\.record)
        }
        result.deleted = recordDeletions.filter { $0.at > mark && zones[$0.id.zone] != nil }.map(\.id)
        return result
    }

    private func store(_ record: SyncRecord, tag: Int) -> SyncRecord {
        clock += 1
        writeCount += 1
        var stored = record
        stored.systemFields = Self.fields(for: tag)
        stored.modifiedAt = now()
        zones[record.id.zone]?[record.id.name] = Stored(record: stored, tag: tag, changedAt: clock)
        return stored
    }

    nonisolated static func fields(for tag: Int) -> Data {
        Data("tag-\(tag)".utf8)
    }

    nonisolated static func tag(in fields: Data?) -> Int? {
        fields.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.hasPrefix("tag-") ? Int($0.dropFirst(4)) : nil }
    }
}

/// An engine over a `FakeSyncCloud`. `sendNow` keeps sending until the model has nothing more to retry, as the real one keeps
/// scheduling failed changes.
@MainActor
final class FakeSyncEngine: SyncEngine {
    let cloud: FakeSyncCloud
    weak var delegate: (any SyncEngineDelegate)?
    var available = true
    /// A send that waits until it is cancelled, for the limit on quit.
    var hangsOnSend = false
    private(set) var pending: [SyncChange] = []
    private(set) var sendCount = 0
    private(set) var fetchCount = 0
    private var fetchedAt = 0
    private var stateRevision = 0

    init(cloud: FakeSyncCloud, delegate: (any SyncEngineDelegate)? = nil) {
        self.cloud = cloud
        self.delegate = delegate
    }

    func add(_ changes: [SyncChange]) {
        for change in changes {
            pending.removeAll { Self.target(of: $0) == Self.target(of: change) }
            pending.append(change)
        }
    }

    func sendNow() async throws {
        sendCount += 1
        if hangsOnSend {
            try await Task.sleep(for: .seconds(86_400))
        }
        var rounds = 0
        while !pending.isEmpty, rounds < 8 {
            rounds += 1
            let batch = pending
            pending = []
            await send(batch)
        }
    }

    func fetchNow() async throws {
        fetchCount += 1
        let changes = cloud.changes(since: fetchedAt)
        fetchedAt = cloud.clock
        if !changes.zones.isEmpty {
            await delegate?.handle(.zonesDeleted(changes.zones))
        }
        if !changes.modified.isEmpty || !changes.deleted.isEmpty {
            await delegate?.handle(.fetched(modified: changes.modified, deleted: changes.deleted))
        }
        await publishState()
    }

    func accountIsAvailable() async -> Bool {
        available
    }

    /// The account changed under the engine: its queue is gone, and a different account is fetched from the start.
    func simulateAccount(_ change: SyncAccountChange) async {
        pending = []
        if change != .signOut {
            fetchedAt = 0
        }
        await delegate?.handle(.account(change))
    }

    private func send(_ batch: [SyncChange]) async {
        for change in batch {
            switch change {
            case .saveZone(let zone):
                cloud.createZone(zone)
            case .deleteZone(let zone):
                cloud.deleteZone(zone, reason: .deleted)
            case .saveRecord, .deleteRecord:
                break
            }
        }
        var saved: [SyncRecord] = []
        var deleted: [SyncRecordID] = []
        var failed: [SyncFailedSave] = []
        for change in batch {
            switch change {
            case .saveRecord(let id):
                // A record the model no longer wants is dropped, as the real engine drops it.
                guard let record = delegate?.record(for: id) else { continue }
                switch cloud.save(record) {
                case .saved(let stored):
                    saved.append(stored)
                case .failed(let failure):
                    failed.append(SyncFailedSave(id: id, failure: failure))
                }
            case .deleteRecord(let id):
                cloud.remove(id)
                deleted.append(id)
            case .saveZone, .deleteZone:
                break
            }
        }
        await delegate?.handle(.sent(saved: saved, deleted: deleted, failed: failed))
        await publishState()
    }

    private func publishState() async {
        stateRevision += 1
        await delegate?.handle(.state(Data("state-\(stateRevision)".utf8)))
    }

    private static func target(of change: SyncChange) -> String {
        switch change {
        case .saveZone(let zone), .deleteZone(let zone):
            "zone:" + zone
        case .saveRecord(let id), .deleteRecord(let id):
            "record:" + id.zone + "/" + id.name
        }
    }
}

/// One simulated device: its model, its engine and what the model reported to its owner.
@MainActor
final class SyncDevice {
    final class Box {
        var state: TabSyncState?
        var ended: [UUID?] = []
    }

    let sync: TabSync
    let engine: FakeSyncEngine
    let installID: String
    let box = Box()

    init(cloud: FakeSyncCloud, installID: String, name: String = "Ana’s MacBook Air", state: TabSyncState = TabSyncState()) {
        self.installID = installID
        let box = box
        sync = TabSync(
            installID: installID,
            device: DeviceInfo(name: name, kind: .mac, appVersion: "0.1.7"),
            state: state,
            persist: { box.state = $0 }
        )
        engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.onSharingEnded = { box.ended.append($0) }
    }

    /// What the app does at launch: decide what is shared, then attach the engine.
    func start(sharing profiles: Set<UUID>) {
        sync.reconcile(sharing: profiles)
        sync.attach(engine)
    }

    func id(in zone: String) -> SyncRecordID {
        SyncRecordID(zone: zone, name: installID)
    }
}

/// Small payloads for tests.
enum SyncSamples {
    static func tab(_ url: String, title: String? = nil) -> SessionNode {
        SessionNode(id: UUID(), title: title ?? url, url: url)
    }

    static func session(running: Bool = true, tabs: [String] = [], favorites: [String] = [], pins: [String] = []) -> DeviceSessionPayload {
        DeviceSessionPayload(
            running: running,
            favorites: favorites.map { tab($0) },
            pins: pins.map { tab($0) },
            windows: tabs.isEmpty ? [] : [SessionWindow(id: UUID(), nodes: tabs.map { tab($0) })]
        )
    }
}

/// An install ID store in memory.
nonisolated final class MemoryInstallIDStorage: InstallIDStorage, Sendable {
    private struct State {
        var value: String?
        var failsReads = false
        var writes = 0
    }

    private let state = Mutex(State())

    init(value: String? = nil) {
        state.withLock { $0.value = value }
    }

    var value: String? {
        state.withLock { $0.value }
    }

    var writes: Int {
        state.withLock { $0.writes }
    }

    var failsReads: Bool {
        get { state.withLock { $0.failsReads } }
        set { state.withLock { $0.failsReads = newValue } }
    }

    func read() throws -> String? {
        try state.withLock { state in
            guard !state.failsReads else { throw CocoaError(.fileReadNoPermission) }
            return state.value
        }
    }

    func write(_ id: String) throws {
        state.withLock { state in
            state.value = id
            state.writes += 1
        }
    }
}
