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
    }

    public var user: String?
    public var lastSynced: [SharedCatalogCategory: Date]?
    public var enabled: [SharedCatalogCategory: Set<UUID>] = [:]
    public var remote: [SyncRecordID: Remote] = [:]
    public var pending: [SyncRecordID: Edit] = [:]
    public var conflicts: [SyncRecordID: Edit] = [:]

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
    public var onAccountChange: (() -> Void)?

    @ObservationIgnored var engine: (any SyncEngine)?
    @ObservationIgnored private let persist: (SharedCatalogState) throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var persisted = true
    @ObservationIgnored private var reads: [SharedCatalogCategory: (id: UUID, task: Task<Void, Error>)] = [:]
    @ObservationIgnored private var buffered: [SharedCatalogCategory: [SyncEvent]] = [:]

    public init(state: SharedCatalogState, persist: @escaping (SharedCatalogState) throws -> Void) {
        self.state = state
        self.persist = persist
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
        if on {
            state.enabled[category, default: []].insert(profile)
            ready.remove(category)
        } else {
            state.enabled[category]?.remove(profile)
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
        for (id, edit) in state.pending where edit.item.category == category {
            items[id] = edit.item
        }
        return Array(items.values)
    }

    public func item(_ id: UUID, in category: SharedCatalogCategory) -> SharedSpaceItem? {
        let key = SyncRecordID(zone: category.zone, name: id.uuidString)
        return state.pending[key]?.item ?? state.remote[key]?.item
    }

    public func prepare(_ category: SharedCatalogCategory) async throws {
        guard state.enabled[category]?.isEmpty == false else { throw SharedCatalogError.paused }
        guard !ready.contains(category) else { return }
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
            if epoch == generation {
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
        guard save() else { throw SharedCatalogError.storage }
        buffered[category] = []
        let read: SyncZoneRead
        do {
            read = try await engine.fetchAll(zone: category.zone)
        } catch where (error as? CKError)?.code == .zoneNotFound || (error as? URLError)?.code == .fileDoesNotExist {
            try check(epoch, category)
            engine.add([.saveZone(category.zone)])
            try await engine.sendNow()
            try check(epoch, category)
            read = try await engine.fetchAll(zone: category.zone)
        }
        try check(epoch, category)
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
            return true
        } catch {
            return false
        }
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

    public func stage(_ item: SharedSpaceItem, for profile: UUID) {
        stage([item], for: profile)
    }

    public func stage(_ items: [SharedSpaceItem], for profile: UUID) {
        var changed = false
        var send: [SyncChange] = []
        for item in items where enabled(item.category, for: profile) {
            let id = item.recordID
            guard (state.pending[id]?.item ?? state.remote[id]?.item) != item,
                  state.conflicts[id] == nil || item.removed, item.record(fields: nil) != nil else { continue }
            if item.removed {
                state.conflicts[id] = nil
            }
            if item == state.remote[id]?.item {
                state.pending[id] = nil
            } else {
                state.pending[id] = .init(profile: profile, base: state.pending[id]?.base ?? state.remote[id]?.item, item: item)
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

    public func discardPending(for profile: UUID, ids: Set<UUID>, category: SharedCatalogCategory) {
        for id in ids {
            let key = SyncRecordID(zone: category.zone, name: id.uuidString)
            if state.pending[key]?.profile == profile {
                state.pending[key] = nil
            }
            if state.conflicts[key]?.profile == profile {
                state.conflicts[key] = nil
            }
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

    public func record(for id: SyncRecordID) -> SyncRecord? {
        guard persisted, let edit = state.pending[id], ready.contains(edit.item.category),
              enabled(edit.item.category, for: edit.profile) else { return nil }
        return edit.item.record(fields: state.remote[id]?.fields)
    }

    public func enqueue() {
        guard save() else { return }
        engine?.add(state.pending.keys.compactMap { record(for: $0) == nil ? nil : .saveRecord($0) })
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
            for category in SharedCatalogCategory.allCases where zones[category.zone] != nil {
                for profile in state.enabled[category] ?? [] {
                    setEnabled(false, category, for: profile)
                }
                state.remote = state.remote.filter { $0.key.zone != category.zone }
                state.pending = state.pending.filter { $0.key.zone != category.zone }
                state.conflicts = state.conflicts.filter { $0.key.zone != category.zone }
            }
        case .zoneSavesOverQuota(let zones):
            failed.formUnion(SharedCatalogCategory.allCases.filter { zones.contains($0.zone) })
        case .fetched(let records, let deleted):
            for category in Array(buffered.keys) {
                let owned = records.filter { $0.id.zone == category.zone }
                let removed = deleted.filter { $0.zone == category.zone }
                buffered[category]?.append(.fetched(modified: owned, deleted: removed))
            }
            records.filter { accepts($0.id) }.forEach(receive)
            deleted.filter(accepts).forEach(forget)
        case .sent(let saved, let deleted, let errors):
            saved.filter { accepts($0.id) }.forEach(acknowledge)
            deleted.filter(accepts).forEach(forget)
            retry = failedSaves(errors)
        }
        if save(), !retry.isEmpty {
            engine?.add(retry)
        }
        onReceive?()
    }

    private func failedSaves(_ errors: [SyncFailedSave]) -> [SyncChange] {
        var retry: [SyncChange] = []
        for error in errors where accepts(error.id) {
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
        if let edit = state.pending[id] {
            if edit.item == item {
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
        state.remote[id] = .init(item: item, fields: record.systemFields)
    }

    private func acknowledge(_ record: SyncRecord) {
        guard let item = SharedSpaceItem(record: record) else { return }
        stamp(item.category)
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
        if let edit = state.pending.removeValue(forKey: id), !edit.item.removed {
            state.conflicts[id] = edit
        }
        state.remote[id] = .init(item: prior.tombstone, fields: nil)
    }

    private func reset(user: String?) {
        generation += 1
        reads.values.forEach { $0.task.cancel() }
        reads = [:]
        buffered = [:]
        ready = []
        failed = []
        state = SharedCatalogState()
        state.user = user
        onAccountChange?()
        save()
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try persist(state)
            persisted = true
        } catch {
            persisted = false
        }
        return persisted
    }
}
