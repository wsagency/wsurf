// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Pro only, excluded from the default run: needs `TEST_RUNNER_WSURF_VAULT_BENCHMARK=1` in the environment of
/// `xcodebuild test` (Tasks 16/17 set it). Builds a store whose history exceeds 1 GB and verifies it once.
struct VaultVerificationBenchmark {
    @Test(
        .tags(.benchmark),
        .enabled(if: ProcessInfo.processInfo.environment["WSURF_VAULT_BENCHMARK"] == "1"),
        .timeLimit(.minutes(30))
    )
    func gigabyteHistoryVerifiesWithBoundedResidentSize() throws {
        let rowBytes = StoreFormat.historyRowBytes
        let rows = 1_000_000_000 / rowBytes + 5  // just over 1 GB of sealed history
        let accounts = [VaultFixtures.account(username: "ada", origin: "https://a.example")]
        let build = ContinuousClock.now
        let f = try VaultStoreFixture.make(accounts: accounts, historyRows: rows, historyRowBytes: rowBytes)
        defer { f.env.cleanUp() }
        let buildTime = ContinuousClock.now - build

        let before = residentBytes()
        var peak = before
        let start = ContinuousClock.now
        try f.verify(isCancelled: {
            peak = max(peak, residentBytes())
            return false
        })
        let elapsed = ContinuousClock.now - start
        let growthMB = (peak - before) / 1024 / 1024
        print("VaultVerificationBenchmark: \(rows) rows x \(rowBytes) B, fixture \(buildTime), verification \(elapsed), resident growth \(growthMB) MB")
        #expect(growthMB < 256, "resident size grew by \(growthMB) MB while verifying > 1 GB of history")
    }
}
