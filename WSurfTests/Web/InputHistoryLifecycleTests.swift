// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import LocalAuthentication
import Synchronization
import Testing

@testable import WSurf

/// A private-key storage whose next read waits until the test lets it go, so a lock can land while authentication is open.
nonisolated final class InputHistoryBlockingStorage: AutofillSecureStorage {
    let memory = MemoryAutofillStorage()
    private let gate = DispatchSemaphore(value: 0)
    private let state = Mutex((armed: false, blocked: false))

    var isBlocked: Bool {
        state.withLock { $0.blocked }
    }

    func blockNextRead() {
        state.withLock { $0.armed = true }
    }

    func release() {
        gate.signal()
    }

    func read(service: String, context: LAContext) throws -> Data? {
        let shouldBlock = state.withLock { state -> Bool in
            defer { state.armed = false }
            if state.armed {
                state.blocked = true
            }
            return state.armed
        }
        if shouldBlock {
            gate.wait()
            state.withLock { $0.blocked = false }
        }
        return try memory.read(service: service, context: context)
    }

    func write(_ data: Data, service: String, context: LAContext) throws {
        try memory.write(data, service: service, context: context)
    }

    func erase(service: String) throws {
        try memory.erase(service: service)
    }

    func exists(service: String) throws -> Bool {
        try memory.exists(service: service)
    }
}

/// An `InputHistory` over temporary directories, in-memory keys, a clock the test moves and a wall clock the test moves.
@MainActor
final class InputHistoryHarness {
    final class Calls {
        var profiles: [UUID] = []
    }

    let wall: InputHistoryTestWallClock
    let clock: TestClock
    let calls: Calls
    let privateKeys: any AutofillSecureStorage
    let publicKeys: MemoryAutofillStorage
    private(set) var history: InputHistory
    private var profiles: [Profile] = []

    init(ownsSession: Bool = true, privateKeys: (any AutofillSecureStorage)? = nil) {
        let wall = InputHistoryTestWallClock()
        let clock = TestClock()
        let calls = Calls()
        let privateKeys = privateKeys ?? MemoryAutofillStorage()
        let publicKeys = MemoryAutofillStorage()
        self.wall = wall
        self.clock = clock
        self.calls = calls
        self.privateKeys = privateKeys
        self.publicKeys = publicKeys
        history = Self.makeHistory(
            ownsSession: ownsSession, wall: wall, clock: clock, calls: calls, privateKeys: privateKeys, publicKeys: publicKeys
        )
    }

    private static func makeHistory(
        ownsSession: Bool,
        wall: InputHistoryTestWallClock,
        clock: TestClock,
        calls: Calls,
        privateKeys: any AutofillSecureStorage,
        publicKeys: MemoryAutofillStorage
    ) -> InputHistory {
        InputHistory(
            ownsSession: ownsSession,
            clock: clock,
            now: { wall.now() },
            makeStore: { profile, owns in
                calls.profiles.append(profile.id)
                return InputHistoryStore(
                    profileID: profile.id,
                    directory: InputHistory.directory(for: profile),
                    privateKeys: privateKeys,
                    publicKeys: publicKeys,
                    ownsSession: owns,
                    now: { wall.now() }
                )
            }
        )
    }

    /// A new `InputHistory` over the same files and keys, as the next launch would have, and a cleared call log.
    func relaunch(ownsSession: Bool = true) -> InputHistory {
        calls.profiles = []
        history = Self.makeHistory(
            ownsSession: ownsSession, wall: wall, clock: clock, calls: calls, privateKeys: privateKeys, publicKeys: publicKeys
        )
        return history
    }

    func makeProfile() -> Profile {
        let profile = Profile(id: UUID(), name: "Test", symbol: "key", color: .blue)
        profiles.append(profile)
        return profile
    }

    /// Writes entries straight into the profile's store, bypassing the history's own work queue and timers.
    func seed(_ profile: Profile, _ values: [String], retention: InputHistoryRetention = .thirtyMinutes) async throws {
        let store = try #require(history.store(for: profile))
        for value in values {
            _ = try await store.record(.testSample(value), key: "seed-\(value)", retention: retention)
            wall.advance(1)
        }
    }

    func exists(_ profile: Profile) -> Bool {
        FileManager.default.fileExists(atPath: InputHistory.directory(for: profile).path)
    }

    func hasKeys(_ profile: Profile) throws -> Bool {
        let service = try #require(history.store(for: profile)).service
        return try privateKeys.exists(service: service) || publicKeys.exists(service: service)
    }

    func cleanUp() {
        for profile in profiles {
            try? FileManager.default.removeItem(at: profile.supportDirectory)
        }
    }
}

@MainActor
struct InputHistoryLifecycleTests {
    private func unlockedValues(_ history: InputHistory, _ profile: Profile) -> [String]? {
        history.unlocked[profile.id]?.map(\.payload.value)
    }

    // MARK: - Opening and locking

    @Test func unlockPublishesNewestFirstAndTheCount() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["one", "two", "three"])
        #expect(harness.history.unlocked[profile.id] == nil)

        harness.history.listDidOpen(profile.id)
        try await harness.history.unlock(profile)
        #expect(unlockedValues(harness.history, profile) == ["three", "two", "one"])
        #expect(harness.history.count(for: profile.id) == 3)
    }

    @Test func lockDropsDecryptedEntries() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let (first, second) = (harness.makeProfile(), harness.makeProfile())
        for profile in [first, second] {
            try await harness.seed(profile, ["secret"])
            harness.history.listDidOpen(profile.id)
            try await harness.history.unlock(profile)
        }

        harness.history.lock(profileID: first.id)
        #expect(harness.history.unlocked[first.id] == nil)
        #expect(unlockedValues(harness.history, second) == ["secret"])
        // The files stay: locking forgets what was decrypted, not what was recorded.
        #expect(harness.history.count(for: first.id) == 1)

        harness.history.lockAll()
        #expect(harness.history.unlocked.isEmpty)
        // Opening again asks again: nothing was kept that could open it.
        let reads = (harness.privateKeys as? MemoryAutofillStorage)?.readCount
        try await harness.history.unlock(first)
        #expect((harness.privateKeys as? MemoryAutofillStorage)?.readCount == reads.map { $0 + 1 })
    }

    @Test func aLockWhileAuthenticationIsOpenDiscardsTheResult() async throws {
        let storage = InputHistoryBlockingStorage()
        let harness = InputHistoryHarness(privateKeys: storage)
        defer {
            storage.release()
            harness.cleanUp()
        }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["secret"])

        storage.blockNextRead()
        let opening = Task { try await harness.history.unlock(profile) }
        #expect(await waitUntil { storage.isBlocked })
        harness.history.lock(profileID: profile.id)
        storage.release()
        try await opening.value
        #expect(harness.history.unlocked[profile.id] == nil)

        // A later unlock is not affected.
        try await harness.history.unlock(profile)
        #expect(unlockedValues(harness.history, profile) == ["secret"])
    }

    @Test func listClosingLocksTwoMinutesLater() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["secret"])
        harness.history.listDidOpen(profile.id)
        try await harness.history.unlock(profile)
        #expect(harness.clock.pendingCount == 0, "an open list is never locked by a timer")

        harness.history.listDidClose(profile.id)
        #expect(await waitUntil { harness.clock.pendingCount == 1 })
        harness.clock.advance(by: .seconds(119))
        #expect(harness.clock.pendingCount == 1)
        #expect(harness.history.unlocked[profile.id] != nil)

        harness.clock.advance(by: .seconds(1))
        #expect(await waitUntil { harness.history.unlocked[profile.id] == nil })
        #expect(harness.clock.pendingCount == 0)
    }

    @Test func reopeningTheListCancelsTheRelock() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["secret"])
        harness.history.listDidOpen(profile.id)
        try await harness.history.unlock(profile)
        harness.history.listDidClose(profile.id)
        #expect(await waitUntil { harness.clock.pendingCount == 1 })

        harness.history.listDidOpen(profile.id)
        #expect(await waitUntil { harness.clock.pendingCount == 0 })
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(unlockedValues(harness.history, profile) == ["secret"])
    }

    @Test func anUnlockWithoutAnOpenListLocksByItself() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["secret"])

        // The list was closed while the prompt was still open.
        try await harness.history.unlock(profile)
        #expect(await waitUntil { harness.clock.pendingCount == 1 })
        harness.clock.advance(by: .seconds(120))
        #expect(await waitUntil { harness.history.unlocked[profile.id] == nil })
    }

    // MARK: - Vault lock events

    @Test(arguments: LockTrigger.allCases)
    func vaultLockEventsLockInputHistoryOfProfilesWithoutAVault(trigger: LockTrigger) async throws {
        try await VaultManagerFixture.exclusive {
            let harness = InputHistoryHarness()
            let saved = InputHistory.shared
            InputHistory.shared = harness.history
            defer {
                InputHistory.shared = saved
                harness.cleanUp()
            }
            let (first, second) = (harness.makeProfile(), harness.makeProfile())
            for profile in [first, second] {
                try await harness.seed(profile, ["secret"])
                harness.history.listDidOpen(profile.id)
                try await harness.history.unlock(profile)
            }
            #expect(CredentialManager.unlockedManagers(for: first).isEmpty, "neither profile has a vault")

            trigger.fire(for: first)

            if trigger == .profileSwitch {
                // A profile switch locks the profile being left and leaves the others alone.
                #expect(await waitUntil { harness.history.unlocked[first.id] == nil })
                #expect(unlockedValues(harness.history, second) == ["secret"])
            } else {
                #expect(await waitUntil { harness.history.unlocked.isEmpty })
            }
        }
    }

    @Test func retiringAProfileLocksItsInputHistory() async throws {
        try await VaultManagerFixture.exclusive {
            let harness = InputHistoryHarness()
            let saved = InputHistory.shared
            InputHistory.shared = harness.history
            defer {
                InputHistory.shared = saved
                harness.cleanUp()
            }
            let profile = harness.makeProfile()
            try await harness.seed(profile, ["secret"])
            harness.history.listDidOpen(profile.id)
            try await harness.history.unlock(profile)

            await CredentialManager.retire(profileID: profile.id)
            #expect(harness.history.unlocked[profile.id] == nil)
        }
    }

    // MARK: - Who gets a store

    @Test func privateProfileGetsNoStoreAndRecordsNothing() async {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = Profile.privateBrowsing()

        #expect(harness.history.store(for: profile) == nil)
        harness.history.record(.testSample(), key: "a", profile: profile, retention: .thirtyMinutes)
        harness.history.forget(key: "a", profile: profile)
        await harness.history.drain(profileID: profile.id)
        await #expect(throws: InputHistoryError.privateBrowsing) { try await harness.history.unlock(profile) }

        #expect(harness.calls.profiles.isEmpty)
        #expect(harness.history.counts[profile.id] == nil)
        #expect(!harness.exists(profile))
    }

    @Test func recordsAreAppliedInTheOrderTheyWereMade() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()

        for index in 0..<20 {
            harness.history.record(.testSample("value-\(index)"), key: "doc#field", profile: profile, retention: .thirtyMinutes)
        }
        await harness.history.drain(profileID: profile.id)

        #expect(harness.history.count(for: profile.id) == 1)
        try await harness.history.unlock(profile)
        #expect(unlockedValues(harness.history, profile) == ["value-19"])
    }

    // MARK: - Expiry

    @Test func purgeTimerDeletesExpiredEntriesWithoutPolling() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        func settle(_ expected: Int) async -> Bool {
            await waitUntil { harness.history.counts[profile.id] == expected }
        }

        harness.history.record(.testSample("first"), key: "a", profile: profile, retention: .thirtyMinutes)
        await harness.history.drain(profileID: profile.id)
        #expect(harness.history.count(for: profile.id) == 1)
        #expect(await waitUntil { harness.clock.pendingCount == 1 }, "one task sleeps until the next expiry")

        // Ten minutes later a second entry comes in. The one timer is re-aimed at the entry that expires first.
        harness.wall.advance(10 * 60)
        harness.clock.advance(by: .seconds(10 * 60))
        harness.history.record(.testSample("second"), key: "b", profile: profile, retention: .thirtyMinutes)
        await harness.history.drain(profileID: profile.id)
        #expect(await settle(2))
        #expect(await waitUntil { harness.clock.pendingCount == 1 })

        harness.wall.advance(20 * 60)
        harness.clock.advance(by: .seconds(20 * 60))
        #expect(await settle(1))
        #expect(await waitUntil { harness.clock.pendingCount == 1 })

        harness.wall.advance(10 * 60)
        harness.clock.advance(by: .seconds(10 * 60))
        #expect(await settle(0))
        await harness.history.drain(profileID: profile.id)
        // Nothing left to expire: no timer, no files, no keys.
        #expect(await waitUntil { harness.clock.pendingCount == 0 })
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: InputHistory.directory(for: profile).path)) ?? []
        #expect(leftovers.isEmpty)
        #expect(try !harness.hasKeys(profile))
    }

    @Test func launchPurgeDeletesWhatExpiredWhileTheAppWasClosed() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let (expiring, lasting, never) = (harness.makeProfile(), harness.makeProfile(), harness.makeProfile())
        let untouched = harness.makeProfile()
        try await harness.seed(expiring, ["old"])
        try await harness.seed(lasting, ["old"])
        harness.wall.advance(25 * 60)
        try await harness.seed(lasting, ["new"])
        try await harness.seed(never, ["forever"], retention: .untilDeleted)
        harness.wall.advance(10 * 60)

        let relaunched = harness.relaunch()
        relaunched.purgeAllProfilesAtLaunch([expiring, lasting, never, untouched, .privateBrowsing()])
        for profile in [expiring, lasting, never] {
            await relaunched.drain(profileID: profile.id)
        }

        #expect(relaunched.counts[expiring.id] == 0)
        #expect(relaunched.counts[lasting.id] == 1)
        #expect(relaunched.counts[never.id] == 1)
        let expiredFiles = try FileManager.default.contentsOfDirectory(atPath: InputHistory.directory(for: expiring).path)
        #expect(expiredFiles.isEmpty)
        #expect(try !harness.hasKeys(expiring))
        #expect(try harness.hasKeys(lasting))
        // Only profiles that already have a directory get a store; the private profile never does.
        #expect(Set(harness.calls.profiles) == [expiring.id, lasting.id, never.id])
        try await relaunched.unlock(never)
        #expect(unlockedValues(relaunched, never) == ["forever"])
    }

    @Test func aSecondCopyDoesNotPurgeAtLaunch() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["owned"])
        harness.wall.advance(31 * 60)

        let second = harness.relaunch(ownsSession: false)
        second.purgeAllProfilesAtLaunch([profile])
        await second.drain(profileID: profile.id)

        #expect(harness.calls.profiles.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: InputHistory.directory(for: profile).path).count == 1)
        #expect(second.counts[profile.id] == nil)
    }

    @Test func retentionChangeLocksTheListAndMovesEntries() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["secret"])
        harness.history.listDidOpen(profile.id)
        try await harness.history.unlock(profile)
        let before = try #require(harness.history.unlocked[profile.id]?.first)

        harness.history.applyRetention(.oneWeek, in: profile)
        #expect(harness.history.unlocked[profile.id] == nil, "what the list shows no longer matches the files")
        await harness.history.drain(profileID: profile.id)
        try await harness.history.unlock(profile)

        let after = try #require(harness.history.unlocked[profile.id]?.first)
        #expect(after.id == before.id)
        #expect(after.expiresAt == after.createdAt.addingTimeInterval(7 * 24 * 3600))
    }

    // MARK: - Changing the list

    @Test func deleteAndClearUpdateTheOpenListAndTheFiles() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        harness.history.record(.testSample("one"), key: "a", profile: profile, retention: .thirtyMinutes)
        harness.history.record(.testSample("two"), key: "b", profile: profile, retention: .thirtyMinutes)
        await harness.history.drain(profileID: profile.id)
        harness.history.listDidOpen(profile.id)
        try await harness.history.unlock(profile)
        let newest = try #require(harness.history.unlocked[profile.id]?.first)

        harness.history.delete(newest.id, in: profile)
        #expect(harness.history.unlocked[profile.id]?.count == 1, "the row goes at once")
        await harness.history.drain(profileID: profile.id)
        #expect(harness.history.count(for: profile.id) == 1)

        harness.history.clearAll(in: profile)
        #expect(harness.history.unlocked[profile.id]?.isEmpty == true)
        await harness.history.drain(profileID: profile.id)
        #expect(harness.history.count(for: profile.id) == 0)
        #expect(!harness.exists(profile))
        #expect(try !harness.hasKeys(profile))
    }

    @Test func profileEraseRemovesKeysAndFiles() async throws {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        harness.history.record(.testSample("secret"), key: "a", profile: profile, retention: .untilDeleted)
        harness.history.listDidOpen(profile.id)
        try await harness.history.unlock(profile)
        #expect(harness.exists(profile))
        #expect(try harness.hasKeys(profile))
        let service = try #require(harness.history.store(for: profile)).service

        await harness.history.erase(profile)

        #expect(!harness.exists(profile))
        #expect(try !harness.privateKeys.exists(service: service) && !harness.publicKeys.exists(service: service))
        #expect(harness.history.unlocked[profile.id] == nil)
        #expect(harness.history.counts[profile.id] == nil)
        // An erased profile cannot grow a store again, so a late commit from one of its pages records nothing.
        #expect(harness.history.store(for: profile) == nil)
        harness.history.record(.testSample("late"), key: "a", profile: profile, retention: .thirtyMinutes)
        await harness.history.drain(profileID: profile.id)
        #expect(!harness.exists(profile))
        #expect(harness.publicKeys.itemCount == 0)
    }

    @Test func erasingThePrivateProfileTouchesNothing() async {
        let harness = InputHistoryHarness()
        defer { harness.cleanUp() }
        await harness.history.erase(.privateBrowsing())
        #expect(harness.calls.profiles.isEmpty)
        #expect(harness.publicKeys.eraseCount == 0)
    }
}
