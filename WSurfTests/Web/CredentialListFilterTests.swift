// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Searching, filtering and counting the Credentials tab's list: pure values built from summaries, so no vault is read and no
/// secret is involved. Everything here is synthetic.
struct CredentialListFilterTests {
    private func account(
        title: String? = nil, username: String = "user1@example.test", password: String? = "pw-secret-1", origins: [String] = ["https://one.example.test"]
    ) -> CredentialAccount {
        var account = VaultFixtures.account(username: username, password: password, origin: origins.first ?? "https://one.example.test")
        account.displayName = title
        account.origins = origins
        account.loginURLs = []
        return account
    }

    private func summary(_ account: CredentialAccount) -> CredentialSummary {
        CredentialSummary(account)
    }

    private func ids(_ summaries: [CredentialSummary]) -> [UUID] {
        summaries.map(\.id)
    }

    private func passkey(_ index: UInt8) throws -> WebsitePasskey {
        try VaultFixtures.passkey(rpID: "pk\(index).example.test", credentialID: Data(repeating: index, count: 32))
    }

    private let code = TOTPGenerator(secret: Data("seed".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: "user1")

    /// One credential of each kind, and one that is all of them: [login, passkey, code, note, everything].
    private func oneOfEach() throws -> [CredentialSummary] {
        let login = account(title: "Login")
        var passkeyOnly = account(title: "Passkey", username: "", password: nil, origins: [])
        passkeyOnly.passkeys = [try passkey(1)]
        var codeOnly = account(title: "Code", username: "", password: nil)
        codeOnly.totp = code
        var noteOnly = account(title: "Note", username: "", password: nil)
        noteOnly.notes = [CredentialNote(text: "note-text-1", field: nil)]
        var everything = account(title: "Everything")
        everything.passkeys = [try passkey(2), try passkey(3)]
        everything.totp = code
        everything.notes = [CredentialNote(text: "note-text-2", field: nil)]
        return [login, passkeyOnly, codeOnly, noteOnly, everything].map(summary)
    }

    // MARK: Search

    @Test func searchMatchesNameUsernameAndEveryWebsite() {
        let mail = account(title: "Work Mail", username: "user7@example.test", origins: ["https://mail.example.test", "https://second.example.test"])
        let other = account(title: "Other", username: "user8@example.test", origins: ["https://other.example.test"])
        let all = [summary(mail), summary(other)]

        for query in ["work mail", "user7@", "mail.example", "second.example"] {
            #expect(ids(CredentialListFilter.visible(all, query: query, filter: .all)) == [all[0].id])
        }
        #expect(CredentialListFilter.visible(all, query: "example.test", filter: .all).count == 2)
        #expect(CredentialListFilter.visible(all, query: "no such thing", filter: .all).isEmpty)
        // An empty or blank query leaves the list alone.
        #expect(CredentialListFilter.visible(all, query: "", filter: .all) == all)
        #expect(CredentialListFilter.visible(all, query: "  \n", filter: .all) == all)
    }

    @Test func searchUsesTheTitleAWebsiteOnlyCredentialShows() {
        // No name: the title is the first website's host, so a search for it finds the credential.
        let nameless = summary(account(title: nil, username: "", origins: ["https://hostonly.example.test"]))
        #expect(nameless.title == "hostonly.example.test")
        #expect(ids(CredentialListFilter.visible([nameless], query: "hostonly", filter: .all)) == [nameless.id])
    }

    @Test func searchNeverMatchesAConcealedUsernameOrAnySecret() throws {
        var concealed = account(title: "Concealed", username: "hidden-user-9", password: "pw-secret-9")
        concealed.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString),
            password: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
        )
        concealed.notes = [CredentialNote(text: "private-note-text", field: nil)]
        concealed.totp = TOTPGenerator(secret: Data("seed-9".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Issuer9", userName: "totp-user-9")
        concealed.passkeys = [try passkey(9)]
        let all = [summary(concealed)]

        for secret in ["hidden-user-9", "pw-secret-9", "private-note-text", "seed-9", "totp-user-9", "pk9.example.test"] {
            #expect(CredentialListFilter.visible(all, query: secret, filter: .all).isEmpty)
            #expect(!all[0].searchKey.contains(secret))
        }
        // What the row itself shows still finds it.
        #expect(CredentialListFilter.visible(all, query: "concealed", filter: .all).count == 1)
    }

    @Test func searchIgnoresCaseAndAccents() {
        let cafe = summary(account(title: "Café Müller", username: "user1@example.test"))
        let all = [cafe]
        for query in ["cafe muller", "CAFÉ", "müller", "Cafe Müller", "USER1@EXAMPLE"] {
            #expect(CredentialListFilter.visible(all, query: query, filter: .all).count == 1)
        }
    }

    /// `CredentialSummary.==` leaves `searchKey` out on purpose: it is built only from fields the comparison already covers, so
    /// equal summaries have equal keys and a changed key always shows as a changed summary.
    @Test func theSearchKeyFollowsTheComparedFieldsAndNothingElse() {
        let base = account(title: "Alpha", username: "user1@example.test", origins: ["https://one.example.test"])
        let summaryOfBase = summary(base)

        // A secret-only edit changes neither the summary nor its key.
        var secretOnly = base
        secretOnly.password = "pw-changed"
        secretOnly.notes = [CredentialNote(text: "a note", field: nil)]
        #expect(summary(secretOnly) != summaryOfBase)  // the notes flag is shown on the row
        var passwordOnly = base
        passwordOnly.password = "pw-changed"
        #expect(summary(passwordOnly) == summaryOfBase)
        #expect(summary(passwordOnly).searchKey == summaryOfBase.searchKey)

        // Every field the key is built from is compared, so a different key is a different summary.
        var renamed = base
        renamed.displayName = "Beta"
        var moved = base
        moved.origins = ["https://two.example.test"]
        var otherUser = base
        otherUser.username = "user2@example.test"
        for changed in [renamed, moved, otherUser].map(summary) {
            #expect(changed.searchKey != summaryOfBase.searchKey)
            #expect(changed != summaryOfBase)
        }
    }

    // MARK: Kinds

    @Test func eachFilterSelectsItsKind() throws {
        let all = try oneOfEach()
        let (login, passkeyOnly, codeOnly, noteOnly, everything) = (all[0].id, all[1].id, all[2].id, all[3].id, all[4].id)

        #expect(ids(CredentialListFilter.visible(all, query: "", filter: .all)).count == 5)
        #expect(ids(CredentialListFilter.visible(all, query: "", filter: .logins)) == [login, everything])
        #expect(ids(CredentialListFilter.visible(all, query: "", filter: .passkeys)) == [passkeyOnly, everything])
        #expect(ids(CredentialListFilter.visible(all, query: "", filter: .codes)) == [codeOnly, everything])
        #expect(ids(CredentialListFilter.visible(all, query: "", filter: .notes)) == [noteOnly, everything])
    }

    @Test func aSearchAndAKindNarrowTheListTogether() throws {
        let all = try oneOfEach()
        #expect(ids(CredentialListFilter.visible(all, query: "every", filter: .passkeys)) == [all[4].id])
        #expect(CredentialListFilter.visible(all, query: "note", filter: .passkeys).isEmpty)
    }

    @Test func countsPerFilterMatchTheVault() throws {
        let all = try oneOfEach()
        let noItems: [CredentialListFilter: Int] = [.cards: 0, .addresses: 0, .documents: 0, .otherItems: 0]
        #expect(CredentialListFilter.counts(all) == [.all: 5, .logins: 2, .passkeys: 2, .codes: 2, .notes: 2].merging(noItems) { $1 })
        #expect(CredentialListFilter.counts([]) == [.all: 0, .logins: 0, .passkeys: 0, .codes: 0, .notes: 0].merging(noItems) { $1 })
        for kind in CredentialListFilter.allCases {
            #expect(CredentialListFilter.counts(all)[kind] == CredentialListFilter.visible(all, query: "", filter: kind).count)
        }
    }

    @Test func statisticsCountACredentialInEveryKindItHas() throws {
        let statistics = CredentialStatistics(try oneOfEach())
        #expect(statistics.credentials == 5)
        #expect(statistics.logins == 2)
        // Every passkey counts, and the credentials that hold them are counted apart.
        #expect(statistics.passkeys == 3)
        #expect(statistics.credentialsWithPasskeys == 2)
        #expect(statistics.codes == 2)
        #expect(statistics.notes == 2)
        // Only the passkey-only credential has no website.
        #expect(statistics.withoutWebsite == 1)
        #expect(CredentialStatistics([]) == CredentialStatistics([]))
        #expect(CredentialStatistics([]).credentials == 0)
    }

    // MARK: Scale

    @Test(.timeLimit(.minutes(1))) func filteringThreeThousandCredentialsTakesUnder50Milliseconds() {
        let clock = ContinuousClock()
        let summaries = (0..<3_000).map { index -> CredentialSummary in
            var item = account(
                title: index % 2 == 0 ? "Site \(index)" : nil, username: "user\(index)@example.test",
                origins: ["https://site\(index).example.test"]
            )
            item.totp = index % 5 == 0 ? code : nil
            item.notes = index % 7 == 0 ? [CredentialNote(text: "note \(index)", field: nil)] : nil
            return summary(item)
        }

        var matched: [CredentialSummary] = []
        var counts: [CredentialListFilter: Int] = [:]
        let elapsed = clock.measure {
            matched = CredentialListFilter.visible(summaries, query: "site29", filter: .all)
            counts = CredentialListFilter.counts(summaries)
            _ = CredentialListFilter.visible(summaries, query: "user1", filter: .codes)
            _ = CredentialStatistics(summaries)
        }
        print("[credential-list] search, filter, counts and statistics over 3000 credentials: \(elapsed)")
        // site29, site290-site299 and site2900-site2999.
        #expect(matched.count == 111)
        #expect(counts[.all] == 3_000 && counts[.codes] == 600 && counts[.notes] == 429)
        #expect(elapsed < .milliseconds(50))
    }
}
