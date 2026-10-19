// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Grouping by site is pure and reads only a summary: no vault, no secret.
struct CredentialSiteGroupsTests {
    private func summary(_ origins: [String], passkeyRP: String? = nil, username: String = "ada") throws -> CredentialSummary {
        var account = VaultFixtures.account(username: username, origin: origins.first ?? "https://unused.example.test")
        account.origins = origins
        account.loginURLs = []
        if let passkeyRP {
            account.passkeys = [try VaultFixtures.passkey(rpID: passkeyRP, credentialID: Data(UUID().uuidString.utf8))]
        }
        return CredentialSummary(account)
    }

    @Test func groupsByTheRegistrableDomainOfTheFirstWebsite() throws {
        let www = try summary(["https://www.example.test", "https://shop.other.test"])
        let login = try summary(["https://login.example.test"], username: "bob")
        let other = try summary(["https://other.test"])
        let groups = CredentialSiteGroups.groups([www, other, login])
        #expect(groups.map(\.site) == ["example.test", "other.test"])
        #expect(groups[0].ids == [www.id, login.id])
        #expect(groups[1].ids == [other.id])
    }

    @Test func passkeyOnlyCredentialsGroupByRelyingParty() throws {
        let passkeyOnly = try summary([], passkeyRP: "accounts.example.test")
        let login = try summary(["https://www.example.test"])
        let groups = CredentialSiteGroups.groups([passkeyOnly, login])
        #expect(groups.count == 1)
        #expect(groups[0].site == "example.test")
        #expect(groups[0].ids == [passkeyOnly.id, login.id])
    }

    @Test func credentialsWithoutAWebsiteShareOneGroupAtTheEnd() throws {
        let none = try summary([])
        let more = try summary([], username: "bob")
        let site = try summary(["https://example.test"])
        let groups = CredentialSiteGroups.groups([none, site, more])
        #expect(groups.map(\.site) == ["example.test", nil])
        #expect(groups[1].ids == [none.id, more.id])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test func aPublicSuffixSiteStaysItsOwnGroup() throws {
        let first = try summary(["https://a.github.io"])
        let second = try summary(["https://b.github.io"])
        let groups = CredentialSiteGroups.groups([first, second])
        #expect(groups.map(\.site) == ["a.github.io", "b.github.io"])
    }
}
