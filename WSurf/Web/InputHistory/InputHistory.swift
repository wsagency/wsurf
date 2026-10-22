// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Input History on the main actor: the stores of the profiles, what is unlocked, and the timers that purge and lock.
///
/// - Counts come from a directory listing and need no authentication. Decrypted entries exist only in `unlocked`.
/// - Entries are locked again two minutes after the list closes, and on every vault lock event (`CredentialManager.lock` and
///   `lockAll`), which also reaches profiles that have no vault.
/// - Nothing outside the browser's own UI may read this type. The agent and the MCP server never do (`InputHistoryIsolationTests`).
@MainActor
@Observable
final class InputHistory {
    typealias StoreFactory = @MainActor (_ profile: Profile, _ ownsSession: Bool) -> InputHistoryStore?

    /// Tests replace it to see the hooks that reach it.
    static var shared = InputHistory()

    static let relockDelay: Duration = .seconds(120)
    private static let retryDelay: Duration = .seconds(60)

    /// Entries per profile.
    private(set) var counts: [UUID: Int] = [:]
    /// Decrypted entries, newest first, per profile. Absent while the profile is locked.
    private(set) var unlocked: [UUID: [InputHistoryEntry]] = [:]

    @ObservationIgnored private let ownsSession: Bool
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let makeStore: StoreFactory
    @ObservationIgnored private var stores: [UUID: InputHistoryStore] = [:]
    @ObservationIgnored private var retired: Set<UUID> = []
    @ObservationIgnored private var purgeTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var relockTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var openLists: Set<UUID> = []
    /// Bumped by every lock, so an unlock that was waiting for authentication cannot publish after it.
    @ObservationIgnored private var generations: [UUID: Int] = [:]
    /// One chain of store work per profile, so a field's commits are applied in the order they were made.
    @ObservationIgnored private var tails: [UUID: Task<Void, Never>] = [:]

    /// The default clock keeps counting while the Mac sleeps, so a timer set before sleep fires when it is due on waking.
    init(
        ownsSession: Bool = AppDatabase.ownsSession,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeStore: @escaping StoreFactory = InputHistory.liveStore
    ) {
        self.ownsSession = ownsSession
        self.clock = clock
        self.now = now
        self.makeStore = makeStore
    }

    /// `<profile support directory>/InputHistory`. The private profile has none.
    static func directory(for profile: Profile) -> URL {
        profile.supportDirectory.appendingPathComponent("InputHistory", isDirectory: true)
    }

    /// Opening an entry needs the private key, which asks for Touch ID or the Mac password. Sealing needs only the public key. Both
    /// items are this-device-only and never sync.
    nonisolated static let privateKeyStorage = AutofillKeychainStorage(access: .userPresence)
    nonisolated static let publicKeyStorage = AutofillKeychainStorage(access: .whenUnlocked)

    /// The store on the real Keychain.
    static func liveStore(for profile: Profile, ownsSession: Bool) -> InputHistoryStore? {
        guard !profile.isPrivate else { return nil }
        return InputHistoryStore(
            profileID: profile.id,
            directory: directory(for: profile),
            privateKeys: privateKeyStorage,
            publicKeys: publicKeyStorage,
            ownsSession: ownsSession
        )
    }

    // MARK: - Stores

    /// Nil for the private profile and for a profile that is being erased: neither may have a store.
    func store(for profile: Profile) -> InputHistoryStore? {
        guard !profile.isPrivate, !retired.contains(profile.id) else { return nil }
        if let existing = stores[profile.id] {
            return existing
        }
        guard let store = makeStore(profile, ownsSession) else { return nil }
        stores[profile.id] = store
        // The lock events are observed once for the whole session. A profile that never used a vault must not miss them.
        CredentialManager.installObserversOnce()
        return store
    }

    func count(for profileID: UUID) -> Int {
        counts[profileID] ?? 0
    }

    // MARK: - Recording

    /// Remembers a field's value. Runs off the main actor and in order with the profile's other changes.
    func record(_ payload: InputHistoryPayload, key: String, profile: Profile, retention: InputHistoryRetention) {
        guard store(for: profile) != nil else { return }
        enqueue(profile.id) { try await $0.record(payload, key: key, retention: retention) }
    }

    func forget(key: String, profile: Profile) {
        guard store(for: profile) != nil else { return }
        enqueue(profile.id) { try await $0.forget(key) }
    }

    /// Waits for the changes that were already requested. For tests, and before a profile's directory is removed.
    func drain(profileID: UUID) async {
        await tails[profileID]?.value
    }

    // MARK: - Opening

    /// Decrypts the profile's entries. This is what asks for Touch ID or the Mac password. A lock that happens while the prompt
    /// is open discards the result.
    func unlock(_ profile: Profile) async throws {
        guard !profile.isPrivate else { throw InputHistoryError.privateBrowsing }
        guard let store = store(for: profile) else { throw InputHistoryError.unavailable }
        let id = profile.id
        let generation = generations[id, default: 0]
        relockTimers.removeValue(forKey: id)?.cancel()
        await drain(profileID: id)
        let entries = try await store.unlock(reason: String(localized: "Open Input History in WSurf."))
        guard generations[id, default: 0] == generation, !retired.contains(id) else { return }
        unlocked[id] = entries
        counts[id] = entries.count
        if !openLists.contains(id) {
            armRelock(id)
        }
    }

    /// The list is on screen: it stays unlocked.
    func listDidOpen(_ profileID: UUID) {
        openLists.insert(profileID)
        relockTimers.removeValue(forKey: profileID)?.cancel()
    }

    /// The list was closed: the entries are dropped two minutes later.
    func listDidClose(_ profileID: UUID) {
        openLists.remove(profileID)
        if unlocked[profileID] != nil {
            armRelock(profileID)
        }
    }

    private func armRelock(_ profileID: UUID) {
        relockTimers[profileID]?.cancel()
        relockTimers[profileID] = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.relockDelay)
            } catch {
                return
            }
            self?.lock(profileID: profileID)
        }
    }

    // MARK: - Locking

    /// Drops the profile's decrypted entries. The private key is never kept, so opening again asks again.
    func lock(profileID: UUID) {
        generations[profileID, default: 0] += 1
        relockTimers.removeValue(forKey: profileID)?.cancel()
        if unlocked[profileID] != nil {
            unlocked[profileID] = nil
        }
    }

    /// Locks every profile, including one with no vault.
    func lockAll() {
        for id in Set(stores.keys).union(unlocked.keys).union(generations.keys) {
            lock(profileID: id)
        }
    }

    // MARK: - Changing

    func delete(_ id: String, in profile: Profile) {
        unlocked[profile.id]?.removeAll { $0.id == id }
        guard store(for: profile) != nil else { return }
        enqueue(profile.id) { try await $0.delete(id) }
    }

    /// Deletes every entry and both keys.
    func clearAll(in profile: Profile) {
        if unlocked[profile.id] != nil {
            unlocked[profile.id] = []
        }
        guard store(for: profile) != nil else { return }
        enqueue(profile.id) { try await $0.clear() }
    }

    /// Entries move to the expiry the new retention gives them. The list locks first: what it shows no longer matches the files.
    func applyRetention(_ retention: InputHistoryRetention, in profile: Profile) {
        lock(profileID: profile.id)
        guard store(for: profile) != nil else { return }
        enqueue(profile.id) { try await $0.applyRetention(retention) }
    }

    /// Profile erasure: the entries and both keys go before the caller removes the directory, and the profile gets no store again.
    func erase(_ profile: Profile) async {
        guard !profile.isPrivate else { return }
        let id = profile.id
        retired.insert(id)
        lock(profileID: id)
        purgeTimers.removeValue(forKey: id)?.cancel()
        counts[id] = nil
        openLists.remove(id)
        await drain(profileID: id)
        tails[id] = nil
        let store = stores.removeValue(forKey: id) ?? makeStore(profile, ownsSession)
        try? await store?.erase()
    }

    // MARK: - Expiry

    /// Deletes what expired while the app was closed, before anything lists the profiles' entries.
    func purgeAllProfilesAtLaunch(_ profiles: [Profile]) {
        guard ownsSession else { return }
        for profile in profiles where !profile.isPrivate {
            guard FileManager.default.fileExists(atPath: Self.directory(for: profile).path), store(for: profile) != nil else { continue }
            enqueue(profile.id) { await $0.purge() }
        }
    }

    // One task per profile sleeps until its next expiry: nothing polls.
    private func schedulePurge(_ id: UUID, nextExpiry: Date?) {
        purgeTimers.removeValue(forKey: id)?.cancel()
        guard let nextExpiry, !retired.contains(id) else { return }
        let delay = nextExpiry.timeIntervalSince(now())
        purgeTimers[id] = Task { [weak self, clock] in
            do {
                // Already due yet still listed: the file could not be deleted. Try again later instead of spinning.
                try await clock.sleep(for: delay > 0 ? .seconds(delay) : Self.retryDelay)
            } catch {
                return
            }
            self?.enqueue(id) { await $0.purge() }
        }
    }

    // MARK: - Applying results

    private func enqueue(_ id: UUID, _ work: @escaping @Sendable (InputHistoryStore) async throws -> InputHistoryStatus) {
        guard let store = stores[id] else { return }
        let previous = tails[id]
        tails[id] = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard let status = try? await work(store) else { return }
            self?.apply(status, to: id)
        }
    }

    private func apply(_ status: InputHistoryStatus, to id: UUID) {
        guard !retired.contains(id) else { return }
        if counts[id] != status.count {
            counts[id] = status.count
        }
        if let entries = unlocked[id] {
            // Entries that expired while the list was open must not stay on screen.
            let current = now()
            let live = entries.filter { ($0.expiresAt ?? .distantFuture) > current }
            if live.count != entries.count {
                unlocked[id] = live
            }
        }
        schedulePurge(id, nextExpiry: status.nextExpiry)
    }
}
