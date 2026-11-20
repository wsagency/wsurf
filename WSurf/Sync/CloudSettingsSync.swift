// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Observation
import WSurfCore

@MainActor
@Observable
final class CloudSettingsSync: SyncZoneHandler {
    enum Issue: Error {
        case unavailable, incomplete, changedAccount, invalidRecord, duplicateLink
    }

    enum BufferedChange {
        case save(SyncRecord)
        case remove(SyncRecordID)
    }

    struct State: Codable {
        var account: String?
        var channels: [String: MacSettingChannel] = [:]
    }

    typealias Read = @MainActor (MacSettingsCategory, UUID?) throws -> [String: Data]
    typealias Apply = @MainActor (Data?, String, MacSettingsCategory, UUID?) throws -> Void

    private(set) var state: State
    var notice: String?
    var onNeedsEngine: (() -> Void)?
    @ObservationIgnored var registerProfile: ((Profile) -> Void)?
    @ObservationIgnored let read: Read
    @ObservationIgnored let apply: Apply
    @ObservationIgnored private let stateFile: URL
    @ObservationIgnored var engine: (any SyncEngine)?
    @ObservationIgnored var ready: Set<String> = []
    @ObservationIgnored var loading: [String: UUID] = [:]
    @ObservationIgnored var buffered: [String: [BufferedChange]] = [:]
    @ObservationIgnored var preparations: [String: Task<Void, Error>] = [:]
    @ObservationIgnored var names: [SyncRecordID: String] = [:]
    @ObservationIgnored var trustedUser: String?
    @ObservationIgnored var sendingAllowed = false
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored private var requesting = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored var accountNotifications: Task<Void, Never>?
    @ObservationIgnored var accountLookup: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?

    var needsEngine: Bool {
        requesting > 0 || !state.channels.isEmpty
    }

    convenience init(stateFile: URL, profiles: [Profile]) {
        let adapter = MacSettingsSyncAdapter(profiles: profiles)
        self.init(stateFile: stateFile, read: adapter.values(for:profileID:), apply: adapter.apply(_:key:for:profileID:))
        registerProfile = adapter.register
        observation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .wsurfMacSettingsDidChange).map({ _ in () }) {
                guard let self, !Task.isCancelled else { return }
                guard !state.channels.isEmpty else { continue }
                do { try collectChanges() } catch { reportError() }
            }
        }
    }

    init(stateFile: URL, read: @escaping Read, apply: @escaping Apply) {
        self.stateFile = stateFile
        self.read = read
        self.apply = apply
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
        } catch {
            state = State()
            if FileManager.default.fileExists(atPath: stateFile.path) {
                notice = String(localized: "The saved sync settings could not be read. Choose what to share again.")
            }
        }
    }

    deinit {
        observation?.cancel()
        accountNotifications?.cancel()
        accountLookup?.cancel()
        work?.cancel()
    }

    func attach(_ engine: any SyncEngine) {
        self.engine = engine
    }

    func owns(zone: String) -> Bool {
        if zone == "mac-prefs-providers" { return true }
        for category in MacSettingsCategory.allCases {
            let prefix = "mac-prefs-" + category.rawValue + "-"
            if zone.hasPrefix(prefix), let id = UUID(uuidString: String(zone.dropFirst(prefix.count))), prefix + id.uuidString == zone {
                return true
            }
        }
        return false
    }

    func updateChannel(_ channel: MacSettingChannel) {
        state.channels[channel.zone] = channel
    }

    func channel(_ category: MacSettingsCategory, localProfileID: UUID?) -> MacSettingChannel? {
        state.channels.values.first { $0.localProfileID == localProfileID && $0.category == category }
    }

    func isEnabled(_ category: MacSettingsCategory, localProfileID: UUID?) -> Bool {
        channel(category, localProfileID: localProfileID) != nil
    }

    func enable(_ category: MacSettingsCategory, localProfileID: UUID?, cloudProfileID: UUID?) async throws {
        guard localProfileID != Profile.privateID, cloudProfileID != Profile.privateID,
            (localProfileID == nil) == (cloudProfileID == nil), category == .providers || localProfileID != nil
        else { throw Issue.unavailable }
        requesting += 1
        defer { requesting -= 1 }
        let started = generation
        onNeedsEngine?()
        try await verifyAccount(started)
        let proposed = MacSettingChannel(category: category, localProfileID: localProfileID, cloudProfileID: cloudProfileID)
        if let existing = channel(category, localProfileID: localProfileID), existing.zone != proposed.zone {
            throw Issue.duplicateLink
        }
        if let existing = state.channels[proposed.zone], existing.localProfileID != localProfileID {
            throw Issue.duplicateLink
        }
        if state.channels[proposed.zone] == nil {
            state.channels[proposed.zone] = proposed
            try save()
        }
        try await prepare(zone: proposed.zone)
    }

    func disable(_ category: MacSettingsCategory, localProfileID: UUID?) throws {
        guard let channel = channel(category, localProfileID: localProfileID) else { return }
        forget(zone: channel.zone)
        try save()
    }

    func beat() {
        guard work == nil, needsEngine else { return }
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            do {
                try await verifyAccount(generation)
                for zone in state.channels.keys.sorted() where !ready.contains(zone) {
                    try await prepare(zone: zone)
                }
                try collectChanges()
                try await engine?.fetchNow()
                try await engine?.sendNow()
                for zone in ready {
                    state.channels[zone]?.lastSync = .now
                }
                try save()
                if state.channels.values.allSatisfy({ channel in channel.records.values.allSatisfy { $0.pending == nil } }) {
                    notice = nil
                }
            } catch {
                reportError()
            }
        }
    }

    func collectChanges() throws {
        for zone in state.channels.keys.sorted() {
            guard var channel = state.channels[zone] else { continue }
            channel.collect(try read(channel.category, channel.localProfileID))
            state.channels[zone] = channel
        }
        try save()
        for zone in ready {
            queuePending(zone)
        }
    }

    func resolve(_ key: String, in zone: String, useCloud: Bool) throws {
        guard ready.contains(zone), var channel = state.channels[zone] else { throw Issue.unavailable }
        let category = channel.category
        let profile = channel.localProfileID
        try channel.resolve(key, useCloud: useCloud) { try apply($0, $1, category, profile) }
        if useCloud {
            channel.observed[key] = try read(category, profile)[key]
        }
        state.channels[zone] = channel
        try save()
        queuePending(zone)
    }

    func verifyAccount(_ started: UUID) async throws {
        guard let identity = engine as? any SyncAccountIdentity else { throw Issue.unavailable }
        do {
            let user = try await identity.currentAccountUser()
            guard !user.isEmpty, generation == started else { throw Issue.changedAccount }
            if let previous = state.account, previous != user {
                try resetAccount(to: user)
                throw Issue.changedAccount
            }
            state.account = user
            trustedUser = user
            if accountNotifications != nil {
                ProviderKeySharing.shared.setAccountIdentifier(user)
            }
        } catch {
            if generation == started {
                suspendAccount()
                if accountNotifications != nil {
                    ProviderKeySharing.shared.suspendAccountVerification()
                }
            }
            throw error
        }
    }

    private func prepare(zone: String) async throws {
        guard !ready.contains(zone) else { return }
        if let existing = preparations[zone] {
            try await existing.value
            return
        }
        let token = UUID()
        loading[zone] = token
        let read = Task { try await readBaseline(zone: zone, token: token) }
        preparations[zone] = read
        defer {
            if loading[zone] == token {
                loading[zone] = nil
                buffered[zone] = nil
                preparations[zone] = nil
            }
        }
        try await read.value
    }

    private func readBaseline(zone: String, token: UUID) async throws {
        guard let channel = state.channels[zone], let engine, loading[zone] == token else { throw Issue.unavailable }
        let started = generation
        let baseline: SyncZoneRead
        do {
            baseline = try await engine.fetchAll(zone: zone)
        } catch where Self.missingZone(error) {
            try await verifyAccount(started)
            guard loading[zone] == token, state.channels[zone]?.enrollment == channel.enrollment else { throw CancellationError() }
            guard !channel.fetched else {
                forget(zone: zone)
                try save()
                throw Issue.incomplete
            }
            engine.add([.saveZone(zone)])
            try await engine.sendNow()
            baseline = try await engine.fetchAll(zone: zone)
        }
        try await verifyAccount(started)
        guard loading[zone] == token, state.channels[zone]?.enrollment == channel.enrollment else { throw CancellationError() }
        guard baseline.skipped == 0 else { throw Issue.incomplete }
        try collectChanges()
        for record in baseline.records {
            try receive(record)
        }
        try reconcileDeletions(in: zone, seen: Set(baseline.records.map(\.id)))
        for change in buffered[zone] ?? [] {
            switch change {
            case .save(let record):
                try receive(record)
            case .remove(let id):
                try removed(id)
            }
        }
        state.channels[zone]?.fetched = true
        state.channels[zone]?.lastSync = .now
        try save()
        ready.insert(zone)
        queuePending(zone)
    }

    private static func missingZone(_ error: Error) -> Bool {
        (error as? CKError)?.code == .zoneNotFound || (error as? URLError)?.code == .fileDoesNotExist
    }

    func save() throws {
        sendingAllowed = false
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        sendingAllowed = true
    }

    func forget(zone: String) {
        state.channels[zone] = nil
        ready.remove(zone)
        loading[zone] = nil
        buffered[zone] = nil
        preparations.removeValue(forKey: zone)?.cancel()
        names = names.filter { $0.key.zone != zone }
    }

    func resetAccount(to user: String?) throws {
        generation = UUID()
        for zone in Array(state.channels.keys) {
            forget(zone: zone)
        }
        state.account = user
        trustedUser = nil
        try save()
        notice = String(localized: "The Apple Account changed. Choose what to sync with this account.")
    }

    func reportError() {
        if notice == nil {
            notice = String(localized: "Settings could not finish syncing. Try again on this Mac.")
        }
    }
}
