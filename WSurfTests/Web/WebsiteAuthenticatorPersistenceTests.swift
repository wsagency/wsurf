// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
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
            let permissions = try #require(
                FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? NSNumber
            ).intValue
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: permissions], ofItemAtPath: fixture.directory.path
                )
            }

            await #expect(throws: (any Error).self) {
                _ = try await get(fixture, user, request: assertion(userVerification: .required))
            }
            #expect(user.prompts.count == 1 && user.verifications == 1)

            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fixture.directory.path)
            #expect(try fixture.bytes() == before)
            let stored = try await fixture.manager.snapshot()
            let passkey = try #require(stored.accounts.flatMap(\.passkeys).first)
            #expect(passkey.lastSignedAt == nil)
        }
    }
}
