// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

@MainActor
extension WebsiteAuthenticatorCeremonyTests {
    @Test(.boundedWebViews) func assertionVaultWriteFailureRefusesDelivery() async throws {
        try await withFixture { fixture in
            _ = try await create(fixture, User())
            let before = try fixture.bytes()
            let user = User()
            user.respond = { .approved(choice: $0.choices.first?.id) }
            // A commit takes the operation lock shared and writes in one `BEGIN IMMEDIATE` transaction, so another connection's
            // open write transaction is what fails it. WAL keeps every read (and so the prompt and the verification) working: the
            // real write fails, after the user approved, once the store's busy timeout runs out. The test-owned holder connection
            // keeps its transaction open across `writeWithoutTransaction` calls (`allowsUnsafeTransactions`) and always rolls it
            // back and closes in the `defer`, so no thread, signal or semaphore can outlive a failure or a cancellation.
            var configuration = Configuration()
            configuration.allowsUnsafeTransactions = true
            let holder = try DatabaseQueue(
                path: fixture.profile.supportDirectory.appendingPathComponent("Credentials.store").path, configuration: configuration
            )
            do {
                defer {
                    try? holder.writeWithoutTransaction { try $0.rollback() }
                    try? holder.close()
                }
                try holder.writeWithoutTransaction { try $0.beginTransaction(.immediate) }

                await #expect(throws: (any Error).self) {
                    _ = try await get(fixture, user, request: assertion(userVerification: .required))
                }
                #expect(user.prompts.count == 1 && user.verifications == 1)
            }
            #expect(try fixture.bytes() == before)
            let stored = try await fixture.manager.snapshot()
            let passkey = try #require(stored.accounts.flatMap(\.passkeys).first)
            #expect(passkey.lastSignedAt == nil)
        }
    }
}
