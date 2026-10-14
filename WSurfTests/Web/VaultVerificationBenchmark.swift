// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

/// Pro only, excluded from the default run: needs `WSURF_VAULT_BENCHMARK=1` in the environment of the test host (the Pro runner
/// sets it only in its own generated `.xctestrun`; a SKIPPED case is not a pass).
/// Builds ONE store with at least 100 000 history rows holding at least 1 GB of
/// plaintext (the spec's many-rows-and-large-store case, not two separate fixtures) and verifies it once.
struct VaultVerificationBenchmark {
    private static let rows = 100_000
    private static let rowBytes = 11_000  // 100 000 x 11 000 B = 1.1 GB, above 1 GiB (1 073 741 824 B)

    @Test(
        .tags(.benchmark),
        .enabled(if: ProcessInfo.processInfo.environment["WSURF_VAULT_BENCHMARK"] == "1"),
        .timeLimit(.minutes(30))
    )
    func hundredThousandRowsOverAGigabyteVerifyWithBoundedResidentSize() throws {
        let requestedRows = Self.rows
        let requestedRowBytes = Self.rowBytes
        let accounts = [VaultFixtures.account(username: "ada", origin: "https://a.example")]
        let build = ContinuousClock.now
        let f = try VaultStoreFixture.make(accounts: accounts, historyRows: requestedRows, historyRowBytes: requestedRowBytes)
        defer { f.env.cleanUp() }
        let buildTime = ContinuousClock.now - build

        // What actually reached the database (history = every non-account row; `sealed` is the stored ciphertext), not the request.
        let stored = try f.read { db in
            try Row.fetchOne(
                db, sql: "SELECT COUNT(*), COALESCE(SUM(LENGTH(sealed)), 0) FROM record WHERE vaultID = ? AND kind != 'account'",
                arguments: [f.vaultID.lowerText]
            )
        }
        let rows: Int = try #require(stored)[0]
        let sealedBytes: Int64 = try #require(stored)[1]
        #expect(rows >= 100_000, "the fixture persisted \(rows) history rows")
        #expect(sealedBytes >= 1 << 30, "the fixture persisted \(sealedBytes) sealed history bytes")

        let before = residentBytes()
        var peak = before
        let start = ContinuousClock.now
        try f.verify(isCancelled: {
            peak = max(peak, residentBytes())
            return false
        })
        let elapsed = ContinuousClock.now - start
        let growthMB = (peak - before) / 1024 / 1024
        print(
            "VaultVerificationBenchmark: requested \(requestedRows) rows x \(requestedRowBytes) B; persisted \(rows) history rows, "
                + "\(sealedBytes) sealed bytes; fixture \(buildTime), verification \(elapsed), "
                + "resident before \(before / 1024 / 1024) MB, peak \(peak / 1024 / 1024) MB, growth \(growthMB) MB"
        )
        #expect(growthMB < 256, "resident size grew by \(growthMB) MB while verifying \(rows) rows (\(sealedBytes) sealed bytes)")
    }
}
