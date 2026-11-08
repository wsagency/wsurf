// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// D5(a): every autofill list is made from the vault's candidates and rows, which hold no secret, and lists exactly what it listed from
/// whole entries: the same rows, order, titles, details and search keys for the dropdown, its sibling rows and Pick Credential…. The
/// three files that list for autofill never read the whole vault (a source scan, since the compiler cannot see a later edit that
/// would). What a pick fills is made from that one credential's secret (`CredentialAccountSelection.fillFields`). Pure: no vault, no
/// page. Synthetic values only.
struct AutofillListingTests {
    private static let site = "https://login.example.test"
    private static let generator = TOTPGenerator(
        secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 30, digits: 8, issuer: nil, userName: nil
    )

    private static func account(
        _ username: String, password: String? = "pw-listing", displayName: String? = nil, origins: [String] = [site],
        path: String = "/login", totp: Bool = false, passkeys: [WebsitePasskey] = [], items: [SecureItem]? = nil, concealed: Bool = false
    ) -> CredentialAccount {
        var account = CredentialAccount(
            id: UUID(), username: username, displayName: displayName, origins: origins,
            loginURLs: origins.compactMap { URL(string: $0 + path) }, password: password, passkeys: passkeys,
            totp: totp ? generator : nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        account.secureItems = items
        if concealed {
            account.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
                username: CredentialEditableFieldMetadata(fieldType: .concealedString),
                password: password == nil ? nil : CredentialEditableFieldMetadata(fieldType: .concealedString)
            )
        }
        return account
    }

    /// Logins, codes, passkeys and items of this website, its siblings and another domain, with every title and detail rule in play.
    private static func accounts() throws -> [CredentialAccount] {
        [
            account("ada"), account("Ada", password: "pw-upper"), account("ada", displayName: "Work"), account("ada", path: "/checkout"),
            account("grace", password: nil, totp: true), account("", password: "pw-nameless", displayName: "Nameless"),
            account("", password: "pw-bare"), account("pk", password: nil, passkeys: [try VaultFixtures.passkey(rpID: "login.example.test")]),
            account("hidden@example.test", concealed: true), account("bob", origins: ["https://www.example.test"]),
            account("", password: nil, origins: ["https://example.test"], totp: true),
            account("carol", origins: ["https://other.test"], totp: true),
            account("", password: "pw-card", origins: [], items: [SecureItemFixtures.card(), SecureItemFixtures.custom(label: "Locker")]),
            account("dave", items: [SecureItemFixtures.card(number: "378282246310005")]),
            account("", password: nil, displayName: "Only items", origins: [], items: [SecureItemFixtures.address(), SecureItemFixtures.wifi()]),
        ]
    }

    // MARK: A2 The listing files never read the whole vault

    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The dropdown, Pick Credential… and the card and address rules name no whole-vault read; the first two hold no whole vault.
    /// `VaultItemAutofill.saveWrite`, on the save path, still takes one, which is why that file keeps `StoreSnapshot`.
    @Test func theAutofillListingFilesNeverReadTheWholeVault() throws {
        let files = [
            ("WSurf/Web/Autofill/AutofillSuggestions.swift", true), ("WSurf/Web/Autofill/CredentialPicker.swift", true),
            ("WSurf/Web/Autofill/VaultItemAutofill.swift", false),
        ]
        var scanned = 0
        for (path, holdsNoSnapshot) in files {
            let text = try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
            #expect(text.count > 1_000, "\(path) was not read")
            scanned += 1
            #expect(!text.contains(".snapshot()"), "\(path) reads the whole vault")
            if holdsNoSnapshot {
                #expect(!text.contains("StoreSnapshot"), "\(path) holds a whole vault")
            }
        }
        // A scan that read nothing would pass for the wrong reason.
        #expect(scanned == files.count)
    }

    // MARK: A3 Candidates list exactly what whole entries listed

    @Test(arguments: [CredentialAutofillField.password, .totp])
    func theDropdownListsTheSameRowsFromCandidates(field: CredentialAutofillField) throws {
        let accounts = try Self.accounts()
        let candidates = accounts.map(AutofillCandidate.init)
        let page = URL(string: Self.site + "/login?next=1")
        for entered in [nil, "", "a", "ADA", "ada", "hidden@example.test"] as [String?] {
            for pinned in [nil, accounts[2].id] as [UUID?] {
                let whole = CredentialAccountSelection.suggestions(accounts, origin: Self.site, pageURL: page, entered: entered, field: field, pinned: pinned)
                let listed = CredentialAccountSelection.suggestions(
                    candidates, origin: Self.site, pageURL: page, entered: entered, field: field, pinned: pinned
                )
                #expect(listed.map { [$0.id.uuidString, $0.title, $0.detail] } == whole.map { [$0.id.uuidString, $0.title, $0.detail] })
            }
            let wholeSiblings = CredentialAccountSelection.siblings(in: accounts, origin: Self.site, entered: entered, field: field)
            let siblings = CredentialAccountSelection.siblings(in: candidates, origin: Self.site, entered: entered, field: field)
            #expect(siblings.map { "\($0.account.id)/\($0.website)" } == wholeSiblings.map { "\($0.account.id)/\($0.website)" })
        }
        let vaults: [(id: UUID, label: String?, accounts: [CredentialAccount])] = [
            (id: UUID(), label: "Personal", accounts: accounts), (id: UUID(), label: "Work", accounts: Array(accounts.reversed())),
        ]
        let used: (UUID, UUID) -> Date? = { _, account in account == accounts[1].id ? Date(timeIntervalSinceReferenceDate: 1) : nil }
        let whole = CredentialAccountSelection.listed(in: vaults, origin: Self.site, pageURL: page, entered: "a", field: field, usedAt: used)
        let listed = CredentialAccountSelection.listed(
            in: vaults.map { (id: $0.id, label: $0.label, accounts: $0.accounts.map(AutofillCandidate.init)) },
            origin: Self.site, pageURL: page, entered: "a", field: field, usedAt: used
        )
        #expect(listed == whole)
    }

    @Test func aCandidateIsASiblingTitledAndGivenAWebsiteAsItsEntryIs() throws {
        for account in try Self.accounts() {
            let candidate = AutofillCandidate(account)
            for origin in [Self.site, "https://example.test", "https://other.test", "https://a.github.io"] {
                #expect(CredentialAccountSelection.isSibling(candidate, of: origin) == CredentialAccountSelection.isSibling(account, of: origin))
                #expect(CredentialAccountSelection.title(candidate, origin: origin) == CredentialAccountSelection.title(account, origin: origin))
                for anySite in [false, true] {
                    #expect(
                        CredentialAccountSelection.canAddWebsite(origin, to: candidate, anySite: anySite)
                            == CredentialAccountSelection.canAddWebsite(origin, to: account, anySite: anySite)
                    )
                }
            }
        }
    }

    /// Pick Credential… keeps item titles (owner decision 3): from a candidate it names and finds a credential exactly as the Credential
    /// Manager does from the whole entry, a concealed username, card titles and custom group titles included.
    @Test func pickCredentialListsTheSameRowsFromCandidates() throws {
        let accounts = try Self.accounts()
        let used = [accounts[0].id: Date(timeIntervalSinceReferenceDate: 5)]
        func shown(_ rows: [CredentialPicker.Row]) -> [String] {
            rows.map { "\($0.accountID)|\($0.fill)|\($0.title)|\($0.detail)|\($0.matchesSite)|\($0.searchKey)|\(String(describing: $0.lastUsed))" }
        }
        let vaultID = UUID()
        let whole = CredentialPicker.rows(accounts, vaultID: vaultID, origin: Self.site, vault: "Personal", used: used)
        let listed = CredentialPicker.rows(accounts.map(AutofillCandidate.init), vaultID: vaultID, origin: Self.site, vault: "Personal", used: used)
        #expect(shown(listed) == shown(whole))
        for field in [CredentialPicker.Field.password, .code, .text] {
            #expect(shown(CredentialPicker.ordered(listed, for: field)) == shown(CredentialPicker.ordered(whole, for: field)))
        }
        #expect(CredentialPicker.filter(listed, query: "Visa").map(\.accountID) == [accounts[12].id], "a card's title is still found")
        #expect(CredentialPicker.filter(listed, query: "locker").map(\.accountID) == [accounts[12].id], "a custom group's title is still found")
        #expect(CredentialPicker.filter(listed, query: "hidden@").isEmpty, "a concealed username is not searched")
        for account in accounts {
            let summary = CredentialSummary(account), named = CredentialSummary.naming(AutofillCandidate(account))
            #expect(named.username == summary.username && named.title == summary.title && named.searchKey == summary.searchKey)
        }
    }

    // MARK: What a pick fills

    /// The dropdown's fill, made at delivery from the picked credential's one secret: the username and password, or a fresh code only
    /// on this website or a sibling website the person chose.
    @Test func aPickedLoginFillsItsUsernameAndPasswordOrAFreshCode() throws {
        let login = AutofillLogin(Self.account("ada", password: "pw-picked"), field: .password)
        let fields = try CredentialAccountSelection.fillFields(login, field: .password, origin: Self.site, sibling: false, at: .now)
        let isTheLogin = fields["username"] as? String == "ada" && fields["password"] as? String == "pw-picked" && fields.count == 2
        #expect(isTheLogin, "a password pick does not fill the login")
        let bare = try CredentialAccountSelection.fillFields(
            AutofillLogin(Self.account("ada", password: nil), field: .password), field: .password, origin: Self.site, sibling: false, at: .now
        )
        #expect(bare["username"] as? String == "ada" && bare.count == 1)

        let at = Date(timeIntervalSince1970: 59)
        let code = AutofillLogin(Self.account("grace", password: nil, totp: true), field: .totp)
        #expect(try CredentialAccountSelection.fillFields(code, field: .totp, origin: Self.site, sibling: false, at: at)["code"] as? String == "94287082")
        let sibling = AutofillLogin(Self.account("", password: nil, origins: ["https://example.test"], totp: true), field: .totp)
        #expect(throws: ContactAutofillError.noField) {
            _ = try CredentialAccountSelection.fillFields(sibling, field: .totp, origin: Self.site, sibling: false, at: at)
        }
        #expect(try CredentialAccountSelection.fillFields(sibling, field: .totp, origin: Self.site, sibling: true, at: at)["code"] as? String == "94287082")
        let elsewhere = AutofillLogin(Self.account("carol", origins: ["https://other.test"], totp: true), field: .totp)
        #expect(throws: ContactAutofillError.noField) {
            _ = try CredentialAccountSelection.fillFields(elsewhere, field: .totp, origin: Self.site, sibling: true, at: at)
        }
        #expect(throws: ContactAutofillError.noField) {
            _ = try CredentialAccountSelection.fillFields(login, field: .totp, origin: Self.site, sibling: false, at: at)
        }
    }

    /// A card or contact row of the vault is shown as the whole card or contact was.
    @Test func aCardOrContactRowShowsWhatTheWholeItemShowed() throws {
        let items = [
            SecureItemFixtures.card(), SecureItemFixtures.card(number: "378282246310005", name: "Grace"),
            SecureItemFixtures.card(number: "6200000000000005", name: ""),
        ]
        for item in items {
            let values = try #require(AutofillCardValues(item))
            let card = try #require(VaultItemAutofill.paymentCard(item))
            let row = AutofillSuggestion(id: card.id, card: AutofillCardRow(accountID: UUID(), item: 0, values))
            let whole = AutofillSuggestion(.card(card))
            #expect(row.title == whole.title && row.detail == whole.detail && row.month == whole.month && row.year == whole.year)
        }
        let entries = [
            SecureItemFixtures.account([SecureItemFixtures.name(), SecureItemFixtures.address()], name: "Home"),
            SecureItemFixtures.account([SecureItem(kind: .address, fields: [SecureItemFixtures.field("city", "Testville")])], name: nil),
        ]
        for entry in entries {
            let values = try #require(AutofillContactValues(of: entry))
            let contact = try #require(VaultItemAutofill.contact(of: entry))
            let row = AutofillSuggestion(id: contact.id, contact: AutofillContactRow(accountID: entry.id, item: 0, values))
            let whole = AutofillSuggestion(.contact(contact))
            let sameFill = AutofillContact(values).fields == contact.fields
            #expect(row.title == whole.title && row.detail == whole.detail && sameFill)
        }
    }
}
