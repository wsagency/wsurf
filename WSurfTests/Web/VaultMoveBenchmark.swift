// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

/// Pro only, excluded from the default run: needs `WSURF_VAULT_BENCHMARK=1` in the environment of the test host (the Pro runner
/// sets it only in its own generated `.xctestrun`; a SKIPPED case is not a pass).
/// Deletes an account whose history is moved to Trash one row at a time, undeletes it, and watches the resident size.
struct VaultMoveBenchmark {
    private static let growthLimitMB: Int64 = 256

    @Test(
        .tags(.benchmark),
        .enabled(if: ProcessInfo.processInfo.environment["WSURF_VAULT_BENCHMARK"] == "1"),
        .timeLimit(.minutes(30))
    )
    func accountWithMoreThan32MBHistoryDeletesWithBoundedResidentSize() async throws {
        try await Self.deleteWithHistory(rows: 32_000_000 / StoreFormat.historyRowBytes + 1)
    }

    @Test(
        .tags(.benchmark),
        .enabled(if: ProcessInfo.processInfo.environment["WSURF_VAULT_BENCHMARK"] == "1"),
        .timeLimit(.minutes(60))
    )
    func gigabyteHistoryDeletesWithBoundedResidentSize() async throws {
        try await Self.deleteWithHistory(rows: 1_000_000_000 / StoreFormat.historyRowBytes + 5)  // just over 1 GB of sealed history
    }

    /// The MOVE authenticates every history row of the vault it walks (a row's owner is only trustworthy once it is opened), so
    /// the cost of deleting a small account grows with the history of the others. Time and resident size of exactly that.
    @Test(
        .tags(.benchmark),
        .enabled(if: ProcessInfo.processInfo.environment["WSURF_VAULT_BENCHMARK"] == "1"),
        .timeLimit(.minutes(60))
    )
    func smallAccountDeleteAuthenticatesAGigabyteOfOtherHistoryWithBoundedResidentSize() async throws {
        let rows = 1_000_000_000 / StoreFormat.historyRowBytes + 5
        let victim = VaultFixtures.account(username: "ada", origin: "https://a.example")
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(
            accounts: [victim, bystander], historyRows: 1, historyRowBytes: StoreFormat.historyRowBytes,
            extraHistory: [FixtureHistoryRun(subject: .password, count: rows, ownerIndex: 1)]
        ) { f in
            let (store, access) = try await f.unlocked()
            let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
            let before = residentBytes()
            let sampler = Task.detached(priority: .utility) { () -> Int64 in
                var peak: Int64 = 0
                while !Task.isCancelled {
                    peak = max(peak, residentBytes())
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return max(peak, residentBytes())
            }
            let start = ContinuousClock.now
            _ = try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: revision, using: access)
            let deleteTime = ContinuousClock.now - start
            sampler.cancel()
            let growthMB = (max(await sampler.value, before) - before) / 1024 / 1024
            print("VaultMoveBenchmark: small delete over \(rows) other rows, delete \(deleteTime), resident growth \(growthMB) MB")
            // The victim's one revision (`historyRows: 1` is owned by `accounts[0]`) plus the `trashEntry`, which is owned by the account too.
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: victim.id) == 2)
            #expect(growthMB < Self.growthLimitMB, "resident size grew by \(growthMB) MB authenticating \(rows) bystander rows")
        }
    }

    /// Runs `body` with the resident size sampled every 20 ms (a MOVE has no progress callback to hook, unlike verification);
    /// returns its result, wall time and resident growth in MB over the size at entry.
    private static func sampled<T: Sendable>(_ body: () async throws -> T) async throws -> (value: T, time: Duration, growthMB: Int64) {
        let before = residentBytes()
        let sampler = Task.detached(priority: .utility) { () -> Int64 in
            var peak: Int64 = 0
            while !Task.isCancelled {
                peak = max(peak, residentBytes())
                try? await Task.sleep(for: .milliseconds(20))
            }
            return max(peak, residentBytes())
        }
        let start = ContinuousClock.now
        let value: T
        do {
            value = try await body()
        } catch {
            sampler.cancel()
            _ = await sampler.value
            throw error
        }
        let time = ContinuousClock.now - start
        sampler.cancel()
        return (value, time, (max(await sampler.value, before) - before) / 1024 / 1024)
    }

    /// The identities of `owner`'s revisions in `vault`, streamed one row at a time (`moveRevisions` would hold every sealed row,
    /// about 1 GB here, and inflate the resident baseline being measured).
    private static func revisionKeys(_ f: VaultStoreFixture, in vault: UUID, owner: UUID) throws -> Set<MoveRowKey> {
        try f.read { db in
            var keys: Set<MoveRowKey> = []
            try StoreTables.forEachHistoryRecord(db, vaultID: vault) { row in
                if row.kind == .revision && row.ownerID == owner {
                    keys.insert(row.moveKey)
                }
            }
            return keys
        }
    }

    /// The id of `owner`'s whole-account Trash entry, without opening every Trash row (`trashEntry(of:)` decrypts them all).
    private static func trashEntryID(_ f: VaultStoreFixture, owner: UUID) throws -> UUID {
        let text = try f.read { db in
            try String.fetchOne(
                db, sql: "SELECT recordID FROM record WHERE vaultID = ? AND kind = 'trashEntry' AND ownerID = ?",
                arguments: [f.trashID.lowerText, owner.lowerText]
            )
        }
        return try #require(text.flatMap { UUID(uuidString: $0) })
    }

    /// `rows` full-size history rows owned by one account beside a bystander: delete (MOVE to Trash), verify, undelete (MOVE back),
    /// verify. The resident size is sampled across each transition and each must stay bounded; the end state is the original pair.
    private static func deleteWithHistory(rows: Int) async throws {
        let rowBytes = StoreFormat.historyRowBytes
        let victim = VaultFixtures.account(username: "ada", origin: "https://a.example")
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        let build = ContinuousClock.now
        try await VaultStoreFixture.with(accounts: [victim, bystander], historyRows: rows, historyRowBytes: rowBytes) { f in
            let buildTime = ContinuousClock.now - build
            let (store, access) = try await f.unlocked()
            let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
            let originalKeys = try revisionKeys(f, in: f.vaultID, owner: victim.id)
            #expect(originalKeys.count == rows)

            let deleted = try await sampled {
                try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: revision, using: access)
            }
            #expect(deleted.value.revision == revision + 1)
            let counts = try f.read { db in
                (
                    try StoreTables.recordCount(db, vaultID: f.vaultID, kind: .revision),
                    try StoreTables.recordCount(db, vaultID: f.trashID, kind: .revision)
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == rows)
            let afterDelete = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(afterDelete.accounts.map(\.id) == [bystander.id])
            let verifyDeleted = ContinuousClock.now
            try f.verify()
            let verifyDeletedTime = ContinuousClock.now - verifyDeleted

            let entryID = try trashEntryID(f, owner: victim.id)
            let restored = try await sampled {
                try await store.undelete(vaultID: f.vaultID, entryID: entryID, expectedRevision: deleted.value.revision, using: access)
            }
            #expect(restored.value.revision == deleted.value.revision + 1)
            let afterUndelete = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(Set(afterUndelete.accounts.map(\.id)) == [victim.id, bystander.id])
            #expect(afterUndelete.accounts.first { $0.id == victim.id } == victim)
            #expect(afterUndelete.accounts.first { $0.id == bystander.id } == bystander)
            #expect(try f.read { try StoreTables.recordCount($0, vaultID: f.trashID, kind: .revision) } == 0)
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: victim.id) == 0)
            #expect(try revisionKeys(f, in: f.vaultID, owner: victim.id) == originalKeys)
            try f.expectMoveRegistryMatchesHeads()
            let verifyRestored = ContinuousClock.now
            try f.verify()
            print(
                "VaultMoveBenchmark: \(rows) rows x \(rowBytes) B, fixture \(buildTime), "
                    + "delete \(deleted.time) (growth \(deleted.growthMB) MB), verification \(verifyDeletedTime), "
                    + "undelete \(restored.time) (growth \(restored.growthMB) MB), verification \(ContinuousClock.now - verifyRestored)"
            )
            #expect(deleted.growthMB < growthLimitMB, "resident size grew by \(deleted.growthMB) MB while moving \(rows) history rows to Trash")
            #expect(restored.growthMB < growthLimitMB, "resident size grew by \(restored.growthMB) MB while moving \(rows) history rows back")
        }
    }
}
