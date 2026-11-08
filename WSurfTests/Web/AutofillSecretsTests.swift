// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf
@testable import WSurfVault

/// D5(a): no secret reaches autofill before the person picks a row. The dropdown's focus reads candidates or rows, never the whole vault
/// (the read audit, keyed by this test's own profile, counts every vault read); its pick reads that one credential's secret at the
/// revision the list was read at; a write or a lock in between delivers nothing. Real manager and store, synthetic data only. A failed
/// check never prints a secret: it compares to a Bool first. The lookup needs a key window and an active app to show its panel, as every
/// dropdown test notes, so it is read here from what it records on its request before that (`MessagesCodeRowTests`).
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AutofillSecretsTests {
    private static let shop = "https://shop.example"
    private static let password = "pw-SENTINEL-7f3c9a1e"
    private static let note = "note-SENTINEL-91d0c4"
    private static let street = "street-SENTINEL-3a9f61"
    private static let cardNumber = "4000056655665556"
    private static let cardCode = "8317"
    /// RFC 6238 appendix B's seed with an hour's period, so a code made before and after a fill is almost always the same one.
    private static let generator = TOTPGenerator(
        secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 3600, digits: 6, issuer: nil, userName: nil
    )

    @MainActor
    private final class Rig {
        let tab: BrowserTab
        let page: BrowserPage
        let window: NSWindow
        let main: BrowserFrame

        init(context: BrowserProfileContext) {
            tab = BrowserTab(opensBlank: false, context: context)
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration), context: context)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            AutofillSaveCoordinator.shared.install(in: page, session: tab.autofillSave)
            page.url = URL(string: AutofillSecretsTests.shop + "/login")
            page.hasOnlySecureContent = true
            main = BrowserFrame(
                id: "MAIN", documentID: "loader-main", url: URL(string: AutofillSecretsTests.shop + "/login")!, isMainFrame: true,
                securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "shop.example", port: 0)
            )
        }

        /// A request for `kind`'s field, the page's current one, as a `select` from the page makes it.
        func request(_ kind: AutofillSaveKind, field: CredentialAutofillField = .password) -> AutofillSuggestions.Request {
            let request = AutofillSuggestions.Request(
                page: page, context: page.context, frame: main, token: UUID().uuidString, kind: kind,
                frameURL: URL(string: AutofillSecretsTests.shop + "/login")!, topURL: URL(string: AutofillSecretsTests.shop + "/login")!,
                world: PasswordAutofill.world, bridge: "__wsurfPasswords", documentID: UUID().uuidString, formID: "1", fieldID: "2",
                field: field, enteredUsername: nil, typeToSearch: false, isWebAuthnField: false
            )
            AutofillSuggestions.shared.requests[ObjectIdentifier(page)] = request
            return request
        }

        func close() async {
            AutofillSuggestions.shared.requests[ObjectIdentifier(page)] = nil
            window.contentView = nil
            window.close()
            await page.close()
        }
    }

    /// A login that holds every kind of secret, an entry with a contact, and an entry with a card.
    private func entries() throws -> [CredentialAccount] {
        var login = VaultFixtures.account(
            username: "ada", password: Self.password, origin: Self.shop, passkeys: [try VaultFixtures.passkey(rpID: "shop.example")]
        )
        login.totp = Self.generator
        login.notes = [CredentialNote(text: Self.note)]
        login.secureItems = [SecureItemFixtures.wifi()]
        let contact = SecureItemFixtures.account(
            [SecureItemFixtures.name(), SecureItemFixtures.address(street: Self.street), SecureItemFixtures.custom()], name: "Home"
        )
        let card = SecureItemFixtures.account(
            [SecureItemFixtures.card(number: Self.cardNumber, code: Self.cardCode, name: "Grace Hopper")], name: "Wallet"
        )
        return [login, contact, card]
    }

    /// The fixture's one unlocked vault holding `entries()`, a page rig, and an audit of every vault read made from here on.
    private func withVault(
        _ body: (Rig, FixtureVault, [CredentialAccount], VaultReadAudit) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let accounts = try entries()
            try await VaultManagerFixture.save(accounts, in: vaults[0])
            let audit = VaultReadAudit()
            CredentialManager.readAuditsForTesting[profile.id] = audit
            let rig = Rig(context: BrowserProfileContext(profile: profile))
            defer { CredentialManager.readAuditsForTesting[profile.id] = nil }
            do {
                try await body(rig, vaults[0], accounts, audit)
            } catch {
                await rig.close()
                throw error
            }
            await rig.close()
        }
    }

    /// Every secret the fixture holds, and the contact values a row does not show, found in what a lookup left on the main actor.
    private static func leaks(in values: [Any], showing shown: [String] = []) -> [String] {
        let secrets = [password, note, cardNumber, SecureItemFixtures.wifiPassphrase, "Lovelace", "Testville", "+385", street]
            .filter { !shown.contains($0) }
        var found: [String] = []
        for (index, value) in values.enumerated() {
            var dumped = ""
            dump(value, to: &dumped)
            if secrets.contains(where: dumped.contains) || dumped.contains("TOTPCodeSource") || dumped.contains("AutofillLogin") {
                found.append("value \(index)")
            }
            if Self.holdsCode(value) {
                found.append("value \(index) holds the security code")
            }
        }
        return found
    }

    /// Whether a text under `value` is the card's security code, compared whole: a UUID's hex could spell it.
    private static func holdsCode(_ value: Any) -> Bool {
        if let text = value as? String {
            return text == cardCode
        }
        guard !(value is URL), !(value is UUID) else { return false }
        return Mirror(reflecting: value).children.contains { holdsCode($0.value) }
    }

    /// What a request kept: the rows, grants and actions a lookup or a pick left on it.
    private static func kept(by request: AutofillSuggestions.Request) -> [Any] {
        [request.grants, request.rows, request.itemRows, request.siblingRows, request.siblings, request.actions]
    }

    // MARK: A1 Focus reads no secret

    @Test(arguments: [CredentialAutofillField.password, .totp])
    func aLoginOrCodeFieldsFocusReadsCandidatesOnly(field: CredentialAutofillField) async throws {
        try await withVault { rig, vault, _, audit in
            let request = rig.request(.password, field: field)
            _ = await AutofillSuggestions.shared.lookUp(
                request, origin: Self.shop, presentation: AutofillSuggestions.shared.presentationID, in: rig.page
            )
            #expect(audit.reads == [.candidates], "the focus read something else: \(audit.reads)")
            #expect(request.grants.keys.contains(vault.vaultID), "the lookup did not read the vault")
            let leaks = Self.leaks(in: Self.kept(by: request))
            #expect(leaks.isEmpty, "the request holds a secret: \(leaks)")
        }
    }

    @Test(arguments: [AutofillSaveKind.card, .contact])
    func aCardOrAddressFieldsFocusReadsRowsOfItsKindOnly(kind: AutofillSaveKind) async throws {
        try await withVault { rig, vault, _, audit in
            let request = rig.request(kind)
            let rows = await AutofillSuggestions.shared.vaultItemSuggestions(
                for: request, origin: Self.shop, presentation: AutofillSuggestions.shared.presentationID
            )
            let itemKind: AutofillItemKind = kind == .card ? .cards : .contacts
            #expect(audit.reads == [.items(itemKind, pick: false)], "the focus read something else: \(audit.reads)")
            #expect(request.grants.keys.contains(vault.vaultID) && rows.count == 1 && request.itemRows.count == 1)
            let shownAsBefore = switch kind {
            case .card:
                rows.first?.title == "Visa •••• 5556" && rows.first?.detail == "Grace Hopper"
            default:
                rows.first?.title == "Home" && rows.first?.detail == Self.street
            }
            #expect(shownAsBefore, "the row is not titled and detailed as before")
            let shown = kind == .contact ? [Self.street] : []
            let leaks = Self.leaks(in: [rows] + Self.kept(by: request), showing: shown)
            #expect(leaks.isEmpty, "the rows or the request hold a secret: \(leaks)")
        }
    }

    // MARK: A3 The pick still fills (the dropdown; Pick Credential… in `CredentialPickerTests`)

    /// The picked row's credential is read for its one secret at the list's revision: the password and its username, or a fresh code.
    @Test(arguments: [CredentialAutofillField.password, .totp])
    func aPickedRowFillsItsSecretReadAtTheListsRevision(field: CredentialAutofillField) async throws {
        try await withVault { rig, vault, accounts, audit in
            let request = rig.request(.password, field: field)
            let rowID = try await list(accounts[0], for: request, in: vault)
            let earlier = try TOTP.code(Self.generator, at: Date.now.timeIntervalSince1970).value

            let filled = try await AutofillSuggestions.shared.managerFill(rowID, request: request, in: rig.page)
            let delivered = try #require(try filled.prepare()["fields"] as? [String: Any])

            let later = try TOTP.code(Self.generator, at: Date.now.timeIntervalSince1970).value
            switch field {
            case .password:
                let isTheLogin = delivered["username"] as? String == "ada" && delivered["password"] as? String == Self.password
                #expect(isTheLogin && delivered.count == 2, "the pick did not deliver the login")
                #expect(filled.username == "ada")
            case .totp:
                let code = delivered["code"] as? String
                let isTheCode = (code == earlier || code == later) && delivered.count == 1
                #expect(isTheCode, "the pick did not deliver the code")
                #expect(filled.username == nil)
            }
            #expect(audit.reads == [.candidates, .login(field == .totp ? .totp : .password)], "\(audit.reads)")
            let leaks = Self.leaks(in: Self.kept(by: request))
            #expect(leaks.isEmpty, "the request keeps the picked secret: \(leaks)")
        }
    }

    /// A row listed as a sibling website's ("Check other logins") fills its login or code; the same credential not listed as one
    /// fills nothing, since it is not saved for this website.
    @Test(arguments: [CredentialAutofillField.password, .totp])
    func aSiblingRowFillsOnlyAsASibling(field: CredentialAutofillField) async throws {
        try await withVault { rig, vault, accounts, _ in
            var sibling = VaultFixtures.account(username: "grace", password: "pw-sibling", origin: "https://www.shop.example")
            sibling.totp = Self.generator
            try await VaultManagerFixture.save(accounts + [sibling], in: vault)
            let request = rig.request(.password, field: field)
            let rowID = try await list(sibling, for: request, in: vault)

            var refused: (any Error)?
            do {
                _ = try await AutofillSuggestions.shared.managerFill(rowID, request: request, in: rig.page)
            } catch {
                refused = error
            }
            #expect(refused as? ContactAutofillError == .changedPage, "a credential of another website filled as this website's")

            request.siblingRows.insert(rowID)
            let earlier = try TOTP.code(Self.generator, at: Date.now.timeIntervalSince1970).value
            let filled = try await AutofillSuggestions.shared.managerFill(rowID, request: request, in: rig.page)
            let delivered = try #require(try filled.prepare()["fields"] as? [String: Any])
            let later = try TOTP.code(Self.generator, at: Date.now.timeIntervalSince1970).value
            switch field {
            case .password:
                let isTheLogin = delivered["username"] as? String == "grace" && delivered["password"] as? String == "pw-sibling"
                #expect(isTheLogin && delivered.count == 2, "the sibling pick did not deliver its login")
            case .totp:
                let code = delivered["code"] as? String
                let isTheCode = (code == earlier || code == later) && delivered.count == 1
                #expect(isTheCode, "the sibling pick did not deliver its code")
            }
        }
    }

    /// A card or address row fills that row's values, read only at the pick, and a card only after Touch ID (stubbed).
    @Test(arguments: [AutofillSaveKind.card, .contact])
    func aPickedCardOrAddressFillsThatRowsValues(kind: AutofillSaveKind) async throws {
        try await withVault { rig, _, _, audit in
            let suggestions = AutofillSuggestions.shared
            let verify = suggestions.verifyUser
            var asked = 0
            suggestions.verifyUser = { _ in asked += 1 }
            defer { suggestions.verifyUser = verify }
            let request = rig.request(kind)
            _ = await suggestions.vaultItemSuggestions(for: request, origin: Self.shop, presentation: suggestions.presentationID)
            let rowID = try #require(request.itemRows.keys.first)

            let prepare = try await suggestions.vaultItemFill(rowID, request: request, in: rig.page)
            let delivered = try #require(try prepare()["fields"] as? [String: Any])

            switch kind {
            case .card:
                let isTheCard = delivered["number"] as? String == Self.cardNumber && delivered["securityCode"] as? String == Self.cardCode
                    && delivered["cardholder"] as? String == "Grace Hopper" && delivered["month"] as? Int == 7
                    && delivered["year"] as? Int == 2031
                #expect(isTheCard, "the pick did not deliver the card")
                #expect(asked == 1, "a card fills only after Touch ID")
            default:
                let isTheContact = delivered["street-address"] as? String == Self.street && delivered["family-name"] as? String == "Lovelace"
                    && delivered["address-level2"] as? String == "Testville" && delivered["country"] as? String == "HR"
                #expect(isTheContact, "the pick did not deliver the contact")
                #expect(asked == 0)
            }
            let itemKind: AutofillItemKind = kind == .card ? .cards : .contacts
            #expect(audit.reads == [.items(itemKind, pick: false), .items(itemKind, pick: true)], "\(audit.reads)")
            let leaks = Self.leaks(in: Self.kept(by: request), showing: kind == .contact ? [Self.street] : [])
            #expect(leaks.isEmpty, "the request keeps the picked values: \(leaks)")
        }
    }

    // MARK: A4 A stale pick delivers nothing

    @Test func aWriteBetweenTheListAndThePickDeliversNothing() async throws {
        try await withVault { rig, vault, accounts, audit in
            let request = rig.request(.password)
            let rowID = try await list(accounts[0], for: request, in: vault)
            let listed = try #require(request.grants[vault.vaultID]?.revision)
            try await VaultManagerFixture.save(accounts + [VaultFixtures.account(username: "grace", origin: Self.shop)], in: vault)

            let stale = await failure { _ = try await vault.manager.autofillLogin(accountID: accounts[0].id, field: .password, expectedRevision: listed) }
            #expect(stale as? CredentialVaultError == .staleRevision)
            let before = audit.reads.count
            let refused = await failure { _ = try await AutofillSuggestions.shared.managerFill(rowID, request: request, in: rig.page) }
            #expect(refused as? ContactAutofillError == .changedPage, "the dropdown's pick of a changed vault is not refused as before")
            #expect(Array(audit.reads.dropFirst(before)) == [.login(.password)], "the pick read something else")
        }
    }

    @Test(arguments: [AutofillSaveKind.card, .contact])
    func aWriteBetweenTheRowsAndThePickOfACardOrAddressFillsNothing(kind: AutofillSaveKind) async throws {
        try await withVault { rig, vault, accounts, _ in
            let suggestions = AutofillSuggestions.shared
            let verify = suggestions.verifyUser
            var asked = 0
            suggestions.verifyUser = { _ in asked += 1 }
            defer { suggestions.verifyUser = verify }
            let request = rig.request(kind)
            _ = await suggestions.vaultItemSuggestions(for: request, origin: Self.shop, presentation: suggestions.presentationID)
            let rowID = try #require(request.itemRows.keys.first)
            try await VaultManagerFixture.save(accounts + [VaultFixtures.account(username: "grace", origin: Self.shop)], in: vault)

            var refused: (any Error)?
            do {
                _ = try await suggestions.vaultItemFill(rowID, request: request, in: rig.page)
            } catch {
                refused = error
            }
            #expect(refused as? ContactAutofillError == .changedPage, "the pick of a changed vault is not refused as before")
            #expect(asked == 0, "Touch ID was asked for a card that will not fill")
        }
    }

    /// A card that ends between its row and the pick (review F3). The vault refuses that pick as stale, by its own calendar clock
    /// (`VaultAutofillReadTests.aCardThatEndsAfterItsListIsStale` moves it across a month end); the panel then fails it as it did before
    /// D5(a), with `PaymentCardError.noField`, from the expiry its row showed. Anything else stale, and any contact, is `changedPage`.
    /// Both show the same "Couldn't Fill Saved Details" alert, and no Touch ID is asked.
    @Test func aCardThatEndsBeforeItsPickFailsAsBefore() async throws {
        let july = Date(timeIntervalSince1970: 1_941_883_200), august = Date(timeIntervalSince1970: 1_944_561_600)
        #expect(Self.isNoField(VaultItemAutofill.stalePickError(month: 7, year: 2031, now: august)))
        #expect(VaultItemAutofill.stalePickError(month: 7, year: 2031, now: july) as? ContactAutofillError == .changedPage)
        #expect(VaultItemAutofill.stalePickError(month: nil, year: nil, now: august) as? ContactAutofillError == .changedPage)
        try await withVault { rig, vault, accounts, _ in
            let suggestions = AutofillSuggestions.shared
            let verify = suggestions.verifyUser
            var asked = 0
            suggestions.verifyUser = { _ in asked += 1 }
            defer { suggestions.verifyUser = verify }
            let request = rig.request(.card)
            _ = await suggestions.vaultItemSuggestions(for: request, origin: Self.shop, presentation: suggestions.presentationID)
            let rowID = try #require(request.itemRows.keys.first)
            let keptExpiry = request.itemRows[rowID]?.month == 7 && request.itemRows[rowID]?.year == 2031
            #expect(keptExpiry, "a card row does not keep the expiry it showed")
            // The row's card has ended by now, and the vault refuses the pick as stale: here a write stands in for the month end,
            // which only the store's calendar clock decides.
            request.itemRows[rowID]?.month = 12
            request.itemRows[rowID]?.year = 2020
            try await VaultManagerFixture.save(accounts + [VaultFixtures.account(username: "grace", origin: Self.shop)], in: vault)

            var refused: (any Error)?
            do {
                _ = try await suggestions.vaultItemFill(rowID, request: request, in: rig.page)
            } catch {
                refused = error
            }
            #expect(Self.isNoField(refused), "a card that ended since its row fails otherwise than before D5(a)")
            #expect(asked == 0, "Touch ID was asked for a card that will not fill")
        }
    }

    // MARK: A5 A lock still drops everything

    /// List, lock every vault as a screen lock does, then pick: the request's authority, the vault read and the store's grant are all
    /// gone, and the request keeps nothing a secret could be reached from (references dropped, not memory zeroed).
    @Test func aLockBetweenTheListAndThePickLeavesNothingToFill() async throws {
        try await VaultManagerFixture.exclusive {
            try await withVault { rig, vault, accounts, _ in
                let request = rig.request(.password)
                let rowID = try await list(accounts[0], for: request, in: vault)
                let listed = try #require(request.grants[vault.vaultID]?.revision)
                let access = try vault.manager.currentAccess()
                try AutofillSuggestions.shared.requireAuthority(request, in: rig.page)

                CredentialManager.lockAll(reason: .screenLock)

                #expect(throws: ContactAutofillError.changedPage) { try AutofillSuggestions.shared.requireAuthority(request, in: rig.page) }
                var login: (any Error)?
                do {
                    _ = try await vault.manager.autofillLogin(accountID: accounts[0].id, field: .password, expectedRevision: listed)
                } catch {
                    login = error
                }
                #expect(login as? CredentialVaultError == .unauthorized)
                var grant: (any Error)?
                do {
                    _ = try await vault.manager.store.snapshot(vaultID: vault.vaultID, using: access)
                } catch {
                    grant = error
                }
                #expect(grant as? CredentialVaultError == .unauthorized, "the store still holds a grant")
                var pick: (any Error)?
                do {
                    _ = try await AutofillSuggestions.shared.managerFill(rowID, request: request, in: rig.page)
                } catch {
                    pick = error
                }
                #expect(pick as? ContactAutofillError == .changedPage)
                let leaks = Self.leaks(in: Self.kept(by: request))
                #expect(leaks.isEmpty, "the request keeps a secret after the lock: \(leaks)")
            }
        }
    }

    // MARK: Helpers

    /// `account` listed on `request` as the dropdown lists it (`managerSuggestions` after its focus checks): the vault's grant at the
    /// revision of its candidates, and one row.
    private func list(_ account: CredentialAccount, for request: AutofillSuggestions.Request, in vault: FixtureVault) async throws -> UUID {
        let epoch = try #require(vault.manager.authorizationEpoch)
        let candidates = try await vault.manager.autofillCandidates()
        #expect(candidates.candidates.contains { $0.id == account.id })
        request.grants[vault.vaultID] = .init(epoch: epoch, revision: candidates.revision)
        let rowID = UUID()
        request.rows[rowID] = (vault.vaultID, account.id)
        return rowID
    }

    /// Whether `error` is `PaymentCardError.noField`, the panel's error for a card that cannot fill.
    private static func isNoField(_ error: (any Error)?) -> Bool {
        guard let error = error as? PaymentCardError, case .noField = error else { return false }
        return true
    }

    private func failure(_ body: () async throws -> Void) async -> (any Error)? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }
}
