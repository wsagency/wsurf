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
public final class TabSync {
    public let installID: String
    public let device: DeviceInfo
    public private(set) var state: TabSyncState
    /// Nil until the engine has answered.
    public private(set) var accountAvailable: Bool?
    /// The profile whose sharing ended on the server or by an account change, or nil for every profile. Not called for the
    /// person's own choice. The owner turns its opt-in off.
    @ObservationIgnored public var onSharingEnded: ((UUID?) -> Void)?

    @ObservationIgnored private let persist: (TabSyncState) -> Void
    @ObservationIgnored private var persistRemoval: ((TabRemovalCheckpoint) -> Void)?
    @ObservationIgnored private var migratedLegacyEvidence = false
    @ObservationIgnored private var hasReconciled = false
    @ObservationIgnored private var engine: (any SyncEngine)?
    @ObservationIgnored private var restoredUnidentifiedRecords: Bool
    @ObservationIgnored private var desired: Set<UUID> = []
    /// Zone name to the fitted, compressed payload of this device's next session record.
    @ObservationIgnored private var outgoing: [String: Data] = [:]
    /// Zone name to the last shared payload with `seq` zeroed, to drop a send that would change nothing.
    @ObservationIgnored private var lastShared: [String: DeviceSessionPayload] = [:]

    /// One uninterrupted opt-in on one engine. A previous read may still return after the person opts in again.
    struct FetchStart: Equatable {
        let enrollment = UUID()
        var generation = 0
    }

    private final class Enrollment {
        var start = FetchStart()
        var task: Task<Void, Never>?
        var firstAccountLookups = 0
        var complete = false
        var readAgain = false
        var changedDuringRead: Set<SyncRecordID> = []
    }

    func markFetchStart() -> FetchStart? {
        enrollment?.start.generation += 1
        return enrollment?.start
    }

    @ObservationIgnored private var enrollment: Enrollment?
    @ObservationIgnored private var handouts: [String: TabSaveHandouts] = [:]
    @ObservationIgnored private var deferredUploads: Set<String> = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var signedOut = false
    @ObservationIgnored private var accountGeneration = 0
    @ObservationIgnored var accountEventID: UUID?

    /// Whether this device owns anything on the server or wants to: the owner creates the engine only then.
    public var needsEngine: Bool {
        !desired.isEmpty || !ownedZones.isEmpty || (accountAvailable == nil && hasParkedWithdrawals)
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
        migratedLegacyEvidence = self.state.migrateObservedZones()
        self.state.migratePublishedRecords(installID: installID)
    }

    /// Install the durable stop before attach can replay a queued zone creation, including when the tab cache is unreadable.
    func bindRemovalCheckpoint(_ saved: TabRemovalCheckpoint?, persistRemoval: @escaping (TabRemovalCheckpoint) -> Void) {
        self.persistRemoval = persistRemoval
        let local = state.removalCheckpoint
        if let saved, saved != local, saved.revision >= (local?.revision ?? 0) {
            let owner = saved.pending?.account ?? saved.observations?.account
            if owner != state.accountUser, saved.pending != nil || saved.observations != nil {
                clearAccountData()
                state.accountUser = owner
            }
            // Pre-observation routers only describe the named zones in their pending check.
            let migrated = migratedLegacyEvidence ? state.zoneObservations?.restoringLegacyEvidence(for: saved.pending) : nil
            state.zoneObservations = saved.observations ?? migrated
            state.removalRevision = saved.revision
            state.removalCheck = saved.pending
            state.migratePublishedRecords(installID: installID)
            persist(state)
            if hasReconciled {
                retainCheckpoint(for: desired)
            }
        }
        migratedLegacyEvidence = false
        if let latest = state.removalCheckpoint {
            persistRemoval(latest)
        }
    }

    private func setRemovalCheck(_ check: TabSyncState.RemovalCheck?) {
        setCheckpoint(check, observations: state.zoneObservations)
    }

    private func setCheckpoint(_ check: TabSyncState.RemovalCheck?, observations: TabSyncState.ZoneObservations?) {
        guard state.removalCheck != check || state.zoneObservations != observations else { return }
        let next = TabRemovalCheckpoint(revision: (state.removalRevision ?? 0) + 1, pending: check, observations: observations)
        state.zoneObservations = observations
        state.removalRevision = next.revision
        state.removalCheck = check
        persistRemoval?(next)
        persist(state)
    }

    private func observe(_ presence: TabSyncState.ZoneObservations.Presence, in zone: String) {
        guard let account = state.accountUser, wants(zone: zone) else { return }
        var observations = state.zoneObservations ?? .init(account: account)
        guard observations.account == account, observations.zones[zone] != presence else { return }
        observations.zones[zone] = presence
        setCheckpoint(state.removalCheck, observations: observations)
    }

    private func requiresExistence(_ zone: String) -> Bool {
        state.zoneObservations?.zones[zone].map { $0 != .absent } ?? false
    }

    private var ownedZones: Set<String> {
        guard let scope = state.zoneObservations, scope.account == state.accountUser,
              let publication = scope.publication, publication.installID == installID else { return [] }
        return publication.zones
    }

    private var hasParkedWithdrawals: Bool {
        state.zoneObservations?.withdrawals?.values.contains { $0.installID == installID && !$0.zones.isEmpty } == true
    }

    private func rememberOwnRow(in zone: String) {
        let owned = ownedZones
        if !owned.contains(zone) {
            setOwnedZones(owned.union([zone]))
        }
    }

    private func setOwnedZones(_ zones: Set<String>) {
        guard let owner = state.accountUser else { return }
        var scope = state.zoneObservations ?? .init(account: owner)
        guard scope.account == owner else { return }
        scope.publication = .init(installID: installID, zones: zones)
        setCheckpoint(state.removalCheck, observations: scope)
    }

    // MARK: - Engine and sharing

    /// Hands the engine everything this device wants on the server: zones, deletions and the latest session records.
    public func attach(_ engine: any SyncEngine) {
        if self.engine !== engine {
            if self.engine != nil {
                discardAccountSwitchEvidence()
            }
            self.engine = engine
            invalidateHandouts()
            // An interrupted partial read still has to verify its zone before a restored creation can go out.
            let unfinished = state.zoneObservations?.zones.compactMap { $0.value == .incomplete ? $0.key : nil } ?? []
            holdRemovals(unfinished)
            renewEnrollment()
        }
        replay()
        guard let enrollment else {
            if hasParkedWithdrawals {
                Task { [weak self] in await self?.refresh() }
            }
            return
        }
        Task { [weak self] in
            guard let self, self.enrollment === enrollment else { return }
            let available = await engine.accountIsAvailable()
            guard self.enrollment === enrollment, accountAvailable == nil else { return }
            accountAvailable = available
        }
    }

    /// The only place that decides what this device keeps on the server. Without an engine it only records `profiles`.
    public func reconcile(sharing profiles: Set<UUID>) {
        hasReconciled = true
        let changed = desired != profiles
        for profile in profiles.subtracting(desired) {
            handouts[SyncZone.profile(profile)]?.retire()
        }
        if desired.isEmpty, !profiles.isEmpty {
            handouts[SyncZone.devices]?.retire()
        }
        desired = profiles
        deferredUploads = deferredUploads.filter(wants)
        retainCheckpoint(for: profiles)
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
        let owned = ownedZones
        for zone in owned.union(outgoing.keys).sorted() {
            guard let id = SyncZone.profileID(zone), !profiles.contains(id) else { continue }
            outgoing[zone] = nil
            lastShared[zone] = nil
            if owned.contains(zone) {
                changes.append(.deleteRecord(own(zone)))
            }
        }
        if profiles.isEmpty {
            if owned.contains(SyncZone.devices) {
                changes.append(.deleteRecord(own(SyncZone.devices)))
            }
        } else {
            changes.append(.saveZone(SyncZone.devices))
            if state.publishedDevice != device || state.ownSystemFields[SyncZone.devices] == nil {
                changes.append(.saveRecord(own(SyncZone.devices)))
            }
        }
        for profile in profiles.sorted(by: { $0.uuidString < $1.uuidString }) {
            changes.append(.saveZone(SyncZone.profile(profile)))
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
        guard let engine, let identity = engine as? any SyncAccountIdentity else { return }
        guard let enrollment else {
            // The approved account may have returned before its sign-in notification.
            let generation = accountGeneration
            if !signedOut, hasParkedWithdrawals, let user = try? await identity.currentAccountUser(), !user.isEmpty,
               self.engine === engine, self.enrollment == nil, accountGeneration == generation, hasParkedWithdrawals {
                _ = acceptsUploadAccount(user)
                accountAvailable = true
            }
            return
        }
        startBaseline()
        await enrollment.task?.value
        guard !refreshing, await verifiedUser(for: enrollment, using: identity) != nil, !refreshing else { return }
        for zone in deferredUploads {
            add([.saveZone(zone), .saveRecord(own(zone))])
        }
        refreshing = true
        defer { refreshing = false }
        try? await engine.fetchNow()
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
        enrollment.start.generation += 1
        enrollment.task = Task { [weak self] in
            defer {
                enrollment.task = nil
                enrollment.changedDuringRead.removeAll()
                if enrollment.readAgain, self?.enrollment === enrollment {
                    enrollment.readAgain = false
                    enrollment.complete = false
                    self?.startBaseline()
                }
            }
            await self?.readBaseline(zones, for: enrollment, engine: engine, identity: identity)
        }
    }

    private func verifiedUser(for expected: Enrollment, using identity: any SyncAccountIdentity, identifyingRemoval: Bool = false) async -> String? {
        guard enrollment === expected else { return nil }
        // A lookup already authorized by this opt-in may identify a deletion delivered while it was suspended.
        let first = state.accountUser == nil && (identifyingRemoval || canBindFirstAccount)
        if first {
            expected.firstAccountLookups += 1
        }
        defer {
            if first {
                expected.firstAccountLookups -= 1
            }
        }
        guard let user = try? await identity.currentAccountUser(), !user.isEmpty, enrollment === expected else { return nil }
        if first, state.accountUser == nil, state.removalCheck != nil {
            rememberAccount(user, beforeFirstRead: true)
        } else if !acceptsUploadAccount(user) {
            return nil
        }
        accountAvailable = true
        return user
    }

    private func acceptsIncoming(_ event: SyncEvent, from start: FetchStart?, for expected: Enrollment) async -> Bool {
        guard let identity = engine as? any SyncAccountIdentity else { return false }
        let user = await verifiedUser(for: expected, using: identity)
        guard start == enrollment?.start else {
            recoverMissedFetch(event)
            return false
        }
        guard user != nil else {
            // The shared cursor can advance past a rejected event. Recover it on the next verified read.
            expected.complete = false
            expected.task?.cancel()
            return false
        }
        return true
    }

    public func beginFetch() -> SyncFetchDelivery {
        { [weak self, start = markFetchStart()] event in await self?.receive(event, from: start) }
    }

    private func recoverMissedFetch(_ event: SyncEvent) {
        guard let enrollment else { return }
        // A coalesced fetch can also contain changes made after re-enrollment. Read their current server values.
        guard case .fetched(let records, let deleted) = event,
              records.contains(where: { wants(zone: $0.id.zone) }) || deleted.contains(where: { wants(zone: $0.zone) }) else { return }
        enrollment.complete = false
        if enrollment.task == nil {
            startBaseline()
        } else {
            enrollment.readAgain = true
        }
    }

    private func receiveRemovedZones(_ zones: [String], from start: FetchStart?) async {
        let selected = zones.filter { wants(zone: $0) }
        guard let active = enrollment, !selected.isEmpty else { return }
        if state.accountUser == nil, start?.enrollment == active.start.enrollment {
            let canIdentify = canBindFirstAccount
            recordRemovalCheck(selected)
            guard canIdentify, let identity = engine as? any SyncAccountIdentity,
                  await verifiedUser(for: active, using: identity, identifyingRemoval: true) != nil else { return }
        }
        let current = start == active.start
        let check = recheckRemovedZones(selected)
        if current {
            await check?.value
        }
    }

    /// A database deletion can predate a zone this enrollment has since created. Verify its current existence.
    private func recheckRemovedZones(_ zones: [String]) -> Task<Void, Never>? {
        let selected = zones.filter { wants(zone: $0) }
        guard let prior = enrollment, !selected.isEmpty else { return nil }
        let established = Set(selected.filter(requiresExistence))
        if prior.task != nil, selected.contains(where: { state.zoneObservations?.zones[$0] == nil }) {
            // The first read may already have seen this zone. Hold sends, let its answer arrive, then verify current existence.
            recordRemovalCheck(selected, established: established)
            prior.start.generation += 1
            prior.readAgain = true
            return nil
        }
        holdRemovals(selected, established: established)
        // A callback can run inside the interrupted read. Give the new read its own task before awaiting it.
        let next = Enrollment()
        next.start = prior.start
        enrollment = next
        startBaseline()
        return next.task
    }

    private func holdRemovals(_ zones: [String], established: Set<String>? = nil) {
        let selected = zones.filter { wants(zone: $0) }
        guard !selected.isEmpty else { return }
        recordRemovalCheck(selected, established: established)
        enrollment?.complete = false
        enrollment?.task?.cancel()
    }

    private func recordRemovalCheck(_ selected: [String], established: Set<String>? = nil) {
        var check = state.removalCheck ?? .init(account: state.accountUser, profiles: [], zones: [])
        let required = check.zonesRequiringExistence.union(established ?? Set(selected))
        check.profiles.formUnion(desired)
        check.zones.formUnion(selected)
        check.establishedZones = required == check.zones ? nil : required
        setRemovalCheck(check)
    }

    private func retainCheckpoint(for profiles: Set<UUID>) {
        var observations = state.zoneObservations
        let activeZones = observations?.zones.filter { wants(zone: $0.key) } ?? [:]
        observations?.zones = activeZones
        if observations?.account != state.accountUser {
            observations = nil
        }
        var retained = state.removalCheck
        if var check = retained {
            check.profiles.formIntersection(profiles)
            check.zones = check.zones.filter { zone in
                zone == SyncZone.devices ? !check.profiles.isEmpty : SyncZone.profileID(zone).map(check.profiles.contains) == true
            }
            check.establishedZones?.formIntersection(check.zones)
            retained = check.account == state.accountUser && !check.zones.isEmpty ? check : nil
        }
        setCheckpoint(retained, observations: observations)
    }

    /// The engine's cursor covers other categories too. Start each enrollment from the remote mirrors still on the server.
    private func readBaseline(_ zones: [String], for expected: Enrollment, engine: any SyncEngine, identity: any SyncAccountIdentity) async {
        guard let user = await verifiedUser(for: expected, using: identity), !Task.isCancelled else { return }
        let established = state.removalCheck?.zonesRequiringExistence ?? []
        var snapshots: [String: SyncZoneRead] = [:]
        var confirmedRemovals: [String] = []
        for zone in zones {
            do {
                snapshots[zone] = try await engine.fetchAll(zone: zone)
            } catch where Self.zoneIsMissing(error) {
                guard enrollment === expected, !Task.isCancelled else { return }
                if established.contains(zone) || requiresExistence(zone) {
                    // Hold pending sends before the account recheck can suspend or fail.
                    recordRemovalCheck([zone])
                    confirmedRemovals.append(zone)
                }
            } catch {
                return
            }
            guard await verifiedUser(for: expected, using: identity) == user, !Task.isCancelled else { return }
            if let snapshot = snapshots[zone] {
                observe(snapshot.skipped == 0 ? .present : .incomplete, in: zone)
            } else {
                if expected.changedDuringRead.contains(where: { $0.zone == zone }) {
                    expected.readAgain = true
                    return
                }
                if !confirmedRemovals.contains(zone) {
                    observe(.absent, in: zone)
                }
                snapshots[zone] = SyncZoneRead(records: [])
            }
        }

        if expected.readAgain, state.removalCheck != nil {
            return
        }
        let wasHeld = state.removalCheck != nil
        if wasHeld {
            applyZonesDeleted(confirmedRemovals)
            setRemovalCheck(nil)
            guard enrollment === expected else {
                replay()
                return
            }
        }
        var alreadyPublished: Set<String> = []
        for (zone, snapshot) in snapshots {
            let id = own(zone)
            if !expected.changedDuringRead.contains(id) {
                if let row = snapshot.records.first(where: { $0.id == id }) {
                    adoptOwnRecord(row)
                    if row.type == .deviceSession, row.payload == outgoing[zone] {
                        alreadyPublished.insert(zone)
                    }
                } else if snapshot.skipped == 0 {
                    applyFetched(modified: [], deleted: [id])
                }
            }
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
        if wasHeld {
            replay(excluding: alreadyPublished)
        }
        persist(state)
    }

    private static func zoneIsMissing(_ error: Error) -> Bool {
        let code = (error as? CKError)?.code
        return code == .zoneNotFound || code == .userDeletedZone || (error as? URLError)?.code == .fileDoesNotExist
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
}

extension TabSync: SyncEngineDelegate {
    public func discardAccountSwitchEvidence() {
        setCheckpoint(state.removalCheck, observations: state.zoneObservations?.withoutVerifiedSwitch)
    }

    public func acceptsUploadAccount(_ user: String) -> Bool {
        if state.accountUser == nil, !canBindFirstAccount, (enrollment?.firstAccountLookups ?? 0) > 0 {
            return false
        }
        guard matchesAccount(user) else {
            let receipt = state.accountUser.flatMap { signedOut ? nil : switchReceipt(from: $0, after: accountEventID) }
            applyAccount(.switchAccounts(user: user), receipt: receipt)
            return false
        }
        if state.accountUser == nil, needsEngine {
            rememberAccount(user)
            persist(state)
        }
        return true
    }

    public func allowsZoneCreation(_ zone: String) -> Bool {
        allowsRecordSave(in: zone) && !requiresExistence(zone)
    }

    private func allowsRecordSave(in zone: String) -> Bool {
        !signedOut && !restoredUnidentifiedRecords && wants(zone: zone) && state.removalCheck == nil
    }

    public func wantsRecordDeletion(_ id: SyncRecordID) -> Bool {
        !signedOut && id.name == installID && ownedZones.contains(id.zone) && !wants(zone: id.zone)
    }

    public func record(for id: SyncRecordID) -> SyncRecord? {
        guard id.name == installID, allowsRecordSave(in: id.zone) else { return nil }
        if id.zone == SyncZone.devices {
            guard let data = try? SessionCodec.encode(device) else { return nil }
            return SyncRecord(id: id, type: .device, schema: 1, payload: data, systemFields: state.ownSystemFields[id.zone])
        }
        guard SyncZone.profileID(id.zone) != nil, let data = outgoing[id.zone] else { return nil }
        return SyncRecord(id: id, type: .deviceSession, schema: 1, payload: data, systemFields: state.ownSystemFields[id.zone])
    }

    public func recordForUpload(_ id: SyncRecordID) async -> SyncRecord? {
        guard let expected = enrollment, state.accountUser != nil, allowsRecordSave(in: id.zone), id.name == installID else { return nil }
        if !requiresExistence(id.zone) {
            // Prove the first creation before handing out content. Even a delayed save receipt can then outlive a real removal.
            guard await verifyZoneForFirstUpload(id, for: expected) else { return nil }
        }
        guard enrollment === expected, let record = record(for: id) else { return nil }
        deferredUploads.remove(id.zone)
        rememberOwnRow(in: id.zone)
        handouts[id.zone, default: TabSaveHandouts()].issue(record.payload)
        return record
    }

    private func verifyZoneForFirstUpload(_ id: SyncRecordID, for expected: Enrollment) async -> Bool {
        guard let engine, let identity = engine as? any SyncAccountIdentity else { return false }
        let firstTry = deferredUploads.insert(id.zone).inserted
        let owner = state.accountUser
        let read: SyncZoneRead?
        do {
            read = try await engine.fetchAll(zone: id.zone)
        } catch where Self.zoneIsMissing(error) {
            read = nil
        } catch {
            return false
        }
        guard let verified = await verifiedUser(for: expected, using: identity), verified == owner,
              enrollment === expected, allowsRecordSave(in: id.zone) else { return false }
        guard let read else {
            if firstTry, allowsZoneCreation(id.zone) {
                add([.saveZone(id.zone), .saveRecord(id)])
            }
            return false
        }
        if expected.task != nil {
            expected.changedDuringRead.insert(id)
        }
        observe(read.skipped == 0 ? .present : .incomplete, in: id.zone)
        return true
    }

    private func finishHandout(_ record: SyncRecord) -> TabSaveHandouts.Receipt? {
        let zone = record.id.zone
        guard record.id.name == installID else { return nil }
        let receipt = handouts[zone]?.finish(record.payload, sharing: wants(zone: zone))
        if handouts[zone]?.isEmpty == true {
            handouts[zone] = nil
        }
        return signedOut ? nil : receipt
    }

    private func invalidateHandouts() {
        for zone in handouts.keys {
            handouts[zone]?.retire()
        }
    }

    public func handle(_ event: SyncEvent) async {
        switch event {
        case .fetched, .zonesDeleted:
            await receive(event, from: enrollment?.start)
            return
        case .sent(let saved, let deleted, let failed):
            await applySent(saved: saved, deleted: deleted, failed: failed)
        case .account(let change):
            discardAccountSwitchEvidence()
            applyAccount(change)
            return
        case .state, .zoneDeletesFailed, .zoneSavesOverQuota:
            return
        }
        persist(state)
    }

    func receive(_ event: SyncEvent, from start: FetchStart?) async {
        if case .zonesDeleted(let zones) = event {
            await receiveRemovedZones(Array(zones.keys), from: start)
            return
        }
        guard start == enrollment?.start else {
            recoverMissedFetch(event)
            return
        }
        switch event {
        case .fetched(let modified, let deleted):
            guard let enrollment else { return }
            let records = modified.filter { wants(zone: $0.id.zone) }
            let removals = deleted.filter { wants(zone: $0.zone) }
            guard !records.isEmpty || !removals.isEmpty, await acceptsIncoming(event, from: start, for: enrollment) else { return }
            for zone in Set(records.map(\.id.zone)) where !requiresExistence(zone) {
                observe(.present, in: zone)
            }
            if enrollment.task != nil {
                enrollment.changedDuringRead.formUnion(records.map(\.id))
                enrollment.changedDuringRead.formUnion(removals)
            }
            applyFetched(modified: records, deleted: removals)
        default:
            return
        }
        persist(state)
    }

    // MARK: - Events

    private func applyFetched(modified: [SyncRecord], deleted: [SyncRecordID]) {
        for record in modified {
            if record.id.name == installID {
                // This device's own record: keep its change tag, never list it.
                adoptOwnRecord(record)
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

    private func adoptOwnRecord(_ record: SyncRecord) {
        let zone = record.id.zone
        guard record.type == (zone == SyncZone.devices ? .device : .deviceSession) else { return }
        rememberOwnRow(in: zone)
        state.ownSystemFields[zone] = record.systemFields ?? state.ownSystemFields[zone]
        if zone == SyncZone.devices, let info = try? SessionCodec.decodeDevice(record.payload) {
            state.publishedDevice = info
        }
    }

    private func applySent(saved: [SyncRecord], deleted: [SyncRecordID], failed: [SyncFailedSave]) async {
        var recheck: Set<String> = []
        for record in saved {
            guard let issued = finishHandout(record) else { continue }
            let zone = record.id.zone
            if issued == .ambiguous, wants(zone: zone) {
                recheck.insert(zone)
                continue
            }
            if enrollment?.task != nil {
                enrollment?.changedDuringRead.insert(record.id)
            }
            adoptOwnRecord(record)
            // Sharing was turned off while this save was on its way: remove what it created.
            if !wants(zone: zone) {
                add([.deleteRecord(record.id)])
            }
        }
        let removed = deleted.filter(wantsRecordDeletion)
        if !removed.isEmpty {
            let remaining = ownedZones.subtracting(removed.map(\.zone))
            applyFetched(modified: [], deleted: removed)
            setOwnedZones(remaining)
        }
        for failure in failed {
            let zone = failure.id.zone
            guard let attempted = failure.attempted, attempted.id == failure.id,
                  let issued = finishHandout(attempted), wants(zone: zone) else { continue }
            if issued == .ambiguous {
                recheck.insert(zone)
            } else {
                retry(failure, recheck: &recheck)
            }
        }
        await recheckRemovedZones(Array(recheck))?.value
    }

    private func retry(_ failure: SyncFailedSave, recheck: inout Set<String>) {
        let id = failure.id
        switch failure.failure {
        case .serverRecordChanged(let server):
            // Save again on the server's change tag, with this device's payload.
            state.ownSystemFields[id.zone] = server.systemFields ?? state.ownSystemFields[id.zone]
            add([.saveRecord(id)])
        case .zoneNotFound:
            recheck.insert(id.zone)
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
        let remaining = ownedZones.subtracting(zones)
        var ended: [UUID?] = []
        for zone in zones {
            state.sessions[zone] = nil
            state.ownSystemFields[zone] = nil
            outgoing[zone] = nil
            lastShared[zone] = nil
            handouts[zone]?.retire()
            if zone == SyncZone.devices {
                invalidateHandouts()
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
        if !zones.isEmpty {
            setOwnedZones(remaining)
        }
        if desired != before {
            renewEnrollment()
        }
        for profile in ended {
            onSharingEnded?(profile)
        }
        retainCheckpoint(for: desired)
    }

    func applyAccount(_ change: SyncAccountChange, receipt: TabSyncState.VerifiedSwitch? = nil) {
        defer { persist(state) }
        accountGeneration += 1
        signedOut = change == .signOut
        accountAvailable = !signedOut
        switch change {
        case .signOut:
            clearAccountData()
            if state.accountUser == nil, !desired.isEmpty {
                endSharing()
            }
        case .signIn(let user) where matchesAccount(user):
            if enrollment == nil {
                renewEnrollment()
            }
            rememberAccount(user)
            replay()
        case .signIn(let user), .switchAccounts(let user):
            // Another Apple Account: nothing of the old one is shown, and nothing is uploaded until the person opts in again.
            let prior = state.zoneObservations ?? receipt.map { .init(account: $0.previousUser) }
            let withdrawals = prior?.switching(to: user, verifiedSwitch: receipt, withdrawing: ownedZones.filter { !wants(zone: $0) }, installID: installID)
            clearAccountData()
            endSharing(account: user, observations: withdrawals)
            if !ownedZones.isEmpty {
                replay()
            }
        }
    }

    private func matchesAccount(_ user: String) -> Bool {
        state.accountUser.map { $0 == user } ?? canBindFirstAccount
    }

    private var canBindFirstAccount: Bool {
        !restoredUnidentifiedRecords && (state.removalCheck?.zonesRequiringExistence.isEmpty ?? true)
    }

    private func rememberAccount(_ user: String, beforeFirstRead: Bool = false) {
        state.accountUser = user
        if var check = state.removalCheck, check.account == nil {
            check.account = user
            if beforeFirstRead {
                // No zone read or record handout was authorized before this first verified account.
                check.establishedZones = []
            }
            setRemovalCheck(check)
        }
    }

    private func endSharing(account: String? = nil, observations: TabSyncState.ZoneObservations? = nil) {
        outgoing = [:]
        desired = []
        onSharingEnded?(nil)
        state.accountUser = account
        setCheckpoint(nil, observations: observations)
    }

    /// Everything the account's database gave this device, and the marks that say it was written there.
    private func clearAccountData() {
        invalidateHandouts()
        deferredUploads.removeAll()
        enrollment?.task?.cancel()
        enrollment = nil
        restoredUnidentifiedRecords = false
        state.devices = [:]
        state.sessions = [:]
        state.ownSystemFields = [:]
        state.publishedDevice = nil
        lastShared = [:]
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
        let approved = changes.filter { change in
            switch change {
            case .saveZone(let zone):
                allowsZoneCreation(zone)
            case .saveRecord(let id):
                allowsRecordSave(in: id.zone)
            case .deleteZone, .deleteRecord:
                true
            }
        }
        if !approved.isEmpty {
            engine?.add(approved)
        }
    }

    /// Requeue local content missed during a hold. Only a first enrollment can also ask for its zone.
    private func replay(excluding published: Set<String> = []) {
        reconcile(sharing: desired)
        let changed = Set(outgoing.keys).subtracting(published)
        add(changed.sorted().map { .saveRecord(own($0)) })
    }
}
