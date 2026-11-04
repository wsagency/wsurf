// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

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
        let numbered = (1...copies).map { login("ada@example.test (\($0))", "pw", on: "https://example.test") }
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

    // MARK: The recommended primary

    private func recommended(_ accounts: [CredentialAccount]) throws -> UUID {
        try #require(CredentialMerge.defaultPicks(for: accounts)).survivor
    }

    /// Wherever the vault lists the plain username among its copies, it is the one the merge sheet starts from. The merge never
    /// reads the order of the vault as a ranking of its own.
    @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    func thePlainUsernameIsRecommendedOverItsNumberedCopies(order: [Int]) throws {
        let all = [login("ada@example.test"), login("ada@example.test (1)"), login("ada@example.test (2)")]
        let accounts = order.map { all[$0] }
        let picks = try #require(CredentialMerge.defaultPicks(for: accounts))
        #expect(picks.survivor == all[0].id)
        let merged = try CredentialMerge.merged(accounts, picks: picks)
        #expect(merged.id == all[0].id)
        #expect(merged.username == "ada@example.test")
    }

    @Test func aCopyThatHoldsMoreOrIsLinkedIsStillNotRecommendedOverThePlainOne() throws {
        var copy = login("ada@example.test (1)", "newer")
        copy.totp = VaultFixtures.totp()
        copy.exchangeItemID = Data([1])
        let plain = login("ada@example.test", "older")
        #expect(try recommended([copy, plain]) == plain.id)
        // Nothing the copy holds is left behind: its code is the merged credential's and its link is kept in `mergedFrom`.
        let merged = try CredentialMerge.merged([copy, plain], picks: try #require(CredentialMerge.defaultPicks(for: [copy, plain])))
        #expect(merged.id == plain.id)
        #expect(merged.password == "older")
        #expect(merged.totp != nil)
        #expect(merged.mergedFrom?.first?.exchangeItemID == Data([1]))
    }

    @Test func plainUsernamesKeepTheirUsualOrderAmongThemselves() throws {
        let (first, second) = (login("ada@example.test"), login("ada@example.test"))
        let copy = login("ada@example.test (1)")
        #expect(try recommended([copy, second, first]) == second.id)
        #expect(try recommended([first, copy, second]) == first.id)
    }

    @Test func withCopiesOnlyThereIsNothingToPreferAndTheUsualOrderDecides() throws {
        let (two, one) = (login("ada@example.test (2)"), login("ada@example.test (1)"))
        #expect(try recommended([two, one]) == two.id)
        #expect(try recommended([one, two]) == one.id)
        let merged = try CredentialMerge.merged([two, one], picks: try #require(CredentialMerge.defaultPicks(for: [two, one])))
        #expect(merged.username == "ada@example.test", "the merged credential still drops the number")
    }

    /// A trailing parenthesis that is part of the name is not a copy number: neither side is demoted, so the usual order decides.
    @Test(arguments: [
        "ada (work)", "ada (12345)", "ada(1)", "ada (one)", "ada ()", "ada (1", "ada 1)", "ada (\u{0661})", "(1)", "ada (1)x",
    ])
    func realParenthesesAreNotACopyNumber(name: String) throws {
        let (odd, plain) = (login(name), login("ada"))
        #expect(try recommended([odd, plain]) == odd.id)
        #expect(try recommended([plain, odd]) == plain.id)
    }

    @Test func aCopyNumberAfterRealParenthesesIsStillOnlyTheNumber() throws {
        let (copy, named) = (login("ada (work) (1)"), login("ada (work)"))
        #expect(try recommended([copy, named]) == named.id)
        #expect(try recommended([named, copy]) == named.id)
        let merged = try CredentialMerge.merged([copy, named], picks: try #require(CredentialMerge.defaultPicks(for: [copy, named])))
        #expect(merged.username == "ada (work)")
    }

    /// Usernames are compared as exact bytes, as the suggestions group them: another case or other spacing is another username, so
    /// it is neither the plain one of a copy nor a copy.
    @Test(arguments: [
        ("Ada@example.test", "ada@example.test (1)"),
        ("ada@example.test ", "ada@example.test (1)"),
        (" ada@example.test", "ada@example.test (1)"),
        ("ada@example.test", "ada@example.test  (1)"),
        ("ada@example.test", " ada@example.test (1)"),
        ("ada@example.test", "ada@example.test (1) "),
    ])
    func otherCaseOrSpacingIsNotThePlainUsernameOfACopy(plain: String, copy: String) throws {
        let (copied, other) = (login(copy), login(plain))
        #expect(try recommended([copied, other]) == copied.id)
        #expect(try recommended([other, copied]) == other.id)
    }

    @Test(arguments: ["Ada@Example.test", "ada smith", "ADA", "ada  smith", "ada.o'neil+tag@example.test"])
    func caseAndSpacesInsideTheNameAreKept(name: String) throws {
        let (plain, copy) = (login(name), login("\(name) (1)"))
        #expect(try recommended([copy, plain]) == plain.id)
        let merged = try CredentialMerge.merged([copy, plain], picks: try #require(CredentialMerge.defaultPicks(for: [copy, plain])))
        #expect(merged.username == name)
    }
}
