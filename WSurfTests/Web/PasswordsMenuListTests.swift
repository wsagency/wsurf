// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// What the Passwords popover in the menu bar lists: pure values, no vault, manager or window.
struct PasswordsMenuListTests {
    private let first = VaultFixtures.reference(800_000_000)
    private let second = VaultFixtures.reference(800_100_000)
    private let third = VaultFixtures.reference(800_200_000)

    private func summary(
        _ origin: String = "https://example.test", username: String = "ada", displayName: String? = nil, password: String? = "pw",
        created: Date? = nil, modified: Date? = nil
    ) -> CredentialSummary {
        var account = VaultFixtures.account(username: username, password: password, origin: origin)
        account.displayName = displayName
        account.createdAt = created
        account.modifiedAt = modified
        return CredentialSummary(account)
    }

    private func sections(_ summaries: [CredentialSummary], query: String = "", origin: String? = nil) -> PasswordsMenuList.Sections {
        PasswordsMenuList.sections(summaries: summaries, query: query, origin: origin)
    }

    // MARK: Sections

    @Test func theCredentialsOfTheFrontWebsiteComeFirstAndTheRestFollow() {
        let a = summary("https://a.test", displayName: "A")
        let b = summary("https://b.test", displayName: "B")
        let other = summary("https://other.test", displayName: "Other")

        let result = sections([other, a, b], origin: "https://a.test")

        #expect(result.matching.map(\.id) == [a.id])
        #expect(Set(result.recent.map(\.id)) == [b.id, other.id])
        #expect(result.rows.first?.id == a.id)
        #expect(result.more == 0)
        // A credential of another website is never matched by a prefix of its address.
        #expect(sections([summary("https://a.test.evil.example")], origin: "https://a.test").matching.isEmpty)
    }

    @Test func noFrontWebsiteMatchesNothing() {
        let result = sections([summary("https://a.test")], origin: nil)
        #expect(result.matching.isEmpty)
        #expect(result.recent.count == 1)
    }

    @Test func theFrontTabMatchesOnlyWhenItsWindowShowsTheSameProfileAndIsNotPrivate() {
        let profile = UUID()
        let url = URL(string: "https://a.test/login?next=1#top")
        func origin(_ front: PasswordsMenuList.FrontTab?) -> String? {
            PasswordsMenuList.origin(of: front, shown: profile)
        }

        #expect(origin(.init(url: url, profileID: profile, isPrivate: false)) == "https://a.test")
        #expect(origin(.init(url: url, profileID: UUID(), isPrivate: false)) == nil, "another profile's front tab")
        #expect(origin(.init(url: url, profileID: profile, isPrivate: true)) == nil, "a private window")
        #expect(origin(nil) == nil, "no browser window")
        #expect(origin(.init(url: nil, profileID: profile, isPrivate: false)) == nil, "a new tab with no address")
        #expect(origin(.init(url: URL(string: "http://a.test"), profileID: profile, isPrivate: false)) == nil, "no vault origin is plain http")
    }

    @Test func theRestIsNewestChangeFirstAndAnUnknownDateIsLast() {
        // `updated` is the last change when it differs from `added`; otherwise `added`; with neither the credential is undated.
        let changed = summary("https://changed.test", created: first, modified: third)
        let added = summary("https://added.test", created: second, modified: second)
        let undated = summary("https://undated.test")
        #expect(changed.changed == third && added.changed == second && undated.changed == nil)

        let result = sections([undated, added, changed])

        #expect(result.recent.map(\.id) == [changed.id, added.id, undated.id])
    }

    @Test func twoCredentialsWithOneDateKeepOneOrderWhateverTheInputOrder() {
        let one = summary("https://one.test", created: first, modified: first)
        let two = summary("https://two.test", created: first, modified: first)

        #expect(sections([one, two]).recent.map(\.id) == sections([two, one]).recent.map(\.id))
    }

    @Test func atMostFiftyRowsAreListedAndTheRestIsCounted() {
        let many = (0..<120).map { summary("https://site\($0).test", created: first, modified: first.addingTimeInterval(Double($0))) }

        let all = sections(many)
        #expect(all.rows.count == PasswordsMenuList.limit && PasswordsMenuList.limit == 50)
        #expect(all.more == 70)
        #expect(all.recent.first?.id == many[119].id, "the newest of 120")

        // The front website's credentials are kept first, and the limit covers both lists together.
        let matching = (0..<60).map { summary("https://front.test", username: "user\($0)", displayName: "M\($0)") }
        let both = sections(matching + many, origin: "https://front.test")
        #expect(both.matching.count == 50 && both.recent.isEmpty)
        #expect(both.more == 60 + 120 - 50)

        #expect(PasswordsMenuList.sections(summaries: many, query: "", origin: nil, limit: 5).more == 115)
        #expect(sections([]) == .empty)
    }

    // MARK: Search

    @Test func anEmptyQueryListsEverythingAndAQueryIgnoresCaseAndAccents() {
        let bank = summary("https://bank.test", displayName: "Crédit Bank")
        let mail = summary("https://mail.test", username: "grace", displayName: "Mail")

        #expect(sections([bank, mail], query: "").rows.count == 2)
        #expect(sections([bank, mail], query: "  \n").rows.count == 2)
        #expect(sections([bank, mail], query: "CREDIT").rows.map(\.id) == [bank.id])
        #expect(sections([bank, mail], query: "grace").rows.map(\.id) == [mail.id])
        #expect(sections([bank, mail], query: "mail.test").rows.map(\.id) == [mail.id], "a website's host is searched")
        #expect(sections([bank, mail], query: "nothing").rows.isEmpty)
    }

    @Test func aConcealedUsernameIsNeverSearched() {
        var account = VaultFixtures.account(username: "hidden-name", origin: "https://vault.test")
        account.displayName = "Vault"
        account.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(fieldType: .concealedString), password: nil
        )
        let concealed = CredentialSummary(account)
        #expect(concealed.usernameIsConcealed && concealed.username == nil)

        #expect(sections([concealed], query: "hidden-name").rows.isEmpty)
        #expect(sections([concealed], query: "vault").rows.count == 1)
    }

    @Test func aCredentialWithNothingToCopyOrOpenIsNotListed() {
        // A card, an identity or a note without a username, password, code or website: its row would do nothing.
        var card = VaultFixtures.account(username: "", password: nil)
        card.displayName = "Visa 4242"
        card.origins = []
        card.loginURLs = []
        let empty = CredentialSummary(card)
        #expect(PasswordsMenuAction.offered(for: empty).isEmpty)
        let login = summary("https://a.test", displayName: "Login")

        let result = sections([empty, login])

        #expect(result.rows.map(\.id) == [login.id])
        #expect(result.more == 0, "an unlisted credential is not counted as one more")
        #expect(sections([empty], query: "visa").rows.isEmpty)
    }

    // MARK: Row text

    @Test func aRowDrawsNoBidiOrLineBreakCharacterOfWhatAWebsiteSupplied() {
        let tricky = summary("https://example.test", username: "ada\u{202E}\nroot", displayName: "Bank\u{202E}\u{2028}Corp")

        #expect(tricky.menuTitle == "BankCorp")
        #expect(tricky.menuDetail == "adaroot · example.test")
        #expect(tricky.menuLabel == "BankCorp, adaroot · example.test")
        // Display only: the summary and what is copied keep the stored username.
        #expect(tricky.username == "ada\u{202E}\nroot")

        let bare = summary("https://example.test", username: "\u{202E}", displayName: "")
        #expect(bare.menuDetail == "example.test", "a username that is only a format character leaves no empty part")
    }

    // MARK: Row actions

    @Test func aRowOffersOnlyWhatItHoldsAndNeverShowsAValue() {
        let login = summary("https://example.test", username: "ada", password: "pw")
        #expect(PasswordsMenuAction.offered(for: login) == [.copyUsername, .copyPassword, .openWebsite])
        #expect(PasswordsMenuAction.primary(for: login) == .copyPassword)

        let noPassword = summary("https://example.test", username: "ada", password: nil)
        #expect(PasswordsMenuAction.offered(for: noPassword) == [.copyUsername, .openWebsite])
        #expect(PasswordsMenuAction.primary(for: noPassword) == .copyUsername)

        var code = VaultFixtures.account(username: "", password: nil)
        code.totp = TOTPGenerator(secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: "ada")
        let codeOnly = CredentialSummary(code)
        #expect(PasswordsMenuAction.offered(for: codeOnly) == [.copyCode, .openWebsite])
        #expect(PasswordsMenuAction.primary(for: codeOnly) == nil)

        // A concealed username can still be copied; it is never drawn.
        var hidden = VaultFixtures.account(username: "secret-name")
        hidden.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(fieldType: .concealedString), password: nil
        )
        #expect(PasswordsMenuAction.offered(for: CredentialSummary(hidden)).contains(.copyUsername))

        let titles = [PasswordsMenuAction.copyUsername, .copyPassword, .copyCode, .openWebsite].map(\.title)
        #expect(titles == ["Copy Username", "Copy Password", "Copy Verification Code", "Open Website"])
    }
}
