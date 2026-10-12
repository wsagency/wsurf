// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import WSurf

// Task 6: grants, listing/discovery and the operation lock of every database operation (the second half of `VaultStoreUnlockTests`,
// split out to keep that file small). The shared plumbing (`unlockResult`, `secondVault`, ...) lives in VaultStoreUnlockTests.swift.

// MARK: - Parameters

private func isIntegrityFailure(_ error: (any Error)?) -> Bool {
    if case .integrityFailure = error as? CredentialStoreError {
        return true
    }
    return false
}

/// The error `body` throws when it runs in a task that is already cancelled (`nil` when it returns). Cancellation is only observed at
/// suspension points that check it (`Task.sleep`), so this tells a code path that sleeps from one that does not, with no clock.
private func inCancelledTask(_ body: @escaping @Sendable () async throws -> some Sendable) async -> (any Error)? {
    await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }.value
}

private nonisolated enum ListingLapse: CaseIterable, Sendable {
    case revoked, pastTheDeadline
}

/// Every public call that takes the database after an unlock (spec §15: every new-build operation takes the operation lock).
private nonisolated enum GuardedOperation: CaseIterable, Sendable {
    case snapshot, authorize, addUnlock, removeUnlock, updatePolicy

    /// `extra` is a second credential already enrolled on the vault (what `removeUnlock` removes); `access` holds the grant;
    /// `revision` is the vault's head revision, read by the caller because reading it opens the database.
    func run(
        _ store: ProfileVaultStore, _ f: VaultStoreFixture, _ access: VaultAccess, extra: VaultUnlockProof, revision: UInt64
    ) async throws {
        switch self {
        case .snapshot:
            _ = try await store.snapshot(vaultID: f.vaultID, using: access)
        case .authorize:
            try await store.authorize(
                vaultID: f.vaultID, FreshAuthorization(credentialID: f.proof.credentialID, prf: f.proof.prf), using: access
            )
        case .addUnlock:
            _ = try await store.addUnlock(vaultID: f.vaultID, VaultFixtures.proof(11), using: access)
        case .removeUnlock:
            _ = try await store.removeUnlock(
                vaultID: f.vaultID, credentialID: extra.credentialID, verifiedRemaining: f.proof, using: access
            )
        case .updatePolicy:
            _ = try await store.updatePasswordSavePolicy(
                vaultID: f.vaultID, ["https://c.example"], expectedRevision: revision, using: access
            )
        }
    }
}

private nonisolated enum AnchorChange: CaseIterable, Sendable {
    /// A present A3 that names another store: fail closed.
    case foreignWitness
    /// Store file, stub and A3 all gone: the open state is now `.firstRun`.
    case totalAnchorLoss
}

private nonisolated struct StorePragmas: Equatable, Sendable {
    let synchronous: Int
    let secureDelete: Int
    let foreignKeys: Int
    let journalMode: String
    let busyTimeout: Int
}

private nonisolated func readStorePragmas(_ db: Database) throws -> StorePragmas {
    StorePragmas(
        synchronous: try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1,
        secureDelete: try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? -1,
        foreignKeys: try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1,
        journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
        busyTimeout: try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? -1
    )
}

/// A busy/locked database is an operational failure: `storeBusy` or the database's own busy error, never a corruption verdict.
private nonisolated func isBusyFailure(_ error: (any Error)?) -> Bool {
    if let database = error as? DatabaseError {
        return database.resultCode == .SQLITE_BUSY || database.resultCode == .SQLITE_LOCKED
    }
    return (error as? CredentialStoreError) == .storeBusy
}

private nonisolated enum NonProvisional: CaseIterable, Sendable {
    case legacy, firstRun, resumeMigration

    func arrange(_ env: VaultTestEnvironment) throws -> StoreOpenState {
        let vault = env.directory.appendingPathComponent("Credentials.vault")
        switch self {
        case .legacy:
            let id = UUID()
            try v1Bytes(profileID: env.profileID, vaultID: id).write(to: vault)
            return .legacy(vaultID: id)
        case .firstRun:
            return .firstRun
        case .resumeMigration:
            let ids = StoreIDs(storeID: UUID(), profileID: env.profileID)
            try StoreAnchors.stubBytes(ids: ids).write(to: vault)
            let pending = try DatabaseQueue(path: env.directory.appendingPathComponent("Credentials.store.migrating").path)
            try pending.write { try StoreTables.create(in: $0, ids: ids) }
            try pending.close()
            return .resumeMigration(storeID: ids.storeID)
        }
    }
}

private nonisolated enum LockWay: CaseIterable, Sendable {
    case lockVault, lockIfUsing, lockAll
}

// MARK: - Tests

extension VaultStoreUnlockTests {
    // MARK: Grants

    @Test func sharedPasskeyOpensOnlyItsVault() async throws {
        let a = VaultFixtures.account(username: "ada", origin: "https://a.example")
        let b = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [a], secondVault: true, sharedProof: true, secondAccounts: [b]) { f in
            let second = try secondVault(of: f)
            // The same credential is enrolled on both vaults.
            #expect(try f.wrapperRows(of: f.vaultID).map(\.credentialID) == [f.proof.credentialID])
            #expect(try f.wrapperRows(of: second).map(\.credentialID) == [f.proof.credentialID])

            let (store, access) = try await f.unlocked()

            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(snapshot.accounts == [a])
            await expectNoGrant(store, second, access)
        }
    }

    @Test(arguments: NonProvisional.allCases)
    private func unlockInitializedRefusesEveryStateButProvisional(_ state: NonProvisional) async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let expected = try state.arrange(env)
            #expect(StoreAnchors.evaluate(directory: env.directory, profileID: env.profileID, defaults: env.defaults) == expected)
            let directoryBefore = try VaultStoreFixture.directoryImage(of: env.directory)
            let defaultsBefore = VaultStoreFixture.defaultsImage(of: env.defaults)
            let store = tracker.makeStore(env: env)
            let proof = VaultFixtures.proof()

            let failure: (any Error)?
            do {
                try await store.unlockInitialized(
                    vaultID: UUID(), credentialID: proof.credentialID, prf: proof.prf,
                    access: VaultAccess(profileID: env.profileID, epoch: 1, deadline: ContinuousClock().now.advanced(by: .seconds(300))),
                    verifying: nil, scratchWarning: nil
                )
                failure = nil
            } catch {
                failure = error
            }

            #expect(failure as? CredentialStoreError == .stateChanged)
            var after = try VaultStoreFixture.directoryImage(of: env.directory)
            if let lock = after.removeValue(forKey: "Credentials.lock") {
                #expect(lock.isEmpty)
            }
            var before = directoryBefore
            before.removeValue(forKey: "Credentials.lock")
            #expect(after == before)
            #expect(VaultStoreFixture.defaultsImage(of: env.defaults) == defaultsBefore)
        }
    }

    @Test(arguments: LockWay.allCases)
    private func lockRevokesGrants(_ way: LockWay) async throws {
        let a = VaultFixtures.account(username: "ada", origin: "https://a.example")
        let b = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [a], secondVault: true, secondAccounts: [b]) { f in
            let second = try secondVault(of: f)
            let store = f.makeStore()
            let accessA = f.beginAccess()
            let accessB = f.beginAccess()
            #expect(await unlockResult(f, store, vault: f.vaultID, access: accessA) == nil)
            #expect(await unlockResult(f, store, vault: second, access: accessB) == nil)
            _ = try await store.snapshot(vaultID: f.vaultID, using: accessA)
            _ = try await store.snapshot(vaultID: second, using: accessB)
            let now = ContinuousClock().now

            switch way {
            case .lockVault:
                await store.lock(vaultID: f.vaultID)
                await expectNoGrant(store, f.vaultID, accessA)
                _ = try await store.snapshot(vaultID: second, using: accessB)
            case .lockIfUsing:
                await store.lock(ifUsing: f.beginAccess())  // an access that holds no grant
                _ = try await store.snapshot(vaultID: f.vaultID, using: accessA)
                _ = try await store.snapshot(vaultID: second, using: accessB)
                await store.lock(ifUsing: accessA)
                await expectNoGrant(store, f.vaultID, accessA)
                #expect(!accessA.isAuthorized(at: now))
                _ = try await store.snapshot(vaultID: second, using: accessB)
            case .lockAll:
                await store.lockAll()
                await expectNoGrant(store, f.vaultID, accessA)
                await expectNoGrant(store, second, accessB)
                #expect(!accessA.isAuthorized(at: now))
                #expect(!accessB.isAuthorized(at: now))
            }
        }
    }

    @Test func authorizeNeedsAFreshAssertionFromAnEnrolledCredential() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 2) { f in
            let (store, access) = try await f.unlocked()
            let rowsBefore = try f.recordAndJournalImage()
            let revisionBefore = try f.headRevision(of: f.vaultID)

            let unenrolled = FreshAuthorization(credentialID: Data(repeating: 0xEE, count: 32), prf: f.proof.prf)
            await #expect(throws: CredentialVaultError.authenticationFailed) {
                try await store.authorize(vaultID: f.vaultID, unenrolled, using: access)
            }
            let wrongPRF = FreshAuthorization(credentialID: f.proof.credentialID, prf: SymmetricKey(size: .bits256))
            await #expect(throws: CredentialVaultError.authenticationFailed) {
                try await store.authorize(vaultID: f.vaultID, wrongPRF, using: access)
            }

            let fresh = FreshAuthorization(credentialID: f.proof.credentialID, prf: f.proof.prf)
            try await store.authorize(vaultID: f.vaultID, fresh, using: access)

            // It publishes and writes nothing: another access still cannot read, and no row or head moved.
            let stranger = f.beginAccess()
            await expectNoGrant(store, f.vaultID, stranger)
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await store.authorize(vaultID: f.vaultID, fresh, using: stranger)
            }
            #expect(try f.recordAndJournalImage() == rowsBefore)
            #expect(try f.headRevision(of: f.vaultID) == revisionBefore)
        }
    }

    // MARK: Listing and discovery

    @Test func listingExposesOrdinalsOnlyUntilUnlock() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true) { f in
            let second = try secondVault(of: f)
            let store = f.makeStore()

            func listing() async throws -> [VaultListing] {
                try await store.listing().sorted { $0.ordinal < $1.ordinal }
            }

            // Locked: ordinals and ids only; the names are sealed in the heads. Trash vaults are never listed.
            #expect(
                try await listing() == [
                    VaultListing(vaultID: f.vaultID, ordinal: 1, name: nil, isUnlocked: false, isVerified: false),
                    VaultListing(vaultID: second, ordinal: 2, name: nil, isUnlocked: false, isVerified: false),
                ]
            )

            #expect(await unlockResult(f, store, vault: f.vaultID, access: f.beginAccess()) == nil)
            #expect(
                try await listing() == [
                    VaultListing(vaultID: f.vaultID, ordinal: 1, name: f.sourceHead.name, isUnlocked: true, isVerified: true),
                    VaultListing(vaultID: second, ordinal: 2, name: nil, isUnlocked: false, isVerified: false),
                ]
            )

            #expect(await unlockResult(f, store, vault: second, access: f.beginAccess()) == nil)
            let both = try await listing()
            #expect(both.map(\.name) == [f.sourceHead.name, f.secondHead?.name])
            #expect(both.allSatisfy { $0.isUnlocked && $0.isVerified })
        }

        // A fail-closed state is not listed.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            f.env.defaults.set(UUID().uuidString, forKey: StoreAnchors.witnessKey)
            guard case .failClosed(let closed) = f.evaluate() else {
                Issue.record("a foreign A3 did not fail closed")
                return
            }
            let store = f.makeStore()
            await #expect(throws: CredentialStoreError.failClosed(closed)) {
                _ = try await store.listing()
            }
        }
    }

    @Test func discoveryReturnsWrapperPlaintextOnly() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true) { f in
            let second = try secondVault(of: f)
            let secondProof = f.proof(for: second)
            let store = f.makeStore()  // never unlocked: discovery needs no grant

            let first = try await store.discovery(vaultID: f.vaultID)
            #expect(first.vaultID == f.vaultID)
            #expect(first.unlocks.map(\.credentialID) == [f.proof.credentialID])
            #expect(first.unlocks.map(\.prfInput) == [f.proof.prfInput])

            let other = try await store.discovery(vaultID: second)
            #expect(other.vaultID == second)
            #expect(other.unlocks.map(\.credentialID) == [secondProof.credentialID])
            #expect(other.unlocks.map(\.prfInput) == [secondProof.prfInput])

            // Trash vaults are not vaults a user can pick, and unknown ids do not exist.
            await #expect(throws: CredentialStoreError.noSuchVault) { _ = try await store.discovery(vaultID: f.trashID) }
            await #expect(throws: CredentialStoreError.noSuchVault) { _ = try await store.discovery(vaultID: UUID()) }
        }
    }

    // MARK: listing/discovery honour the operation lock and the grant's authorization

    @Test func listingAndDiscoveryWaitForTheOperationLockAndWriteNothingWhileItIsHeld() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true) { f in
            let second = try secondVault(of: f)
            let hold = try await OperationLock.acquire(in: f.directory, mode: .exclusive)
            let store = f.makeStore(lockWait: Self.lockWait)
            let before = try settledImage(f)
            let sidecarsBefore = try sidecars(f)
            let defaultsBefore = f.defaultsImage()

            // Each call keeps trying for the injected `lockWait` (150 ms) and then refuses, and never reads while another process holds
            // the lock. The elapsed time only has a lower bound: an upper bound measures how fast the test process can resume a sleeping
            // task, which the other (blocking) tests in a parallel run starve for seconds, so "bounded by `lockWait`, never the default
            // 5 s" is proven by the two scheduler-independent probes below instead.
            let started = ContinuousClock().now
            await #expect(throws: CredentialStoreError.storeBusy) { _ = try await store.listing() }
            await #expect(throws: CredentialStoreError.storeBusy) { _ = try await store.discovery(vaultID: f.vaultID) }
            #expect(ContinuousClock().now - started >= Self.lockWait * 2)

            // Honours the injected wait: with `.zero` the refusal comes before any sleep, so a task that is already cancelled still gets
            // `storeBusy`; a store that used any positive wait (the 5 s default included) would reach `Task.sleep` and throw cancellation.
            let impatient = f.makeStore(lockWait: .zero)
            #expect(await inCancelledTask { try await impatient.listing() } as? CredentialStoreError == .storeBusy)
            #expect(await inCancelledTask { try await impatient.discovery(vaultID: f.vaultID) } as? CredentialStoreError == .storeBusy)
            // And it does wait: a positive wait sleeps between attempts, so the same cancelled task is cancelled out of that sleep.
            #expect(await inCancelledTask { try await store.listing() } is CancellationError)
            #expect(await inCancelledTask { try await store.discovery(vaultID: f.vaultID) } is CancellationError)

            #expect(try sidecars(f) == sidecarsBefore)
            #expect(try settledImage(f) == before)
            #expect(f.defaultsImage() == defaultsBefore)

            // Once the holder is gone both calls work on the same store, and neither keeps the lock.
            hold.release()
            #expect(try await store.listing().map(\.vaultID).sorted { $0.uuidString < $1.uuidString } == [f.vaultID, second].sorted { $0.uuidString < $1.uuidString })
            #expect(try await store.discovery(vaultID: f.vaultID).unlocks.map(\.credentialID) == [f.proof.credentialID])
            #expect(!operationLockIsHeld(in: f.directory))
        }
    }

    @Test func listingAndDiscoveryPreflightLeaveEveryNonProvisionalStateUntouched() async throws {
        // Fail closed: the exact error, and not a byte or preference changes.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            f.env.defaults.set(UUID().uuidString, forKey: StoreAnchors.witnessKey)
            guard case .failClosed(let closed) = f.evaluate() else {
                Issue.record("a foreign A3 did not fail closed")
                return
            }
            let before = try settledImage(f)
            let defaultsBefore = f.defaultsImage()
            let store = f.makeStore()

            await #expect(throws: CredentialStoreError.failClosed(closed)) { _ = try await store.listing() }
            await #expect(throws: CredentialStoreError.failClosed(closed)) { _ = try await store.discovery(vaultID: f.vaultID) }

            #expect(try settledImage(f) == before)
            #expect(f.defaultsImage() == defaultsBefore)
        }

        // Legacy, first run and resume: whatever the answer, nothing is created (no store file, no sidecar, no preference).
        for state in NonProvisional.allCases {
            try await VaultStoreFixture.withEnvironment { env, tracker in
                let expected = try state.arrange(env)
                #expect(StoreAnchors.evaluate(directory: env.directory, profileID: env.profileID, defaults: env.defaults) == expected)
                var before = try VaultStoreFixture.directoryImage(of: env.directory)
                before.removeValue(forKey: "Credentials.lock")
                let defaultsBefore = VaultStoreFixture.defaultsImage(of: env.defaults)
                let store = tracker.makeStore(env: env)

                _ = try? await store.listing()
                _ = try? await store.discovery(vaultID: UUID())

                var after = try VaultStoreFixture.directoryImage(of: env.directory)
                if let lock = after.removeValue(forKey: "Credentials.lock") {
                    #expect(lock.isEmpty)
                }
                #expect(after == before, "\(state)")
                #expect(VaultStoreFixture.defaultsImage(of: env.defaults) == defaultsBefore, "\(state)")
            }
        }
    }

    @Test(arguments: ListingLapse.allCases)
    private func listingForgetsTheNameAndUnlockOnceTheAccessIsRevokedOrPastItsDeadline(_ lapse: ListingLapse) async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true) { f in
            let second = try secondVault(of: f)
            let clock = ManualClock()
            let store = f.makeStore(now: { clock.now() })
            let access = VaultAccess(profileID: f.env.profileID, epoch: 1, deadline: clock.base.advanced(by: .seconds(300)))
            let secondAccess = VaultAccess(profileID: f.env.profileID, epoch: 2, deadline: clock.base.advanced(by: .seconds(3000)))
            #expect(await unlockResult(f, store, vault: f.vaultID, access: access) == nil)
            #expect(await unlockResult(f, store, vault: second, access: secondAccess) == nil)

            func listing() async throws -> [VaultListing] {
                try await store.listing().sorted { $0.ordinal < $1.ordinal }
            }

            // Initially (a valid access, before the deadline) both names and the unlocked state are visible.
            let initial = try await listing()
            #expect(initial.map(\.name) == [f.sourceHead.name, f.secondHead?.name])
            #expect(initial.map(\.isUnlocked) == [true, true])

            switch lapse {
            case .revoked:
                access.revoke()
            case .pastTheDeadline:
                clock.advance(by: .seconds(301))
            }

            // The lapsed vault shows its ordinal only; the other vault's still-valid grant is unaffected.
            let after = try await listing()
            #expect(after.map(\.vaultID) == [f.vaultID, second])
            #expect(after[0].name == nil)
            #expect(after[0].isUnlocked == false)
            #expect(after[1].name == f.secondHead?.name)
            #expect(after[1].isUnlocked)
        }
    }

    // MARK: every database operation takes the operation lock (spec §15) and re-reads the anchors first

    @Test(arguments: GuardedOperation.allCases)
    private func everyDatabaseOperationWaitsForTheOperationLockAndWritesNothing(_ operation: GuardedOperation) async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 2) { f in
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()
            #expect(await unlockResult(f, store, access: access) == nil)
            let extra = VaultFixtures.proof(9)
            _ = try await store.addUnlock(vaultID: f.vaultID, extra, using: access)
            let impatient = f.makeStore(lockWait: .zero)
            let impatientAccess = f.beginAccess()
            #expect(await unlockResult(f, impatient, access: impatientAccess) == nil)
            let imageBefore = try f.headWriteImage()
            let revision = try f.headRevision(of: f.vaultID)
            let defaultsBefore = f.defaultsImage()

            let hold = try await OperationLock.acquire(in: f.directory, mode: .exclusive)
            let started = ContinuousClock().now
            var failure: (any Error)?
            do {
                try await operation.run(store, f, access, extra: extra, revision: revision)
            } catch {
                failure = error
            }
            let elapsed = ContinuousClock().now - started
            hold.release()

            // The injected `lockWait` is honoured, nothing logical changed. The elapsed time only has a lower bound (an upper bound
            // measures how fast a sleeping task resumes, which blocking tests in a parallel run starve for seconds); the bound itself
            // is the two probes below, which need no clock.
            #expect(failure as? CredentialStoreError == .storeBusy, "\(operation)")
            #expect(elapsed >= Self.lockWait, "\(operation)")
            #expect(try f.headWriteImage() == imageBefore, "\(operation)")
            #expect(f.defaultsImage() == defaultsBefore, "\(operation)")

            // `.zero` refuses before any sleep (a cancelled task still gets `storeBusy`; the 5 s default would reach `Task.sleep`), while
            // the 150 ms store does sleep between attempts (the cancelled task is cancelled out of it).
            let busy = try await OperationLock.acquire(in: f.directory, mode: .exclusive)
            #expect(
                await inCancelledTask { try await operation.run(impatient, f, impatientAccess, extra: extra, revision: revision) }
                    as? CredentialStoreError == .storeBusy,
                "\(operation)"
            )
            #expect(
                await inCancelledTask { try await operation.run(store, f, access, extra: extra, revision: revision) } is CancellationError,
                "\(operation)"
            )
            busy.release()
            #expect(try f.headWriteImage() == imageBefore, "\(operation)")
            #expect(f.defaultsImage() == defaultsBefore, "\(operation)")

            // The refusal costs nothing: the grant is kept across operations, so the same call now runs, and the lock is not left held.
            try await operation.run(store, f, access, extra: extra, revision: revision)
            #expect(!operationLockIsHeld(in: f.directory), "\(operation)")
        }
    }

    @Test(arguments: GuardedOperation.allCases, AnchorChange.allCases)
    private func anchorsChangedAfterTheUnlockRefuseEveryDatabaseOperationBeforeTouchingTheDatabase(
        _ operation: GuardedOperation, _ change: AnchorChange
    ) async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 2) { f in
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()
            #expect(await unlockResult(f, store, access: access) == nil)
            let extra = VaultFixtures.proof(9)
            _ = try await store.addUnlock(vaultID: f.vaultID, extra, using: access)
            let storeFile = f.directory.appendingPathComponent("Credentials.store", isDirectory: false)
            let imageBefore = try f.headWriteImage()
            let revision = try f.headRevision(of: f.vaultID)

            let expected: CredentialStoreError
            switch change {
            case .foreignWitness:
                f.env.defaults.set(UUID().uuidString, forKey: StoreAnchors.witnessKey)
                guard case .failClosed(let closed) = f.evaluate() else {
                    Issue.record("a foreign A3 did not fail closed")
                    return
                }
                expected = .failClosed(closed)
            case .totalAnchorLoss:
                try FileManager.default.removeItem(at: storeFile)
                try FileManager.default.removeItem(at: f.vaultFile)
                f.env.defaults.removeObject(forKey: StoreAnchors.witnessKey)
                #expect(f.evaluate() == .firstRun)
                expected = .stateChanged
            }
            let filesBefore = Set(try f.directoryImage().keys)
            let defaultsBefore = f.defaultsImage()

            var failure: (any Error)?
            do {
                try await operation.run(store, f, access, extra: extra, revision: revision)
            } catch {
                failure = error
            }

            // The exact refusal, and the database was never opened: no store file, sidecar or other file was created.
            #expect(failure as? CredentialStoreError == expected, "\(operation) / \(change)")
            let created = Set(try f.directoryImage().keys).subtracting(filesBefore).subtracting(["Credentials.lock"])
            #expect(created.isEmpty, "\(operation) / \(change) created \(created)")
            #expect(f.defaultsImage() == defaultsBefore, "\(operation) / \(change)")
            switch change {
            case .foreignWitness:
                #expect(try f.headWriteImage() == imageBefore, "\(operation)")
            case .totalAnchorLoss:
                #expect(!FileManager.default.fileExists(atPath: storeFile.path), "\(operation)")
            }
            #expect(!operationLockIsHeld(in: f.directory), "\(operation) / \(change)")
        }
    }

    // MARK: the pool's pragmas and operational database errors

    @Test func poolsRunSynchronousFullOnTheWriterAndOnEveryReader() async throws {
        // GRDB 7.11.1 `DatabasePool.init` sets the writer to `synchronous=NORMAL` after `prepareDatabase`; the store sets FULL
        // afterwards, so the actual connections (not the configuration) must report it.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let store = f.makeStore()
            let pool = try await store.openPool()
            let writer = try await pool.write(readStorePragmas)
            let reader = try await pool.read(readStorePragmas)
            try pool.close()

            let expected = StorePragmas(
                synchronous: 2, secureDelete: 1, foreignKeys: 1, journalMode: "wal", busyTimeout: StoreFormat.busyTimeoutMS
            )
            #expect(writer == expected, "writer")
            #expect(reader == expected, "reader")
        }
    }

    @Test func anOperationalDatabaseErrorIsNeverReportedAsCorruption() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 2) { f in
            let (store, access) = try await f.unlocked()
            let before = try f.headWriteImage()
            let headBefore = try f.headRevision(of: f.vaultID)

            // Another connection holds the database write lock (an immediate transaction parked on a thread, since GRDB refuses
            // to return from an access with a transaction still open): the store's `BEGIN IMMEDIATE` runs into its busy timeout.
            let holder = try DatabaseQueue(path: f.directory.appendingPathComponent("Credentials.store", isDirectory: false).path)
            defer { try? holder.close() }
            let (heldSignal, held) = AsyncStream<Void>.makeStream()
            let (finishedSignal, finished) = AsyncStream<Void>.makeStream()
            let letGo = DispatchSemaphore(value: 0)
            Thread {
                try? holder.writeWithoutTransaction { db in
                    try db.inTransaction(.immediate) {
                        held.yield()
                        letGo.wait()
                        return .rollback
                    }
                }
                finished.yield()
            }.start()
            for await _ in heldSignal {
                break
            }
            var failure: (any Error)?
            do {
                _ = try await store.addUnlock(vaultID: f.vaultID, VaultFixtures.proof(9), using: access)
            } catch {
                failure = error
            }
            letGo.signal()
            for await _ in finishedSignal {
                break
            }

            #expect(isBusyFailure(failure), "\(String(describing: failure))")
            #expect(!isIntegrityFailure(failure))
            #expect(try f.headWriteImage() == before)

            // Nothing was lost: the grant is intact and the write goes through once the lock is gone.
            let receipt = try await store.addUnlock(vaultID: f.vaultID, VaultFixtures.proof(9), using: access)
            #expect(receipt.revision == headBefore + 1)
        }
    }

    @Test func aFullDiskInsideTheBodyIsDiskFullNotIntegrityFailure() async throws {
        // A real SQLITE_FULL from an inner statement (a page cap smaller than the insert needs), through the real `mapIntegrity`.
        let queue = try DatabaseQueue()
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(x BLOB)")
            let pages = try #require(try Int.fetchOne(db, sql: "PRAGMA page_count"))
            try db.execute(sql: "PRAGMA max_page_count = \(pages)")
            #expect(throws: CredentialStoreError.diskFull) {
                try mapIntegrity(3) { try db.execute(sql: "INSERT INTO t VALUES (zeroblob(100000))") }
            }
        }
    }
}
