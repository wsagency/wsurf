// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Task 16: real stores on ONE directory racing through the real operation lock (spec §6.8/§7/§8/§10/§15). Every worker owns its own
// `ProfileVaultStore` (so the lock, not an in-process actor, is what orders them) and starts behind a barrier, with no sleeps. The contract
// being exercised: the lock serializes without deadlock and loses nothing. The only conflicts a caller may meet are the public
// `CredentialStoreError.storeBusy` (the lock wait ran out), `CredentialVaultError.staleRevision` (another store committed since this grant
// was read: unlock again, re-snapshot, retry) and, migrating, `CredentialStoreError.stateChanged`. Each is retried within a small per-
// operation bound; every other error, a raw SQLite busy/locked error and `integrityFailure` included, and cancellation fail at once.

// MARK: - Plumbing

/// All `parties` tasks suspend in `arrive()` until the last one has arrived, then run together.
private actor Barrier {
    private let parties: Int
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) {
        self.parties = parties
    }

    func arrive() async {
        arrived += 1
        if arrived == parties {
            waiting.forEach { $0.resume() }
            waiting = []
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }
}

/// The most mutating operations that can win while one operation is pending: 3 committers x 3 appends plus 2 vault creations. Each
/// winner advances the registry revision at most once, so one operation can go stale at most that often.
private nonisolated let mutatingWinners = 11
private nonisolated let busyRetries = 2

/// Runs `body`, retrying only the named public conflicts, each against its own bound; the error past a bound is rethrown unchanged.
/// `refresh` (an unlock with its own storeBusy retries) runs before the retry that follows a `staleRevision`; a `storeBusy` it still throws
/// counts against this call's busy bound.
private nonisolated func retrying<T>(
    staleRetries: Int = 0, stateChangedRetries: Int = 0, refresh: () async throws -> Void = {}, _ body: () async throws -> T
) async throws -> T {
    var busy = 0, stale = 0, changed = 0
    var needsRefresh = false
    while true {
        try Task.checkCancellation()
        do {
            if needsRefresh {
                try await refresh()
                needsRefresh = false
            }
            return try await body()
        } catch CredentialStoreError.storeBusy {
            busy += 1
            if busy > busyRetries {
                throw CredentialStoreError.storeBusy
            }
        } catch CredentialVaultError.staleRevision {
            stale += 1
            if stale > staleRetries {
                throw CredentialVaultError.staleRevision
            }
            needsRefresh = true
        } catch CredentialStoreError.stateChanged {
            changed += 1
            if changed > stateChangedRetries {
                throw CredentialStoreError.stateChanged
            }
        }
    }
}

/// One fixture store with its own session, as a separate window or process would hold it.
private nonisolated struct Session: Sendable {
    let store: ProfileVaultStore
    let access: VaultAccess
    let vaultID: UUID
    let proof: VaultUnlockProof

    func unlock() async throws {
        try await retrying {
            try await store.unlockInitialized(
                vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, access: access, verifying: nil, scratchWarning: nil
            )
        }
    }

    /// Appends `account` to whatever the vault holds now. `staleRevision` means another store committed since this grant was read:
    /// unlock again, which re-reads the registry entries, then rebuild from the new snapshot.
    func append(_ account: CredentialAccount) async throws -> UInt64 {
        try await retrying(staleRetries: mutatingWinners, refresh: { try await unlock() }) {
            let snapshot = try await store.snapshot(vaultID: vaultID, using: access)
            return try await store.commit(
                vaultID: vaultID, snapshot.accounts + [account], expectedRevision: snapshot.revision, cause: nil, using: access
            ).revision
        }
    }

    func createVault(name: String, proof newProof: VaultUnlockProof) async throws -> UUID {
        try await retrying(staleRetries: mutatingWinners, refresh: { try await unlock() }) {
            try await store.createVault(name: name, unlock: newProof, authorizedBy: .unlockedVault(vaultID: vaultID, access: access))
        }
    }
}

private nonisolated enum Outcome: Sendable {
    case committed(revision: UInt64)
    case created(UUID)
    case unlocked
}

private nonisolated func accounts(_ prefix: String, _ count: Int) -> [CredentialAccount] {
    (0..<count).map { VaultFixtures.account(username: "\(prefix)\($0)", origin: "https://\(prefix)\($0).example") }
}

// MARK: - Tests

struct VaultConcurrencyTests {
    /// Long enough that ordinary contention between a handful of stores resolves inside one wait, short enough that a lost wakeup or a
    /// deadlock surfaces as `storeBusy` after at most `busyRetries + 1` waits and fails the test.
    nonisolated static let lockWait: Duration = .seconds(2)

    @Test(.timeLimit(.minutes(1)))
    func racingUnlocksCommitsAndCreationsLoseNothing() async throws {
        let seed = accounts("seed", 3)
        try await VaultStoreFixture.with(accounts: seed, blockedOrigins: ["https://blocked.example"], historyRows: 3) { f in
            let committerCount = 3, perCommitter = 3, creatorCount = 2, verifierCount = 2
            let barrier = Barrier(parties: committerCount + creatorCount + verifierCount)

            func session() -> Session {
                Session(store: f.makeStore(lockWait: Self.lockWait), access: f.beginAccess(), vaultID: f.vaultID, proof: f.proof)
            }
            // Committers and creators are unlocked before the race, so they start from a real grant; the verifiers unlock inside it.
            var committers: [(Session, [CredentialAccount])] = []
            for index in 0..<committerCount {
                let worker = session()
                try await worker.unlock()
                committers.append((worker, accounts("c\(index)-", perCommitter)))
            }
            var creators: [(Session, String, VaultUnlockProof)] = []
            for index in 0..<creatorCount {
                let worker = session()
                try await worker.unlock()
                creators.append((worker, "Created \(index)", VaultFixtures.proof(UInt8(20 + index))))
            }
            let verifiers = (0..<verifierCount).map { _ in session() }

            let outcomes = try await withThrowingTaskGroup(of: [Outcome].self) { group in
                for (worker, additions) in committers {
                    group.addTask {
                        await barrier.arrive()
                        var done: [Outcome] = []
                        for account in additions {
                            done.append(.committed(revision: try await worker.append(account)))
                        }
                        return done
                    }
                }
                for (worker, name, proof) in creators {
                    group.addTask {
                        await barrier.arrive()
                        return [.created(try await worker.createVault(name: name, proof: proof))]
                    }
                }
                for worker in verifiers {
                    group.addTask {
                        await barrier.arrive()
                        for _ in 0..<3 {
                            try await worker.unlock()
                        }
                        return [.unlocked]
                    }
                }
                var all: [Outcome] = []
                for try await part in group {
                    all += part
                }
                return all
            }

            let revisions = outcomes.compactMap { outcome -> UInt64? in
                if case .committed(let revision) = outcome {
                    revision
                } else {
                    nil
                }
            }
            let created = outcomes.compactMap { outcome -> UUID? in
                if case .created(let id) = outcome {
                    id
                } else {
                    nil
                }
            }
            #expect(revisions.count == committerCount * perCommitter)
            #expect(Set(revisions).count == revisions.count, "each commit won its own revision")
            #expect(created.count == creatorCount && Set(created).count == creatorCount)

            // Nothing was lost, duplicated or half-applied: the vault holds the seed plus every committed account exactly once.
            let (reader, access) = try await f.unlocked()
            let final = try await reader.snapshot(vaultID: f.vaultID, using: access)
            let expected = seed + committers.flatMap(\.1)
            #expect(final.accounts.count == expected.count)
            #expect(Set(final.accounts.map(\.id)) == Set(expected.map(\.id)))
            #expect(final.revision == revisions.max())
            #expect(Set(try await reader.listing().map(\.vaultID)) == Set([f.vaultID] + created))
            try f.verify()
            try CommitProbe(f: f).expectRegistryMatchesStore()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func racingUnlocksRepairTheMissingStubAndGrantEveryCaller() async throws {
        let seed = accounts("seed", 3)
        try await VaultStoreFixture.with(accounts: seed, historyRows: 3, stubAbsent: true) { f in
            let callers = 4
            let barrier = Barrier(parties: callers)
            let sessions = (0..<callers).map { _ in
                Session(store: f.makeStore(lockWait: Self.lockWait), access: f.beginAccess(), vaultID: f.vaultID, proof: f.proof)
            }
            #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: true))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in sessions {
                    group.addTask {
                        await barrier.arrive()
                        try await worker.unlock()
                        let snapshot = try await worker.store.snapshot(vaultID: worker.vaultID, using: worker.access)
                        #expect(Set(snapshot.accounts.map(\.id)) == Set(seed.map(\.id)))
                    }
                }
                try await group.waitForAll()
            }

            #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: false))
            #expect(try Data(contentsOf: f.vaultFile) == StoreAnchors.stubBytes(ids: f.ids))
            #expect(f.env.defaults.string(forKey: StoreAnchors.witnessKey) == f.ids.storeID.uuidString)
            try f.verify()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func racingMigrationsMigrateOnceAndEveryCallerUnlocks() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try LegacyV1.make(profileID: env.profileID, accounts: accounts("legacy", 3))
            try legacy.write(to: env.directory)
            let callers = 3
            let barrier = Barrier(parties: callers)
            let stores = (0..<callers).map { _ in (tracker.makeStore(env: env, lockWait: Self.lockWait), newAccess(env.profileID)) }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for (store, access) in stores {
                    group.addTask {
                        await barrier.arrive()
                        // A state that changed between the route and the lock is re-routed once inside `unlock`; a caller that
                        // loses both races sees `stateChanged` and asks again, at most as often as there are other migrators.
                        try await retrying(stateChangedRetries: callers - 1) {
                            try await store.unlock(
                                vaultID: legacy.vaultID, credentialID: legacy.proof.credentialID, prf: legacy.proof.prf,
                                confirmMigration: true, access: access, verifying: nil, scratchWarning: nil
                            )
                        }
                        let snapshot = try await store.snapshot(vaultID: legacy.vaultID, using: access)
                        let byID: (CredentialAccount, CredentialAccount) -> Bool = { $0.id.uuidString < $1.id.uuidString }
                        #expect(snapshot.accounts.sorted(by: byID) == legacy.accounts.sorted(by: byID))
                    }
                }
                try await group.waitForAll()
            }

            let names = try FileManager.default.contentsOfDirectory(atPath: env.directory.path)
            #expect(names.filter { $0.hasPrefix("Credentials.vault.pre-v2") } == ["Credentials.vault.pre-v2"], "exactly one backup")
            #expect(try Data(contentsOf: env.directory.appendingPathComponent("Credentials.vault.pre-v2")) == legacy.bytes)
            #expect(names.filter { $0.hasPrefix("Credentials.store.migrating") }.isEmpty, "no pending store left")
            guard case .provisional(_, let stubMissing) = StoreAnchors.evaluate(
                directory: env.directory, profileID: env.profileID, defaults: env.defaults
            ) else {
                Issue.record("the migrated directory is not a settled provisional store")
                return
            }
            #expect(!stubMissing)
        }
    }
}
