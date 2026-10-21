// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Exports name duplicates "ada@example.test (1)", "(2)" …: those are one login, suggested and merged as one. Pure and synthetic.
struct CredentialNumberedCopiesTests {
    private func login(_ username: String, _ password: String? = "pw", on origin: String = "https://example.test") -> CredentialAccount {
        VaultFixtures.account(username: username, password: password, origin: origin)
    }

    @Test(arguments: [
        ("ada@example.test (1)", "ada@example.test"),
        ("ada@example.test (12)", "ada@example.test"),
        ("ada@example.test (4096)", "ada@example.test"),
        ("ada (1) (2)", "ada (1)"),
        ("ada@example.test", "ada@example.test"),
        ("ada@example.test (12345)", "ada@example.test (12345)"),
        ("ada@example.test(1)", "ada@example.test(1)"),
        ("ada@example.test (one)", "ada@example.test (one)"),
        ("ada@example.test (\u{0661})", "ada@example.test (\u{0661})"),
        ("(1)", "(1)"),
        (" (1)", " (1)"),
        ("ada ()", "ada ()"),
    ])
    func theCopyNumberIsTheOnlyPartLeftOut(stored: String, base: String) {
        #expect(CredentialMergeSuggestions.baseUsername(stored) == base)
    }

    @Test(arguments: 1...4)
    func numberedCopiesOnOneSiteAreOneSuggestion(copies: Int) {
        let plain = login("ada@example.test", "pw", on: "https://www.example.test")
        let numbered = (1...copies).map { login("ada@example.test (\($0))", "pw", on: "https://login.example.test") }
        let found = CredentialMergeSuggestions.index(for: [plain] + numbered, revision: 1)
        #expect(found.suggestions.count == 1)
        #expect(found.suggestions.first?.reason == .numberedCopies)
        #expect(found.suggestions.first?.ids == [plain.id] + numbered.map(\.id))
        #expect(found.suggestions.first?.isIdentical == true, "the same password on the same site: Merge All Identical takes it")
    }

    @Test func copiesWithDifferentPasswordsAreSuggestedButNotIdentical() {
        let found = CredentialMergeSuggestions.index(for: [login("ada (1)", "one"), login("ada (2)", "two")], revision: 1)
        #expect(found.suggestions.first?.reason == .numberedCopies)
        #expect(found.suggestions.first?.isIdentical == false)
    }

    @Test func aCopyOnAnotherSiteIsNotGrouped() {
        let here = login("ada@example.test", "one", on: "https://example.test")
        let copy = login("ada@example.test (1)", "two", on: "https://example.test")
        let elsewhere = login("ada@example.test (2)", "three", on: "https://unrelated.test")
        let found = CredentialMergeSuggestions.index(for: [here, copy, elsewhere], revision: 1)
        #expect(found.suggestions.count == 1)
        #expect(found.suggestions.first?.ids == [here.id, copy.id])
    }

    @Test func plainRepeatsKeepTheSameLoginReason() {
        let found = CredentialMergeSuggestions.index(for: [login("ada (1)"), login("ada (1)")], revision: 1)
        #expect(found.suggestions.first?.reason == .sameLogin)
    }

    @Test func aMergeOfCopiesTakesTheUsernameWithoutTheNumber() throws {
        let primary = login("ada@example.test (2)", "newest")
        let others = [login("ada@example.test", "old"), login("ada@example.test (1)", "older")]
        let accounts = [primary] + others
        let picks = try #require(CredentialMerge.defaultPicks(for: accounts, survivor: primary.id))
        let merged = try CredentialMerge.merged(accounts, picks: picks)
        #expect(merged.id == primary.id)
        #expect(merged.username == "ada@example.test")
        #expect(merged.password == "newest")
        #expect(merged.mergedFrom?.map(\.accountID) == others.map(\.id))
        #expect(CredentialMerge.mayMerge(accounts.map(CredentialSummary.init)))
    }

    @Test func aLoneNumberedUsernameIsLeftAsItIs() throws {
        let primary = login("ada (1)", "pw")
        var passkeyOnly = login("", nil)
        passkeyOnly.passkeys = [try VaultFixtures.passkey(credentialID: Data(repeating: 4, count: 32))]
        passkeyOnly.passkeys[0].userName = "ada"
        let picks = try #require(CredentialMerge.defaultPicks(for: [primary, passkeyOnly], survivor: primary.id))
        #expect(try CredentialMerge.merged([primary, passkeyOnly], picks: picks).username == "ada (1)")
    }

    @Test func differentPeopleStillNeverMerge() {
        let accounts = [login("ada (1)"), login("grace (1)")]
        #expect(!CredentialMerge.mayMerge(accounts.map(CredentialSummary.init)))
        #expect(throws: CredentialMergeError.usernamesDiffer) {
            try CredentialMerge.merged(accounts, picks: MergePicks(survivor: accounts[0].id, name: accounts[0].id, login: accounts[0].id, code: accounts[0].id))
        }
    }
}
