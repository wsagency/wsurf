// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// D5 PR-7: the vault reads that answer a question about every credential without a secret leaving the store. `passkeyRoutes` gives
// routing each passkey's relying party, algorithm and credential ID, never its key; `passwordMatches` gives a password save the
// candidates and the ids of the credentials with the submitted username that hold its password, never a stored password. Synthetic vaults only; a
// failure never prints a value. The refusals and the revocation of these reads are in `VaultAutofillReadTests`, with every other read.
struct VaultMatchReadTests {
    private static let ids = (1...3).map { Data(repeating: UInt8($0), count: 32) }
    /// One password written two ways that `String` compares as equal (a precomposed "é", and "e" with a combining accent).
    private static let composed = "pw-caf\u{E9}-41", decomposed = "pw-cafe\u{301}-41"

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

    /// The route asks a vault's passkey routes the ceremony's own question (`WebsiteAuthenticator.canAssert`). For every relying party
    /// and allow list below, the routes hold a passkey for the request exactly when the ceremony would offer one from the whole
    /// credentials: the same relying party only (a parent or another case is another one), ES256 only, an allowed ID or any.
    @Test func theRouteAndTheCeremonyMeetTheSamePasskeys() async throws {
        try await VaultStoreFixture.with(accounts: try Self.passkeyAccounts()) { f in
            let (store, access) = try await f.unlocked()
            let routes = try await store.passkeyRoutes(vaultID: f.vaultID, using: access).passkeys
            let accounts = try await store.snapshot(vaultID: f.vaultID, using: access).accounts
            let allowLists: [[Data]] = [[]] + (Self.ids + [Data(repeating: 9, count: 32)]).map { [$0] } + [Self.ids]
            var offeredCount = 0
            for rpID in ["login.example.test", "other.example.test", "example.test", "Login.example.test"] {
                for allowed in allowLists {
                    let routed = routes.contains {
                        WebsiteAuthenticator.canAssert(
                            passkeyRPID: $0.rpID, algorithm: $0.algorithm, credentialID: $0.credentialID, rpID: rpID, allowed: allowed
                        )
                    }
                    let offered = !WebsiteAuthenticator.assertionCandidates(accounts, rpID: rpID, allowed: allowed).isEmpty
                    #expect(routed == offered, "\(rpID), allowing \(allowed.count) IDs")
                    offeredCount += offered ? 1 : 0
                }
            }
            // Both answers occur: login.example.test with any list but the EdDSA passkey's, the unknown ID's or the other party's
            // ID (3 of 6), and other.example.test with the empty list, its own ID or all of them (3 of 6).
            #expect(offeredCount == 6)
        }
    }

    /// The ids of exactly the credentials with the username asked about whose password is the one asked about, by the same `String`
    /// equality the save offer used on whole credentials: a password written another canonically equal way matches, another case
    /// does not, and a credential without a password matches nothing. Another username's credential is never named, even with the
    /// same password. Beside them, the candidates and the excluded websites of the same read, and no password.
    @Test func passwordMatchesNameTheCredentialsThatHoldThePassword() async throws {
        let first = VaultFixtures.account(username: "ada", password: Self.composed, origin: "https://login.example.test")
        let second = VaultFixtures.account(username: "grace", password: Self.decomposed, origin: "https://other.example.test")
        let third = VaultFixtures.account(username: "alan", password: "pw-other-17", origin: "https://login.example.test")
        let none = VaultFixtures.account(username: "kay", password: nil, origin: "https://login.example.test")
        let accounts = [first, second, third, none]
        try await VaultStoreFixture.with(accounts: accounts, blockedOrigins: ["https://blocked.example.test"]) { f in
            let (store, access) = try await f.unlocked()
            // Grace's password is Ada's, spelled the other way: each username names its own credential only.
            let cases: [(String, String, Set<UUID>)] = [
                ("ada", Self.composed, [first.id]), ("ada", Self.decomposed, [first.id]), ("grace", Self.composed, [second.id]),
                ("Ada", Self.composed, []), ("alan", "pw-other-17", [third.id]), ("alan", "PW-OTHER-17", []), ("alan", Self.composed, []),
                ("kay", "", []),
            ]
            for (index, (username, password, expected)) in cases.enumerated() {
                let matches = try await store.passwordMatches(vaultID: f.vaultID, username: username, password: password, using: access)
                #expect(matches.samePassword == expected, "case \(index)")
            }
            let matches = try await store.passwordMatches(vaultID: f.vaultID, username: "ada", password: Self.composed, using: access)
            let listed = try await store.autofillCandidates(vaultID: f.vaultID, using: access)
            #expect(matches.vaultID == f.vaultID && matches.revision == listed.revision)
            #expect(matches.accounts == listed.candidates)
            #expect(matches.blockedPasswordOrigins == ["https://blocked.example.test"])
            #expect(
                Mirror(reflecting: matches).children.map(\.label) == ["vaultID", "revision", "accounts", "blockedPasswordOrigins", "samePassword"]
            )
            var dumped = ""
            dump(matches, to: &dumped)
            let printed = [dumped, String(reflecting: matches)]
            let passwords = accounts.compactMap(\.password)
            #expect(!printed.contains { text in passwords.contains { text.contains($0) } }, "the matches hold a password")
        }
    }
}
