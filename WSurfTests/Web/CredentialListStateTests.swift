// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// What the Credentials tab keeps between keystrokes: the query, the kind and the rows they leave.
@MainActor
struct CredentialListStateTests {
    private func summary(_ title: String, passkey: Bool = false) throws -> CredentialSummary {
        var account = VaultFixtures.account(username: "user@example.test")
        account.displayName = title
        if passkey {
            account.passkeys = [try VaultFixtures.passkey(rpID: "\(title).example.test", credentialID: Data(title.utf8))]
        }
        return CredentialSummary(account)
    }

    @Test func theListShowsEveryCredentialUntilASearchOrKindNarrowsIt() throws {
        let alpha = try summary("alpha", passkey: true)
        let beta = try summary("beta")
        let all = [alpha, beta]
        let list = CredentialListState()
        #expect(!list.isFiltering)
        #expect(list.rows(of: all) == all)

        // A blank search narrows nothing.
        list.query = "  "
        #expect(!list.isFiltering)
        #expect(list.rows(of: all) == all)

        list.query = "alpha"
        #expect(list.isFiltering)
        list.refresh(all)
        #expect(list.rows(of: all).map(\.id) == [alpha.id])
        #expect(list.counts?[.all] == 2 && list.counts?[.passkeys] == 1)

        list.query = ""
        list.filter = .passkeys
        list.refresh(all)
        #expect(list.rows(of: all).map(\.id) == [alpha.id])

        list.filter = .notes
        list.refresh(all)
        #expect(list.rows(of: all).isEmpty)
    }

    @Test func resettingReturnsToTheWholeList() throws {
        let all = [try summary("alpha"), try summary("beta")]
        let list = CredentialListState()
        list.query = "alpha"
        list.filter = .logins
        list.refresh(all)
        #expect(list.rows(of: all).count == 1)

        list.reset()
        #expect(list.query.isEmpty && list.filter == .all && !list.isFiltering)
        #expect(list.rows(of: all) == all)
    }
}
