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
        fileprivate var optOuts: [String: OptOut]?

        static func read(from file: URL) throws -> Self {
            var saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            // A legacy baseline identifies an enrolled channel. An unfinished choice may predate the account binding.
            for (zone, channel) in saved.channels where channel.awaitingAccountConfirmation == nil || saved.account == nil {
                saved.channels[zone]?.awaitingAccountConfirmation = saved.account == nil || !channel.fetched
            }
            return saved
        }
    }

    fileprivate struct OptOut: Codable {
        let category: MacSettingsCategory
        let localProfileID: UUID?
        let enrollment: UUID

        init(_ channel: MacSettingChannel) {
            category = channel.category
            localProfileID = channel.localProfileID
            enrollment = channel.enrollment
        }
    }

    typealias Read = @MainActor (MacSettingsCategory, UUID?) throws -> [String: Data]
    typealias Snapshot = @MainActor (inout MacSettingChannel) throws -> [String: Data]
    typealias Apply = @MainActor (Data?, String, MacSettingsCategory, UUID?) throws -> Void

    private(set) var state: State
    private var pendingOptOuts: [String: OptOut] {
        get { state.optOuts ?? [:] }
        set { state.optOuts = newValue.isEmpty ? nil : newValue }
    }

    @ObservationIgnored private var optOutsToFinish: Set<String> = []
    private(set) var checkpointUnavailable = false
    @ObservationIgnored private var checkpointRetry: Task<Void, Never>?
    @ObservationIgnored private var profilesForRecovery: Set<UUID>?
    var notice: String?
    @ObservationIgnored var onAccountVerification: ((CloudSharedSpaces.AccountVerification) -> Void)?
    var onNeedsEngine: (() -> Void)?
    @ObservationIgnored var registerProfile: ((Profile) -> Void)?
    @ObservationIgnored let snapshot: Snapshot
    @ObservationIgnored let apply: Apply
    @ObservationIgnored private let stateFile: URL
    @ObservationIgnored private let discardWebsiteApprovals: (UUID) throws -> Void
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
            stateFile: stateFile, snapshot: adapter.snapshot,
            apply: adapter.apply(_:key:for:profileID:),
            discardWebsiteApprovals: adapter.discardWebsiteApprovals(profileID:)
        )
        registerProfile = adapter.register
        let live = Set(profiles.map(\.id)).subtracting([Profile.privateID])
        if checkpointUnavailable {
            profilesForRecovery = live
        }
        pruneChannels(outside: live)
        if hasPendingOptOuts && !checkpointUnavailable {
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

    convenience init(
        stateFile: URL, read: @escaping Read, apply: @escaping Apply,
        discardWebsiteApprovals: @escaping (UUID) throws -> Void = { _ in }, clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(stateFile: stateFile, snapshot: { try read($0.category, $0.localProfileID) }, apply: apply,
                  discardWebsiteApprovals: discardWebsiteApprovals, clock: clock)
    }

    private init(
        stateFile: URL, snapshot: @escaping Snapshot, apply: @escaping Apply,
        discardWebsiteApprovals: @escaping (UUID) throws -> Void = { _ in }, clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.stateFile = stateFile
        self.snapshot = snapshot
        self.apply = apply
        self.discardWebsiteApprovals = discardWebsiteApprovals
        do {
            state = try State.read(from: stateFile)
        } catch CocoaError.fileReadNoSuchFile {
            state = State()
        } catch is DecodingError {
            state = State()
            notice = String(localized: "The saved sync settings could not be read. Choose what to share again.")
        } catch {
            state = State()
            checkpointUnavailable = true
            notice = String(localized: "Your saved sync settings are temporarily unavailable. Try again to load them.")
        }
        restorePendingOptOuts()
        if checkpointUnavailable {
            // The shared engine's heartbeat may be off until we can read this Mac's enrollments.
            checkpointRetry = Task { [weak self] in
                while self?.checkpointUnavailable == true {
                    do { try await clock.sleep(for: .seconds(30)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.beat()
                }
            }
        }
    }

    deinit {
        checkpointRetry?.cancel()
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
        try reloadStateIfNeeded()
        var proposed = MacSettingChannel(category: category, localProfileID: localProfileID, cloudProfileID: cloudProfileID)
        if let existing = channel(category, localProfileID: localProfileID), existing.zone != proposed.zone {
            throw Issue.duplicateLink
        }
        try finishOptOuts { zone, removal in
            zone == proposed.zone || (removal.category == category && removal.localProfileID == localProfileID)
        }
        if let existing = state.channels[proposed.zone] {
            guard existing.localProfileID == localProfileID else { throw Issue.duplicateLink }
            proposed = existing
        } else {
            // Older versions could detach a website channel while its proposals were still on disk.
            if category == .websiteSettings, let localProfileID {
                do {
                    try discardWebsiteApprovals(localProfileID)
                } catch {
                    pendingOptOuts[proposed.zone] = OptOut(proposed)
                    try save()
                    throw error
                }
            }
            // Observe the starting values before any account or baseline read can suspend.
            let values = try snapshot(&proposed)
            proposed.collect(values)
            updateChannel(proposed)
            do {
                try save()
            } catch {
                state.channels[proposed.zone] = nil
                throw error
            }
        }

        try await confirmEnrollment(proposed)
    }

    /// A confirmation from Settings belongs to the displayed enrollment, even if the account lookup suspends.
    func confirmEnrollment(_ channel: MacSettingChannel) async throws {
        guard state.channels[channel.zone]?.enrollment == channel.enrollment else { throw CancellationError() }
        onNeedsEngine?()
        let started = generation
        let user = try await verifyAccount(started)
        guard generation == started, let current = state.channels[channel.zone], current.enrollment == channel.enrollment else { throw CancellationError() }
        if current.needsConfirmation {
            let previous = state
            state.account = user
            state.channels[channel.zone]?.awaitingAccountConfirmation = false
            do {
                try save()
            } catch {
                state = previous
                throw error
            }
        }
        try await prepare(zone: channel.zone)
    }

    var hasPendingOptOuts: Bool {
        !pendingOptOuts.isEmpty
    }

    func isTurningOff(_ category: MacSettingsCategory, localProfileID: UUID?) -> Bool {
        pendingOptOuts.values.contains { $0.category == category && $0.localProfileID == localProfileID }
    }

    func disable(_ category: MacSettingsCategory, localProfileID: UUID?) throws {
        try reloadStateIfNeeded()
        if let channel = channel(category, localProfileID: localProfileID) {
            forget(zone: channel.zone)
        }
        try finishOptOuts { _, removal in removal.category == category && removal.localProfileID == localProfileID }
    }

    func forgetProfile(_ id: UUID) throws {
        try reloadStateIfNeeded()
        for channel in state.channels.values where channel.localProfileID == id {
            forget(zone: channel.zone)
        }
        try finishOptOuts { _, removal in removal.localProfileID == id }
    }

    private var confirmedChannels: [MacSettingChannel] {
        state.channels.values.filter { !$0.needsConfirmation }
    }

    var hasConfirmedChannels: Bool {
        !confirmedChannels.isEmpty
    }

    func beat() {
        // Retrying local cleanup works offline, even after the last opt-out.
        do {
            try reloadStateIfNeeded()
        } catch {
            reportError()
            return
        }
        if hasPendingOptOuts {
            optOutsToFinish.formUnion(pendingOptOuts.keys)
            do {
                try save()
            } catch {
                return
            }
        }
        guard work == nil, hasConfirmedChannels else { return }
        if engine == nil {
            onNeedsEngine?()
        }
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            let started = generation
            do {
                try await verifyAccount(started)
                var preparationFailed = false
                for zone in confirmedChannels.map(\.zone).sorted() where !ready.contains(zone) {
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
                } else if confirmedChannels.allSatisfy({ channel in
                    ready.contains(channel.zone) && channel.records.values.allSatisfy { $0.pending == nil }
                }) {
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
        let values = try snapshot(&channel)
        channel.collect(values)
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
            let values = try snapshot(&channel)
            channel.observed[key] = values[key]
        }
        state.channels[zone] = channel
        try save()
        queuePending(zone)
    }

    @discardableResult
    func verifyAccount(_ started: UUID) async throws -> String {
        guard let identity = engine as? any SyncAccountIdentity else { throw Issue.unavailable }
        do {
            let user = try await identity.currentAccountUser()
            guard !user.isEmpty, generation == started else { throw Issue.changedAccount }
            if let previous = state.account, previous != user {
                try resetAccount(to: user)
                throw Issue.changedAccount
            }
            trustedUser = user
            if accountNotifications != nil {
                ProviderKeySharing.shared.setAccountIdentifier(user)
            }
            return user
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
        guard state.channels[zone]?.needsConfirmation == false else { throw Issue.unavailable }
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

    private func finishOptOuts(where matches: (String, OptOut) -> Bool) throws {
        let zones = Set(pendingOptOuts.filter { matches($0.key, $0.value) }.keys)
        if !zones.isEmpty {
            try save(requiring: zones)
        }
    }

    func save() throws {
        try save(requiring: [])
    }

    private func save(requiring zones: Set<String>) throws {
        try reloadStateIfNeeded()
        sendingAllowed = false
        do {
            // Persist the revocation before touching the separate permission store.
            try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        } catch {
            if hasPendingOptOuts {
                try JSONEncoder().encode(pendingOptOuts).write(to: optOutFile, options: .atomic)
            }
            throw error
        }
        sendingAllowed = true
        let attempts = optOutsToFinish.union(zones)
        guard !attempts.isEmpty else { return }
        optOutsToFinish.removeAll()
        var remaining = pendingOptOuts
        var requiredFailure: Error?
        for zone in attempts {
            guard let removal = remaining[zone] else { continue }
            do {
                if removal.category == .websiteSettings, let id = removal.localProfileID {
                    try discardWebsiteApprovals(id)
                }
                remaining[zone] = nil
            } catch {
                if zones.contains(zone) {
                    requiredFailure = error
                }
            }
        }
        if remaining.count != pendingOptOuts.count {
            var completed = state
            completed.optOuts = remaining.isEmpty ? nil : remaining
            try JSONEncoder().encode(completed).write(to: stateFile, options: .atomic)
            state.optOuts = completed.optOuts
            if remaining.isEmpty && state.channels.isEmpty {
                notice = nil
            }
        }
        // The primary file now includes every unfinished revocation.
        try? FileManager.default.removeItem(at: optOutFile)
        if let requiredFailure {
            throw requiredFailure
        }
    }

    private var optOutFile: URL {
        stateFile.appendingPathExtension("opt-outs")
    }

    private func restorePendingOptOuts() {
        let hasJournal = FileManager.default.fileExists(atPath: optOutFile.path)
        if hasJournal {
            readOptOutJournal()
        }
        guard !checkpointUnavailable else { return }
        if hasPendingOptOuts {
            optOutsToFinish.formUnion(pendingOptOuts.keys)
            do { try save() } catch { reportError() }
        } else if hasJournal {
            try? FileManager.default.removeItem(at: optOutFile)
        }
    }

    private func readOptOutJournal() {
        do {
            restore(try JSONDecoder().decode([String: OptOut].self, from: Data(contentsOf: optOutFile)))
        } catch {
            // A damaged revocation list cannot authorize an old enrollment.
            for zone in state.channels.keys {
                forget(zone: zone)
            }
            notice = String(localized: "The saved sync settings could not be read. Choose what to share again.")
        }
    }

    private func restore(_ revoked: [String: OptOut]) {
        for (zone, removal) in revoked {
            if let current = state.channels[zone] {
                if current.enrollment == removal.enrollment {
                    forget(zone: zone)
                }
            } else if pendingOptOuts[zone] == nil && channel(removal.category, localProfileID: removal.localProfileID) == nil {
                pendingOptOuts[zone] = removal
            }
        }
    }

    /// Restore the checkpoint and replay any pending revocations before allowing a write.
    func reloadStateIfNeeded() throws {
        guard checkpointUnavailable else { return }
        let revoked = pendingOptOuts
        state = try State.read(from: stateFile)
        checkpointUnavailable = false
        checkpointRetry?.cancel()
        checkpointRetry = nil
        notice = nil
        restore(revoked)
        if FileManager.default.fileExists(atPath: optOutFile.path) {
            readOptOutJournal()
        }
        if let live = profilesForRecovery {
            pruneChannels(outside: live)
            profilesForRecovery = nil
        }
        optOutsToFinish.formUnion(pendingOptOuts.keys)
        // The first successful read may come from profile erasure instead of the heartbeat.
        if needsEngine && engine == nil {
            onNeedsEngine?()
        }
    }

    private func pruneChannels(outside live: Set<UUID>) {
        for channel in state.channels.values {
            if let id = channel.localProfileID, !live.contains(id) {
                forget(zone: channel.zone)
            }
        }
    }

    func forget(zone: String) {
        if let channel = state.channels.removeValue(forKey: zone) {
            pendingOptOuts[zone] = OptOut(channel)
            optOutsToFinish.insert(zone)
        }
        ready.remove(zone)
        loading[zone] = nil
        buffered[zone] = nil
        preparations.removeValue(forKey: zone)?.cancel()
        names = names.filter { $0.key.zone != zone }
    }

    func resetAccount(to user: String?) throws {
        generation = UUID()
        trustedUser = nil
        // An explicit account reset revokes every enrollment, even when its checkpoint is still inaccessible.
        if checkpointUnavailable {
            try? reloadStateIfNeeded()
        }
        checkpointUnavailable = false
        profilesForRecovery = nil
        for zone in Array(state.channels.keys) {
            forget(zone: zone)
        }
        state.account = user
        onAccountVerification?(.checking)
        try save()
        notice = String(localized: "The Apple Account changed. Choose what to sync with this account.")
    }

    func reportError() {
        if notice == nil && !hasPendingOptOuts {
            notice = String(localized: "Settings could not finish syncing. Try again on this Mac.")
        }
    }
}
