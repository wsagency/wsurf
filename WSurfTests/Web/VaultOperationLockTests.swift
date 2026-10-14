// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

struct VaultOperationLockTests {
    nonisolated private func acquire(_ mode: OperationLock.Mode, in directory: URL, wait: Duration = .milliseconds(100)) async throws -> OperationLockHold {
        try await OperationLock.acquire(in: directory, mode: mode, wait: wait)
    }

    nonisolated private func expectBusy(_ mode: OperationLock.Mode, in directory: URL) async {
        await #expect(throws: CredentialStoreError.storeBusy) { try await acquire(mode, in: directory) }
    }

    nonisolated private func acquireAndDrop(in directory: URL) async throws {
        _ = try await acquire(.exclusive, in: directory)
    }

    @Test func exclusiveWaitsThenReportsStoreBusy() async throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let shared = try await acquire(.shared, in: environment.directory)
        defer { shared.release() }

        let start = ContinuousClock.now
        await #expect(throws: CredentialStoreError.storeBusy) {
            try await acquire(.exclusive, in: environment.directory, wait: .milliseconds(150))
        }
        #expect(ContinuousClock.now - start >= .milliseconds(140))
    }

    @Test func twoSharedHoldsCoexistAndEachBlocksTheWriter() async throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let first = try await acquire(.shared, in: environment.directory)
        let second = try await acquire(.shared, in: environment.directory)
        defer { first.release(); second.release() }

        await expectBusy(.exclusive, in: environment.directory)
        first.release()
        await expectBusy(.exclusive, in: environment.directory)  // the second hold alone still blocks the writer
        second.release()
        let writer = try await acquire(.exclusive, in: environment.directory)  // both gone: the writer gets in
        defer { writer.release() }
        await expectBusy(.shared, in: environment.directory)
    }

    @Test func sharedHolderRequestingExclusiveTimesOutInsteadOfUpgrading() async throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let shared = try await acquire(.shared, in: environment.directory)
        defer { shared.release() }

        await expectBusy(.exclusive, in: environment.directory)
        let third = try await acquire(.shared, in: environment.directory)
        third.release()
        // The original shared hold survived the failed upgrade: a writer is still refused.
        await expectBusy(.exclusive, in: environment.directory)
    }

    @Test func exclusiveExcludesShared() async throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let writer = try await acquire(.exclusive, in: environment.directory)
        defer { writer.release() }

        await expectBusy(.shared, in: environment.directory)
        await expectBusy(.exclusive, in: environment.directory)
    }

    @Test func releaseIsIdempotentAndCannotDropALaterOwner() async throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let old = try await acquire(.exclusive, in: environment.directory)
        old.release()
        let replacement = try await acquire(.exclusive, in: environment.directory)
        defer { replacement.release() }

        old.release()  // second release of the old hold must not touch the replacement's lock
        await expectBusy(.shared, in: environment.directory)
        await expectBusy(.exclusive, in: environment.directory)
    }

    @Test func deinitReleasesTheLockToTheNextOwner() async throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        try await acquireAndDrop(in: environment.directory)
        let replacement = try await acquire(.exclusive, in: environment.directory)
        defer { replacement.release() }

        await expectBusy(.shared, in: environment.directory)  // the replacement genuinely owns it
    }
}
