// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// A real Passwords library through the real coordinator and a real store: stage (preview, classify, review), commit, reopen, stage the
// same transfer again against the committed vault, and save one edit. Synthetic data only (`ExchangeScale`).
extension CredentialExchangeCoordinatorTests {
    /// The time limit catches a step that grows with the square of the library, without timing every step on a loaded machine.
    /// Each duration is printed as its step ends, so a slow step shows even when a later one hits the limit.
    @Test(.timeLimit(.minutes(2)))
    func importOf20000ItemsPreviewsCommitsAndReimports() async throws {
        let clock = ContinuousClock()
        let count = 20_000
        let transfer = try ExchangeScale.transfer(items: count)
        var timings: [(step: String, time: Duration)] = []
        func time<T>(_ step: String, _ work: () async throws -> T) async rethrows -> T {
            let start = clock.now
            defer {
                let elapsed = clock.now - start
                timings.append((step, elapsed))
                print("[scale] \(step): \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
            }
            return try await work()
        }

        // The codec alone, against an empty vault.
        let empty = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
        let preview = try await time("preview") { try CredentialExchangeCodec.preview(transfer, against: empty) }
        #expect(preview.candidates.count == count)
        #expect(preview.omitted.isEmpty)

        try await withFixture { f in
            try await f.seed([])

            try await time("stage (preview, classify, review)") { try await f.stage(transfer) }
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.candidates.count == count)
            #expect(review.isResolved)
            #expect(counts(review.outcome) == [count, 0])

            _ = try await time("commit") { try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            let committed = try await f.stored()
            #expect(committed.accounts.count == count)
            #expect(committed.accounts.filter { !$0.passkeys.isEmpty }.count == count / 10)
            #expect(committed.accounts.allSatisfy { $0.notes?.count == 1 && $0.password != nil })

            // Reopen: lock, then unlock verifies every stored row again; then read the whole vault back.
            f.manager.lock(reason: .manual)
            try await time("reopen (unlock and verify)") { try await f.unlock(f.manager) }
            let reloaded = try await time("reload (snapshot)") { try await f.stored() }
            #expect(reloaded.accounts.count == count)
            #expect(Set(reloaded.accounts.map(\.id)) == Set(committed.accounts.map(\.id)))

            // The same transfer again against 20,000 stored items: every login is a conflict to decide, everything else is unchanged.
            try await time("stage again (20,000 x 20,000)") { try await f.stage(transfer) }
            let again = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(again.candidates.count == count)
            #expect(!again.isResolved)
            #expect(again.candidates.allSatisfy { $0.records.contains { $0.isConflict && $0.kind == .password } })
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            // One edit pays for the whole vault too.
            let victim = try #require(reloaded.accounts.first)
            var edited = victim
            edited.password = "changed-password"
            let stamp = try #require(reloaded.stamps[victim.id])
            let epoch = try #require(f.manager.authorizationEpoch)
            _ = try await time("single edit") {
                try await f.manager.commitAccounts(
                    [AccountWrite(accountID: victim.id, expected: .stamp(stamp), replacement: edited)], authorizedEpoch: epoch
                )
            }
            #expect(try await f.stored().accounts.first { $0.id == victim.id }?.password == "changed-password")
        }

    }

    /// A decision in the review is local to its own item. Deciding 1,000 items of a 25,000-item review must cost 1,000 small steps, not
    /// 1,000 passes over the whole review; the budget is generous, and the loop stops at it so a regression fails in seconds, not hours.
    @Test(.timeLimit(.minutes(2)))
    func deciding1000ItemsOfA25000ItemReviewIsNotQuadratic() async throws {
        let clock = ContinuousClock()
        let transfer = try ExchangeScale.transfer(items: 25_000)
        try await withFixture { f in
            try await f.seed([])
            let staging = try await clock.measure { try await f.stage(transfer) }
            print("[scale] stage 25,000: \(staging.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            let records = review.candidates.prefix(1_000).compactMap(\.records.first)
            #expect(records.count == 1_000)

            let started = clock.now
            var decided = 0
            for record in records where clock.now - started < .seconds(30) {
                try f.coordinator.choose(.skip, for: record.incoming, owner: f.owner)
                decided += 1
            }
            let elapsed = clock.now - started
            print("[scale] decide \(decided) of 1,000: \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
            #expect(decided == 1_000, "only \(decided) of 1,000 decisions fit in 30 seconds")
        }
    }
}
