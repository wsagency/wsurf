// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Darwin
import Foundation
import GRDB
import Synchronization
import Testing

@testable import WSurf

// The per-vault `CredentialManager` and its profile-level registry, asserted through real managers over real stores. Only the native
// passkey prompt is stubbed (`VaultPasskeys`).

/// Every event that locks the whole session or one profile, with the reason its managers must report.
nonisolated enum LockTrigger: CaseIterable, Sendable {
    case profileSwitch, lockAll, sleep, sessionResign, screenLocked, termination

    var reason: CredentialLockReason {
        switch self {
        case .profileSwitch:
            .profileSwitch
        case .lockAll:
            .manual
        case .sleep:
            .sleep
        case .sessionResign, .screenLocked:
            .screenLock
        case .termination:
            .termination
        }
    }

    @MainActor
    func fire(for profile: Profile) {
        switch self {
        case .profileSwitch:
            CredentialManager.lock(profileID: profile.id, reason: .profileSwitch)
        case .lockAll:
            CredentialManager.lockAll(reason: .manual)
        case .sleep:
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        case .sessionResign:
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        case .screenLocked:
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.apple.screenIsLocked"), object: nil, userInfo: nil, deliverImmediately: true
            )
        case .termination:
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        }
    }
}

/// `now()` that advances 300 ms on every read, so a store's unlock crosses its "verifying" threshold at the first cancellation poll.
private nonisolated final class SteppingClock: Sendable {
    private let base = ContinuousClock().now
    private let reads = Mutex(0)

    func now() -> ContinuousClock.Instant {
        let count = reads.withLock { value -> Int in
            value += 1
            return value
        }
        return base.advanced(by: .milliseconds(300) * count)
    }
}

/// Cancels the task that runs an unlock from inside its `verifying` callback, which fires before the task handle exists to capture:
/// whichever of `fire`/`attach` comes second does the cancelling.
private nonisolated final class Canceller: Sendable {
    private let state = Mutex<(task: Task<Void, any Error>?, fired: Bool)>((nil, false))

    func fire() {
        let task = state.withLock { state -> Task<Void, any Error>? in
            state.fired = true
            return state.task
        }
        task?.cancel()
    }

    func attach(_ task: Task<Void, any Error>) {
        let fired = state.withLock { state -> Bool in
            state.task = task
            return state.fired
        }
        if fired {
            task.cancel()
        }
    }
}

private nonisolated func setMode(_ mode: Int, _ url: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private nonisolated func isTheScratchFile(_ url: URL) -> Bool {
    url.deletingLastPathComponent().lastPathComponent == "Credentials.scratch" && url.pathExtension == "db"
}

/// A live row that no longer authenticates.
private nonisolated func tamper(_ f: VaultStoreFixture, _ account: CredentialAccount) throws {
    let row = try f.storedRecord(f.vaultID, account.id)
    try f.mutate { db in
        try db.execute(
            sql: "UPDATE record SET sealed = ? WHERE vaultID = ? AND recordID = ?",
            arguments: [VaultStoreFixture.flipped(row.sealed), f.vaultID.lowerText, account.id.lowerText]
        )
    }
}

struct VaultManagerTests {
    /// Two accounts, one deleted to the Trash through the manager: the id of the one still live and the Trash entry of the other.
    private func seedTrash(_ vault: FixtureVault) async throws -> (live: UUID, entry: UUID) {
        let keep = VaultFixtures.account(username: "keep")
        let gone = VaultFixtures.account(username: "gone")
        let receipt = try await VaultManagerFixture.save([keep, gone], in: vault)
        let epoch = try #require(vault.manager.authorizationEpoch)
        _ = try await vault.manager.delete(.account(gone.id), expectedRevision: receipt.revision, authorizedEpoch: epoch)
        let entry = try #require(try await vault.manager.trashPage(after: nil).items.first)
        return (keep.id, entry.id)
    }

    // MARK: - Epochs and locks

    @Test func commitRequiresTheAuthorizedEpoch() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let manager = vaults[0].manager
            let epoch = try #require(manager.authorizationEpoch)
            let account = VaultFixtures.account()
            let base = try await manager.snapshot().revision

            for wrong in [epoch &+ 1, epoch &- 1, 0] {
                await #expect(throws: CredentialVaultError.unauthorized) {
                    _ = try await manager.commit([account], expectedRevision: base, authorizedEpoch: wrong)
                }
            }
            let untouched = try await manager.snapshot()
            #expect(untouched.revision == base)
            #expect(untouched.accounts.isEmpty)

            let receipt = try await manager.commit([account], expectedRevision: base, authorizedEpoch: epoch)
            let written = try await manager.snapshot()
            #expect(written.revision == receipt.revision)
            #expect(written.accounts == [account])

            // Every other durable write goes through the same gate.
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await manager.delete(.account(account.id), expectedRevision: receipt.revision, authorizedEpoch: epoch &+ 1)
            }
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await manager.updatePasswordSavePolicy(["https://x.test"], expectedRevision: receipt.revision, authorizedEpoch: epoch &+ 1)
            }
            #expect(try await manager.snapshot().accounts == [account])
        }
    }

    // The fixture's gate never admits a writer while a reader holds it: a waiting writer that is cancelled leaves with a CancellationError
    // (had it been admitted it would have returned normally), and once the reader is gone the writer enters at once.
    @Test func theRegistryGateNeverAdmitsAWriterWhileAReaderHoldsIt() async throws {
        let gate = RegistryGate()
        let reader = UUID()
        try await gate.enterShared(reader)
        let writer = Task { try await gate.enterExclusive() }
        for _ in 0..<20 {
            await Task.yield()
        }
        writer.cancel()
        await #expect(throws: CancellationError.self) { try await writer.value }

        gate.leaveShared(reader)
        try await gate.enterExclusive()
        gate.leaveExclusive()
    }

    // `exclusive`: a session-wide lock would otherwise lock the managers of every test running at the same time.
    @Test(arguments: LockTrigger.allCases)
    func lockAllProfileSwitchSleepScreenLockAndTerminationLockEveryVaultManager(trigger: LockTrigger) async throws {
        try await VaultManagerFixture.exclusive {
            try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
                try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, others in
                    #expect(vaults.allSatisfy { $0.manager.isUnlocked })

                    trigger.fire(for: profile)

                    let locked = await waitUntil { vaults.allSatisfy { !$0.manager.isUnlocked } }
                    #expect(locked)
                    #expect(vaults.allSatisfy { $0.manager.lastLockReason == trigger.reason })
                    if trigger == .profileSwitch {
                        // A profile switch leaves every other profile alone.
                        #expect(others[0].manager.isUnlocked)
                    } else {
                        let everyoneLocked = await waitUntil { !others[0].manager.isUnlocked }
                        #expect(everyoneLocked)
                        #expect(others[0].manager.lastLockReason == trigger.reason)
                    }
                }
            }
        }
    }

    @Test func retireDrainsEveryManagerThenClosesTheStoreBeforeDirectoryRemoval() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            let store = try CredentialManager.store(for: profile)
            let epoch = try #require(a.manager.authorizationEpoch)
            let base = try await a.manager.snapshot().revision

            // A write is in flight when the profile is erased: it completes or is refused, never half done.
            let write = Task { try await a.manager.commit([VaultFixtures.account()], expectedRevision: base, authorizedEpoch: epoch) }
            await Task.yield()
            await CredentialManager.retire(profileID: profile.id)
            switch await write.result {
            case .success(let receipt):
                #expect(receipt.revision > base)
            case .failure(let error):
                #expect(error as? CredentialVaultError == .unauthorized)
            }

            #expect(CredentialManager.unlockedManagers(for: profile).isEmpty)
            #expect(!a.manager.isUnlocked && !b.manager.isUnlocked)
            #expect(throws: CredentialVaultError.unauthorized) { try CredentialManager.store(for: profile) }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await b.manager.snapshot() }
            await #expect(throws: CredentialVaultError.unauthorized) { try await b.manager.discoverUnlocks() }

            // The directory goes; nothing the retired profile owns brings it back.
            try FileManager.default.removeItem(at: profile.supportDirectory)
            await #expect(throws: CredentialVaultError.unauthorized) {
                let lease = VaultAccess(profileID: profile.id, epoch: 0, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
                _ = try await store.createVault(name: "Late", unlock: VaultFixtures.proof(), authorizedBy: .firstVault(lease: lease))
            }
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await a.manager.commit([], expectedRevision: 0, authorizedEpoch: epoch)
            }
            #expect(!FileManager.default.fileExists(atPath: profile.supportDirectory.path))
        }
    }

    @Test func privateProfileHasNoVault() async throws {
        let profile = Profile.privateBrowsing()
        #expect(throws: CredentialVaultError.privateBrowsing) { try CredentialManager.store(for: profile) }
        #expect(throws: CredentialVaultError.privateBrowsing) { try CredentialManager.forVault(profile, vaultID: UUID()) }
        await #expect(throws: CredentialVaultError.privateBrowsing) {
            _ = try await CredentialManager.createVault(
                profile: profile, name: "Nope", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor(),
                native: VaultPasskeys().native
            )
        }
        #expect(CredentialManager.unlockedManagers(for: profile).isEmpty)
        for name in ["Credentials.store", "Credentials.vault"] {
            #expect(!FileManager.default.fileExists(atPath: profile.supportDirectory.appendingPathComponent(name).path))
        }
    }

    // MARK: - Trash, versions, purge

    @Test func trashAndVersionOperationsUseTheSourceManagersLease() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { _, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            let seededA = try await seedTrash(a)
            let seededB = try await seedTrash(b)
            a.manager.lock(reason: .manual)

            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.manager.trashPage(after: nil) }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.manager.revisionPage(accountID: seededA.live, after: nil) }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.manager.previewUndelete(entryID: seededA.entry) }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.manager.removedIdentifiers() }

            // The sibling's own lease is not affected, and it never sees A's entry.
            #expect(try await b.manager.trashPage(after: nil).items.map(\.id) == [seededB.entry])
            _ = try await b.manager.revisionPage(accountID: seededB.live, after: nil)
            #expect(try await b.manager.previewUndelete(entryID: seededB.entry).entry.id == seededB.entry)
            _ = try await b.manager.removedIdentifiers()
        }
    }

    @Test func purgeRequiresAFreshAssertion() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, passkeys, vaults in
            let a = vaults[0]
            let anchor = VaultManagerFixture.anchor()
            let first = try await seedTrash(a)
            #expect(passkeys.assertions.isEmpty)

            // An assertion of a passkey the vault does not enrol: refused, the Trash is unchanged.
            let stranger = VaultFixtures.proof(9)
            passkeys.answer = stranger
            await #expect(throws: CredentialVaultError.authenticationFailed) {
                _ = try await a.manager.purge(entryIDs: [first.entry], emptyAll: false, in: anchor)
            }
            #expect(try await a.manager.trashPage(after: nil).items.map(\.id) == [first.entry])
            passkeys.answer = nil

            // The enrolled passkey purges, after exactly one native assertion.
            let receipt = try await a.manager.purge(entryIDs: [first.entry], emptyAll: false, in: anchor)
            #expect(passkeys.assertions == [stranger.credentialID, a.proof.credentialID])
            #expect(receipt.removedEntries == 1)
            #expect(try await a.manager.trashPage(after: nil).items.isEmpty)

            // A locked manager asks nothing and purges nothing.
            let second = try await seedTrash(a)
            a.manager.lock(reason: .manual)
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await a.manager.purge(entryIDs: [second.entry], emptyAll: true, in: anchor)
            }
            #expect(passkeys.assertions.count == 2)
            try await VaultManagerFixture.unlock(a)
            // Seeding again replaced the earlier live login too, so the Trash holds both; the refused purge removed nothing.
            let remaining = try await a.manager.trashPage(after: nil).items.map(\.id)
            #expect(remaining.contains(second.entry))
            #expect(!remaining.contains(first.entry))
        }
    }

    // MARK: - Creating vaults

    @Test func createVaultCoversEveryChoice() async throws {
        try await VaultManagerFixture.with(vaults: []) { profile, passkeys, _ in
            let anchor = VaultManagerFixture.anchor()
            let store = try CredentialManager.store(for: profile)
            func create(_ name: String, _ choice: NewVaultChoice) async throws -> UUID {
                try await CredentialManager.createVault(profile: profile, name: name, choice: choice, in: anchor, native: passkeys.native)
            }

            // The first vault is created locked: nobody holds a grant.
            let firstID = try await create("First", .newPasskey(authorizedBy: nil))
            let proofA = try #require(passkeys.registered.last)
            let a = FixtureVault(manager: try CredentialManager.forVault(profile, vaultID: firstID, native: passkeys.native), vaultID: firstID, proof: proofA)
            #expect(!a.manager.isUnlocked)
            #expect(CredentialManager.unlockedManagers(for: profile).isEmpty)
            #expect(try await store.listing().map(\.isUnlocked) == [false])

            try await VaultManagerFixture.unlock(a)
            let kept = VaultFixtures.account()
            try await VaultManagerFixture.save([kept], in: a)
            let epoch = try #require(a.manager.authorizationEpoch)
            let rowsA = try VaultManagerFixture.rows(of: firstID, in: profile)
            @MainActor func expectTheSourceIsUntouched() async throws {
                #expect(a.manager.authorizationEpoch == epoch)
                #expect(try await a.manager.snapshot().accounts == [kept])
                #expect(try VaultManagerFixture.rows(of: firstID, in: profile) == rowsA)
            }

            // A new passkey authorized by the unlocked vault, then an enrolled passkey asserted again: A's rows and its lease stay as they were.
            let secondID = try await create("Second", .newPasskey(authorizedBy: a.manager))
            #expect(passkeys.registered.count == 2)
            try await expectTheSourceIsUntouched()
            let thirdID = try await create(
                "Third", .existing(sourceVaultID: firstID, credentialID: proofA.credentialID, prfInput: proofA.prfInput)
            )
            #expect(passkeys.assertions == [proofA.credentialID])
            try await expectTheSourceIsUntouched()

            // Every new vault is locked, and the re-used passkey opens the third.
            #expect(try await store.listing().map(\.vaultID) == [firstID, secondID, thirdID])
            #expect(CredentialManager.unlockedManagers(for: profile).map(\.vaultID) == [firstID])
            let third = FixtureVault(manager: try CredentialManager.forVault(profile, vaultID: thirdID, native: passkeys.native), vaultID: thirdID, proof: proofA)
            try await VaultManagerFixture.unlock(third)
            #expect(try await third.manager.snapshot().accounts.isEmpty)
            third.manager.lock(reason: .manual)

            // A profile lock while the registration prompt is open refuses the creation and writes nothing.
            var before = VaultManagerFixture.image(of: profile.supportDirectory)
            passkeys.beforeRegister = { CredentialManager.lock(profileID: profile.id, reason: .profileSwitch) }
            var failure: (any Error)?
            do {
                _ = try await create("Fourth", .newPasskey(authorizedBy: a.manager))
            } catch {
                failure = error
            }
            passkeys.beforeRegister = nil
            guard let refusal = failure as? CredentialManagerError, case .externalPasskeyRemains(_, let underlying) = refusal else {
                Issue.record("expected the creation to be refused with externalPasskeyRemains, got \(String(describing: failure))")
                return
            }
            #expect(underlying as? CredentialVaultError == .unauthorized)
            #expect(!a.manager.isUnlocked)
            #expect(VaultManagerFixture.image(of: profile.supportDirectory) == before)

            // The same while the passkey of an existing vault is being asserted.
            before = VaultManagerFixture.image(of: profile.supportDirectory)
            passkeys.beforeAssert = { CredentialManager.lock(profileID: profile.id, reason: .profileSwitch) }
            failure = nil
            do {
                _ = try await create("Fifth", .existing(sourceVaultID: firstID, credentialID: proofA.credentialID, prfInput: proofA.prfInput))
            } catch {
                failure = error
            }
            passkeys.beforeAssert = nil
            #expect(failure as? CredentialVaultError == .unauthorized)
            #expect(VaultManagerFixture.image(of: profile.supportDirectory) == before)
            #expect(try await store.listing().count == 3)
        }

        // The first vault of a profile: the lock lands before anything exists.
        try await VaultManagerFixture.with(vaults: []) { profile, passkeys, _ in
            passkeys.beforeRegister = { CredentialManager.lock(profileID: profile.id, reason: .profileSwitch) }
            var failure: (any Error)?
            do {
                _ = try await CredentialManager.createVault(
                    profile: profile, name: "First", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor(),
                    native: passkeys.native
                )
            } catch {
                failure = error
            }
            #expect(failure is CredentialManagerError)
            #expect(passkeys.cancelCount > 0)
            #expect(VaultManagerFixture.image(of: profile.supportDirectory).isEmpty)
            #expect(CredentialManager.unlockedManagers(for: profile).isEmpty)
        }
    }

    // MARK: - Scratch warnings

    /// A manager over a hand-built fixture whose store reads a stepping clock. The leases come from a clock set far ahead, so they
    /// outlive however many reads the store makes.
    private func scratchManager(_ f: VaultStoreFixture, passkeys: VaultPasskeys) -> (manager: CredentialManager, scratch: URL) {
        let stepping = SteppingClock()
        let clock = TestClock()
        clock.advance(by: .seconds(3000))
        passkeys.adopt(f.proof)
        let manager = VaultManagerFixture.manager(
            profileID: f.env.profileID, vaultID: f.vaultID, store: f.makeStore(now: { stepping.now() }), passkeys: passkeys,
            now: { clock.now }
        )
        return (manager, VerificationScratch.directory(in: f.directory))
    }

    @Test(.enabled(if: getuid() != 0))
    func scratchWarningsAreCapturedByTheManagerForEveryUnlockSurface() async throws {
        let accounts = [VaultFixtures.account(username: "ada"), VaultFixtures.account(username: "grace", origin: "https://b.example")]

        // The native unlock succeeds; the report is kept and the next unlock clears it.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let passkeys = VaultPasskeys()
            let (manager, scratch) = scratchManager(f, passkeys: passkeys)
            defer {
                setMode(0o700, scratch)
                manager.lock(reason: .manual)
            }

            try await manager.unlock(in: VaultManagerFixture.anchor(), verifying: { if $0 { setMode(0o500, scratch) } })

            #expect(manager.isUnlocked)
            #expect(manager.scratchCleanupWarnings.contains(where: isTheScratchFile))
            setMode(0o700, scratch)
            manager.lock(reason: .manual)
            try await manager.unlock(in: VaultManagerFixture.anchor())
            #expect(manager.isUnlocked)
            #expect(manager.scratchCleanupWarnings.isEmpty)
        }

        // A tampered row stays an integrity failure, never a file error, and the report is kept.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let (manager, scratch) = scratchManager(f, passkeys: VaultPasskeys())
            defer { setMode(0o700, scratch) }
            try tamper(f, accounts[0])

            var failure: (any Error)?
            do {
                try await manager.completeUnlock(
                    credentialID: f.proof.credentialID, prf: f.proof.prf, access: manager.beginAccess(),
                    verifying: { if $0 { setMode(0o500, scratch) } }
                )
            } catch {
                failure = error
            }

            #expect(failure as? CredentialStoreError == .integrityFailure(vaultOrdinal: 1))
            #expect(!manager.isUnlocked)
            #expect(manager.scratchCleanupWarnings.contains(where: isTheScratchFile))
        }

        // A cancelled unlock is a CancellationError and still reports the path.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let (manager, scratch) = scratchManager(f, passkeys: VaultPasskeys())
            defer { setMode(0o700, scratch) }
            let canceller = Canceller()
            let task = Task {
                try await manager.completeUnlock(
                    credentialID: f.proof.credentialID, prf: f.proof.prf, access: manager.beginAccess(),
                    verifying: {
                        if $0 {
                            setMode(0o500, scratch)
                            canceller.fire()
                        }
                    }
                )
            }
            canceller.attach(task)

            var failure: (any Error)?
            do {
                try await task.value
            } catch {
                failure = error
            }

            #expect(failure is CancellationError)
            #expect(!manager.isUnlocked)
            #expect(manager.scratchCleanupWarnings.contains(where: isTheScratchFile))
        }

        // A lock that lands while the store is verifying makes the report late: it is dropped.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let (manager, scratch) = scratchManager(f, passkeys: VaultPasskeys())
            defer { setMode(0o700, scratch) }

            var failure: (any Error)?
            do {
                try await manager.completeUnlock(
                    credentialID: f.proof.credentialID, prf: f.proof.prf, access: manager.beginAccess(),
                    verifying: {
                        if $0 {
                            setMode(0o500, scratch)
                            // The store runs off the main thread, which is free while the unlock awaits it.
                            DispatchQueue.main.sync { MainActor.assumeIsolated { manager.lock(reason: .manual) } }
                        }
                    }
                )
            } catch {
                failure = error
            }

            #expect(failure as? CredentialVaultError == .unauthorized)
            #expect(!manager.isUnlocked)
            // The scratch file really was left behind (a report was due), and the manager did not publish it.
            let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            #expect(!left.isEmpty)
            #expect(manager.scratchCleanupWarnings.isEmpty)
        }

        // A newer `beginAccess` that lands while an older unlock is still verifying drops the older unlock's late report.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let (manager, scratch) = scratchManager(f, passkeys: VaultPasskeys())
            defer { setMode(0o700, scratch) }

            _ = try? await manager.completeUnlock(
                credentialID: f.proof.credentialID, prf: f.proof.prf, access: manager.beginAccess(),
                verifying: {
                    if $0 {
                        setMode(0o500, scratch)
                        DispatchQueue.main.sync { MainActor.assumeIsolated { _ = manager.beginAccess() } }
                    }
                }
            )

            let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            #expect(!left.isEmpty)
            #expect(manager.scratchCleanupWarnings.isEmpty)
        }
    }

    // MARK: - Migration

    @Test func migrationConsentComesBeforeAnyPasskeyPrompt() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try LegacyV1.make(profileID: env.profileID)
            try legacy.write(to: env.directory)
            let passkeys = VaultPasskeys()
            passkeys.adopt(legacy.proof)
            let manager = VaultManagerFixture.manager(
                profileID: env.profileID, vaultID: legacy.vaultID, store: tracker.makeStore(env: env), passkeys: passkeys
            )
            let anchor = VaultManagerFixture.anchor()
            let image = try directoryImage(env.directory)

            await #expect(throws: CredentialStoreError.migrationNeedsConfirmation) { try await manager.unlock(in: anchor) }
            #expect(passkeys.assertions.isEmpty)
            #expect(!manager.isUnlocked)
            #expect(try directoryImage(env.directory) == image)

            try await manager.unlock(in: anchor, confirmMigration: true)
            #expect(passkeys.assertions == [legacy.proof.credentialID])
            #expect(manager.isUnlocked)
            #expect(try await manager.snapshot().accounts == legacy.accounts)
            manager.lock(reason: .manual)
        }
    }
}
