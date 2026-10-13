// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import WSurf

// Task 9: the routed public `unlock` and the one-way v1 → v2 migration (spec §10). Every v1 file is a real `CredentialVaultCrypto`
// envelope; assertions are on the files, the open state and the unlock result.

private nonisolated enum Name {
    static let vault = "Credentials.vault"
    static let store = "Credentials.store"
    static let migrating = "Credentials.store.migrating"
    static let swap = "Credentials.vault.swap"
    static let cutover = "Credentials.vault.cutover-v1"
    static let preV2 = "Credentials.vault.pre-v2"
}

private nonisolated struct MigrationTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private nonisolated func state(_ env: VaultTestEnvironment) -> StoreOpenState {
    StoreAnchors.evaluate(directory: env.directory, profileID: env.profileID, defaults: env.defaults)
}

private nonisolated func bytes(_ env: VaultTestEnvironment, _ name: String) throws -> Data {
    try Data(contentsOf: anchorURL(env.directory, name))
}

private nonisolated func present(_ env: VaultTestEnvironment, _ name: String) -> Bool {
    StoreAnchors.exists(anchorURL(env.directory, name))
}

private nonisolated func arrangeLegacy(
    _ env: VaultTestEnvironment,
    accounts: [CredentialAccount] = [VaultFixtures.account()],
    blocked: Set<String> = []
) throws -> LegacyV1 {
    let legacy = try LegacyV1.make(profileID: env.profileID, accounts: accounts, blocked: blocked)
    try legacy.write(to: env.directory)
    return legacy
}

private nonisolated func routed(
    _ store: ProfileVaultStore, _ vaultID: UUID, _ proof: VaultUnlockProof, confirm: Bool, access: VaultAccess
) async throws {
    try await store.unlock(
        vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, confirmMigration: confirm, access: access,
        verifying: nil, scratchWarning: nil
    )
}

private nonisolated func sorted(_ accounts: [CredentialAccount]) -> [CredentialAccount] {
    accounts.sorted { $0.id.uuidString < $1.id.uuidString }
}

/// Moves every file except the operation lock into `stash/` (and back), turning a directory into another §6.3 state and back.
private nonisolated func stash(_ directory: URL, restore: Bool) throws {
    let manager = FileManager.default
    let bin = directory.appendingPathComponent("stash", isDirectory: true)
    let (from, to) = restore ? (bin, directory) : (directory, bin)
    try manager.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in try manager.contentsOfDirectory(atPath: from.path) where name != "Credentials.lock" && name != "stash" {
        try manager.moveItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
    }
}

/// A provisional fixture store turned into a legacy directory holding a v1 file for the same vault (A3 cleared), and back.
private nonisolated struct Flip {
    let f: VaultStoreFixture
    let legacy: LegacyV1

    init(_ f: VaultStoreFixture) throws {
        self.f = f
        legacy = try LegacyV1.make(
            profileID: f.env.profileID, accounts: f.accounts, proof: f.proof, vaultID: f.vaultID
        )
    }

    func toLegacy() throws {
        try stash(f.directory, restore: false)
        try legacy.write(to: f.directory)
        f.env.defaults.removeObject(forKey: StoreAnchors.witnessKey)
    }

    func toProvisional() throws {
        try FileManager.default.removeItem(at: anchorURL(f.directory, Name.vault))
        try stash(f.directory, restore: true)
        f.env.defaults.set(f.ids.storeID.uuidString, forKey: StoreAnchors.witnessKey)
    }
}

// MARK: - Routing

struct VaultUnlockRoutingTests {
    static let lockWait: Duration = .milliseconds(150)

    @Test func routedUnlockNeverNestsTheLock() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            // A nested second `flock` from the same process would time out with `storeBusy`.
            let migrating = tracker.makeStore(env: env, lockWait: Self.lockWait)
            try await routed(migrating, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))

            let provisional = tracker.makeStore(env: env, lockWait: Self.lockWait)
            let access = newAccess(env.profileID)
            try await routed(provisional, legacy.vaultID, legacy.proof, confirm: false, access: access)
            #expect(try await provisional.snapshot(vaultID: legacy.vaultID, using: access).accounts == legacy.accounts)
        }
    }

    @Test func routerSendsProvisionalToTheInitializedPath() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let store = f.makeStore()
            let access = f.beginAccess()
            try await routed(store, f.vaultID, f.proof, confirm: false, access: access)  // no migration prompt
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).accounts == f.accounts)
        }
    }

    @Test func firstRunAndFailClosedStatesAreRefusedWithoutWriting() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let proof = VaultFixtures.proof()
            let store = tracker.makeStore(env: env)
            let empty = try directoryImage(env.directory)
            for confirm in [false, true] {
                let failure = await Result { try await routed(store, UUID(), proof, confirm: confirm, access: newAccess(env.profileID)) }.error
                #expect(failure as? CredentialStoreError == .noSuchVault)
            }
            #expect(try directoryImage(env.directory) == empty)

            try Data("not a database".utf8).write(to: anchorURL(env.directory, Name.store))
            guard case .failClosed(let closed) = state(env) else { throw MigrationTestFailure("garbage store is not fail-closed") }
            let image = try directoryImage(env.directory)
            let failure = await Result { try await routed(store, UUID(), proof, confirm: true, access: newAccess(env.profileID)) }.error
            #expect(failure as? CredentialStoreError == .failClosed(closed))
            #expect(try directoryImage(env.directory) == image)
        }
    }

    /// `actions[n]` runs at the n-th route→lock boundary (`afterMigrationStep(0)`); other seam steps are ignored. No timing involved.
    private func changingAtRoute(in directory: URL, _ actions: [@Sendable () throws -> Void], boundaries: ProbeLog) -> StoreFileOps {
        probingOps(in: directory) { step in
            guard step == 0 else { return }
            let index = boundaries.all.count
            boundaries.add("route")
            if index < actions.count {
                try actions[index]()
            }
        }
    }

    @Test func stateChangingBetweenRouteAndLockIsReroutedOnce() async throws {
        // Legacy at the route, provisional at the lock: the store re-routes once and unlocks.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let flip = try Flip(f)
            try flip.toLegacy()
            let boundaries = ProbeLog()
            let store = f.makeStore(fileOps: changingAtRoute(in: f.directory, [{ try flip.toProvisional() }], boundaries: boundaries))
            let access = f.beginAccess()
            try await routed(store, f.vaultID, f.proof, confirm: true, access: access)
            #expect(boundaries.all.count == 2)  // the first route, then the one re-route
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).accounts == f.accounts)
        }

        // Provisional at the first route, legacy at its lock, then provisional again at the second lock: `stateChanged`, no grant.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let flip = try Flip(f)
            let boundaries = ProbeLog()
            let actions: [@Sendable () throws -> Void] = [{ try flip.toLegacy() }, { try flip.toProvisional() }]
            let store = f.makeStore(fileOps: changingAtRoute(in: f.directory, actions, boundaries: boundaries))
            let access = f.beginAccess()
            let failure = await Result { try await routed(store, f.vaultID, f.proof, confirm: true, access: access) }.error
            #expect(failure as? CredentialStoreError == .stateChanged)
            #expect(boundaries.all.count == 2)  // never a third route
            await expectNoGrant(store, f.vaultID, access)
        }
    }
}

// MARK: - Migration

struct VaultMigrationTests {
    static let lockWait: Duration = .milliseconds(150)

    // MARK: Crash safety

    @Test(arguments: 1...10)
    func crashAtEachStepLeavesV1OrTheNewStoreAuthoritative(step: Int) async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(
                env, accounts: [VaultFixtures.account(), VaultFixtures.account(username: "grace", origin: "https://g.example")]
            )
            let crashing = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: step)))
            let access = newAccess(env.profileID)
            await #expect(throws: SeamStop(step: step)) {
                try await routed(crashing, legacy.vaultID, legacy.proof, confirm: true, access: access)
            }
            await expectNoGrant(crashing, legacy.vaultID, access)

            switch (step, state(env)) {
            case (1...6, .legacy(let id)):
                #expect(id == legacy.vaultID)
                #expect(try bytes(env, Name.vault) == legacy.bytes)  // v1 is untouched until the swap
            case (7...8, .resumeMigration):
                #expect(throws: CredentialVaultError.corruptVault) {
                    try CredentialVaultCrypto.decodeEnvelope(try bytes(env, Name.vault), profileID: env.profileID)
                }
            case (9...10, .provisional(_, let stubMissing)):
                #expect(!stubMissing)
            case (_, let other):
                throw MigrationTestFailure("step \(step): unexpected state \(other)")
            }
            if step >= 2 {
                #expect(try bytes(env, Name.preV2) == legacy.bytes)
            }

            // A retry completes whatever was left, and nothing is unrecoverable.
            let retry = tracker.makeStore(env: env)
            let again = newAccess(env.profileID)
            try await routed(retry, legacy.vaultID, legacy.proof, confirm: true, access: again)
            #expect(sorted(try await retry.snapshot(vaultID: legacy.vaultID, using: again).accounts) == sorted(legacy.accounts))
            guard case .provisional(let storeID, false) = state(env) else { throw MigrationTestFailure("retry left no store") }
            #expect(env.defaults.string(forKey: StoreAnchors.witnessKey) == storeID.uuidString)
            #expect(!present(env, Name.migrating) && !present(env, Name.swap))
            #expect(try bytes(env, Name.preV2) == legacy.bytes)
        }
    }

    // MARK: Content

    @Test func migratedVaultKeepsEverythingAndUnlocksWithTheOriginalPasskey() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let rich = try VaultFixtures.richAccount()
            let plain = VaultFixtures.account(username: "grace", origin: "https://g.example", passkeys: [try VaultFixtures.passkey()])
            let blocked = Set((0..<4_096).map { "https://blocked\($0).example" })
            let legacy = try arrangeLegacy(env, accounts: [rich, plain], blocked: blocked)

            let store = tracker.makeStore(env: env)
            let access = newAccess(env.profileID)
            try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: access)

            let snapshot = try await store.snapshot(vaultID: legacy.vaultID, using: access)
            #expect(sorted(snapshot.accounts) == sorted([rich, plain]))  // ids, passkeys, exchange ids and values, dates all unchanged
            #expect(snapshot.accounts.allSatisfy { $0.createdAt == nil && $0.modifiedAt == nil && $0.migratedAt == nil })
            #expect(snapshot.blockedPasswordOrigins == blocked)
            #expect(snapshot.revision == 1)

            // The stored wrapper list is B0's wrapper list byte for byte, under the same vault id.
            let row = try #require(try tracker.storeRows(env).first { $0.vaultID == legacy.vaultID && $0.role == .active })
            let b0Wrappers = try CredentialVaultCrypto.decodeEnvelope(legacy.bytes, profileID: env.profileID).wrappers  // decoded from B0's bytes
            #expect(row.wrappers == (try VaultWrapperList.encode(b0Wrappers)))
            #expect(row.ordinal == 1)
            let listing = try await store.listing()
            #expect(listing.map(\.vaultID) == [legacy.vaultID])
            #expect(listing.first?.name == "Personal")

            // A fresh store unlocks with the original passkey and nothing else.
            let fresh = tracker.makeStore(env: env)
            let other = newAccess(env.profileID)
            try await routed(fresh, legacy.vaultID, legacy.proof, confirm: false, access: other)
            #expect(try await fresh.snapshot(vaultID: legacy.vaultID, using: other).blockedPasswordOrigins == blocked)
        }
    }

    // MARK: Backup

    @Test func preMigrationBackupIsReusedOnlyIfByteIdentical() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            try legacy.bytes.write(to: anchorURL(env.directory, Name.preV2))
            let store = tracker.makeStore(env: env)
            try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            #expect(try bytes(env, Name.preV2) == legacy.bytes)
        }

        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let different = try LegacyV1.make(profileID: env.profileID, vaultID: legacy.vaultID)
            let backup = anchorURL(env.directory, Name.preV2)
            try different.bytes.write(to: backup)
            let image = try directoryImage(env.directory)
            let failure = await Result {
                try await routed(tracker.makeStore(env: env), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }.error
            #expect(failure as? CredentialStoreError == .migrationAborted(path: backup))
            #expect(try directoryImage(env.directory) == image)
            #expect(state(env) == .legacy(vaultID: legacy.vaultID))
        }
    }

    @Test func pendingStoreIsRemovedOnlyAfterV1AndBackupAreVerified() async throws {
        // v1 that cannot be opened: the leftover pending store stays.
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let leftover = Data("leftover pending store".utf8)
            try leftover.write(to: anchorURL(env.directory, Name.migrating))
            let wrong = VaultUnlockProof(credentialID: legacy.proof.credentialID, prfInput: legacy.proof.prfInput, prf: SymmetricKey(size: .bits256))
            let failure = await Result {
                try await routed(tracker.makeStore(env: env), legacy.vaultID, wrong, confirm: true, access: newAccess(env.profileID))
            }.error
            #expect(failure as? CredentialVaultError == .authenticationFailed)
            #expect(try bytes(env, Name.migrating) == leftover)
            #expect(try bytes(env, Name.vault) == legacy.bytes)
            #expect(!present(env, Name.preV2))
        }

        // v1 fine, backup not reusable: still kept.
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let leftover = Data("leftover pending store".utf8)
            try leftover.write(to: anchorURL(env.directory, Name.migrating))
            try Data("other".utf8).write(to: anchorURL(env.directory, Name.preV2))
            let failure = await Result {
                try await routed(tracker.makeStore(env: env), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }.error
            #expect(failure as? CredentialStoreError == .migrationAborted(path: anchorURL(env.directory, Name.preV2)))
            #expect(try bytes(env, Name.migrating) == leftover)
        }

        // v1 and backup fine: the derived leftover is replaced.
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            try Data("leftover pending store".utf8).write(to: anchorURL(env.directory, Name.migrating))
            try await routed(tracker.makeStore(env: env), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            #expect(!present(env, Name.migrating))
            guard case .provisional = state(env) else { throw MigrationTestFailure("not migrated") }
        }
    }

    // MARK: Old builds

    @Test func oldBuildWriteBeforeTheSwapIsPreservedAsCutoverV1() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let newer = try LegacyV1.make(
                profileID: env.profileID, accounts: [VaultFixtures.account(username: "late")], proof: legacy.proof, vaultID: legacy.vaultID
            )
            let vault = anchorURL(env.directory, Name.vault)
            let ops = probingOps(in: env.directory) { step in
                if step == 6 { try newer.bytes.write(to: vault) }  // an old build saves just before the swap
            }
            let store = tracker.makeStore(env: env, fileOps: ops)
            let access = newAccess(env.profileID)
            let failure = await Result { try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: access) }.error

            let closed = try #require(failClosedCause(failure))
            #expect(closed.cause == .cutoverV1Present)
            #expect(closed.paths.contains(anchorURL(env.directory, Name.cutover)))
            #expect(try bytes(env, Name.cutover) == newer.bytes)  // never merged, never rolled back
            #expect(throws: CredentialVaultError.corruptVault) {
                try CredentialVaultCrypto.decodeEnvelope(try bytes(env, Name.vault), profileID: env.profileID)
            }
            #expect(present(env, Name.migrating) && !present(env, Name.store) && !present(env, Name.swap))
            #expect(try bytes(env, Name.preV2) == legacy.bytes)
            await expectNoGrant(store, legacy.vaultID, access)
        }
    }

    @Test func oldBuildWriteAfterTheSwapYieldsRowOneOrThree() async throws {
        // Before the store rename: `legacy` (row 1).
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let vault = anchorURL(env.directory, Name.vault)
            let ops = probingOps(in: env.directory) { step in
                if step == 8 {
                    try legacy.bytes.write(to: vault)
                    throw SeamStop(step: 8)
                }
            }
            await #expect(throws: SeamStop(step: 8)) {
                try await routed(tracker.makeStore(env: env, fileOps: ops), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            #expect(state(env) == .legacy(vaultID: legacy.vaultID))
            #expect(present(env, Name.migrating) && !present(env, Name.store))
        }

        // After it: `failClosed(.v1AfterMigration)`; both files kept.
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let vault = anchorURL(env.directory, Name.vault)
            let ops = probingOps(in: env.directory) { step in
                if step == 9 {
                    try legacy.bytes.write(to: vault)
                }
            }
            let store = tracker.makeStore(env: env, fileOps: ops)
            let access = newAccess(env.profileID)
            let failure = await Result { try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: access) }.error
            #expect(failClosedCause(failure)?.cause == .v1AfterMigration)
            #expect(try bytes(env, Name.vault) == legacy.bytes)
            #expect(present(env, Name.store))
            await expectNoGrant(store, legacy.vaultID, access)
        }
    }

    @Test func renameSwapUnsupportedAbortsUnchanged() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let ops = probingOps(in: env.directory, renameSwap: { _, _ in throw StoreFileError.unsupported })
            let failure = await Result {
                try await routed(tracker.makeStore(env: env, fileOps: ops), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }.error
            #expect(failure as? CredentialStoreError == .renameSwapUnsupported)
            #expect(try bytes(env, Name.vault) == legacy.bytes)
            #expect(!present(env, Name.swap) && !present(env, Name.store))
            #expect(state(env) == .legacy(vaultID: legacy.vaultID))
        }
    }

    @Test func aSwapFileThatIsNotOurStubAbortsTheMigration() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let evidence = try LegacyV1.make(profileID: env.profileID, vaultID: legacy.vaultID).bytes
            try evidence.write(to: anchorURL(env.directory, Name.swap))
            let failure = await Result {
                try await routed(tracker.makeStore(env: env), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }.error
            #expect(failure as? CredentialStoreError == .migrationAborted(path: anchorURL(env.directory, Name.swap)))
            #expect(try bytes(env, Name.swap) == evidence)
            #expect(try bytes(env, Name.vault) == legacy.bytes)
        }
    }

    // MARK: Pending connections

    private enum Scenario: CaseIterable {
        case migration, firstVault
    }

    @Test(arguments: Scenario.allCases)
    private func pendingConnectionsFollowTheExclusiveNoPersistRecipe(scenario: Scenario) async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let log = ProbeLog()
            let ops = probingOps(in: env.directory, log: log)
            let store = tracker.makeStore(env: env, fileOps: ops)
            let vaultID: UUID
            let proof: VaultUnlockProof
            switch scenario {
            case .migration:
                let legacy = try arrangeLegacy(env, accounts: [VaultFixtures.account()])
                vaultID = legacy.vaultID
                proof = legacy.proof
                try await routed(store, vaultID, proof, confirm: true, access: newAccess(env.profileID))
            case .firstVault:
                proof = VaultFixtures.proof()
                vaultID = try await store.createVault(
                    name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID))
                )
            }

            // Every hook that ran after the pending store was first closed saw neither `-wal` nor `-shm`.
            let events = log.all
            #expect(events.count > 5)
            #expect(events.allSatisfy { $0.hasSuffix(": []") }, "\(events)")
            #expect(events.contains { $0.hasPrefix("step9") } && events.contains { $0.hasPrefix("renameExclusive") })
            if scenario == .migration {
                #expect(events.contains { $0.hasPrefix("renameSwap") })
            }
            #expect(pendingSidecars(in: env.directory).isEmpty)

            // The renamed file opens through a normal store, and an empty `-wal`/`-shm` left by its use never fails the state or an unlock.
            for _ in 0..<2 {
                let reopened = tracker.makeStore(env: env)
                let access = newAccess(env.profileID)
                try await routed(reopened, vaultID, proof, confirm: false, access: access)
                _ = try await reopened.snapshot(vaultID: vaultID, using: access)
                await reopened.close()
                guard case .provisional = state(env) else { throw MigrationTestFailure("state after reopen") }
            }
        }
    }

    @Test(arguments: [4, 5, 6, 7, 8])
    func aSidecarPlantedBeforePublicationAbortsAndIsNeverUnlinked(step: Int) async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let planted = anchorURL(env.directory, "Credentials.store.migrating-wal")
            let ops = probingOps(in: env.directory) { current in
                if current == step {
                    try Data([0]).write(to: planted)
                }
            }
            let failure = await Result {
                try await routed(tracker.makeStore(env: env, fileOps: ops), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }.error
            #expect(failure as? CredentialStoreError == .migrationAborted(path: planted))
            #expect(try bytes(env, "Credentials.store.migrating-wal") == Data([0]))
            #expect(present(env, Name.migrating) && !present(env, Name.store))  // nothing was published
            if step <= 6 {
                #expect(state(env) == .legacy(vaultID: legacy.vaultID))
                #expect(try bytes(env, Name.vault) == legacy.bytes)
            } else {
                guard case .resumeMigration = state(env) else { throw MigrationTestFailure("step \(step): not resumable") }
            }
        }
    }

    // MARK: Resume

    @Test func resumeAtUnlockPerformsStepEightFirstAndFailsClosedOnABadPendingStore() async throws {
        // Step 8 first: a displaced file that is not the backup goes to `cutover-v1` before the pending store is even looked at.
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                try await routed(crash, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            #expect(try bytes(env, Name.swap) == legacy.bytes)
            let newer = try LegacyV1.make(profileID: env.profileID, vaultID: legacy.vaultID)
            try newer.bytes.write(to: anchorURL(env.directory, Name.swap))

            let failure = await Result {
                try await routed(tracker.makeStore(env: env), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }.error
            #expect(failClosedCause(failure)?.cause == .cutoverV1Present)
            #expect(try bytes(env, Name.cutover) == newer.bytes)
            #expect(present(env, Name.migrating) && !present(env, Name.store))
        }

        // A bad pending store: nothing is renamed, discarded or witnessed.
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                try await routed(crash, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            let pending = anchorURL(env.directory, Name.migrating)
            try flipFirstRecord(inStoreAt: pending)
            #expect(pendingSidecars(in: env.directory).isEmpty)

            let access = newAccess(env.profileID)
            let store = tracker.makeStore(env: env)
            let failure = await Result { try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: access) }.error
            guard case .integrityFailure? = failure as? CredentialStoreError else {
                throw MigrationTestFailure("bad pending store gave \(String(describing: failure))")
            }
            #expect(present(env, Name.migrating) && !present(env, Name.store))
            #expect(env.defaults.object(forKey: StoreAnchors.witnessKey) == nil)
            guard case .resumeMigration = state(env) else { throw MigrationTestFailure("state changed") }
            await expectNoGrant(store, legacy.vaultID, access)
        }
    }

    /// A `-wal`/`-shm` planted by the `F_FULLFSYNC` that follows the resume's verification (after the pending store was closed and checked)
    /// must stop the rename: the pending store is the one thing that may never be published with a sidecar beside it.
    @Test func aSidecarPlantedAfterResumeVerificationAbortsBeforePublication() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                try await routed(crash, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            let wal = anchorURL(env.directory, "Credentials.store.migrating-wal")
            let shm = anchorURL(env.directory, "Credentials.store.migrating-shm")
            var ops = probingOps(in: env.directory)
            let fullFsync = ops.fullFsync
            ops.fullFsync = { url in
                try fullFsync(url)
                if url.lastPathComponent == Name.migrating {  // only `verifyPending` syncs the pending file on a resume
                    try Data([1]).write(to: wal)
                    try Data([2]).write(to: shm)
                }
            }
            let access = newAccess(env.profileID)
            let store = tracker.makeStore(env: env, fileOps: ops)
            let failure = await Result { try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: access) }.error

            #expect(failure as? CredentialStoreError == .migrationAborted(path: wal))
            #expect(present(env, Name.migrating) && !present(env, Name.store))
            #expect(try bytes(env, "Credentials.store.migrating-wal") == Data([1]))  // never unlinked
            #expect(try bytes(env, "Credentials.store.migrating-shm") == Data([2]))
            #expect(env.defaults.object(forKey: StoreAnchors.witnessKey) == nil)
            await expectNoGrant(store, legacy.vaultID, access)
        }
    }

    // MARK: Confirmation and lock

    @Test func migrationNeedsConfirmationAndExclusiveLock() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env, lockWait: Self.lockWait)

            let unconfirmed = await Result {
                try await routed(store, legacy.vaultID, legacy.proof, confirm: false, access: newAccess(env.profileID))
            }.error
            #expect(unconfirmed as? CredentialStoreError == .migrationNeedsConfirmation)
            #expect(try directoryImage(env.directory) == image)
            #expect(!present(env, "Credentials.lock"))  // refused before any lock was taken

            for mode in [OperationLock.Mode.exclusive, .shared] {
                let hold = try await OperationLock.acquire(in: env.directory, mode: mode)
                let busy = await Result {
                    try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
                }.error
                hold.release()
                #expect(busy as? CredentialStoreError == .storeBusy)
                #expect(try directoryImage(env.directory) == image)
            }

            try await routed(store, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            guard case .provisional = state(env) else { throw MigrationTestFailure("not migrated") }
        }
    }

    @Test func oldReaderFence() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            try await routed(tracker.makeStore(env: env), legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            #expect(throws: CredentialVaultError.corruptVault) {
                try CredentialVaultCrypto.decodeEnvelope(try bytes(env, Name.vault), profileID: env.profileID)
            }
        }
    }
}

/// Before any unlock, a v1 directory and an interrupted migration or first-vault bootstrap still show their vault: locked, ordinal 1, with the
/// wrapper plaintext the passkey prompt needs. Reading it changes no credential or pending-store byte, takes a SHARED lock (which may create
/// the empty lock file) and never recovers a pending store.
struct VaultPreUnlockDiscoveryTests {
    private static let lockWait: Duration = .milliseconds(150)

    private func expectLockedVault(_ store: ProfileVaultStore, _ vaultID: UUID, credentials: [Data]) async throws {
        #expect(try await store.listing() == [VaultListing(vaultID: vaultID, ordinal: 1, name: nil, isUnlocked: false, isVerified: false)])
        let discovery = try await store.discovery(vaultID: vaultID)
        #expect(discovery.vaultID == vaultID)
        #expect(discovery.unlocks.map(\.credentialID) == credentials)
    }

    @Test func aLegacyDirectoryListsItsVaultLockedAndDiscoversTheOldWrappers() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let second = VaultFixtures.proof(3)
            let legacy = try LegacyV1.make(profileID: env.profileID, extraProofs: [second])
            try legacy.write(to: env.directory)
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env)

            try await expectLockedVault(store, legacy.vaultID, credentials: legacy.wrappers.map(\.credentialID))
            #expect(try await store.discovery(vaultID: legacy.vaultID).unlocks.map(\.prfInput) == legacy.wrappers.map(\.prfInput))
            let unknown = await Result { try await store.discovery(vaultID: UUID()) }.error
            #expect(unknown as? CredentialStoreError == .noSuchVault)
            #expect(try directoryImage(env.directory) == image)  // nothing written, nothing migrated
            guard case .legacy = state(env) else { throw MigrationTestFailure("not legacy") }

            // The vault the listing named is the one the confirmed unlock opens, with the passkey the discovery listed.
            let chosen = try #require(try await store.listing().first).vaultID
            let access = newAccess(env.profileID)
            try await routed(store, chosen, second, confirm: true, access: access)
            #expect(try await store.snapshot(vaultID: chosen, using: access).accounts == legacy.accounts)
            #expect(try await store.discovery(vaultID: chosen).unlocks.map(\.credentialID) == legacy.wrappers.map(\.credentialID))
        }
    }

    @Test func aMigrationInterruptedAfterStepSevenListsTheSameVaultWithoutChangingAnything() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                try await routed(crash, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            guard case .resumeMigration = state(env) else { throw MigrationTestFailure("not a resume state") }
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env, lockWait: Self.lockWait)

            try await expectLockedVault(store, legacy.vaultID, credentials: legacy.wrappers.map(\.credentialID))
            #expect(try directoryImage(env.directory) == image)
            #expect(pendingSidecars(in: env.directory).isEmpty)

            // A migration holding the lock is waited for, never read through.
            let hold = try await OperationLock.acquire(in: env.directory, mode: .exclusive)
            let busy = await Result { try await store.listing() }.error
            hold.release()
            #expect(busy as? CredentialStoreError == .storeBusy)
            #expect(try directoryImage(env.directory) == image)

            let chosen = try #require(try await store.listing().first).vaultID
            try await routed(store, chosen, legacy.proof, confirm: true, access: newAccess(env.profileID))
            guard case .provisional = state(env) else { throw MigrationTestFailure("resume did not publish") }
        }
    }

    @Test func aFirstVaultBootstrapInterruptedAfterStepSevenListsItsVault() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let proof = VaultFixtures.proof()
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                _ = try await crash.createVault(name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID)))
            }
            guard case .resumeMigration = state(env) else { throw MigrationTestFailure("not a resume state") }
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env)

            // The crashed creator never returned an id: the listing is the only way to learn it.
            let listed = try #require(try await store.listing().first)
            #expect(listed.ordinal == 1 && listed.name == nil && !listed.isUnlocked)
            let discovery = try await store.discovery(vaultID: listed.vaultID)
            #expect(discovery.unlocks.map(\.credentialID) == [proof.credentialID])
            #expect(discovery.unlocks.map(\.prfInput) == [proof.prfInput])
            #expect(try directoryImage(env.directory) == image)

            let access = newAccess(env.profileID)
            try await routed(store, listed.vaultID, proof, confirm: true, access: access)
            #expect(try await store.snapshot(vaultID: listed.vaultID, using: access).accounts.isEmpty)
        }
    }

    @Test func aPendingStoreWithASidecarIsRefusedAndLeftAlone() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                try await routed(crash, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            let wal = anchorURL(env.directory, "Credentials.store.migrating-wal")
            try Data([9]).write(to: wal)
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env)

            let listing = await Result { try await store.listing() }.error
            let discovery = await Result { try await store.discovery(vaultID: legacy.vaultID) }.error
            #expect(listing as? CredentialStoreError == .migrationAborted(path: wal))
            #expect(discovery as? CredentialStoreError == .migrationAborted(path: wal))
            #expect(try directoryImage(env.directory) == image)
        }
    }

    @Test func aPendingStoreWhoseWrappersDoNotDecodeIsRefused() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                try await routed(crash, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            let pending = anchorURL(env.directory, Name.migrating)
            let queue = try PendingStore.open(at: pending)  // the no-persist recipe: no sidecar is left behind
            try await queue.write { try $0.execute(sql: "UPDATE vault SET wrappers = ? WHERE wrappers IS NOT NULL", arguments: [Data([0])]) }
            try PendingStore.finish(queue, at: pending)
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env)

            let failure = await Result { try await store.listing() }.error
            #expect(failure as? CredentialStoreError == .integrityFailure(vaultOrdinal: 1))
            #expect(try directoryImage(env.directory) == image)
        }
    }

    /// A valid pending store holds exactly one active vault; none or several is corruption, never `[]` and never a way to a new vault.
    @Test(arguments: ["UPDATE vault SET role = 'trash'", "UPDATE vault SET role = 'active'"])
    func aPendingStoreWithoutExactlyOneActiveVaultIsRefused(corruption: String) async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try arrangeLegacy(env)
            let crash = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: 7)))
            await #expect(throws: SeamStop(step: 7)) {
                try await routed(crash, legacy.vaultID, legacy.proof, confirm: true, access: newAccess(env.profileID))
            }
            let pending = anchorURL(env.directory, Name.migrating)
            let queue = try PendingStore.open(at: pending)
            try await queue.write { try $0.execute(sql: corruption) }
            try PendingStore.finish(queue, at: pending)
            guard case .resumeMigration = state(env) else { throw MigrationTestFailure("not a resume state") }
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env)

            let listing = await Result { try await store.listing() }.error
            let discovery = await Result { try await store.discovery(vaultID: legacy.vaultID) }.error
            #expect(listing as? CredentialStoreError == .integrityFailure(vaultOrdinal: nil))
            #expect(discovery as? CredentialStoreError == .integrityFailure(vaultOrdinal: nil))
            #expect(try directoryImage(env.directory) == image)
            #expect(!present(env, Name.store))  // nothing published
            let access = newAccess(env.profileID)
            let snapshot = await Result { try await store.snapshot(vaultID: legacy.vaultID, using: access) }.error
            #expect(snapshot as? CredentialVaultError == .unauthorized)  // no grant
        }
    }

    @Test func failClosedLayoutsStayRefusedInsteadOfBeingDiscovered() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            // Another profile's v1 file.
            let foreign = try LegacyV1.make(profileID: UUID())
            try foreign.write(to: env.directory)
            let image = try directoryImage(env.directory)
            let store = tracker.makeStore(env: env)
            let wrongProfile = await Result { try await store.listing() }.error
            #expect(failClosedCause(wrongProfile)?.cause == .wrongProfile)
            let wrongDiscovery = await Result { try await store.discovery(vaultID: foreign.vaultID) }.error
            #expect(failClosedCause(wrongDiscovery)?.cause == .wrongProfile)
            #expect(try directoryImage(env.directory) == image)
        }
        try await VaultStoreFixture.withEnvironment { env, tracker in
            // A v1 file beside a witness: a migration happened before (row 2), so the old file is not a vault to offer.
            let legacy = try arrangeLegacy(env)
            #expect(StoreAnchors.setWitnessIfAbsent(UUID(), defaults: env.defaults))
            let image = try directoryImage(env.directory)
            let failure = await Result { try await tracker.makeStore(env: env).listing() }.error
            #expect(failClosedCause(failure)?.cause == .v1AfterMigration)
            let discovery = await Result { try await tracker.makeStore(env: env).discovery(vaultID: legacy.vaultID) }.error
            #expect(failClosedCause(discovery)?.cause == .v1AfterMigration)
            #expect(try directoryImage(env.directory) == image)
        }
    }
}

private nonisolated func failClosedCause(_ error: (any Error)?) -> StoreFailClosed? {
    if case .failClosed(let closed)? = error as? CredentialStoreError {
        return closed
    }
    return nil
}

private nonisolated extension StoreTracker {
    /// The vault rows of the store on disk, read without creating a sidecar.
    func storeRows(_ env: VaultTestEnvironment) throws -> [StoreTables.VaultRow] {
        var configuration = Configuration()
        configuration.readonly = true
        let url = anchorURL(env.directory, Name.store)
        return try DatabaseQueue(path: url.absoluteString + "?immutable=1", configuration: configuration).read { try StoreTables.vaultRows($0) }
    }
}
