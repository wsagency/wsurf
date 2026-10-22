// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

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

    @Test func typingFiltersSiblingsLikeTheDefaultList() {
        let ada = account("ada@example.test", origins: ["https://www.example.test"])
        let bob = account("bob@example.test", origins: ["https://app.example.test"])
        let typed = CredentialAccountSelection.siblings(in: [bob, ada], origin: Self.page, entered: "AD")
        #expect(typed.map { $0.account.id } == [ada.id])
        let all = CredentialAccountSelection.siblings(in: [bob, ada], origin: Self.page, entered: "")
        #expect(all.map { $0.account.id } == [ada.id, bob.id])
    }

    @Test func theSiblingRowAppearsOnlyWhenTheExactListIsEmpty() {
        #expect(CredentialDropdown.plan(exact: 1, siblings: 3, origin: Self.page, field: .password) == .accounts)
        #expect(CredentialDropdown.plan(exact: 0, siblings: 3, origin: Self.page, field: .password) == .siblings(site: "example.test"))
        #expect(CredentialDropdown.plan(exact: 0, siblings: 0, origin: Self.page, field: .password) == .empty)
        // A verification-code field never borrows another website's code.
        #expect(CredentialDropdown.plan(exact: 0, siblings: 3, origin: Self.page, field: .totp) == .empty)
        #expect(CredentialDropdown.plan(exact: 0, siblings: 3, origin: "https://192.0.2.1", field: .password) == .empty)
    }
}
