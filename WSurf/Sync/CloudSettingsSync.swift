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

    private struct OptOut: Codable {
        let category: MacSettingsCategory
        let localProfileID: UUID?
        let enrollment: UUID
    }

    typealias Read = @MainActor (MacSettingsCategory, UUID?) throws -> [String: Data]
    typealias Apply = @MainActor (Data?, String, MacSettingsCategory, UUID?) throws -> Void

    private(set) var state: State
    private var pendingOptOuts: [String: OptOut] = [:]
    var notice: String?
    var onNeedsEngine: (() -> Void)?
    @ObservationIgnored var registerProfile: ((Profile) -> Void)?
    @ObservationIgnored let read: Read
    @ObservationIgnored let apply: Apply
    @ObservationIgnored private let stateFile: URL
    @ObservationIgnored private let discardWebsiteApprovals: (UUID) -> Void
    @ObservationIgnored var engine: (any SyncEngine)?
    @ObservationIgnored var ready: Set<String> = []
    @ObservationIgnored var loading: [String: UUID] = [:]
    @ObservationIgnored var buffered: [String: [BufferedChange]] = [:]
    @ObservationIgnored var preparations: [String: Task<Void, Error>] = [:]
    @ObservationIgnored var names: [SyncRecordID: String] = [:]
    @ObservationIgnored var trustedUser: String?
    @ObservationIgnored var sendingAllowed = false
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored var accountNotifications: Task<Void, Never>?
    @ObservationIgnored var accountLookup: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?

    var needsEngine: Bool {
        !state.channels.isEmpty
    }

    convenience init(stateFile: URL, profiles: [Profile], adapter: MacSettingsSyncAdapter? = nil) {
        let adapter = adapter ?? MacSettingsSyncAdapter(profiles: profiles)
        self.init(
            stateFile: stateFile, read: adapter.values(for:profileID:), apply: adapter.apply(_:key:for:profileID:),
            discardWebsiteApprovals: adapter.discardWebsiteApprovals(profileID:)
        )
        registerProfile = adapter.register
        let live = Set(profiles.map(\.id)).subtracting([Profile.privateID])
        for channel in state.channels.values {
            if let id = channel.localProfileID, !live.contains(id) {
                forget(zone: channel.zone)
            }
        }
        if hasPendingOptOuts {
            do { try save() } catch { reportError() }
        }
        observation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .wsurfMacSettingsDidChange).map({ _ in () }) {
                guard let self, !Task.isCancelled else { return }
                guard !state.channels.isEmpty else { continue }
                do { try collectChanges() } catch { reportError() }
            }
        }
    }

    init(stateFile: URL, read: @escaping Read, apply: @escaping Apply, discardWebsiteApprovals: @escaping (UUID) -> Void = { _ in }) {
        self.stateFile = stateFile
        self.read = read
        self.apply = apply
        self.discardWebsiteApprovals = discardWebsiteApprovals
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
        } catch {
            state = State()
            if FileManager.default.fileExists(atPath: stateFile.path) {
                notice = String(localized: "The saved sync settings could not be read. Choose what to share again.")
            }
        }
        restorePendingOptOuts()
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
        var proposed = MacSettingChannel(category: category, localProfileID: localProfileID, cloudProfileID: cloudProfileID)
        if let existing = channel(category, localProfileID: localProfileID), existing.zone != proposed.zone {
            throw Issue.duplicateLink
        }
        if hasPendingOptOuts {
            try save()
        }
        if let existing = state.channels[proposed.zone] {
            guard existing.localProfileID == localProfileID else { throw Issue.duplicateLink }
            proposed = existing
        } else {
            // Observe the starting values before any account or baseline read can suspend.
            proposed.collect(try read(category, localProfileID))
            updateChannel(proposed)
            do {
                try save()
            } catch {
                state.channels[proposed.zone] = nil
                throw error
            }
        }

        let started = generation
        onNeedsEngine?()
        try await verifyAccount(started, confirmingEnrollment: true)
        guard state.channels[proposed.zone]?.enrollment == proposed.enrollment else { throw CancellationError() }
        try await prepare(zone: proposed.zone)
    }

    var hasPendingOptOuts: Bool {
        !pendingOptOuts.isEmpty
    }

    func isTurningOff(_ category: MacSettingsCategory, localProfileID: UUID?) -> Bool {
        pendingOptOuts.values.contains { $0.category == category && $0.localProfileID == localProfileID }
    }

    func disable(_ category: MacSettingsCategory, localProfileID: UUID?) throws {
        if let channel = channel(category, localProfileID: localProfileID) {
            forget(zone: channel.zone)
        }
        if isTurningOff(category, localProfileID: localProfileID) {
            try save()
        }
    }

    func forgetProfile(_ id: UUID) throws {
        for channel in state.channels.values where channel.localProfileID == id {
            forget(zone: channel.zone)
        }
        if pendingOptOuts.values.contains(where: { $0.localProfileID == id }) {
            try save()
        }
    }

    func beat(confirmingEnrollment: Bool = false) {
        // Turning a channel off needs only the local file, even after the last opt-out.
        if hasPendingOptOuts {
            do {
                try save()
            } catch {
                return
            }
        }
        guard work == nil, !state.channels.isEmpty else { return }
        if state.account == nil && !confirmingEnrollment {
            reportError()
            return
        }
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            let started = generation
            do {
                try await verifyAccount(started, confirmingEnrollment: confirmingEnrollment)
                var preparationFailed = false
                for zone in state.channels.keys.sorted() where !ready.contains(zone) {
                    do {
                        try await prepare(zone: zone)
                    } catch {
                        guard generation == started else { throw error }
                        preparationFailed = true
                    }
                }
                let readFailure = try collectAvailableChanges()
                try await engine?.fetchNow()
                guard generation == started else { throw Issue.changedAccount }
                try await engine?.sendNow()
                guard generation == started else { throw Issue.changedAccount }
                for zone in ready {
                    state.channels[zone]?.lastSync = .now
                }
                try save()
                if preparationFailed || readFailure != nil {
                    reportError()
                } else if ready.count == state.channels.count && state.channels.values.allSatisfy({ channel in channel.records.values.allSatisfy { $0.pending == nil } }) {
                    notice = nil
                }
            } catch {
                reportError()
            }
        }
    }

    /// Fetched records and deletions must see edits made since the last notification.
    func collectLocalChanges(in zone: String) throws {
        guard var channel = state.channels[zone] else { return }
        channel.collect(try read(channel.category, channel.localProfileID))
        updateChannel(channel)
    }

    func collectChanges() throws {
        if let failure = try collectAvailableChanges() {
            throw failure
        }
    }

    private func collectAvailableChanges() throws -> Error? {
        var failure: Error?
        for zone in state.channels.keys.sorted() {
            do {
                try collectLocalChanges(in: zone)
            } catch {
                ready.remove(zone)
                failure = error
            }
        }
        try save()
        for zone in ready {
            queuePending(zone)
        }
        return failure
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

    func verifyAccount(_ started: UUID, confirmingEnrollment: Bool = false) async throws {
        // Only a user action may bind a first, offline enrollment to a previously unknown account.
        guard state.account != nil || state.channels.isEmpty || confirmingEnrollment else { throw Issue.unavailable }
        guard let identity = engine as? any SyncAccountIdentity else { throw Issue.unavailable }
        do {
            let user = try await identity.currentAccountUser()
            guard !user.isEmpty, generation == started else { throw Issue.changedAccount }
            if let previous = state.account, previous != user {
                try resetAccount(to: user)
                throw Issue.changedAccount
            }
            if state.account == nil {
                state.account = user
                try save()
            }
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
        try collectLocalChanges(in: zone)
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
        do {
            try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        } catch {
            if hasPendingOptOuts {
                // Remember the revoked enrollments across a restart if just the main file is unwritable.
                try JSONEncoder().encode(pendingOptOuts).write(to: optOutFile, options: .atomic)
            }
            throw error
        }
        sendingAllowed = true
        if hasPendingOptOuts {
            pendingOptOuts.removeAll()
            try? FileManager.default.removeItem(at: optOutFile)
            if state.channels.isEmpty {
                notice = nil
            }
        }
    }

    private var optOutFile: URL {
        stateFile.appendingPathExtension("opt-outs")
    }

    private func restorePendingOptOuts() {
        guard FileManager.default.fileExists(atPath: optOutFile.path) else { return }
        do {
            pendingOptOuts = try JSONDecoder().decode([String: OptOut].self, from: Data(contentsOf: optOutFile))
        } catch {
            // A damaged revocation list cannot authorize an old enrollment.
            for zone in state.channels.keys {
                forget(zone: zone)
            }
            notice = String(localized: "The saved sync settings could not be read. Choose what to share again.")
        }
        for (zone, removal) in pendingOptOuts {
            if let current = state.channels[zone] {
                if current.enrollment == removal.enrollment {
                    forget(zone: zone)
                } else {
                    pendingOptOuts[zone] = nil
                }
            }
        }
        if hasPendingOptOuts {
            do { try save() } catch { reportError() }
        }
    }

    func forget(zone: String) {
        if let channel = state.channels.removeValue(forKey: zone) {
            pendingOptOuts[zone] = OptOut(category: channel.category, localProfileID: channel.localProfileID, enrollment: channel.enrollment)
            if channel.category == .websiteSettings, let id = channel.localProfileID {
                discardWebsiteApprovals(id)
            }
        }
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
        if notice == nil && !hasPendingOptOuts {
            notice = String(localized: "Settings could not finish syncing. Try again on this Mac.")
        }
    }
}
