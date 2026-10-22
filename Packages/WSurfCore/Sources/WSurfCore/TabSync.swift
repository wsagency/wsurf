// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import os

nonisolated public struct MirroredDevice: Codable, Equatable, Sendable {
    public var info: DeviceInfo
    public var modifiedAt: Date

    public init(info: DeviceInfo, modifiedAt: Date) {
        self.info = info
        self.modifiedAt = modifiedAt
    }
}

nonisolated public struct MirroredSession: Codable, Equatable, Sendable {
    public var payload: DeviceSessionPayload
    public var modifiedAt: Date

    public init(payload: DeviceSessionPayload, modifiedAt: Date) {
        self.payload = payload
        self.modifiedAt = modifiedAt
    }
}

/// Everything `TabSync` keeps between runs. It caches what the account's private database holds, so a launch lists the other
/// devices at once. It holds no profile identity beyond zone names, and nothing from a private window.
nonisolated public struct TabSyncState: Codable, Equatable, Sendable {
    public var engineState: Data?
    /// The `recordName` of the last signed-in user record.
    public var accountUser: String?
    public var seq: Int64 = 0
    /// Zone name to the system fields of this device's record there. A key means the record exists on the server.
    public var ownSystemFields: [String: Data] = [:]
    public var publishedDevice: DeviceInfo?
    /// Install ID to another device.
    public var devices: [String: MirroredDevice] = [:]
    /// Zone name to install ID to another device's session.
    public var sessions: [String: [String: MirroredSession]] = [:]

    public init() {}
}

nonisolated public struct RemoteDeviceSession: Identifiable, Equatable, Sendable {
    /// The install ID of the device.
    public var id: String
    public var label: String
    public var deviceName: String
    public var kind: DeviceKind
    public var payload: DeviceSessionPayload
    /// The server's modification date of the session record.
    public var lastSeen: Date

    public init(
        id: String,
        label: String,
        deviceName: String,
        kind: DeviceKind,
        payload: DeviceSessionPayload,
        lastSeen: Date
    ) {
        self.id = id
        self.label = label
        self.deviceName = deviceName
        self.kind = kind
        self.payload = payload
        self.lastSeen = lastSeen
    }
}

/// The platform-neutral core of tab sync: what this device publishes, what it keeps of the others, and how engine events change both.
@Observable
public final class TabSync: SyncEngineDelegate {
    public let installID: String
    public let device: DeviceInfo
    public private(set) var state: TabSyncState
    /// Nil until the engine has answered.
    public private(set) var accountAvailable: Bool?
    /// The profile whose sharing ended on the server or by an account change, or nil for every profile. Not called for the
    /// person's own choice. The owner turns its opt-in off.
    @ObservationIgnored public var onSharingEnded: ((UUID?) -> Void)?

    @ObservationIgnored private let persist: (TabSyncState) -> Void
    @ObservationIgnored private var engine: (any SyncEngine)?
    @ObservationIgnored private var desired: Set<UUID> = []
    @ObservationIgnored private var ensuredZones: Set<String> = []
    /// Zone name to the fitted, compressed payload of this device's next session record.
    @ObservationIgnored private var outgoing: [String: Data] = [:]
    /// Zone name to the last shared payload with `seq` zeroed, to drop a send that would change nothing.
    @ObservationIgnored private var lastShared: [String: DeviceSessionPayload] = [:]

    /// Whether this device owns anything on the server or wants to: the owner creates the engine only then.
    public var needsEngine: Bool {
        !desired.isEmpty || !state.ownSystemFields.isEmpty
    }

    // ponytail: `persist` rewrites the whole state per mutation and event, KBs typically; move to an actor-owned file if it shows up.
    public init(installID: String, device: DeviceInfo, state: TabSyncState, persist: @escaping (TabSyncState) -> Void) {
        self.installID = installID
        self.device = device
        self.state = state
        self.persist = persist
    }

    // MARK: - Engine and sharing

    /// Hands the engine everything this device wants on the server: zones, deletions and the latest session records.
    public func attach(_ engine: any SyncEngine) {
        self.engine = engine
        replay()
        Task { [weak self] in
            let available = await engine.accountIsAvailable()
            self?.accountAvailable = available
        }
    }

    /// The only place that decides what this device keeps on the server. Without an engine it only records `profiles`.
    public func reconcile(sharing profiles: Set<UUID>) {
        desired = profiles
        var changes: [SyncChange] = []
        for zone in Set(state.ownSystemFields.keys).union(outgoing.keys).sorted() {
            guard let id = SyncZone.profileID(zone), !profiles.contains(id) else { continue }
            outgoing[zone] = nil
            lastShared[zone] = nil
            if state.ownSystemFields[zone] != nil {
                changes.append(.deleteRecord(own(zone)))
            }
        }
        if profiles.isEmpty {
            if state.ownSystemFields[SyncZone.devices] != nil {
                changes.append(.deleteRecord(own(SyncZone.devices)))
            }
        } else {
            if ensuredZones.insert(SyncZone.devices).inserted {
                changes.append(.saveZone(SyncZone.devices))
            }
            if state.publishedDevice != device || state.ownSystemFields[SyncZone.devices] == nil {
                changes.append(.saveRecord(own(SyncZone.devices)))
            }
        }
        for profile in profiles.sorted(by: { $0.uuidString < $1.uuidString }) {
            let zone = SyncZone.profile(profile)
            if ensuredZones.insert(zone).inserted {
                changes.append(.saveZone(zone))
            }
        }
        add(changes)
    }

    /// Queues this device's session for `profileID`. Nothing happens unless the profile is shared, and a payload equal to the
    /// last one is dropped unless `force` is set (the heartbeat).
    public func share(_ payload: DeviceSessionPayload, profileID: UUID, force: Bool) {
        guard desired.contains(profileID) else { return }
        let zone = SyncZone.profile(profileID)
        var comparable = payload
        comparable.seq = 0
        if !force, lastShared[zone] == comparable {
            return
        }
        var stamped = payload
        stamped.seq = state.seq + 1
        guard let data = SessionCodec.encodeFitted(stamped) else {
            SyncLog.logger.error("sync: session does not fit the record")
            return
        }
        state.seq = stamped.seq
        outgoing[zone] = data
        lastShared[zone] = comparable
        add([.saveRecord(own(zone))])
        persist(state)
    }

    /// Forgets what other devices showed for a profile, when the profile leaves this Mac.
    public func dropMirror(profileID: UUID) {
        state.sessions[SyncZone.profile(profileID)] = nil
        persist(state)
    }

    public func refresh() async {
        try? await engine?.fetchNow()
    }

    public func sendNow() async {
        try? await engine?.sendNow()
    }

    // MARK: - What the other devices show

    /// The other devices' sessions of one profile, by label. A session whose device record is missing is not listed.
    public func remoteSessions(profileID: UUID, fallbackLabel: String) -> [RemoteDeviceSession] {
        let sessions = state.sessions[SyncZone.profile(profileID)] ?? [:]
        let labels = DeviceLabels.labels(
            for: state.devices.map { (id: $0.key, name: $0.value.info.name) },
            fallback: fallbackLabel
        )
        return sessions.compactMap { id, session -> RemoteDeviceSession? in
            guard id != installID, let device = state.devices[id] else { return nil }
            return RemoteDeviceSession(
                id: id,
                label: labels[id] ?? fallbackLabel,
                deviceName: device.info.name,
                kind: device.info.kind,
                payload: session.payload,
                lastSeen: session.modifiedAt
            )
        }
        .sorted { ($0.label, $0.id) < ($1.label, $1.id) }
    }

    // MARK: - SyncEngineDelegate

    public func record(for id: SyncRecordID) -> SyncRecord? {
        guard id.name == installID else { return nil }
        if id.zone == SyncZone.devices {
            guard !desired.isEmpty, let data = try? SessionCodec.encode(device) else { return nil }
            return SyncRecord(id: id, type: .device, schema: 1, payload: data, systemFields: state.ownSystemFields[id.zone])
        }
        guard SyncZone.profileID(id.zone) != nil, let data = outgoing[id.zone] else { return nil }
        return SyncRecord(id: id, type: .deviceSession, schema: 1, payload: data, systemFields: state.ownSystemFields[id.zone])
    }

    public func handle(_ event: SyncEvent) async {
        switch event {
        case .state(let data):
            state.engineState = data
        case .fetched(let modified, let deleted):
            applyFetched(modified: modified, deleted: deleted)
        case .sent(let saved, let deleted, let failed):
            applySent(saved: saved, deleted: deleted, failed: failed)
        case .zonesDeleted(let zones):
            applyZonesDeleted(zones.keys.sorted())
        case .account(let change):
            applyAccount(change)
        }
        persist(state)
    }

    // MARK: - Events

    private func applyFetched(modified: [SyncRecord], deleted: [SyncRecordID]) {
        for record in modified {
            if record.id.name == installID {
                // This device's own record: keep its change tag, never list it.
                state.ownSystemFields[record.id.zone] = record.systemFields ?? state.ownSystemFields[record.id.zone]
                continue
            }
            let modifiedAt = record.modifiedAt ?? .distantPast
            switch record.type {
            case .device:
                guard record.id.zone == SyncZone.devices,
                      let info = try? SessionCodec.decodeDevice(record.payload)
                else { continue }
                state.devices[record.id.name] = MirroredDevice(info: info, modifiedAt: modifiedAt)
            case .deviceSession:
                guard SyncZone.profileID(record.id.zone) != nil,
                      let payload = try? SessionCodec.decodeSession(record.payload)
                else { continue }
                state.sessions[record.id.zone, default: [:]][record.id.name] = MirroredSession(
                    payload: payload, modifiedAt: modifiedAt
                )
            }
        }
        for id in deleted {
            if id.name == installID {
                state.ownSystemFields[id.zone] = nil
                if id.zone == SyncZone.devices {
                    state.publishedDevice = nil
                }
            } else if id.zone == SyncZone.devices {
                state.devices[id.name] = nil
            } else {
                state.sessions[id.zone]?[id.name] = nil
                if state.sessions[id.zone]?.isEmpty == true {
                    state.sessions[id.zone] = nil
                }
            }
        }
    }

    private func applySent(saved: [SyncRecord], deleted: [SyncRecordID], failed: [SyncFailedSave]) {
        for record in saved where record.id.name == installID {
            let zone = record.id.zone
            state.ownSystemFields[zone] = record.systemFields ?? state.ownSystemFields[zone]
            if zone == SyncZone.devices {
                state.publishedDevice = device
            }
            // Sharing was turned off while this save was on its way: remove what it created.
            if !wants(zone: zone) {
                add([.deleteRecord(record.id)])
            }
        }
        for id in deleted where id.name == installID {
            state.ownSystemFields[id.zone] = nil
            if id.zone == SyncZone.devices {
                state.publishedDevice = nil
            }
        }
        for failure in failed where failure.id.name == installID {
            retry(failure)
        }
    }

    private func retry(_ failure: SyncFailedSave) {
        let id = failure.id
        switch failure.failure {
        case .serverRecordChanged(let server):
            // Save again on the server's change tag, with this device's payload.
            state.ownSystemFields[id.zone] = server.systemFields ?? state.ownSystemFields[id.zone]
            add([.saveRecord(id)])
        case .zoneNotFound:
            // The record cannot exist without its zone, so any change tag we hold is stale.
            state.ownSystemFields[id.zone] = nil
            if wants(zone: id.zone) {
                add([.saveZone(id.zone), .saveRecord(id)])
            }
        case .unknownItem:
            state.ownSystemFields[id.zone] = nil
            add([.saveRecord(id)])
        case .other:
            SyncLog.logger.error("sync: a record save failed; the next heartbeat tries again")
        }
    }

    /// A zone removed on the server ends sharing of its profile, whatever the reason. Nothing re-creates it here: it comes back
    /// only after the person turns sharing on again.
    private func applyZonesDeleted(_ zones: [String]) {
        var ended: [UUID?] = []
        for zone in zones {
            state.sessions[zone] = nil
            state.ownSystemFields[zone] = nil
            outgoing[zone] = nil
            lastShared[zone] = nil
            ensuredZones.remove(zone)
            if zone == SyncZone.devices {
                state.devices = [:]
                state.publishedDevice = nil
                desired = []
                ended.append(nil)
            } else if let id = SyncZone.profileID(zone) {
                desired.remove(id)
                ended.append(id)
            }
        }
        for profile in ended {
            onSharingEnded?(profile)
        }
    }

    private func applyAccount(_ change: SyncAccountChange) {
        switch change {
        case .signOut:
            clearAccountData()
            accountAvailable = false
        case .signIn(let user) where state.accountUser == nil || state.accountUser == user:
            state.accountUser = user
            accountAvailable = true
            replay()
        case .signIn(let user), .switchAccounts(let user):
            // Another Apple Account: nothing of the old one is shown, and nothing is uploaded until the person opts in again.
            clearAccountData()
            outgoing = [:]
            desired = []
            state.accountUser = user
            accountAvailable = true
            onSharingEnded?(nil)
        }
    }

    /// Everything the account's database gave this device, and the marks that say it was written there.
    private func clearAccountData() {
        state.devices = [:]
        state.sessions = [:]
        state.ownSystemFields = [:]
        state.publishedDevice = nil
        lastShared = [:]
        ensuredZones = []
    }

    // MARK: - Helpers

    private func own(_ zone: String) -> SyncRecordID {
        SyncRecordID(zone: zone, name: installID)
    }

    private func wants(zone: String) -> Bool {
        if zone == SyncZone.devices {
            return !desired.isEmpty
        }
        return SyncZone.profileID(zone).map(desired.contains) ?? false
    }

    private func add(_ changes: [SyncChange]) {
        guard !changes.isEmpty else { return }
        engine?.add(changes)
    }

    /// Asks the engine again for every zone, the device record and the latest session records.
    private func replay() {
        ensuredZones = []
        reconcile(sharing: desired)
        add(outgoing.keys.sorted().map { .saveRecord(own($0)) })
    }
}
