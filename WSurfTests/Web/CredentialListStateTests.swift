// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

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

    /// Told what a keystroke does to the rows, in the order it does it.
    private final class Told {
        var lists: [[UUID]] = []
    }

    @Test func aKeystrokeNarrowsTheRowsAtOnceAndTellsTheSelectionOnlyWhenTheyChange() throws {
        let alpha = try summary("alpha"), alphabet = try summary("alphabet"), beta = try summary("beta")
        let all = [alpha, beta, alphabet]
        let list = CredentialListState()
        let told = Told()
        list.didNarrow = { told.lists.append($0) }
        list.refresh(all)
        #expect(told.lists == [all.map(\.id)])
        let counts = list.counts

        // The rows follow the keystroke with no refresh in between.
        list.query = "alp"
        #expect(list.rows(of: all).map(\.id) == [alpha.id, alphabet.id])
        #expect(told.lists.count == 2 && told.lists.last == [alpha.id, alphabet.id])

        // The same rows: nothing to tell, and the kinds' counts are not recomputed for a keystroke.
        list.query = "alph"
        list.query = "alpha"
        #expect(list.rows(of: all).map(\.id) == [alpha.id, alphabet.id])
        #expect(told.lists.count == 2)
        #expect(list.counts == counts)
        #expect(list.narrowCount == 4, "every keystroke is narrowed once")

        list.query = "alphab"
        #expect(list.rows(of: all).map(\.id) == [alphabet.id])
        #expect(told.lists.count == 3)

        // The kind narrows the same way.
        list.query = ""
        list.filter = .passkeys
        #expect(list.rows(of: all).isEmpty)
        list.filter = .all
        #expect(list.rows(of: all) == all)
    }

    @Test func aKeystrokeBeforeTheFirstRefreshLeavesTheWholeListUntilItLands() throws {
        let all = [try summary("alpha"), try summary("beta")]
        let list = CredentialListState()
        list.query = "alpha"
        #expect(list.isFiltering)
        #expect(list.rows(of: all) == all, "there is nothing to narrow yet")
        list.refresh(all)
        #expect(list.rows(of: all).map(\.title) == ["alpha"])
    }
}
