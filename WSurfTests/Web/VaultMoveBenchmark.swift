// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

/// Pro only, excluded from the default run: needs `TEST_RUNNER_WSURF_VAULT_BENCHMARK=1` in the environment of `xcodebuild test`
/// (Tasks 16/17 set it). Deletes an account whose history is moved to Trash one row at a time and watches the resident size.
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
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: victim.id) == 1)
            #expect(growthMB < Self.growthLimitMB, "resident size grew by \(growthMB) MB authenticating \(rows) bystander rows")
        }
    }

    /// `rows` full-size history rows owned by one account; deletes it, then verifies. The resident size is sampled every 20 ms
    /// while the delete runs (the delete has no progress callback to hook, unlike verification).
    private static func deleteWithHistory(rows: Int) async throws {
        let rowBytes = StoreFormat.historyRowBytes
        let victim = VaultFixtures.account(username: "ada", origin: "https://a.example")
        let build = ContinuousClock.now
        try await VaultStoreFixture.with(accounts: [victim], historyRows: rows, historyRowBytes: rowBytes) { f in
            let buildTime = ContinuousClock.now - build
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
            let receipt = try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: revision, using: access)
            let deleteTime = ContinuousClock.now - start
            sampler.cancel()
            let peak = max(await sampler.value, before)

            #expect(receipt.revision == revision + 1)
            let counts = try f.read { db in
                (
                    try StoreTables.recordCount(db, vaultID: f.vaultID, kind: .revision),
                    try StoreTables.recordCount(db, vaultID: f.trashID, kind: .revision)
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == rows)
            let verifyStart = ContinuousClock.now
            try f.verify()
            let growthMB = (peak - before) / 1024 / 1024
            print(
                "VaultMoveBenchmark: \(rows) rows x \(rowBytes) B, fixture \(buildTime), delete \(deleteTime), "
                    + "verification \(ContinuousClock.now - verifyStart), resident growth \(growthMB) MB"
            )
            #expect(growthMB < growthLimitMB, "resident size grew by \(growthMB) MB while moving \(rows) history rows")
        }
    }
}
