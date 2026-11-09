// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// Password health (S4a): the weak and reused rules, and the report the vault makes of them (`ProfileVaultStore.passwordHealth`).
// Only flags leave the vault: no password, digest or length. Websites are RFC 2606 names, every password is synthetic, and a failed
// check compares to a Bool first, so its message never prints a password.

@MainActor
struct PasswordHealthTests {
    private func weaknesses(_ password: String, username: String = "", sites: [String] = []) -> Set<PasswordWeakness> {
        PasswordHealth.weaknesses(of: password, username: username, siteNames: sites)
    }

    private func login(_ password: String?, at origins: [String], username: String = "ada", id: UUID = UUID()) -> CredentialAccount {
        CredentialAccount(
            id: id, username: username, displayName: nil, origins: origins, loginURLs: origins.compactMap { URL(string: "\($0)/login") },
            password: password, passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func report(_ accounts: [CredentialAccount]) -> PasswordHealthReport {
        PasswordHealth.report(vaultID: UUID(), revision: 7, accounts: accounts)
    }

    // MARK: - Weak

    @Test func aPasswordShorterThanEightCharactersIsShort() {
        #expect(weaknesses("Kx9!vQ2").contains(.short))
        #expect(!weaknesses("Kx9!vQ2m").contains(.short))
    }

    @Test func aPasswordUnderTwelveCharactersOfOneKindIsWeak() {
        for weak in ["84719305", "mxqvbtrzkw", "MXQVBTRZKW", "žčćšđmxqvb"] {
            #expect(weaknesses(weak).contains(.oneKind), "example \(weak.count)")
        }
        for strong in ["mxqvbtrzkwpl", "84719305284730", "mxqvbTrzkw", "mxqvb7rzkw", "mxqvb-rzkw"] {
            #expect(!weaknesses(strong).contains(.oneKind), "example \(strong.count)")
        }
    }

    @Test func aPasswordThatIsAtLeastHalfAPatternIsWeak() {
        let patterns = [
            "aaaaaaaa", "abcabcabc", "ABCABCabc9", "123456Xy", "qwertyZ9", "fedcba12", "9876543x", "asdfghQ!",
            // Exactly half: six of twelve.
            "abcdefXq9!Lm",
        ]
        for weak in patterns {
            #expect(weaknesses(weak).contains(.pattern), "pattern example of \(weak.count)")
        }
        // Less than half a pattern, a run of five, three of a kind, a run that changes sequence, and a strong password.
        for strong in ["abcdefXq9!Lm4", "abcdeXq9!Lm4", "aaaXq9!Lm4k", "abcqweXq9!", "Tr0ub4dor&3x", "correct-horse-battery"] {
            #expect(!weaknesses(strong).contains(.pattern), "non-pattern example of \(strong.count)")
        }
    }

    @Test func aPasswordHoldingTheUsernameOrTheWebsitesNameIsPersonal() {
        #expect(weaknesses("Ada.Lovelace#2031", username: "ada.lovelace@example.com").contains(.personal))
        #expect(weaknesses("xQ9!grace-hopper", username: "grace-hopper").contains(.personal))
        #expect(weaknesses("Example#2031x!", sites: ["example"]).contains(.personal))
        // Fewer than four characters do not count, and only the part before "@" of an email does.
        #expect(!weaknesses("ada#2031xQ!m", username: "ada").contains(.personal))
        #expect(!weaknesses("abc#2031xQ!m", sites: ["abc"]).contains(.personal))
        #expect(!weaknesses("example#2031xQ!", username: "ada@example.com").contains(.personal))
    }

    @Test func aStrongPasswordHasNoWeakness() {
        for strong in ["Tr0ub4dor&3x", "correct-horse-battery", "x7Kq!m2Pz9Lw"] {
            #expect(weaknesses(strong, username: "ada@example.com", sites: ["example"]).isEmpty, "example of \(strong.count)")
        }
    }

    /// The passwords WSurf generates pass every rule.
    @Test func generatedPasswordsAreNeverWeak() throws {
        for _ in 0..<200 {
            let generated = try SavedPassword.generate()
            #expect(weaknesses(generated, username: "ada@example.com", sites: ["example"]).isEmpty)
        }
    }

    /// The website's name is its registrable domain without the suffix: `login` of `login.example.com` is not it, `example` is.
    @Test func aWebsitesNameIsItsRegistrableDomainAndNotAnyLabel() {
        let notTheName = login("login#2031xQ!m", at: ["https://login.example.com"])
        let theName = login("example#2031xQ!", at: ["https://login.example.com"])
        let found = report([notTheName, theName]).findings
        #expect(found[notTheName.id] == nil)
        #expect(found[theName.id]?.weaknesses == [.personal])
    }

    @Test func anOriginsHostIsReadWithoutParsingAURL() {
        func host(_ origin: String) -> String? {
            PasswordHealth.hostBytes(of: origin).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(host("https://Login.Example.com:8443") == "login.example.com")
        #expect(host("https://example.co.uk/path") == "example.co.uk")
        #expect(host("https://[::1]:8443") == nil)
        #expect(host("example.com") == nil)
    }

    // MARK: - Reused

    @Test func theSamePasswordOnTwoWebsitesIsReusedByEveryCredentialThatHasIt() throws {
        let shared = "Kx9!vQ2#mW7p"
        let onLogin = login(shared, at: ["https://login.example.com"])
        let onOther = login(shared, at: ["https://example.org"])
        let onWWW = login(shared, at: ["https://www.example.com"])
        let elsewhere = login("Zt4$pL8@nR2w", at: ["https://example.net"])
        let found = report([onLogin, onOther, onWWW, elsewhere]).findings

        #expect(Set(found.keys) == [onLogin.id, onOther.id, onWWW.id])
        let reuses = try [onLogin, onOther, onWWW].map { try #require(found[$0.id]?.reuse) }
        #expect(Set(reuses.map(\.group)).count == 1, "one password, one group")
        #expect(reuses.map(\.otherSites) == [1, 1, 1])
        #expect([onLogin, onOther, onWWW].allSatisfy { found[$0.id]?.weaknesses.isEmpty == true })
    }

    /// `login.` and `www.` are one website, and so are the hosts of a two-part suffix: two accounts there with one password are not
    /// reuse.
    @Test func twoAccountsOnOneWebsiteAreNotReuse() {
        let shared = "Kx9!vQ2#mW7p"
        let accounts = [
            login(shared, at: ["https://login.example.com"]), login(shared, at: ["https://www.example.com"], username: "grace"),
            login("Zt4$pL8@nR2w", at: ["https://shop.example.co.uk"]), login("Zt4$pL8@nR2w", at: ["https://www.example.co.uk"]),
        ]
        #expect(report(accounts).findings.isEmpty)
    }

    @Test func aCredentialWithoutAWebsiteIsAWebsiteOfItsOwn() throws {
        let shared = "Kx9!vQ2#mW7p"
        let first = login(shared, at: [])
        let second = login(shared, at: [])
        let third = login(shared, at: ["https://example.com"])
        let found = report([first, second, third]).findings
        #expect(try [first, second, third].map { try #require(found[$0.id]?.reuse).otherSites } == [2, 2, 2])
    }

    /// A credential is listed for how many other websites save its password: one that holds every one of them itself is not.
    @Test func otherSitesCountsOnlyTheWebsitesACredentialDoesNotHold() throws {
        let shared = "Kx9!vQ2#mW7p"
        let both = login(shared, at: ["https://example.com", "https://example.org"])
        let one = login(shared, at: ["https://example.com"])
        let found = report([both, one]).findings
        #expect(found[both.id] == nil)
        #expect(try #require(found[one.id]?.reuse).otherSites == 1)
    }

    // MARK: - The report

    @Test func aReportListsOnlyFlaggedLoginsAndHoldsNoPasswordDigestOrLength() throws {
        let weak = login("qwerty12", at: ["https://example.com"])
        let strong = login("Kx9!vQ2#mW7p", at: ["https://example.org"])
        let none = login(nil, at: ["https://example.net"])
        let health = report([weak, strong, none])
        #expect(Set(health.findings.keys) == [weak.id])
        #expect(health.findings[weak.id]?.weaknesses == [.pattern])
        #expect(health.revision == 7)

        // What a report is made of: identities, a revision, a random group, a count of websites and named rules. Nothing else.
        #expect(Mirror(reflecting: health).children.map(\.label) == ["vaultID", "revision", "findings"])
        let finding = try #require(health.findings[weak.id])
        #expect(Mirror(reflecting: finding).children.map(\.label) == ["reuse", "weaknesses"])
        #expect(Mirror(reflecting: PasswordReuse(group: UUID(), otherSites: 1)).children.map(\.label) == ["group", "otherSites"])
        var dumped = ""
        dump(health, to: &dumped)
        #expect(!dumped.contains("qwerty12") && !dumped.contains("Kx9!vQ2#mW7p"), "a password reached the report")
    }

    @Test func eachReportDrawsNewGroups() throws {
        let shared = "Kx9!vQ2#mW7p"
        let accounts = [login(shared, at: ["https://example.com"]), login(shared, at: ["https://example.org"])]
        let first = try #require(report(accounts).findings[accounts[0].id]?.reuse?.group)
        let second = try #require(report(accounts).findings[accounts[0].id]?.reuse?.group)
        #expect(first != second)
    }

    // MARK: - Through the vault

    /// The manager's read: the vault's live credentials at its revision, as flags, read once as `.health`. A locked vault returns
    /// nothing. The refusals and a lock during the read are those of every vault projection (`VaultAutofillReadTests`).
    @Test func theVaultReportsItsCredentialsAsFlagsUnderTheCurrentUnlock() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let manager = vaults[0].manager
            let shared = "Kx9!vQ2#mW7p"
            let reused = [login(shared, at: ["https://example.com"]), login(shared, at: ["https://example.org"])]
            let weak = login("123456Xy", at: ["https://example.net"])
            let strong = login("Zt4$pL8@nR2w", at: ["https://example.edu"])
            let receipt = try await VaultManagerFixture.save(reused + [weak, strong], in: vaults[0])
            let audit = VaultReadAudit()
            CredentialManager.readAuditsForTesting[profile.id] = audit
            defer { CredentialManager.readAuditsForTesting[profile.id] = nil }

            let health = try await manager.passwordHealth()
            #expect(health.vaultID == manager.vaultID && health.revision == receipt.revision)
            #expect(Set(health.findings.keys) == Set(reused.map(\.id) + [weak.id]))
            #expect(health.findings[weak.id]?.weaknesses == [.pattern])
            #expect(audit.reads == [.health])

            manager.lock(reason: .manual)
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await manager.passwordHealth() }
        }
    }
}
