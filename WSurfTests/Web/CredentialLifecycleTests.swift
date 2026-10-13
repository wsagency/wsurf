// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import WSurf

// Crypto/lifecycle verification only: PRF material is a test-only in-memory key handed straight to `completeUnlock`. Nothing here
// is evidence of Apple provider or PRF behavior.

private nonisolated let allLockReasons: [CredentialLockReason] = [
    .manual, .profileSwitch, .screenLock, .sleep, .termination, .timeout,
]

/// The manager's clock for "the write landed, then the lease ran out": once armed, the first read after the store's files differ from the
/// baseline jumps the shared clock past any five-minute lease. `-shm` is excluded: readers update it without writing anything.
private nonisolated final class CommitTripwire: Sendable {
    private let directory: URL
    private let clock: TestClock
    private let state = Mutex<(baseline: [String: Data]?, fired: Bool)>((nil, false))

    init(directory: URL, clock: TestClock) {
        self.directory = directory
        self.clock = clock
    }

    func arm() {
        let image = Self.image(directory)
        state.withLock { $0.baseline = image }
    }

    var fired: Bool {
        state.withLock { $0.fired }
    }

    func now() -> ContinuousClock.Instant {
        let (baseline, done) = state.withLock { ($0.baseline, $0.fired) }
        if let baseline, !done, Self.image(directory) != baseline {
            state.withLock { $0.fired = true }
            clock.advance(by: .seconds(300))
        }
        return clock.now
    }

    private static func image(_ directory: URL) -> [String: Data] {
        ((try? VaultStoreFixture.directoryImage(of: directory)) ?? [:]).filter { !$0.key.hasSuffix("-shm") }
    }
}

struct CredentialLifecycleTests {
    /// One vault over a private store directory and an injected clock, locked, with the store's rows as the "disk bytes".
    private struct Fixture {
        let standalone: VaultManagerFixture.Standalone

        var proof: VaultUnlockProof {
            standalone.vault.proof
        }

        var clock: TestClock {
            standalone.clock
        }

        var directory: URL {
            standalone.environment.directory
        }

        /// A new, locked manager over the same store (not in the registry); `now` defaults to the fixture clock.
        func manager(now: (@Sendable () -> ContinuousClock.Instant)? = nil) -> CredentialManager {
            let clock = clock
            return VaultManagerFixture.manager(
                profileID: standalone.profile.id, vaultID: standalone.vault.vaultID, store: standalone.store,
                passkeys: standalone.passkeys, now: now ?? { clock.now }
            )
        }

        func bytes() throws -> [String: Data] {
            try VaultManagerFixture.rows(of: standalone.vault.vaultID, inDirectory: directory)
        }

        /// No connection outlives a store operation, so removing the directory needs no store close.
        func cleanup() {
            standalone.environment.cleanUp()
        }
    }

    private func account(username: String = "ada") -> CredentialAccount {
        VaultFixtures.account(username: username)
    }

    /// A real encrypted vault in a private store; revision 1 (2 when `accounts` is non-empty: seeding is one commit). The manager that seeded it is locked again.
    private func makeFixture(accounts: [CredentialAccount] = []) async throws -> Fixture {
        let standalone = try await VaultManagerFixture.standalone(unlocked: !accounts.isEmpty)
        if !accounts.isEmpty {
            try await VaultManagerFixture.save(accounts, in: standalone.vault)
            standalone.manager.lock(reason: .manual)
        }
        return Fixture(standalone: standalone)
    }

    private func unlock(_ manager: CredentialManager, _ f: Fixture) async throws {
        try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: manager.beginAccess())
    }

    // MARK: - Late completions

    @Test(arguments: allLockReasons)
    func lateUnlockCannotReopenRevokedProfile(reason: CredentialLockReason) async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()
        let original = try f.bytes()

        let pending = manager.beginAccess()
        manager.lock(reason: reason)
        await #expect(throws: CredentialVaultError.unauthorized) {
            try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: pending)
        }
        #expect(!manager.isUnlocked)
        #expect(try f.bytes() == original)
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.snapshot() }

        // Same inputs succeed under a fresh epoch, so the rejection above was the revocation.
        try await unlock(manager, f)
        #expect(manager.isUnlocked)
        #expect(manager.unlockCredentials.map(\.credentialID) == [f.proof.credentialID])
        #expect(try await manager.snapshot().revision == 2)
    }

    // A lock that lands while the registration prompt is open stops the creation before the store is written; a later creation is
    // unaffected and, like every creation, leaves the new vault locked.
    @Test(arguments: allLockReasons)
    func lateCreateCannotWriteAVault(reason: CredentialLockReason) async throws {
        let profile = try await VaultManagerFixture.newProfile()
        let passkeys = VaultPasskeys()
        passkeys.beforeRegister = { CredentialManager.lock(profileID: profile.id, reason: reason) }
        let anchor = VaultManagerFixture.anchor()
        do {
            await #expect(throws: (any Error).self) {
                _ = try await CredentialManager.createVault(
                    profile: profile, name: "Late", choice: .newPasskey(authorizedBy: nil), in: anchor, native: passkeys.native
                )
            }
            let store = try CredentialManager.store(for: profile)
            #expect(try await store.listing().isEmpty)

            passkeys.beforeRegister = nil
            let vaultID = try await CredentialManager.createVault(
                profile: profile, name: "Fresh", choice: .newPasskey(authorizedBy: nil), in: anchor, native: passkeys.native
            )
            #expect(try await store.listing().map(\.isUnlocked) == [false])
            #expect(!(try CredentialManager.forVault(profile, vaultID: vaultID)).isUnlocked)
        } catch {
            await VaultManagerFixture.cleanup(profile)
            throw error
        }
        await VaultManagerFixture.cleanup(profile)
    }

    @Test func discoverUnlocksRefreshesUnlockMetadataWithoutUnlocking() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()

        #expect(manager.unlockCredentials.isEmpty)
        try await manager.discoverUnlocks()
        #expect(manager.unlockCredentials.map(\.credentialID) == [f.proof.credentialID])
        #expect(manager.authorizationEpoch == nil)
        #expect(!manager.isUnlocked)
    }

    @Test func discoverUnlocksPropagatesCorruptionWithoutUnlocking() async throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        try Data("not a credential vault".utf8).write(to: environment.directory.appendingPathComponent("Credentials.vault"))
        let store = ProfileVaultStore(
            profileID: environment.profileID, directory: environment.directory, defaults: environment.defaults,
            now: { environment.clock.now }
        )
        let manager = VaultManagerFixture.manager(
            profileID: environment.profileID, vaultID: UUID(), store: store, passkeys: VaultPasskeys()
        )

        await #expect(throws: (any Error).self) { try await manager.discoverUnlocks() }
        #expect(manager.unlockCredentials.isEmpty)
        #expect(manager.authorizationEpoch == nil)
        #expect(!manager.isUnlocked)
        await store.close()
    }

    // MARK: - Five-minute ceiling

    @Test func authorizationExpiresAtFiveMinutes() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()
        try await unlock(manager, f)

        // Repeated use is "webpage activity": it must not move the deadline.
        f.clock.advance(by: .seconds(100))
        _ = try await manager.snapshot()
        f.clock.advance(by: .seconds(100))
        _ = try await manager.snapshot()
        f.clock.advance(by: .seconds(99))
        #expect(try await manager.snapshot().revision == 2)
        let epoch = try #require(manager.authorizationEpoch)
        #expect(try await manager.commit([account(username: "grace")], expectedRevision: 2, authorizedEpoch: epoch).revision == 3)

        let committed = try f.bytes()
        f.clock.advance(by: .seconds(1))
        await #expect(throws: CredentialVaultError.expired) { _ = try await manager.snapshot() }
        // A manager may lock itself once it observes expiry; either rejection keeps the store untouched.
        let operations: [() async throws -> Void] = [
            { _ = try await manager.commit([], expectedRevision: 3, authorizedEpoch: epoch) },
            { _ = try await manager.updatePasswordSavePolicy([], expectedRevision: 3, authorizedEpoch: epoch) },
        ]
        for operation in operations {
            do {
                try await operation()
                Issue.record("expired authorization accepted a mutation")
            } catch let error as CredentialVaultError {
                #expect(error == .expired || error == .unauthorized)
            }
        }
        #expect(try f.bytes() == committed)
    }

    @Test func authorizationPropertiesExpireBeforeSnapshotWhenTimerHasNotRun() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()
        try await unlock(manager, f)

        #expect(manager.authorizationEpoch != nil)
        f.clock.advance(by: .seconds(300))
        #expect(manager.authorizationEpoch == nil)
        #expect(!manager.isUnlocked)
    }

    @Test func authorizationPropertiesIgnoreCallerTaskCancellation() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()
        try await unlock(manager, f)
        let epoch = manager.authorizationEpoch

        let canceledRead = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(manager.authorizationEpoch == epoch)
            #expect(manager.isUnlocked)
        }
        await canceledRead.value
    }

    @Test func registrationUsesAssertionPRFAndRejectsOutputMismatch() throws {
        let credentialID = Data(repeating: 1, count: 32)
        let prfInput = Data(repeating: 2, count: 32)
        let registrationOutput = SymmetricKey(data: Data(repeating: 3, count: 32))
        let assertionOutput = SymmetricKey(data: Data(repeating: 3, count: 32))
        let registration = VaultUnlockRegistration(
            credentialID: credentialID,
            prfInput: prfInput,
            registrationOutput: registrationOutput
        )
        let assertion = VaultUnlockProof(credentialID: credentialID, prfInput: prfInput, prf: assertionOutput)

        let verified = try registration.verifiedAssertion(assertion)
        #expect(verified.prf.withUnsafeBytes { Data($0) } == Data(repeating: 3, count: 32))
        do {
            _ = try registration.verifiedAssertion(
                VaultUnlockProof(
                    credentialID: credentialID,
                    prfInput: prfInput,
                    prf: SymmetricKey(data: Data(repeating: 4, count: 32))
                )
            )
            Issue.record("accepted mismatching registration PRF")
        } catch let error as PasskeyUnlockError {
            if case .invalidNativeResult = error {
            } else {
                Issue.record("unexpected passkey error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test @MainActor func revokedAccessStopsRegistrationBeforeFollowupAssertion() async throws {
        let credentialID = Data(repeating: 7, count: 32)
        let clock = ContinuousClock()
        let access = VaultAccess(profileID: UUID(), epoch: 1, deadline: clock.now.advanced(by: .seconds(300)))
        access.revoke()
        let registration = VaultUnlockRegistration(
            credentialID: credentialID,
            prfInput: Data(repeating: 8, count: 32),
            registrationOutput: nil
        )
        let unlocker = PasskeyVaultUnlocker()

        do {
            _ = try await unlocker.verifyRegistration(registration, in: NSWindow()) {
                try access.checkAuthorization(at: clock.now)
            }
            Issue.record("revoked registration started an assertion")
        } catch PasskeyUnlockError.registrationCompleted(let id, _) {
            #expect(id == credentialID)
        } catch {
            Issue.record("unexpected registration follow-up error: \(error)")
        }
    }

    @Test @MainActor func fullUnlockVaultFailsCapacityPreflightBeforeProvider() async throws {
        let s = try await VaultManagerFixture.standalone(unlocked: false)
        defer { s.environment.cleanUp() }
        let manager = s.manager
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: s.vault.proof.credentialID, prf: s.vault.proof.prf, access: access)
        for seed in UInt8(2)...UInt8(32) {
            _ = try await manager.completeAddUnlock(VaultFixtures.proof(seed), using: access)
        }

        await #expect(throws: CredentialVaultError.oversized) {
            try await manager.preflightAddingUnlock(using: access)
        }
        #expect(manager.unlockCredentials.count == 32)
    }

    @Test @MainActor func committedAddReceiptSurvivesStaleAccessWithoutMetadataDuplication() async throws {
        let s = try await VaultManagerFixture.standalone(unlocked: false)
        defer { s.environment.cleanUp() }
        let first = s.vault.proof, added = VaultFixtures.proof(2)
        let tripwire = CommitTripwire(directory: s.environment.directory, clock: s.clock)
        let manager = VaultManagerFixture.manager(
            profileID: s.profile.id, vaultID: s.vault.vaultID, store: s.store, passkeys: s.passkeys, now: { tripwire.now() }
        )
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: access)
        tripwire.arm()

        let receipt = try await manager.completeAddUnlock(added, using: access)

        #expect(tripwire.fired)
        #expect(receipt.revision == 2)
        #expect(manager.authorizationEpoch == nil)
        #expect(manager.unlockCredentials.map(\.credentialID) == [first.credentialID])

        let fresh = manager.beginAccess()
        try await manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: fresh)
        #expect(manager.unlockCredentials.map(\.credentialID) == [first.credentialID, added.credentialID])
        await #expect(throws: (any Error).self) { _ = try await manager.completeAddUnlock(added, using: fresh) }
        #expect(manager.unlockCredentials.map(\.credentialID) == [first.credentialID, added.credentialID])
    }

    @Test @MainActor func committedRemoveReceiptSurvivesExpiredAccessWithoutMutatingMetadata() async throws {
        let s = try await VaultManagerFixture.standalone(unlocked: false)
        defer { s.environment.cleanUp() }
        let first = s.vault.proof, remaining = VaultFixtures.proof(2)
        let seeding = s.manager.beginAccess()
        try await s.manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: seeding)
        _ = try await s.manager.completeAddUnlock(remaining, using: seeding)
        s.manager.lock(reason: .manual)

        let tripwire = CommitTripwire(directory: s.environment.directory, clock: s.clock)
        let manager = VaultManagerFixture.manager(
            profileID: s.profile.id, vaultID: s.vault.vaultID, store: s.store, passkeys: s.passkeys, now: { tripwire.now() }
        )
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: access)
        tripwire.arm()

        let receipt = try await manager.completeRemoveUnlock(
            credentialID: first.credentialID,
            verifiedRemaining: remaining,
            using: access
        )

        #expect(tripwire.fired)
        #expect(receipt.revision == 3)
        #expect(manager.authorizationEpoch == nil)
        #expect(manager.unlockCredentials.map(\.credentialID) == [first.credentialID, remaining.credentialID])
        let fresh = manager.beginAccess()
        try await manager.completeUnlock(credentialID: remaining.credentialID, prf: remaining.prf, access: fresh)
        #expect(manager.unlockCredentials.map(\.credentialID) == [remaining.credentialID])
    }

    @Test func pendingUnlockExpiresAtFiveMinutes() async throws {
        let inTime = try await makeFixture(accounts: [account()])
        let late = try await makeFixture(accounts: [account()])
        defer { inTime.cleanup(); late.cleanup() }

        let acceptedManager = inTime.manager()
        let accepted = acceptedManager.beginAccess()
        inTime.clock.advance(by: .seconds(299))
        try await acceptedManager.completeUnlock(credentialID: inTime.proof.credentialID, prf: inTime.proof.prf, access: accepted)
        #expect(acceptedManager.isUnlocked)

        let rejectedManager = late.manager()
        let rejected = rejectedManager.beginAccess()
        late.clock.advance(by: .seconds(300))
        await #expect(throws: CredentialVaultError.expired) {
            try await rejectedManager.completeUnlock(credentialID: late.proof.credentialID, prf: late.proof.prf, access: rejected)
        }
        #expect(!rejectedManager.isUnlocked)
    }

    @Test func unlockExpiringAfterVaultAuthenticationIsNotActivated() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let original = try f.bytes()
        let calls = Mutex(0)
        let clock = f.clock
        let manager = f.manager(now: {
            let call = calls.withLock { count -> Int in
                count += 1
                return count
            }
            let instant = clock.now
            if call == 3 {
                clock.advance(by: .seconds(300))
            }
            return instant
        })
        let access = manager.beginAccess()

        await #expect(throws: CredentialVaultError.expired) {
            try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: access)
        }
        #expect(!manager.isUnlocked)
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.snapshot() }
        #expect(try f.bytes() == original)
    }

    // MARK: - Security events

    @Test(arguments: allLockReasons)
    func securityEventsRevokeAccess(reason: CredentialLockReason) async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: access)
        #expect(manager.isUnlocked)
        #expect(try await manager.snapshot().accounts.count == 1)
        let original = try f.bytes()
        let epoch = try #require(manager.authorizationEpoch)

        manager.lock(reason: reason)

        #expect(!manager.isUnlocked)
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.snapshot() }
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.commit([], expectedRevision: 2, authorizedEpoch: epoch) }
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.updatePasswordSavePolicy(["https://example.test"], expectedRevision: 2, authorizedEpoch: epoch) }
        // The revoked access cannot be replayed to reopen the vault.
        await #expect(throws: CredentialVaultError.unauthorized) {
            try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: access)
        }
        #expect(!manager.isUnlocked)
        #expect(try f.bytes() == original)

        try await unlock(manager, f)
        #expect(try await manager.snapshot().accounts.count == 1)
    }

    // A write prepared under one lease must never land under a later one: lock and re-unlock is a new epoch.
    @Test func writesPreparedUnderAnEarlierEpochAreRefusedAfterLockAndReunlock() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()
        try await unlock(manager, f)
        let prepared = try #require(manager.authorizationEpoch)
        let before = try f.bytes()

        manager.lock(reason: .manual)
        try await unlock(manager, f)
        let current = try #require(manager.authorizationEpoch)
        #expect(current != prepared)

        await #expect(throws: CredentialVaultError.unauthorized) {
            _ = try await manager.commit([account(username: "stale")], expectedRevision: 2, authorizedEpoch: prepared)
        }
        await #expect(throws: CredentialVaultError.unauthorized) {
            _ = try await manager.updatePasswordSavePolicy(["https://stale.example"], expectedRevision: 2, authorizedEpoch: prepared)
        }
        #expect(try f.bytes() == before)
        #expect(try await manager.snapshot().revision == 2)

        // The lease that is current still writes both kinds.
        #expect(try await manager.commit([account(username: "fresh")], expectedRevision: 2, authorizedEpoch: current).revision == 3)
        #expect(try await manager.updatePasswordSavePolicy(["https://fresh.example"], expectedRevision: 3, authorizedEpoch: current).revision == 4)
    }

    // MARK: - Isolation

    // A vault copied under another profile is refused by the store itself (VaultIntegrityTests head-wrong-profile, VaultMigrationTests
    // wrong-profile); what stays here is that one manager's lease never opens, locks or touches another's.
    @Test func profilesAndPrivatePagesStayIsolated() async throws {
        let a = try await makeFixture(accounts: [account()])
        let b = try await makeFixture(accounts: [account(username: "other")])
        defer { a.cleanup(); b.cleanup() }
        let first = a.manager()
        let second = b.manager()
        let accessOfFirst = first.beginAccess()
        try await first.completeUnlock(credentialID: a.proof.credentialID, prf: a.proof.prf, access: accessOfFirst)
        let secondBytes = try b.bytes()

        #expect(first.isUnlocked && !second.isUnlocked)
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await second.snapshot() }
        await #expect(throws: CredentialVaultError.unauthorized) {
            try await second.completeUnlock(credentialID: b.proof.credentialID, prf: b.proof.prf, access: accessOfFirst)
        }
        #expect(!second.isUnlocked)
        #expect(try b.bytes() == secondBytes)

        // Locking one profile does not lock the other.
        let third = try await makeFixture(accounts: [account()])
        defer { third.cleanup() }
        let independent = third.manager()
        try await unlock(independent, third)
        first.lock(reason: .profileSwitch)
        #expect(independent.isUnlocked)
        #expect(try await independent.snapshot().revision == 2)
    }

    @Test func privateBrowsingNeverGetsAManagerOrVault() throws {
        let privateDirectory = Profile.privateBrowsing().supportDirectory

        #expect(throws: CredentialVaultError.privateBrowsing) { try CredentialManager.store(for: Profile.privateBrowsing()) }
        #expect(throws: CredentialVaultError.privateBrowsing) {
            try CredentialManager.forVault(Profile.privateBrowsing(), vaultID: UUID())
        }
        for name in ["Credentials.store", "Credentials.vault"] {
            #expect(!FileManager.default.fileExists(atPath: privateDirectory.appendingPathComponent(name).path))
        }
    }

    @Test func forVaultSharesOneLockStatePerVault() async throws {
        let profile = try await VaultManagerFixture.newProfile("Work")
        let other = try await VaultManagerFixture.newProfile("Home")
        let vaultID = UUID()
        #expect(try CredentialManager.forVault(profile, vaultID: vaultID) === CredentialManager.forVault(profile, vaultID: vaultID))
        #expect(try CredentialManager.forVault(profile, vaultID: vaultID) !== CredentialManager.forVault(profile, vaultID: UUID()))
        #expect(try CredentialManager.forVault(profile, vaultID: vaultID) !== CredentialManager.forVault(other, vaultID: vaultID))
        #expect(try CredentialManager.store(for: profile) === CredentialManager.store(for: profile))
        // Creating a manager must not create the real profile directory; only a vault write may.
        #expect(!FileManager.default.fileExists(atPath: profile.supportDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: other.supportDirectory.path))
        await VaultManagerFixture.cleanup(profile)
        await VaultManagerFixture.cleanup(other)
    }

    /// Lock's queued actor cleanup must only clear the access it revoked, never a newer unlock.
    @Test func freshUnlockAfterLockCanRead() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = f.manager()
        try await unlock(manager, f)
        manager.lock(reason: .manual)
        try await unlock(manager, f)
        #expect(manager.isUnlocked)
        #expect(try await manager.snapshot().revision == 2)
    }

    @Test func retiredProfileRejectsPendingLateAndRecreatedAccess() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, passkeys, vaults in
            let (manager, vaultID, proof) = (vaults[0].manager, vaults[0].vaultID, vaults[0].proof)
            let pending = manager.beginAccess()

            await CredentialManager.retire(profileID: profile.id)

            #expect(throws: CredentialVaultError.unauthorized) { try CredentialManager.store(for: profile) }
            #expect(throws: CredentialVaultError.unauthorized) { try CredentialManager.forVault(profile, vaultID: vaultID) }
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: pending)
            }
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: manager.beginAccess())
            }
            #expect(!manager.isUnlocked)

            // The directory goes; nothing the retired profile owns brings it back.
            try FileManager.default.removeItem(at: profile.supportDirectory)
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await CredentialManager.createVault(
                    profile: profile, name: "Recreated", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor(),
                    native: passkeys.native
                )
            }
            #expect(!FileManager.default.fileExists(atPath: profile.supportDirectory.path))
        }
    }
}
