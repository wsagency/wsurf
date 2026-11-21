// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Observation

nonisolated public struct SharedCatalogState: Codable, Equatable, Sendable {
    public struct Remote: Codable, Equatable, Sendable {
        public var item: SharedSpaceItem
        public var fields: Data?
    }

    public struct Edit: Codable, Equatable, Sendable {
        public var profile: UUID
        public var base: SharedSpaceItem?
        public var item: SharedSpaceItem
        /// An earlier version was handed to the engine before this edit. Its receipt advances the base after a restart, too.
        var submitted: SharedSpaceItem?
    }

    struct Paused: Codable, Equatable, Sendable {
        var pending: [SyncRecordID: Edit]
        var conflicts: [SyncRecordID: Edit]
        var bases: [SyncRecordID: Remote]
    }

    var pausedAccounts: [String: Paused]?
    public var user: String?
    public var lastSynced: [SharedCatalogCategory: Date]?
    public var enabled: [SharedCatalogCategory: Set<UUID>] = [:]
    public var remote: [SyncRecordID: Remote] = [:]
    public var pending: [SyncRecordID: Edit] = [:]
    public var conflicts: [SyncRecordID: Edit] = [:]

    /// Local owners are distinct from the cloud profile IDs carried by remote rows.
    public var localProfileIDs: Set<UUID> {
        var ids = Set(enabled.values.joined())
        ids.formUnion(pending.values.map(\.profile))
        ids.formUnion(conflicts.values.map(\.profile))
        for account in (pausedAccounts ?? [:]).values {
            ids.formUnion(account.pending.values.map(\.profile))
            ids.formUnion(account.conflicts.values.map(\.profile))
        }
        return ids
    }

    public init() {}
}

public enum SharedCatalogError: Error {
    case unavailable, accountChanged, unreadable, paused, storage
}

/// The durable outbox carries the value read before an edit. A concurrent close wins over a stale edit.
/// Other conflicting edits retain both versions until the person picks one.
@Observable
public final class SharedCatalogSync: SyncZoneHandler {
    public private(set) var state: SharedCatalogState
    public private(set) var ready: Set<SharedCatalogCategory> = []
    public private(set) var failed: Set<SharedCatalogCategory> = []
    public var onReceive: (() -> Void)?
    public var onAccountChange: ((String?) -> Void)?
    public var onVerifiedUser: ((String) -> Void)?
    public var canUpload: ((SharedCatalogState.Edit) -> Bool)?

    @ObservationIgnored var engine: (any SyncEngine)?
    @ObservationIgnored private let persist: (SharedCatalogState) throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var enrollments: [SharedCatalogCategory: Int] = [:]
    public private(set) var storageAvailable = true
    public private(set) var trustedUser: String?
    @ObservationIgnored private var reads: [SharedCatalogCategory: (id: UUID, task: Task<Void, Error>)] = [:]
    @ObservationIgnored private var buffered: [SharedCatalogCategory: [SyncEvent]] = [:]
    @ObservationIgnored private var sending: [SyncRecordID: (profile: UUID, item: SharedSpaceItem, receipt: SharedCatalogReceipt)] = [:]

    public init(state: SharedCatalogState, persist: @escaping (SharedCatalogState) throws -> Void) {
        self.state = state
        self.persist = persist
    }

    /// Persist local links and consent, including a retry when all categories are paused.
    @discardableResult
    public func persistLocalState() -> Bool {
        save()
    }

    /// Restore a previously unreadable local checkpoint before enrollment or a baseline can start.
    public func recoverLocalCheckpoint(_ restored: SharedCatalogState) {
        guard !needsEngine, ready.isEmpty else { return }
        state = restored
        trustedUser = nil
    }

    /// Apply an account change observed by Settings while catalog discovery was paused.
    public func resetAccount(to user: String?) {
        reset(user: user)
    }

    public func owns(zone: String) -> Bool {
        SharedCatalogCategory.allCases.contains { $0.zone == zone }
    }

    public var needsEngine: Bool {
        state.enabled.values.contains { !$0.isEmpty }
    }

    public func attach(_ engine: any SyncEngine) {
        self.engine = engine
    }

    public func enabled(_ category: SharedCatalogCategory, for profile: UUID) -> Bool {
        state.enabled[category]?.contains(profile) == true
    }

    public func setEnabled(_ on: Bool, _ category: SharedCatalogCategory, for profile: UUID) {
        guard enabled(category, for: profile) != on else { return }
        enrollments[category, default: 0] += 1
        if on {
            if state.enabled[category]?.isEmpty != false {
                state.lastSynced?[category] = nil
            }
            state.enabled[category, default: []].insert(profile)
            ready.remove(category)
        } else {
            state.enabled[category]?.remove(profile)
            sending = sending.filter { $0.value.profile != profile || $0.value.item.category != category }
            if state.enabled[category]?.isEmpty == true {
                ready.remove(category)
                reads.removeValue(forKey: category)?.task.cancel()
                buffered[category] = nil
            }
        }
        save()
    }

    public func items(_ category: SharedCatalogCategory) -> [SharedSpaceItem] {
        var items = state.remote.compactMapValues { $0.item.category == category ? $0.item : nil }
        // A remote close takes effect immediately. Other conflicts keep this Mac's editable version until the person chooses.
        for (id, edit) in state.conflicts where edit.item.category == category && items[id]?.removed == false {
            items[id] = edit.item
        }
        for (id, edit) in state.pending where edit.item.category == category {
            items[id] = edit.item
        }
        return Array(items.values)
    }

    public func item(_ id: UUID, in category: SharedCatalogCategory) -> SharedSpaceItem? {
        let key = SyncRecordID(zone: category.zone, name: id.uuidString)
        let remote = state.remote[key]?.item
        let conflict = remote?.removed == false ? state.conflicts[key]?.item : nil
        return state.pending[key]?.item ?? conflict ?? remote
    }

    public func prepare(_ category: SharedCatalogCategory) async throws {
        guard state.enabled[category]?.isEmpty == false else { throw SharedCatalogError.paused }
        if ready.contains(category) {
            guard await verifyAccount() else { throw SharedCatalogError.unavailable }
            return
        }
        if let read = reads[category] {
            try await read.task.value
            return
        }
        let epoch = generation
        let token = UUID()
        let read = Task { try await baseline(category, epoch: epoch) }
        reads[category] = (token, read)
        defer {
            if reads[category]?.id == token {
                reads[category] = nil
                buffered[category] = nil
            }
        }
        do {
            try await read.value
            failed.remove(category)
        } catch {
            if epoch == generation, reads[category]?.id == token, state.enabled[category]?.isEmpty == false {
                failed.insert(category)
            }
            throw error
        }
    }

    private func baseline(_ category: SharedCatalogCategory, epoch: Int) async throws {
        guard let engine, let identity = engine as? any SyncAccountIdentity else { throw SharedCatalogError.unavailable }
        let user = try await identity.currentAccountUser()
        try check(epoch, category)
        if let previous = state.user, previous != user {
            reset(user: user)
            throw SharedCatalogError.accountChanged
        }
        state.user = user
        trust(user)
        guard save() else { throw SharedCatalogError.storage }
        buffered[category] = []
        let read: SyncZoneRead
        do {
            read = try await engine.fetchAll(zone: category.zone)
        } catch where (error as? CKError)?.code == .zoneNotFound || (error as? URLError)?.code == .fileDoesNotExist {
            try await confirm(user, with: identity, epoch: epoch, category: category)
            if state.lastSynced?[category] != nil {
                zoneRemoved(category)
                guard save() else { throw SharedCatalogError.storage }
                onReceive?()
                throw SharedCatalogError.paused
            }
            engine.add([.saveZone(category.zone)])
            try await engine.sendNow()
            try check(epoch, category)
            read = try await engine.fetchAll(zone: category.zone)
        }
        try await confirm(user, with: identity, epoch: epoch, category: category)
        guard read.skipped == 0, read.records.allSatisfy({ SharedSpaceItem(record: $0)?.category == category }) else {
            throw SharedCatalogError.unreadable
        }
        let found = Set(read.records.map(\.id))
        let gone = state.remote.keys.filter { $0.zone == category.zone && !found.contains($0) }
        gone.forEach(forget)
        read.records.forEach(receive)
        for case .fetched(let records, let deleted) in buffered[category] ?? [] {
            records.forEach(receive)
            deleted.forEach(forget)
        }
        stamp(category)
        guard save() else { throw SharedCatalogError.storage }
        ready.insert(category)
        onReceive?()
        enqueue()
    }

    public func verifyAccount() async -> Bool {
        let epoch = generation
        guard let identity = engine as? any SyncAccountIdentity else { return false }
        do {
            let user = try await identity.currentAccountUser()
            guard epoch == generation else { return false }
            if let known = state.user, user != known {
                reset(user: user)
                return false
            }
            trust(user)
            return true
        } catch {
            if epoch == generation {
                trustedUser = nil
                failed.formUnion(ready)
                failed.formUnion(reads.keys)
                ready.removeAll()
                reads.values.forEach { $0.task.cancel() }
                reads.removeAll()
                buffered.removeAll()
            }
            return false
        }
    }

    public func acceptsUploadAccount(_ user: String) -> Bool {
        if let prior = state.user, prior != user {
            reset(user: user)
            return false
        }
        return true
    }

    private func verifiedIncomingCategories() async -> Set<SharedCatalogCategory> {
        let active = state.enabled.filter { !$0.value.isEmpty }.keys
        let before = enrollments
        guard !active.isEmpty, let user = state.user, await verifyAccount(), state.user == user else { return [] }
        return Set(active.filter { enrollments[$0] == before[$0] })
    }

    private func stamp(_ category: SharedCatalogCategory) {
        var times = state.lastSynced ?? [:]
        times[category] = Date()
        state.lastSynced = times
        failed.remove(category)
    }

    private func check(_ epoch: Int, _ category: SharedCatalogCategory) throws {
        try Task.checkCancellation()
        guard generation == epoch, state.enabled[category]?.isEmpty == false else { throw SharedCatalogError.paused }
    }

    private func confirm(_ user: String, with identity: any SyncAccountIdentity, epoch: Int, category: SharedCatalogCategory) async throws {
        let current = try await identity.currentAccountUser()
        try check(epoch, category)
        if current != user {
            reset(user: current)
            throw SharedCatalogError.accountChanged
        }
    }

    public func stage(_ item: SharedSpaceItem, for profile: UUID) {
        stage([item], for: profile)
    }

    public func stage(_ items: [SharedSpaceItem], for profile: UUID) {
        var changed = false
        var send: [SyncChange] = []
        for item in items where enabled(item.category, for: profile) {
            let id = item.recordID
            let known = state.conflicts[id]?.item ?? state.pending[id]?.item ?? state.remote[id]?.item
            guard known != item, item.record(fields: nil, receipt: .init(submission: UUID())) != nil else { continue }
            if let conflict = state.conflicts[id], !item.removed {
                guard conflict.profile == profile else { continue }
                state.conflicts[id]?.item = item
                changed = true
                continue
            }
            if item.removed {
                state.conflicts[id] = nil
            }
            let previous = state.pending[id]
            let submitted = sending[id]?.item ?? previous?.submitted
            if item == state.remote[id]?.item, submitted == nil {
                state.pending[id] = nil
            } else {
                state.pending[id] = .init(profile: profile, base: previous?.base ?? state.remote[id]?.item, item: item, submitted: submitted)
            }
            changed = true
            if ready.contains(item.category) {
                send.append(.saveRecord(id))
            }
        }
        if changed, save(), !send.isEmpty {
            engine?.add(send)
        }
    }

    /// The explicit replacement commits new record identities with its host's new local-to-cloud links.
    public func replacePublication(for profile: UUID, with items: [SharedSpaceItem]) -> Bool {
        sending = sending.filter { $0.value.profile != profile }
        state.pending = state.pending.filter { $0.value.profile != profile }
        state.conflicts = state.conflicts.filter { $0.value.profile != profile }
        for item in items where enabled(item.category, for: profile) {
            state.pending[item.recordID] = .init(profile: profile, item: item)
        }
        return save()
    }

    public func discardPending(for profile: UUID, ids: Set<UUID>, category: SharedCatalogCategory) {
        for id in ids {
            let key = SyncRecordID(zone: category.zone, name: id.uuidString)
            if state.pending[key]?.profile == profile {
                state.pending[key] = nil
            }
            if sending[key]?.profile == profile {
                sending[key] = nil
            }
            if state.conflicts[key]?.profile == profile {
                state.conflicts[key] = nil
            }
        }
        save()
    }

    /// Erasing a local profile also revokes edits parked for a signed-out account.
    public func discardEdits(for profile: UUID) {
        sending = sending.filter { $0.value.profile != profile }
        state.pending = state.pending.filter { $0.value.profile != profile }
        state.conflicts = state.conflicts.filter { $0.value.profile != profile }
        state.pausedAccounts = state.pausedAccounts?.mapValues { parked in
            var remaining = parked
            remaining.pending = parked.pending.filter { $0.value.profile != profile }
            remaining.conflicts = parked.conflicts.filter { $0.value.profile != profile }
            return remaining
        }
        save()
    }

    public func resolve(_ id: SyncRecordID, keepingLocal: Bool) {
        guard let edit = state.conflicts.removeValue(forKey: id) else { return }
        if keepingLocal {
            stage(edit.item, for: edit.profile)
        }
        save()
        onReceive?()
    }

    private func upload(for id: SyncRecordID) -> SharedCatalogState.Edit? {
        guard storageAvailable, trustedUser != nil, trustedUser == state.user, let edit = state.pending[id], ready.contains(edit.item.category),
              enabled(edit.item.category, for: edit.profile), canUpload?(edit) != false else { return nil }
        return edit
    }

    public func record(for id: SyncRecordID) -> SyncRecord? {
        guard let edit = upload(for: id) else { return nil }
        let previous = sending[id]
        let same = previous?.profile == edit.profile && previous?.item == edit.item
        let receipt = (same ? previous?.receipt : nil) ?? SharedCatalogReceipt(submission: UUID())
        guard let record = edit.item.record(fields: state.remote[id]?.fields, receipt: receipt) else { return nil }
        sending[id] = (edit.profile, edit.item, receipt)
        return record
    }

    private func finishSubmission(_ record: SyncRecord) -> Bool {
        guard let issued = sending[record.id],
              let receipt = try? JSONDecoder().decode(SharedCatalogReceipt.self, from: record.payload),
              receipt == issued.receipt else { return false }
        sending[record.id] = nil
        return true
    }

    public func enqueue() {
        guard save() else { return }
        engine?.add(state.pending.keys.compactMap { upload(for: $0) == nil ? nil : .saveRecord($0) })
    }

    public func handle(_ event: SyncEvent) async {
        var retry: [SyncChange] = []
        switch event {
        case .state, .zoneDeletesFailed:
            return
        case .account(let change):
            switch change {
            case .signOut:
                reset(user: nil)
            case .switchAccounts(let user):
                reset(user: user)
            case .signIn(let user):
                if state.user != nil && state.user != user {
                    reset(user: user)
                } else {
                    state.user = user
                }
            }
        case .zonesDeleted(let zones):
            let verified = await verifiedIncomingCategories()
            guard !verified.isEmpty else { return }
            for category in verified where zones[category.zone] != nil {
                zoneRemoved(category)
            }
        case .zoneSavesOverQuota(let zones):
            failed.formUnion(SharedCatalogCategory.allCases.filter { zones.contains($0.zone) })
        case .fetched(let records, let deleted):
            let verified = await verifiedIncomingCategories()
            guard !verified.isEmpty else { return }
            for category in verified {
                let owned = records.filter { $0.id.zone == category.zone }
                let removed = deleted.filter { $0.zone == category.zone }
                if buffered[category] != nil {
                    buffered[category]?.append(.fetched(modified: owned, deleted: removed))
                } else if ready.contains(category) {
                    owned.forEach(receive)
                    removed.forEach(forget)
                }
            }
        case .sent(let saved, _, let errors):
            guard !saved.isEmpty || !errors.isEmpty, await verifyAccount() else { return }
            for record in saved where accepts(record.id) && finishSubmission(record) {
                acknowledge(record)
            }
            retry = failedSaves(errors)
        }
        if save(), !retry.isEmpty {
            engine?.add(retry)
        }
        onReceive?()
    }

    private func zoneRemoved(_ category: SharedCatalogCategory) {
        for profile in state.enabled[category] ?? [] {
            setEnabled(false, category, for: profile)
        }
        state.remote = state.remote.filter { $0.key.zone != category.zone }
        state.pending = state.pending.filter { $0.key.zone != category.zone }
        state.conflicts = state.conflicts.filter { $0.key.zone != category.zone }
        state.lastSynced?[category] = nil
        failed.remove(category)
    }

    private func failedSaves(_ errors: [SyncFailedSave]) -> [SyncChange] {
        var retry: [SyncChange] = []
        for error in errors where accepts(error.id) {
            guard let attempted = error.attempted, attempted.id == error.id, finishSubmission(attempted) else { continue }
            switch error.failure {
            case .serverRecordChanged(let record):
                receive(record)
                if state.pending[error.id] != nil {
                    retry.append(.saveRecord(error.id))
                }
            case .unknownItem:
                forget(error.id)
            case .zoneNotFound:
                if let category = state.pending[error.id]?.item.category {
                    ready.remove(category)
                    failed.insert(category)
                }
            case .quotaExceeded, .other:
                if let category = state.pending[error.id]?.item.category {
                    failed.insert(category)
                }
            }
        }
        return retry
    }

    private func accepts(_ id: SyncRecordID) -> Bool {
        ready.contains { $0.zone == id.zone }
    }

    private func receive(_ record: SyncRecord) {
        guard let item = SharedSpaceItem(record: record) else { return }
        let id = record.id
        if let prior = state.remote[id] {
            guard prior.item.kind == item.kind, prior.item.profileID == item.profileID else { return }
            if prior.item == item, prior.fields == record.systemFields, state.pending[id] == nil {
                return
            }
        }
        stamp(item.category)
        if let edit = state.pending[id] {
            if edit.submitted == item, edit.item != item {
                state.pending[id]?.base = item
                state.pending[id]?.submitted = nil
            } else if edit.item == item, edit.submitted == nil || edit.submitted == item {
                state.pending[id] = nil
            } else if item != edit.base {
                if edit.item.removed && !item.removed {
                    state.pending[id]?.base = item
                } else {
                    state.conflicts[id] = edit
                    state.pending[id] = nil
                }
            }
        }
        if sending[id]?.item == item {
            sending[id] = nil
        }
        state.remote[id] = .init(item: item, fields: record.systemFields)
    }

    private func acknowledge(_ record: SyncRecord) {
        guard let item = SharedSpaceItem(record: record) else { return }
        stamp(item.category)
        if state.pending[record.id]?.submitted == item {
            state.pending[record.id]?.submitted = nil
        }
        state.remote[record.id] = .init(item: item, fields: record.systemFields)
        if state.pending[record.id]?.item == item {
            state.pending[record.id] = nil
        } else if state.pending[record.id] != nil {
            state.pending[record.id]?.base = item
            engine?.add([.saveRecord(record.id)])
        }
    }

    private func forget(_ id: SyncRecordID) {
        guard let prior = state.remote[id]?.item else { return }
        let tombstone = prior.tombstone
        // A repeated deletion during baseline is also the base for a version the user explicitly chose to restore.
        if state.pending[id]?.base != tombstone, let edit = state.pending.removeValue(forKey: id), !edit.item.removed {
            state.conflicts[id] = edit
        }
        state.remote[id] = .init(item: tombstone, fields: nil)
    }

    private func trust(_ user: String) {
        guard trustedUser != user else { return }
        if let parked = state.pausedAccounts?.removeValue(forKey: user) {
            state.pending.merge(parked.pending) { active, _ in active }
            state.conflicts.merge(parked.conflicts) { active, _ in active }
            state.remote.merge(parked.bases) { active, _ in active }
        }
        trustedUser = user
        onVerifiedUser?(user)
    }

    private func reset(user: String?) {
        let previous = state.user
        var parked = state.pausedAccounts ?? [:]
        if let previous, !state.pending.isEmpty || !state.conflicts.isEmpty {
            let needed = Set(state.pending.keys).union(state.conflicts.keys)
            parked[previous] = .init(pending: state.pending, conflicts: state.conflicts, bases: state.remote.filter { needed.contains($0.key) })
        }
        generation += 1
        reads.values.forEach { $0.task.cancel() }
        reads = [:]
        buffered = [:]
        sending = [:]
        ready = []
        failed = []
        state = SharedCatalogState()
        state.pausedAccounts = parked
        trustedUser = nil
        state.user = user
        onAccountChange?(previous)
        save()
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try persist(state)
            storageAvailable = true
        } catch {
            storageAvailable = false
        }
        return storageAvailable
    }
}
