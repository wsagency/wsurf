// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Merge suggestions are computed from accounts and return ids and reasons only.
struct CredentialMergeSuggestionsTests {
    private func login(
        _ username: String, _ password: String? = "pw", on origin: String = "https://example.test", id: UUID = UUID()
    ) -> CredentialAccount {
        VaultFixtures.account(id: id, username: username, password: password, origin: origin)
    }

    private func passkeyOnly(user: String, rp: String = "example.test", seed: UInt8) throws -> CredentialAccount {
        var passkey = try VaultFixtures.passkey(rpID: rp, credentialID: Data(repeating: seed, count: 32))
        passkey.userName = user
        var account = VaultFixtures.account(username: "", password: nil, origin: "https://unused.example.test", passkeys: [passkey])
        account.origins = []
        account.loginURLs = []
        return account
    }

    private func codeOnly(issuer: String, user: String? = nil) -> CredentialAccount {
        var account = VaultFixtures.account(username: "", password: nil, origin: "https://unused.example.test")
        account.origins = []
        account.loginURLs = []
        account.totp = TOTPGenerator(secret: Data([9, 9, 9]), algorithm: .sha1, period: 30, digits: 6, issuer: issuer, userName: user)
        return account
    }

    private func index(_ accounts: [CredentialAccount]) -> CredentialMergeIndex {
        CredentialMergeSuggestions.index(for: accounts, revision: 1)
    }

    @Test func sameSiteAndUsernameAreSuggestedAcrossSubdomains() {
        let first = login("ada", "one", on: "https://www.example.test")
        let second = login("ada", "two", on: "https://login.example.test")
        let unrelated = login("ada", "three", on: "https://other.test")
        let found = index([first, unrelated, second])
        #expect(found.suggestions.count == 1)
        #expect(found.suggestions[0].reason == .sameLogin)
        #expect(found.suggestions[0].ids == [first.id, second.id])
        #expect(!found.suggestions[0].isIdentical)
    }

    @Test func usernamesAreComparedAsExactBytes() {
        let found = index([login("Ada"), login("ada"), login("\u{00E1}da"), login("a\u{0301}da")])
        #expect(found.suggestions.isEmpty)
    }

    @Test func aGroupIsIdenticalOnlyWhenEveryLoginAndEveryWebsiteMatches() {
        let a = login("ada", "same")
        let b = login("ada", "same")
        #expect(index([a, b]).suggestions.first?.isIdentical == true)

        let differentPassword = login("ada", "other")
        #expect(index([a, differentPassword]).suggestions.first?.isIdentical == false)

        var extraSite = login("ada", "same")
        extraSite.origins.append("https://elsewhere.test")
        #expect(index([a, extraSite]).suggestions.first?.isIdentical == false)

        var codeA = login("ada", "same")
        codeA.totp = VaultFixtures.totp()
        var codeB = login("ada", "same")
        codeB.totp = TOTPGenerator(secret: Data([7, 7]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
        #expect(index([codeA, codeB]).suggestions.first?.isIdentical == false)
        #expect(index([codeA, b]).suggestions.first?.isIdentical == true)
    }

    @Test func differentUsernamesAreNeverSuggested() throws {
        let ada = login("ada")
        let bob = login("bob")
        let passkey = try passkeyOnly(user: "carol", seed: 3)
        let code = codeOnly(issuer: "Example")
        // The code names nobody, so it joins the first person it fits and never a second one.
        let found = index([ada, bob, passkey, code])
        #expect(found.suggestions.map(\.ids) == [[ada.id, code.id]])
    }

    @Test func separatePasswordPasskeyAndCodeItemsAreSuggestedAsOne() throws {
        let password = login("ada", "pw", on: "https://www.example.test")
        let passkey = try passkeyOnly(user: "ada", rp: "example.test", seed: 4)
        let code = codeOnly(issuer: "Example", user: "ada")
        let found = index([password, passkey, code])
        #expect(found.suggestions.count == 1)
        #expect(found.suggestions[0].reason == .splitParts)
        #expect(found.suggestions[0].ids == [password.id, passkey.id, code.id])
        #expect(!found.suggestions[0].isIdentical)
    }

    @Test func aCodeOnlyItemMatchesByIssuerAndUserName() {
        let password = login("ada", "pw", on: "https://www.example.test")
        let matching = codeOnly(issuer: "EXAMPLE", user: "ada")
        let otherPerson = codeOnly(issuer: "Example", user: "bob")
        let otherIssuer = codeOnly(issuer: "Something Else", user: "ada")
        let found = index([password, matching, otherPerson, otherIssuer])
        #expect(found.suggestions.map(\.ids) == [[password.id, matching.id]])
    }

    @Test func twoLoginsAreNotASplit() {
        // Two logins share the part, so they are a duplicate to review, not two halves of one credential.
        let found = index([login("ada", "one"), login("bob", "two")])
        #expect(found.suggestions.isEmpty)
    }

    @Test func aRelatedSiteNeedsTheSamePasswordOrSiteName() {
        let com = login("ada", "pw", on: "https://example.test")
        let samePassword = login("ada", "pw", on: "https://another.test")
        let sameName = login("ada", "different", on: "https://example.org")
        let neither = login("ada", "unrelated", on: "https://unrelated.test")
        let found = index([com, samePassword, sameName, neither])
        #expect(found.suggestions.count == 1)
        #expect(found.suggestions[0].reason == .relatedSite)
        #expect(found.suggestions[0].ids == [com.id, samePassword.id, sameName.id])
        #expect(!found.suggestions[0].isIdentical)
    }

    @Test func publicSuffixSiblingsAreNotSuggested() {
        let found = index([login("ada", "one", on: "https://a.github.io"), login("ada", "two", on: "https://b.github.io")])
        #expect(found.suggestions.isEmpty)
    }

    @Test func anAddressUsedOnManySitesIsNotSuggested() {
        var accounts = (0...CredentialMergeSuggestions.bucketLimit).map { login("ada@example.test", "pw", on: "https://site\($0).test") }
        // Every one shares the username and the password, which says nothing about any pair.
        #expect(index(accounts).suggestions.isEmpty)
        accounts.removeLast()
        #expect(!index(accounts).suggestions.isEmpty)
    }

    @Test func eachMemberListsOnceAndTheStrongestReasonNamesAGroup() {
        let first = login("ada", "pw")
        let second = login("ada", "pw")
        let found = index([first, second])
        #expect(found.suggestions.count == 1)
        #expect(found.suggestions[0].reason == .sameLogin)
        #expect(found.identical.count == 1)
        #expect(found.suggestions(containing: first.id).count == 1)
        #expect(found.suggestions(containing: UUID()).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func groupingAndSuggestingThreeThousandCredentialsIsLinear() {
        var accounts: [CredentialAccount] = []
        for number in 0..<3_000 {
            // One registrable site (example.test) for all; the last 300 repeat the first 300's username and password.
            let site = number < 2_700 ? number : number - 2_700
            accounts.append(login("user\(site)@example.test", "pw\(site)", on: "https://site\(site).example.test"))
        }
        let summaries = accounts.map(CredentialSummary.init)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = CredentialSiteGroups.groups(summaries)
            let found = CredentialMergeSuggestions.index(for: accounts, revision: 1)
            #expect(found.suggestions.count == 300)
        }
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }
}
