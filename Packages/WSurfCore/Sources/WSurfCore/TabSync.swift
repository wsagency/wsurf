// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
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
/// devices at once. It holds no profile identity beyond zone names, and nothing from a private window. The engine's own state
/// belongs to `SyncRouter`.
nonisolated public struct TabSyncState: Codable, Equatable, Sendable {
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
    @ObservationIgnored private var restoredUnidentifiedRecords: Bool
    @ObservationIgnored private var desired: Set<UUID> = []
    @ObservationIgnored private var ensuredZones: Set<String> = []
    /// Zone name to the fitted, compressed payload of this device's next session record.
    @ObservationIgnored private var outgoing: [String: Data] = [:]
    /// Zone name to the last shared payload with `seq` zeroed, to drop a send that would change nothing.
    @ObservationIgnored private var lastShared: [String: DeviceSessionPayload] = [:]

    /// One uninterrupted opt-in on one engine. A previous read may still return after the person opts in again.
    private final class Enrollment {
        var task: Task<Void, Never>?
        var complete = false
        var changedDuringRead: Set<SyncRecordID> = []
        var unverifiedZoneRemovals: Set<String> = []
    }

    @ObservationIgnored private var enrollment: Enrollment?
    @ObservationIgnored private var fetching: Enrollment?
    @ObservationIgnored private var signedOut = false

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
        // A fresh installation may fetch other devices before its first upload. Only pre-existing records lack a verified owner.
        restoredUnidentifiedRecords = state.accountUser == nil && (
            !state.ownSystemFields.isEmpty || state.publishedDevice != nil || !state.devices.isEmpty || !state.sessions.isEmpty
        )
    }

    // MARK: - Engine and sharing

    /// Hands the engine everything this device wants on the server: zones, deletions and the latest session records.
    public func attach(_ engine: any SyncEngine) {
        let changed = self.engine !== engine
        self.engine = engine
        if changed {
            renewEnrollment()
        }
        replay()
        guard let enrollment else { return }
        Task { [weak self] in
            guard let self, self.enrollment === enrollment else { return }
            let available = await engine.accountIsAvailable()
            guard self.enrollment === enrollment, accountAvailable == nil else { return }
            accountAvailable = available
        }
    }

    /// The only place that decides what this device keeps on the server. Without an engine it only records `profiles`.
    public func reconcile(sharing profiles: Set<UUID>) {
        let changed = desired != profiles
        desired = profiles
        let inactive = state.sessions.keys.filter { !wants(zone: $0) }
        if !inactive.isEmpty || (profiles.isEmpty && !state.devices.isEmpty) {
            for zone in inactive {
                state.sessions[zone] = nil
            }
            if profiles.isEmpty {
                state.devices.removeAll()
            }
            persist(state)
        }
        if changed {
            renewEnrollment()
        }
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
        guard let engine, let enrollment, let identity = engine as? any SyncAccountIdentity else { return }
        startBaseline()
        await enrollment.task?.value
        guard fetching == nil, await verifiedUser(for: enrollment, using: identity) != nil, fetching == nil else { return }
        fetching = enrollment
        try? await engine.fetchNow()
        fetching = nil
        if self.enrollment !== enrollment {
            startBaseline()
        }
    }

    private func renewEnrollment() {
        enrollment?.task?.cancel()
        enrollment = !desired.isEmpty && !signedOut ? Enrollment() : nil
        startBaseline()
    }

    private func startBaseline() {
        guard let enrollment, !enrollment.complete, enrollment.task == nil,
              let engine, let identity = engine as? any SyncAccountIdentity else { return }
        let zones = [SyncZone.devices] + desired.map(SyncZone.profile).sorted()
        enrollment.task = Task { [weak self] in
            defer {
                enrollment.task = nil
                enrollment.changedDuringRead.removeAll()
            }
            await self?.readBaseline(zones, for: enrollment, engine: engine, identity: identity)
        }
    }

    private func verifiedUser(for expected: Enrollment, using identity: any SyncAccountIdentity) async -> String? {
        guard enrollment === expected, let user = try? await identity.currentAccountUser(), !user.isEmpty,
              enrollment === expected, acceptsUploadAccount(user) else { return nil }
        accountAvailable = true
        return user
    }

    private func acceptsIncoming(_ expected: Enrollment, removedZones: [String] = []) async -> Bool {
        let currentFetch = fetching == nil || fetching === expected
        if currentFetch, let identity = engine as? any SyncAccountIdentity,
           await verifiedUser(for: expected, using: identity) != nil {
            return true
        }
        if enrollment === expected {
            // The shared cursor can advance past a rejected event. Recover it from the current account on refresh.
            expected.task?.cancel()
            let retry = Enrollment()
            retry.unverifiedZoneRemovals = expected.unverifiedZoneRemovals
            if currentFetch, state.accountUser != nil {
                retry.unverifiedZoneRemovals.formUnion(removedZones)
            }
            enrollment = retry
        }
        return false
    }

    /// The engine's cursor covers other categories too. Start each enrollment from the remote mirrors still on the server.
    private func readBaseline(_ zones: [String], for expected: Enrollment, engine: any SyncEngine, identity: any SyncAccountIdentity) async {
        guard let user = await verifiedUser(for: expected, using: identity) else { return }
        var snapshots: [String: SyncZoneRead] = [:]
        var confirmedRemovals: [String] = []
        for zone in zones {
            do {
                snapshots[zone] = try await engine.fetchAll(zone: zone)
            } catch where (error as? CKError)?.code == .zoneNotFound || (error as? URLError)?.code == .fileDoesNotExist {
                snapshots[zone] = SyncZoneRead(records: [])
                if expected.unverifiedZoneRemovals.contains(zone) {
                    confirmedRemovals.append(zone)
                }
            } catch {
                return
            }
            guard await verifiedUser(for: expected, using: identity) == user else { return }
        }

        if !confirmedRemovals.isEmpty {
            applyZonesDeleted(confirmedRemovals)
            persist(state)
            return
        }
        expected.unverifiedZoneRemovals.removeAll()
        for (zone, snapshot) in snapshots {
            let peers = snapshot.records.filter { $0.id.zone == zone && $0.id.name != installID }
            var absent: Set<SyncRecordID> = []
            if snapshot.skipped == 0 {
                let known = zone == SyncZone.devices ? Set(state.devices.keys) : Set((state.sessions[zone] ?? [:]).keys)
                let missing = known.subtracting(peers.map(\.id.name))
                absent = Set(missing.map { SyncRecordID(zone: zone, name: $0) })
            }
            // An incremental write or deletion that arrived during the read takes precedence, including a same-date edit.
            applyFetched(modified: peers.filter { !expected.changedDuringRead.contains($0.id) },
                         deleted: Array(absent.subtracting(expected.changedDuringRead)))
        }
        expected.complete = snapshots.values.allSatisfy { $0.skipped == 0 }
        persist(state)
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

    public func acceptsUploadAccount(_ user: String) -> Bool {
        guard matchesAccount(user) else {
            applyAccount(.switchAccounts(user: user))
            persist(state)
            return false
        }
        if state.accountUser == nil, needsEngine {
            state.accountUser = user
            persist(state)
        }
        return true
    }

    public func wantsRecordDeletion(_ id: SyncRecordID) -> Bool {
        id.name == installID && state.ownSystemFields[id.zone] != nil && !wants(zone: id.zone)
    }

    public func record(for id: SyncRecordID) -> SyncRecord? {
        guard id.name == installID, wants(zone: id.zone) else { return nil }
        if id.zone == SyncZone.devices {
            guard let data = try? SessionCodec.encode(device) else { return nil }
            return SyncRecord(id: id, type: .device, schema: 1, payload: data, systemFields: state.ownSystemFields[id.zone])
        }
        guard SyncZone.profileID(id.zone) != nil, let data = outgoing[id.zone] else { return nil }
        return SyncRecord(id: id, type: .deviceSession, schema: 1, payload: data, systemFields: state.ownSystemFields[id.zone])
    }

    public func handle(_ event: SyncEvent) async {
        switch event {
        case .state:
            // The router owns the engine's state; a bare device in a test sees the event and has nothing to keep.
            return
        case .fetched(let modified, let deleted):
            guard let enrollment else { return }
            let records = modified.filter { wants(zone: $0.id.zone) }
            let removals = deleted.filter { wants(zone: $0.zone) }
            guard !records.isEmpty || !removals.isEmpty, await acceptsIncoming(enrollment) else { return }
            if enrollment.task != nil {
                enrollment.changedDuringRead.formUnion(records.map(\.id))
                enrollment.changedDuringRead.formUnion(removals)
            }
            applyFetched(modified: records, deleted: removals)
        case .sent(let saved, let deleted, let failed):
            applySent(saved: saved, deleted: deleted, failed: failed)
        case .zoneDeletesFailed, .zoneSavesOverQuota:
            return
        case .zonesDeleted(let zones):
            let relevant = zones.keys.filter { wants(zone: $0) || state.ownSystemFields[$0] != nil }.sorted()
            guard !relevant.isEmpty else { return }
            if let enrollment {
                guard await acceptsIncoming(enrollment, removedZones: relevant) else { return }
            } else {
                // A former opt-in may still own records to remove. Verify the account before retiring those tags.
                guard !signedOut, fetching == nil, let engine, let user = state.accountUser,
                      let identity = engine as? any SyncAccountIdentity, (try? await identity.currentAccountUser()) == user,
                      self.engine === engine, self.enrollment == nil, !signedOut, state.accountUser == user else { return }
            }
            applyZonesDeleted(relevant)
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
            default:
                // A record of another feature does not belong in a tab zone.
                continue
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
        case .quotaExceeded, .other:
            SyncLog.logger.error("sync: a record save failed; the next heartbeat tries again")
        }
    }

    /// A zone removed on the server ends sharing of its profile, whatever the reason. Nothing re-creates it here: it comes back
    /// only after the person turns sharing on again.
    private func applyZonesDeleted(_ zones: [String]) {
        let before = desired
        var ended: [UUID?] = []
        for zone in zones {
            state.sessions[zone] = nil
            state.ownSystemFields[zone] = nil
            outgoing[zone] = nil
            lastShared[zone] = nil
            ensuredZones.remove(zone)
            if zone == SyncZone.devices {
                state.devices = [:]
                state.sessions = [:]
                state.publishedDevice = nil
                outgoing = [:]
                lastShared = [:]
                desired = []
                ended.append(nil)
            } else if let id = SyncZone.profileID(zone) {
                desired.remove(id)
                ended.append(id)
            }
        }
        if desired != before {
            renewEnrollment()
        }
        for profile in ended {
            onSharingEnded?(profile)
        }
    }

    private func applyAccount(_ change: SyncAccountChange) {
        switch change {
        case .signOut:
            signedOut = true
            clearAccountData()
            accountAvailable = false
            if state.accountUser == nil, !desired.isEmpty {
                endSharing()
            }
        case .signIn(let user) where matchesAccount(user):
            signedOut = false
            if enrollment == nil {
                renewEnrollment()
            }
            state.accountUser = user
            accountAvailable = true
            replay()
        case .signIn(let user), .switchAccounts(let user):
            // Another Apple Account: nothing of the old one is shown, and nothing is uploaded until the person opts in again.
            signedOut = false
            clearAccountData()
            state.accountUser = user
            accountAvailable = true
            endSharing()
        }
    }

    private func matchesAccount(_ user: String) -> Bool {
        state.accountUser.map { $0 == user } ?? !restoredUnidentifiedRecords
    }

    private func endSharing() {
        outgoing = [:]
        desired = []
        onSharingEnded?(nil)
    }

    /// Everything the account's database gave this device, and the marks that say it was written there.
    private func clearAccountData() {
        enrollment?.task?.cancel()
        enrollment = nil
        restoredUnidentifiedRecords = false
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
