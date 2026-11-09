// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// D5 PR-7: the vault reads that answer a question about every credential without a secret leaving the store. `passkeyRoutes` gives
// routing each passkey's relying party, algorithm and credential ID, never its key. Synthetic vaults only; a failure never prints a
// value. The refusals and the revocation of these reads are in `VaultAutofillReadTests`, with every other read.
struct VaultMatchReadTests {
    private static let ids = (1...3).map { Data(repeating: UInt8($0), count: 32) }

    /// Passkeys of two relying parties, one of them EdDSA (-8), on two credentials, and a credential with none.
    private static func passkeyAccounts() throws -> [CredentialAccount] {
        let first = try VaultFixtures.passkey(rpID: "login.example.test", credentialID: ids[0])
        var second = try VaultFixtures.passkey(rpID: "login.example.test", credentialID: ids[1])
        second.algorithm = -8
        let third = try VaultFixtures.passkey(rpID: "other.example.test", credentialID: ids[2])
        return [
            VaultFixtures.account(username: "ada", origin: "https://login.example.test", passkeys: [first, second]),
            VaultFixtures.account(username: "grace", origin: "https://other.example.test", passkeys: [third]),
            VaultFixtures.account(username: "alan", origin: "https://plain.example.test"),
        ]
    }

    /// Every passkey of the vault as routing sees it, in the vault's order, at the vault's revision, and nothing else: the type has no
    /// field for a key, a user handle or a user name.
    @Test func thePasskeyRoutesHoldNoKey() async throws {
        try await VaultStoreFixture.with(accounts: try Self.passkeyAccounts()) { f in
            let (store, access) = try await f.unlocked()
            let routes = try await store.passkeyRoutes(vaultID: f.vaultID, using: access)
            let stored = try await store.snapshot(vaultID: f.vaultID, using: access)
            let expected = stored.accounts.flatMap(\.passkeys).map {
                PasskeyRoute(rpID: $0.rpID, algorithm: $0.algorithm, credentialID: $0.credentialID)
            }
            #expect(expected.count == 3)
            #expect(routes.passkeys == expected)
            #expect(routes.vaultID == f.vaultID && routes.revision == stored.revision)
            #expect(Mirror(reflecting: routes).children.map(\.label) == ["vaultID", "revision", "passkeys"])
            let first = try #require(routes.passkeys.first)
            #expect(Mirror(reflecting: first).children.map(\.label) == ["rpID", "algorithm", "credentialID"])
        }
    }
}
