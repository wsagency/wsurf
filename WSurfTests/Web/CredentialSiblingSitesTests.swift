// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// Logins of sibling websites: accounts saved for another website of the page's registrable domain. Pure: no vault, no page.
/// Public-suffix names are rule names here, not user data.
struct CredentialSiblingSitesTests {
    private static let page = "https://login.example.test"

    private func account(_ username: String, password: String? = "pw", origins: [String]) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: origins, loginURLs: [], password: password, passkeys: [],
            totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    @Test func anotherWebsiteOfTheSameRegistrableDomainIsASibling() {
        let www = account("ada", origins: ["https://www.example.test"])
        let other = account("bob", origins: ["https://other.test"])
        let found = CredentialAccountSelection.siblings(in: [other, www], origin: Self.page, entered: nil)
        #expect(found.map { $0.account.id } == [www.id])
        #expect(found.map { $0.website } == ["https://www.example.test"])
        #expect(CredentialAccountSelection.isSibling(www, of: Self.page))
        #expect(!CredentialAccountSelection.isSibling(other, of: Self.page))
        #expect(CredentialAccountSelection.site(of: Self.page) == "example.test")
    }

    @Test func publicSuffixSiblingsAreNeverOffered() {
        // github.io is a public suffix, so a.github.io and b.github.io are different registrable domains.
        let first = account("ada", origins: ["https://a.github.io"])
        #expect(CredentialAccountSelection.siblings(in: [first], origin: "https://b.github.io", entered: nil).isEmpty)
        #expect(!CredentialAccountSelection.isSibling(first, of: "https://b.github.io"))
        let uk = account("ada", origins: ["https://shop.example.co.uk"])
        #expect(CredentialAccountSelection.siblings(in: [uk], origin: "https://www.other.co.uk", entered: nil).isEmpty)
        // Below the suffix, the registrable domain still groups its own hosts.
        let deep = account("ada", origins: ["https://deep.a.github.io"])
        #expect(CredentialAccountSelection.siblings(in: [deep], origin: "https://a.github.io", entered: nil).map { $0.account.id } == [deep.id])
    }

    @Test(arguments: ["http://login.example.test", "https://192.0.2.1", "https://localhost:8443", "https://github.io"])
    func aPageWithoutARegistrableHTTPSDomainHasNoSiblings(origin: String) {
        let saved = account("ada", origins: ["https://www.example.test", "https://192.0.2.2", "https://localhost", "https://a.github.io"])
        #expect(CredentialAccountSelection.site(of: origin) == nil)
        #expect(CredentialAccountSelection.siblings(in: [saved], origin: origin, entered: nil).isEmpty)
        #expect(!CredentialAccountSelection.isSibling(saved, of: origin))
    }

    @Test func anAccountAlreadySavedForThePageIsNotASibling() {
        let both = account("ada", origins: ["https://www.example.test", Self.page])
        #expect(CredentialAccountSelection.siblings(in: [both], origin: Self.page, entered: nil).isEmpty)
    }

    @Test func anAccountWithNothingToFillIsNotOffered() {
        let empty = account("", password: nil, origins: ["https://www.example.test"])
        #expect(CredentialAccountSelection.siblings(in: [empty], origin: Self.page, entered: nil).isEmpty)
    }

    private static let generator = TOTPGenerator(
        secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 30, digits: 8, issuer: nil, userName: nil
    )

    private func codes(origins: [String]) -> CredentialAccount {
        var saved = account("", password: nil, origins: origins)
        saved.totp = Self.generator
        return saved
    }

    /// The owner's authenticator case: a code saved for example.com is offered on login.example.com, behind "Check other logins".
    @Test func aCodeOfTheParentDomainIsOfferedOnASubdomain() {
        let parent = codes(origins: ["https://example.test"])
        let login = account("ada", origins: ["https://www.example.test"])
        let found = CredentialAccountSelection.siblings(in: [login, parent], origin: Self.page, entered: nil, field: .totp)
        #expect(found.map { $0.account.id } == [parent.id], "a code field lists codes only, not logins")
        #expect(found.map { $0.website } == ["https://example.test"])
        let forPasswords = CredentialAccountSelection.siblings(in: [login, parent], origin: Self.page, entered: nil)
        #expect(forPasswords.map { $0.account.id } == [login.id], "a password field still lists logins only")
        // RFC 6238 appendix B, SHA-1, eight digits.
        let at = Date(timeIntervalSince1970: 59)
        #expect(CredentialAccountSelection.totpCode(for: parent, origin: Self.page, at: at) == nil, "never without the explicit pick")
        #expect(CredentialAccountSelection.totpCode(for: parent, origin: Self.page, at: at, sibling: true) == "94287082")
    }

    @Test func aCodeOfAnotherDomainOrALookAlikeIsNeverOffered() {
        let other = codes(origins: ["https://other.test"])
        let paypal = codes(origins: ["https://paypal.com"])
        let lookAlike = codes(origins: ["https://paypa1.com"])
        let publicSuffix = codes(origins: ["https://a.github.io"])
        #expect(CredentialAccountSelection.siblings(in: [other], origin: Self.page, entered: nil, field: .totp).isEmpty)
        let onPaypal = CredentialAccountSelection.siblings(in: [lookAlike, paypal], origin: "https://login.paypal.com", entered: nil, field: .totp)
        #expect(onPaypal.map { $0.account.id } == [paypal.id], "paypa1.com is another registrable domain")
        #expect(CredentialAccountSelection.siblings(in: [paypal], origin: "https://login.paypa1.com", entered: nil, field: .totp).isEmpty)
        #expect(CredentialAccountSelection.siblings(in: [publicSuffix], origin: "https://b.github.io", entered: nil, field: .totp).isEmpty)
        let at = Date(timeIntervalSince1970: 59)
        #expect(CredentialAccountSelection.totpCode(for: lookAlike, origin: "https://login.paypal.com", at: at, sibling: true) == nil)
        #expect(CredentialAccountSelection.totpCode(for: other, origin: Self.page, at: at, sibling: true) == nil)
    }

    @Test func typingFiltersSiblingsLikeTheDefaultList() {
        let ada = account("ada@example.test", origins: ["https://www.example.test"])
        let bob = account("bob@example.test", origins: ["https://app.example.test"])
        let typed = CredentialAccountSelection.siblings(in: [bob, ada], origin: Self.page, entered: "AD")
        #expect(typed.map { $0.account.id } == [ada.id])
        let all = CredentialAccountSelection.siblings(in: [bob, ada], origin: Self.page, entered: "")
        #expect(all.map { $0.account.id } == [ada.id, bob.id])
    }

    /// The vault's candidates of the same accounts (what the dropdown lists since D5) give the same siblings, websites and verdicts as
    /// the whole entries, for logins and codes alike.
    @Test func candidatesGiveTheSameSiblingsAsTheirEntries() {
        let accounts = [
            account("ada", origins: ["https://www.example.test"]), account("bob", origins: ["https://other.test"]),
            account("both", origins: ["https://www.example.test", Self.page]), account("", password: nil, origins: ["https://www.example.test"]),
            codes(origins: ["https://example.test"]), codes(origins: ["https://paypa1.com"]), account("deep", origins: ["https://deep.a.github.io"]),
            account("ada@example.test", origins: ["https://app.example.test"]),
        ]
        let candidates = accounts.map(AutofillCandidate.init)
        for origin in [Self.page, "https://a.github.io", "https://login.paypal.com", "http://login.example.test"] {
            for field in [CredentialAutofillField.password, .totp] {
                for entered in [nil, "", "AD"] as [String?] {
                    let whole = CredentialAccountSelection.siblings(in: accounts, origin: origin, entered: entered, field: field)
                    let listed = CredentialAccountSelection.siblings(in: candidates, origin: origin, entered: entered, field: field)
                    #expect(listed.map { "\($0.account.id) \($0.website)" } == whole.map { "\($0.account.id) \($0.website)" })
                }
            }
            for (account, candidate) in zip(accounts, candidates) {
                #expect(CredentialAccountSelection.isSibling(candidate, of: origin) == CredentialAccountSelection.isSibling(account, of: origin))
            }
        }
    }

    @Test func theSiblingRowAppearsOnlyWhenTheExactListIsEmpty() {
        #expect(CredentialDropdown.plan(exact: 1, siblings: 3, origin: Self.page, field: .password) == .accounts)
        #expect(CredentialDropdown.plan(exact: 0, siblings: 3, origin: Self.page, field: .password) == .siblings(site: "example.test"))
        #expect(CredentialDropdown.plan(exact: 0, siblings: 0, origin: Self.page, field: .password) == .empty)
        // A verification-code field offers the codes of sibling websites the same way (owner's rule, 0.1.13).
        #expect(CredentialDropdown.plan(exact: 0, siblings: 3, origin: Self.page, field: .totp) == .siblings(site: "example.test"))
        #expect(CredentialDropdown.plan(exact: 1, siblings: 3, origin: Self.page, field: .totp) == .accounts)
        #expect(CredentialDropdown.plan(exact: 0, siblings: 0, origin: Self.page, field: .totp) == .empty)
        #expect(CredentialDropdown.plan(exact: 0, siblings: 3, origin: "https://192.0.2.1", field: .password) == .empty)
    }
}
