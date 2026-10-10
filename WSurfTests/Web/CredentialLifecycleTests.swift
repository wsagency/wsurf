// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import CryptoKit
import Synchronization
import Testing

@testable import WSurf

// Crypto/lifecycle verification only: PRF material is a test-only in-memory key handed straight to
// `completeUnlock`/`completeCreate`. Nothing here is evidence of Apple provider or PRF behavior.

private nonisolated let allLockReasons: [CredentialLockReason] = [
    .manual, .profileSwitch, .screenLock, .sleep, .termination, .timeout,
]

struct CredentialLifecycleTests {
    private struct Fixture {
        let profile: Profile
        let directory: URL
        let proof: VaultUnlockProof
        let clock: TestClock

        var fileURL: URL { directory.appendingPathComponent("Credentials.vault", isDirectory: false) }

        func manager(now: (@Sendable () -> ContinuousClock.Instant)? = nil) throws -> CredentialManager {
            let clock = clock
            return try CredentialManager(profile: profile, directory: directory, now: now ?? { clock.now })
        }

        func bytes() throws -> Data { try Data(contentsOf: fileURL) }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func account(username: String = "ada") -> CredentialAccount {
        CredentialAccount(
            id: UUID(),
            username: username,
            displayName: nil,
            origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!],
            password: "secret",
            passkeys: [],
            totp: nil,
            exchangeAccountID: nil,
            exchangeItemID: nil
        )
    }

    /// Real encrypted vault file created through the Task 4 actor; revision 1 when `accounts` is non-empty.
    private func makeFixture(accounts: [CredentialAccount] = [], vaultExists: Bool = true, seed: UInt8 = 1) async throws -> Fixture {
        let clock = TestClock()
        let profile = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let proof = VaultUnlockProof(
            credentialID: Data(repeating: seed, count: 32),
            prfInput: Data(repeating: seed &+ 1, count: 32),
            prf: SymmetricKey(size: .bits256)
        )
        if vaultExists {
            let vault = try CredentialVault(profileID: profile.id, directory: directory, now: { clock.now })
            let access = VaultAccess(profileID: profile.id, epoch: 1, deadline: clock.now.advanced(by: .seconds(300)))
            try await vault.create(unlock: proof, access: access)
            if !accounts.isEmpty { _ = try await vault.commit(accounts, expectedRevision: 0, using: access) }
        }
        return Fixture(profile: profile, directory: directory, proof: proof, clock: clock)
    }

    private func unlock(_ manager: CredentialManager, _ f: Fixture) async throws {
        try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: manager.beginAccess())
    }

    // MARK: - Late completions

    @Test(arguments: allLockReasons)
    func lateUnlockCannotReopenRevokedProfile(reason: CredentialLockReason) async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = try f.manager()
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
        #expect(try await manager.snapshot().revision == 1)
    }

    @Test(arguments: allLockReasons)
    func lateCreateCannotWriteVaultFile(reason: CredentialLockReason) async throws {
        let f = try await makeFixture(vaultExists: false)
        defer { f.cleanup() }
        let manager = try f.manager()

        let pending = manager.beginAccess()
        manager.lock(reason: reason)
        await #expect(throws: CredentialVaultError.unauthorized) {
            try await manager.completeCreate(f.proof, access: pending)
        }
        #expect(!manager.isUnlocked)
        #expect(!FileManager.default.fileExists(atPath: f.fileURL.path))

        try await manager.completeCreate(f.proof, access: manager.beginAccess())
        #expect(manager.isUnlocked)
        #expect(FileManager.default.fileExists(atPath: f.fileURL.path))
        #expect(manager.unlockCredentials.map(\.credentialID) == [f.proof.credentialID])
    }

    @Test func vaultExistsRefreshesUnlockMetadataWithoutUnlocking() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = try f.manager()

        #expect(manager.unlockCredentials.isEmpty)
        #expect(try await manager.vaultExists())
        #expect(manager.unlockCredentials.map(\.credentialID) == [f.proof.credentialID])
        #expect(manager.authorizationEpoch == nil)
        #expect(!manager.isUnlocked)

        try FileManager.default.removeItem(at: f.fileURL)
        #expect(try await manager.vaultExists() == false)
        #expect(manager.unlockCredentials.isEmpty)
        #expect(manager.authorizationEpoch == nil)
    }
    @Test func vaultExistsPropagatesCorruptionWithoutUnlocking() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        try Data("not a credential vault".utf8).write(to: f.fileURL)
        let manager = try f.manager()

        await #expect(throws: CredentialVaultError.corruptVault) { try await manager.vaultExists() }
        #expect(manager.unlockCredentials.isEmpty)
        #expect(manager.authorizationEpoch == nil)
        #expect(!manager.isUnlocked)
    }

    @Test func committedCreateDoesNotActivateAccessExpiredDuringWrite() async throws {
        let f = try await makeFixture(vaultExists: false)
        defer { f.cleanup() }
        let fileURL = f.fileURL
        let clock = f.clock
        let manager = try f.manager(now: {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                clock.advance(by: .seconds(300))
            }
            return clock.now
        })

        try await manager.completeCreate(f.proof, access: manager.beginAccess())

        #expect(FileManager.default.fileExists(atPath: f.fileURL.path))
        #expect(manager.authorizationEpoch == nil)
        #expect(!manager.isUnlocked)
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.snapshot() }
    }

    // MARK: - Five-minute ceiling

    @Test func authorizationExpiresAtFiveMinutes() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = try f.manager()
        try await unlock(manager, f)

        // Repeated use is "webpage activity": it must not move the deadline.
        f.clock.advance(by: .seconds(100))
        _ = try await manager.snapshot()
        f.clock.advance(by: .seconds(100))
        _ = try await manager.snapshot()
        f.clock.advance(by: .seconds(99))
        #expect(try await manager.snapshot().revision == 1)
        #expect(try await manager.commit([account(username: "grace")], expectedRevision: 1).revision == 2)

        let committed = try f.bytes()
        f.clock.advance(by: .seconds(1))
        await #expect(throws: CredentialVaultError.expired) { _ = try await manager.snapshot() }
        // A manager may lock itself once it observes expiry; either rejection keeps the file untouched.
        for operation in [{ _ = try await manager.commit([], expectedRevision: 2) }, { _ = try await manager.updatePasswordSavePolicy([], expectedRevision: 2) }] as [() async throws -> Void] {
            do { try await operation(); Issue.record("expired authorization accepted a mutation") }
            catch let error as CredentialVaultError { #expect(error == .expired || error == .unauthorized) }
        }
        #expect(try f.bytes() == committed)
    }

    @Test func authorizationPropertiesExpireBeforeSnapshotWhenTimerHasNotRun() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = try f.manager()
        try await unlock(manager, f)

        #expect(manager.authorizationEpoch != nil)
        f.clock.advance(by: .seconds(300))
        #expect(manager.authorizationEpoch == nil)
        #expect(!manager.isUnlocked)
    }
    @Test func authorizationPropertiesIgnoreCallerTaskCancellation() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = try f.manager()
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
        let clock = TestClock()
        let profile = Profile(id: UUID(), name: "Full", symbol: "key", color: .blue)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func proof(_ seed: UInt8) -> VaultUnlockProof {
            VaultUnlockProof(
                credentialID: Data(repeating: seed, count: 32),
                prfInput: Data(repeating: seed &+ 1, count: 32),
                prf: SymmetricKey(size: .bits256)
            )
        }
        let first = proof(1)
        let vault = try CredentialVault(profileID: profile.id, directory: directory, now: { clock.now })
        let initialAccess = VaultAccess(profileID: profile.id, epoch: 1, deadline: clock.now.advanced(by: .seconds(300)))
        try await vault.create(unlock: first, access: initialAccess)
        for seed in UInt8(2)...UInt8(32) {
            _ = try await vault.addUnlock(proof(seed), using: initialAccess)
        }
        let manager = try CredentialManager(profile: profile, directory: directory, now: { clock.now })
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: access)

        await #expect(throws: CredentialVaultError.oversized) {
            try await manager.preflightAddingUnlock(using: access)
        }
        #expect(manager.unlockCredentials.count == 32)
    }

    @Test @MainActor func committedAddReceiptSurvivesStaleAccessWithoutMetadataDuplication() async throws {
        let clock = TestClock()
        let profile = Profile(id: UUID(), name: "Add", symbol: "key", color: .blue)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func proof(_ seed: UInt8) -> VaultUnlockProof {
            VaultUnlockProof(
                credentialID: Data(repeating: seed, count: 32),
                prfInput: Data(repeating: seed &+ 1, count: 32),
                prf: SymmetricKey(size: .bits256)
            )
        }
        let first = proof(1), added = proof(2)
        let vault = try CredentialVault(profileID: profile.id, directory: directory, now: { clock.now })
        let initialAccess = VaultAccess(profileID: profile.id, epoch: 1, deadline: clock.now.advanced(by: .seconds(300)))
        try await vault.create(unlock: first, access: initialAccess)
        let fileURL = directory.appendingPathComponent("Credentials.vault")
        let original = try Data(contentsOf: fileURL)
        let observedCommittedWrite = Mutex(false)
        let manager = try CredentialManager(profile: profile, directory: directory, now: {
            let changed = !observedCommittedWrite.withLock { $0 }
                && ((try? Data(contentsOf: fileURL)) != original)
            if changed {
                observedCommittedWrite.withLock { $0 = true }
                clock.advance(by: .seconds(300))
            }
            return clock.now
        })
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: access)

        let receipt = try await manager.completeAddUnlock(added, using: access)

        #expect(observedCommittedWrite.withLock { $0 })
        #expect(receipt.revision == 1)
        #expect(manager.authorizationEpoch == nil)
        #expect(manager.unlockCredentials.map(\.credentialID) == [first.credentialID])

        let fresh = manager.beginAccess()
        try await manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: fresh)
        #expect(manager.unlockCredentials.map(\.credentialID) == [first.credentialID, added.credentialID])
        await #expect(throws: (any Error).self) { _ = try await manager.completeAddUnlock(added, using: fresh) }
        #expect(manager.unlockCredentials.map(\.credentialID) == [first.credentialID, added.credentialID])
    }

    @Test @MainActor func committedRemoveReceiptSurvivesExpiredAccessWithoutMutatingMetadata() async throws {
        let clock = TestClock()
        let profile = Profile(id: UUID(), name: "Remove", symbol: "key", color: .blue)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func proof(_ seed: UInt8) -> VaultUnlockProof {
            VaultUnlockProof(
                credentialID: Data(repeating: seed, count: 32),
                prfInput: Data(repeating: seed &+ 1, count: 32),
                prf: SymmetricKey(size: .bits256)
            )
        }
        let first = proof(1), remaining = proof(2)
        let vault = try CredentialVault(profileID: profile.id, directory: directory, now: { clock.now })
        let initialAccess = VaultAccess(profileID: profile.id, epoch: 1, deadline: clock.now.advanced(by: .seconds(300)))
        try await vault.create(unlock: first, access: initialAccess)
        _ = try await vault.addUnlock(remaining, using: initialAccess)
        let fileURL = directory.appendingPathComponent("Credentials.vault")
        let original = try Data(contentsOf: fileURL)
        let observedCommittedWrite = Mutex(false)
        let manager = try CredentialManager(profile: profile, directory: directory, now: {
            let changed = !observedCommittedWrite.withLock { $0 }
                && ((try? Data(contentsOf: fileURL)) != original)
            if changed {
                observedCommittedWrite.withLock { $0 = true }
                clock.advance(by: .seconds(300))
            }
            return clock.now
        })
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: first.credentialID, prf: first.prf, access: access)

        let receipt = try await manager.completeRemoveUnlock(
            credentialID: first.credentialID,
            verifiedRemaining: remaining,
            using: access
        )

        #expect(observedCommittedWrite.withLock { $0 })
        #expect(receipt.revision == 2)
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

        let acceptedManager = try inTime.manager()
        let accepted = acceptedManager.beginAccess()
        inTime.clock.advance(by: .seconds(299))
        try await acceptedManager.completeUnlock(credentialID: inTime.proof.credentialID, prf: inTime.proof.prf, access: accepted)
        #expect(acceptedManager.isUnlocked)

        let rejectedManager = try late.manager()
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
        let manager = try f.manager(now: {
            let call = calls.withLock { count -> Int in
                count += 1
                return count
            }
            let instant = f.clock.now
            if call == 3 { f.clock.advance(by: .seconds(300)) }
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
        let manager = try f.manager()
        let access = manager.beginAccess()
        try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: access)
        #expect(manager.isUnlocked)
        #expect(try await manager.snapshot().accounts.count == 1)
        let original = try f.bytes()

        manager.lock(reason: reason)

        #expect(!manager.isUnlocked)
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.snapshot() }
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.commit([], expectedRevision: 1) }
        await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.updatePasswordSavePolicy(["https://example.test"], expectedRevision: 1) }
        // The revoked access cannot be replayed to reopen the vault.
        await #expect(throws: CredentialVaultError.unauthorized) {
            try await manager.completeUnlock(credentialID: f.proof.credentialID, prf: f.proof.prf, access: access)
        }
        #expect(!manager.isUnlocked)
        #expect(try f.bytes() == original)

        try await unlock(manager, f)
        #expect(try await manager.snapshot().accounts.count == 1)
    }

    // MARK: - Isolation

    @Test func profilesAndPrivatePagesStayIsolated() async throws {
        let a = try await makeFixture(accounts: [account()], seed: 1)
        let b = try await makeFixture(accounts: [account(username: "other")], seed: 5)
        let foreign = try await makeFixture(vaultExists: false, seed: 9)
        defer { a.cleanup(); b.cleanup(); foreign.cleanup() }
        let first = try a.manager()
        let second = try b.manager()
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

        // A copied vault is bound to its own profile and cannot be opened under another one.
        try FileManager.default.createDirectory(at: foreign.directory, withIntermediateDirectories: true)
        try a.bytes().write(to: foreign.fileURL)
        let stranger = try foreign.manager()
        await #expect(throws: (any Error).self) {
            try await stranger.completeUnlock(credentialID: a.proof.credentialID, prf: a.proof.prf, access: stranger.beginAccess())
        }
        #expect(!stranger.isUnlocked)

        // Locking one profile does not lock the other.
        let third = try await makeFixture(accounts: [account()], seed: 7)
        defer { third.cleanup() }
        let independent = try third.manager()
        try await unlock(independent, third)
        first.lock(reason: .profileSwitch)
        #expect(independent.isUnlocked)
        #expect(try await independent.snapshot().revision == 1)
    }

    @Test func privateBrowsingNeverGetsAManagerOrVault() async throws {
        let privateFile = Profile.privateBrowsing().supportDirectory.appendingPathComponent("Credentials.vault")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: CredentialVaultError.privateBrowsing) { try CredentialManager.forProfile(Profile.privateBrowsing()) }
        #expect(throws: CredentialVaultError.privateBrowsing) {
            try CredentialManager(profile: Profile.privateBrowsing(), directory: directory)
        }
        #expect(!FileManager.default.fileExists(atPath: privateFile.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func forProfileSharesOneLockStatePerProfile() throws {
        let profile = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let other = Profile(id: UUID(), name: "Home", symbol: "house", color: .green)
        defer { for p in [profile, other] { try? FileManager.default.removeItem(at: p.supportDirectory) } }
        #expect(try CredentialManager.forProfile(profile) === CredentialManager.forProfile(profile))
        #expect(try CredentialManager.forProfile(profile) !== CredentialManager.forProfile(other))
        // Creating a manager must not create the real profile directory; only a vault write may.
        #expect(!FileManager.default.fileExists(atPath: profile.supportDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: other.supportDirectory.path))
    }

    /// Lock's queued actor cleanup must only clear the access it revoked, never a newer unlock.
    @Test func freshUnlockAfterLockCanRead() async throws {
        let f = try await makeFixture(accounts: [account()])
        defer { f.cleanup() }
        let manager = try f.manager()
        try await unlock(manager, f)
        manager.lock(reason: .manual)
        try await unlock(manager, f)
        #expect(manager.isUnlocked)
        #expect(try await manager.snapshot().revision == 1)
    }

    @Test func retiredProfileRejectsPendingLateAndRecreatedAccess() async throws {
        let profile = Profile(id: UUID(), name: "Gone", symbol: "trash", color: .red)
        defer { try? FileManager.default.removeItem(at: profile.supportDirectory) }
        let manager = try CredentialManager.forProfile(profile)
        let pending = manager.beginAccess()
        let proof = VaultUnlockProof(credentialID: Data(repeating: 1, count: 32), prfInput: Data(repeating: 2, count: 32), prf: SymmetricKey(size: .bits256))

        await CredentialManager.retire(profileID: profile.id)

        #expect(throws: CredentialVaultError.unauthorized) { try CredentialManager.forProfile(profile) }
        await #expect(throws: CredentialVaultError.unauthorized) { try await manager.completeCreate(proof, access: pending) }
        await #expect(throws: CredentialVaultError.unauthorized) { try await manager.completeCreate(proof, access: manager.beginAccess()) }
        #expect(!manager.isUnlocked)
        #expect(!FileManager.default.fileExists(atPath: profile.supportDirectory.path))
    }
}
