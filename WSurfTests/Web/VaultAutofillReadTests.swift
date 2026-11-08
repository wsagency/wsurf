// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing

@testable import WSurf
@testable import WSurfVault

// D5(a): what autofill reads of a vault (`ProfileVaultStore+Autofill.swift`). A list (candidates, card and contact rows) holds no
// secret value; a pick, named by its credential (and item) and the revision its list was read at, holds that one value and prints
// without it; every refusal is the verified read's own. The card and contact rules the vault now owns read an item exactly as the
// app's `PaymentCard`, `VaultItemAutofill` and `SecureItem.title` do. Synthetic data only. A failed check never prints a secret: it
// compares to a Bool first, and its message names the check, never a value.

/// Values a leak would carry. The long ones are searched for in printed text; the short card codes are only compared as whole values,
/// since a UUID's hex could spell them.
private nonisolated enum Sentinel {
    static let password = "pw-SENTINEL-7f3c9a1e"
    static let note = "note-SENTINEL-91d0c4"
    static let wifi = "wifi-SENTINEL-c2e85b"
    static let apiKey = "apikey-SENTINEL-55aa3d"
    static let hidden = "custom-SENTINEL-0b17e2"
    static let street = "street-SENTINEL-3a9f61"
    static let cardNumber = "4000056655665556"
    static let otherCardNumber = "5555555555554444"
    static let cardCode = "8317"
    static let otherCardCode = "2964"
    static let seed = Data("seed-SENTINEL-4b2d8e".utf8)

    /// Text no list may hold, in a candidate or a card row.
    static let secrets = [password, note, wifi, apiKey, hidden, cardNumber, otherCardNumber]
    static let codes = [cardCode, otherCardCode]
}

private nonisolated enum Entries {
    static let loginID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let codeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let contactID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    /// A login that holds every kind of secret: a password, a code seed, a passkey, a note, two cards, a Wi-Fi network, custom fields
    /// with a hidden value and an API key.
    static func login() throws -> CredentialAccount {
        var account = VaultFixtures.account(
            id: loginID, username: "ada", password: Sentinel.password, origin: "https://example.test",
            passkeys: [try VaultFixtures.passkey(rpID: "example.test")]
        )
        account.totp = TOTPGenerator(secret: Sentinel.seed, algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: nil)
        account.notes = [CredentialNote(text: Sentinel.note)]
        account.secureItems = [
            SecureItemFixtures.card(number: Sentinel.cardNumber, code: Sentinel.cardCode),
            SecureItemFixtures.wifi(passphrase: Sentinel.wifi),
            SecureItemFixtures.custom(label: "Locker", values: [("Code", Sentinel.hidden, true)]),
            SecureItem(kind: .apiKey, fields: [SecureItemFixtures.field("key", Sentinel.apiKey, type: .concealedString)]),
            SecureItemFixtures.card(number: Sentinel.otherCardNumber, code: Sentinel.otherCardCode, name: "Grace Hopper"),
        ]
        return account
    }

    /// RFC 6238 appendix B's SHA-1 seed with eight digits (at 59 s the code is 94287082), no password, and a username the exporter
    /// marked hidden.
    static func code() -> CredentialAccount {
        var account = VaultFixtures.account(id: codeID, username: "grace", password: nil, origin: "https://code.example.test")
        account.totp = TOTPGenerator(
            secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 30, digits: 8, issuer: nil, userName: nil
        )
        account.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(fieldType: .concealedString), password: nil
        )
        return account
    }

    /// An entry that holds a contact only: a name, an address and the contact's email and organization.
    static func contact() -> CredentialAccount {
        SecureItemFixtures.account(
            [SecureItemFixtures.name(), SecureItemFixtures.address(street: Sentinel.street), contactFields()], id: contactID, name: "Home"
        )
    }

    static func contactFields(email: String = "ada@example.test", organization: String = "Analytical Engines") -> SecureItem {
        SecureItem(kind: .customFields, fields: [
            SecureItemField(
                name: "", value: email,
                field: CredentialEditableFieldMetadata(id: AutofillContactValues.emailFieldID, label: "Email", fieldType: .email)
            ),
            SecureItemField(
                name: "", value: organization,
                field: CredentialEditableFieldMetadata(id: AutofillContactValues.organizationFieldID, label: "Organization", fieldType: .string)
            ),
        ])
    }

    static func all() throws -> [CredentialAccount] {
        [try login(), code(), contact()]
    }
}

/// What a list may hold, walked through every stored property: no value of a type that carries a secret, and no text equal to one.
private nonisolated enum Leak {
    /// Types that hold a secret value, or are one.
    static func isSecretCarrying(_ value: Any) -> Bool {
        value is CredentialAccount || value is TOTPGenerator || value is TOTPCodeSource || value is WebsitePasskey || value is SecureItem
            || value is SecureItemField || value is CredentialNote || value is CredentialAttachment || value is Data
            || value is AutofillCardValues || value is AutofillContactValues || value is AutofillItemValues
    }

    /// Every stored value under `value` (URLs and UUIDs are leaves), with its path.
    static func walk(_ value: Any, path: String = "", _ visit: (String, Any) -> Void) {
        visit(path, value)
        guard !(value is URL), !(value is UUID), !(value is String) else { return }
        for child in Mirror(reflecting: value).children {
            walk(child.value, path: path + "." + (child.label ?? "_"), visit)
        }
    }

    /// The paths under `value` that hold a secret-carrying type or a text equal to one of `texts`; empty when it holds none.
    static func paths(in value: Any, texts: [String]) -> [String] {
        var found: [String] = []
        walk(value) { path, child in
            if isSecretCarrying(child) || (child as? String).map(texts.contains) == true {
                found.append(path)
            }
        }
        return found
    }

    /// The paths under `value` whose text equals one of `texts`, for a pick, which holds a secret-carrying value on purpose.
    static func textPaths(in value: Any, texts: [String]) -> [String] {
        var found: [String] = []
        walk(value) { path, child in
            if (child as? String).map(texts.contains) == true {
                found.append(path)
            }
        }
        return found
    }

    /// Whether `value` prints, debug-prints or dumps any of `texts`.
    static func prints(_ value: Any, _ texts: [String]) -> Bool {
        var dumped = ""
        dump(value, to: &dumped)
        let printed = [String(describing: value), String(reflecting: value), dumped]
        return texts.contains { text in printed.contains { $0.contains(text) } }
    }
}

/// The error `body` throws, or nil.
private func failure(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

/// An error as a comparable name (no error here carries a secret).
private nonisolated func name(_ error: (any Error)?) -> String {
    error.map { "\(type(of: $0)).\($0)" } ?? "none"
}

/// The app's names for the networks (`PaymentCard.network`), so a title made from a fact can be compared with `SecureItem.title`.
private nonisolated func networkName(_ network: CardNetwork) -> String {
    switch network {
    case .visa:
        "Visa"
    case .americanExpress:
        "American Express"
    case .mastercard:
        "Mastercard"
    case .discover:
        "Discover"
    case .jcb:
        "JCB"
    case .unionPay:
        "UnionPay"
    }
}

/// What a row would call an item from its fact alone, by `SecureItem.title`'s rule.
private nonisolated func title(of fact: AutofillItemFact) -> String {
    if let custom = fact.customTitle {
        return custom
    }
    guard let lastFour = fact.cardLastFour else { return fact.kind.label }
    return "\(fact.cardNetwork.map(networkName) ?? SecureItemKind.creditCard.label) •••• \(lastFour)"
}

private nonisolated enum Refusal: CaseIterable, Sendable {
    case locked, revoked, expired, unknownVault, tamperedRow
}

struct VaultAutofillReadTests {
    private static let candidateFields = [
        "id", "username", "usernameIsConcealed", "displayName", "origins", "loginURLs", "hasPassword", "hasTOTP", "passkeyCount", "items",
    ]
    private static let factFields = ["kind", "customTitle", "cardLastFour", "cardNetwork"]

    private func withVault(
        _ accounts: [CredentialAccount], _ body: (VaultStoreFixture, ProfileVaultStore, VaultAccess) async throws -> Void
    ) async throws {
        try await VaultStoreFixture.with(accounts: accounts) { f in
            let (store, access) = try await f.unlocked()
            try await body(f, store, access)
        }
    }

    // MARK: V1 Shape

    @Test func aCandidateHoldsIdentityFlagsAndItemNamesOnly() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let candidates = try await store.autofillCandidates(vaultID: f.vaultID, using: access)
            for candidate in candidates.candidates {
                #expect(Mirror(reflecting: candidate).children.map(\.label) == Self.candidateFields)
                for fact in candidate.items {
                    #expect(Mirror(reflecting: fact).children.map(\.label) == Self.factFields)
                }
            }
            let leaks = Leak.paths(in: candidates, texts: Sentinel.secrets + Sentinel.codes + [Sentinel.street])
            #expect(leaks.isEmpty, "a candidate holds a secret-carrying value at \(leaks)")
            let printed = Leak.prints(candidates.candidates, Sentinel.secrets + [Sentinel.street])
            #expect(!printed, "a candidate prints a secret")
        }
    }

    @Test func aPickAndItsValuesPrintAndMirrorWithoutTheirSecret() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            let login = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.loginID, field: .password, expectedRevision: revision, using: access
            )
            let code = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.codeID, field: .totp, expectedRevision: revision, using: access
            )
            let card = try await store.autofillItems(
                vaultID: f.vaultID, kind: .cards, accountID: Entries.loginID, item: 0, expectedRevision: revision, using: access
            )
            let contact = try await store.autofillItems(
                vaultID: f.vaultID, kind: .contacts, accountID: Entries.contactID, item: 0, expectedRevision: revision, using: access
            )
            #expect(login.password != nil && code.code != nil && card.picked != nil && contact.picked != nil)

            #expect("\(login)" == "AutofillLogin" && String(reflecting: login) == "AutofillLogin")
            #expect(Mirror(reflecting: login).children.map(\.label) == ["candidate"])
            #expect(!Leak.prints(login, [Sentinel.password]), "a password pick prints its password")
            let codeSource = try #require(code.code)
            #expect("\(codeSource)" == "TOTPCodeSource" && Mirror(reflecting: codeSource).children.isEmpty)
            #expect(Leak.paths(in: code, texts: []).isEmpty, "a code pick mirrors its seed")

            let values: [Any] = [card.picked as Any, contact.picked as Any]
            for value in values {
                #expect(Mirror(reflecting: value).children.allSatisfy { Mirror(reflecting: $0.value).children.isEmpty })
            }
            if case .card(let values)? = card.picked {
                #expect(Mirror(reflecting: values).children.isEmpty && "\(values)" == "AutofillCardValues")
            }
            if case .contact(let values)? = contact.picked {
                #expect(Mirror(reflecting: values).children.isEmpty && "\(values)" == "AutofillContactValues")
            }
            #expect(!Leak.prints(card, [Sentinel.cardNumber]), "a card pick prints its number")
            // The pick's row shows the street (its detail); the name, city and phone exist only in the values, which never print.
            #expect(!Leak.prints(contact, ["Lovelace", "Testville", "+385"]), "a contact pick prints a value its row does not show")
            let codeHidden = Leak.textPaths(in: card, texts: Sentinel.codes).isEmpty
            #expect(codeHidden, "a card pick mirrors its security code")
        }
    }

    // MARK: V2 Candidates

    @Test func candidatesAreTheVerifiedReadProjected() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            let read = try await store.autofillCandidates(vaultID: f.vaultID, using: access)
            #expect(read.vaultID == f.vaultID && read.revision == snapshot.revision)
            #expect(read.candidates.map(\.id) == snapshot.accounts.map(\.id))

            let byID = Dictionary(uniqueKeysWithValues: read.candidates.map { ($0.id, $0) })
            let login = try #require(byID[Entries.loginID])
            #expect(login.username == "ada" && !login.usernameIsConcealed && login.displayName == nil)
            #expect(login.origins == ["https://example.test"] && login.loginURLs == [URL(string: "https://example.test/login")!])
            #expect(login.hasPassword && login.hasTOTP && login.passkeyCount == 1)
            #expect(login.items.map(\.kind) == [.creditCard, .wifi, .customFields, .apiKey, .creditCard])
            #expect(login.items.map(\.cardLastFour) == ["5556", nil, nil, nil, "4444"])
            #expect(login.items.map(\.cardNetwork) == [.visa, nil, nil, nil, .mastercard])
            #expect(login.items.map(\.customTitle) == [nil, nil, "Locker", nil, nil])

            let code = try #require(byID[Entries.codeID])
            #expect(code.usernameIsConcealed && !code.hasPassword && code.hasTOTP && code.passkeyCount == 0 && code.items.isEmpty)

            let contact = try #require(byID[Entries.contactID])
            #expect(contact.username.isEmpty && contact.displayName == "Home" && !contact.hasPassword && !contact.hasTOTP)
            #expect(contact.items.map(\.kind) == [.personName, .address, .customFields])
            #expect(contact.items.allSatisfy { $0.customTitle == nil && $0.cardLastFour == nil && $0.cardNetwork == nil })
        }
    }

    /// Every read, list or pick, refuses exactly as the verified read does: a locked vault and a revoked access are `unauthorized`, a
    /// lease past its deadline `expired`, a vault the access holds no grant on `unauthorized` (the read never reaches the file), and a
    /// row changed on disk `integrityFailure`. Nothing is returned.
    @Test(arguments: Refusal.allCases)
    private func everyReadRefusesWhatTheVerifiedReadRefuses(_ refusal: Refusal) async throws {
        try await VaultStoreFixture.with(accounts: try Entries.all()) { f in
            let clock = ManualClock()
            let store = f.makeStore(now: { clock.now() })
            let access = VaultAccess(profileID: f.env.profileID, epoch: 1, deadline: clock.base.advanced(by: .seconds(300)))
            #expect(await unlockResult(f, store, access: access) == nil)
            let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            var vaultID = f.vaultID
            switch refusal {
            case .locked:
                await store.lock(vaultID: f.vaultID)
            case .revoked:
                access.revoke()
            case .expired:
                clock.advance(by: .seconds(301))
            case .unknownVault:
                vaultID = UUID()
            case .tamperedRow:
                let row = try f.storedRecord(f.vaultID, Entries.contactID)
                try f.mutate { db in
                    try db.execute(
                        sql: "UPDATE record SET sealed = ? WHERE vaultID = ? AND recordID = ?",
                        arguments: [VaultStoreFixture.flipped(row.sealed), f.vaultID.lowerText, Entries.contactID.lowerText]
                    )
                }
            }
            let expected = name(await failure { _ = try await store.snapshot(vaultID: vaultID, using: access) })
            let reads: [(String, () async throws -> Void)] = [
                ("candidates", { _ = try await store.autofillCandidates(vaultID: vaultID, using: access) }),
                ("password", {
                    _ = try await store.autofillLogin(
                        vaultID: vaultID, accountID: Entries.loginID, field: .password, expectedRevision: revision, using: access
                    )
                }),
                ("code", {
                    _ = try await store.autofillLogin(vaultID: vaultID, accountID: Entries.codeID, field: .totp, expectedRevision: revision, using: access)
                }),
                ("cards", { _ = try await store.autofillItems(vaultID: vaultID, kind: .cards, using: access) }),
                ("contacts", { _ = try await store.autofillItems(vaultID: vaultID, kind: .contacts, using: access) }),
                ("card pick", {
                    _ = try await store.autofillItems(
                        vaultID: vaultID, kind: .cards, accountID: Entries.loginID, item: 0, expectedRevision: revision, using: access
                    )
                }),
            ]
            for (label, read) in reads {
                #expect(name(await failure(read)) == expected, "\(label)")
            }
            switch refusal {
            case .locked, .revoked, .unknownVault:
                #expect(expected == name(CredentialVaultError.unauthorized))
            case .expired:
                #expect(expected == name(CredentialVaultError.expired))
            case .tamperedRow:
                #expect(expected.contains("integrityFailure"))
            }
        }
    }

    // MARK: V3 Pick of a login or a code

    @Test func aPasswordPickHoldsItsCandidateAndPasswordAndNoCode() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let list = try await store.autofillCandidates(vaultID: f.vaultID, using: access)
            let login = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.loginID, field: .password, expectedRevision: list.revision, using: access
            )
            #expect(login.candidate == list.candidates.first { $0.id == Entries.loginID })
            let isThePassword = login.password == Sentinel.password
            #expect(isThePassword, "the pick does not hold the credential's password")
            #expect(login.code == nil)

            let noPassword = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.codeID, field: .password, expectedRevision: list.revision, using: access
            )
            #expect(noPassword.password == nil && noPassword.code == nil && noPassword.candidate.username == "grace")
        }
    }

    @Test func aCodePickMakesTheCodeAtDeliveryAndHoldsNoPassword() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            let code = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.codeID, field: .totp, expectedRevision: revision, using: access
            )
            #expect(code.password == nil && code.candidate.id == Entries.codeID)
            #expect(code.code?.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
            #expect(code.code?.code(at: Date(timeIntervalSince1970: 1_111_111_109)) == "07081804")

            let login = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.loginID, field: .totp, expectedRevision: revision, using: access
            )
            #expect(login.password == nil, "a code pick holds the password")
            #expect(login.code != nil)

            let noCode = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.contactID, field: .totp, expectedRevision: revision, using: access
            )
            #expect(noCode.code == nil && noCode.password == nil)
        }
    }

    /// A pick is read at the revision its list was read at: any write since, or a credential that is not there, is `staleRevision`.
    @Test func aPickAfterAWriteOrOfAnUnknownCredentialIsStale() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let listed = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            let unknown = await failure {
                _ = try await store.autofillLogin(
                    vaultID: f.vaultID, accountID: UUID(), field: .password, expectedRevision: listed, using: access
                )
            }
            #expect(name(unknown) == name(CredentialVaultError.staleRevision))

            _ = try await store.updatePasswordSavePolicy(vaultID: f.vaultID, ["https://c.example"], expectedRevision: listed, using: access)
            let current = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            #expect(current != listed)
            for field in [AutofillLoginField.password, .totp] {
                let stale = await failure {
                    _ = try await store.autofillLogin(
                        vaultID: f.vaultID, accountID: Entries.loginID, field: field, expectedRevision: listed, using: access
                    )
                }
                #expect(name(stale) == name(CredentialVaultError.staleRevision))
            }
            let itemsStale = await failure {
                _ = try await store.autofillItems(
                    vaultID: f.vaultID, kind: .cards, accountID: Entries.loginID, item: 0, expectedRevision: listed, using: access
                )
            }
            #expect(name(itemsStale) == name(CredentialVaultError.staleRevision))
            let fresh = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.loginID, field: .password, expectedRevision: current, using: access
            )
            #expect(fresh.password != nil)
        }
    }

    // MARK: V4 Cards and contacts

    @Test func cardRowsHoldNoNumberCodeOrOtherItem() async throws {
        var expired = SecureItemFixtures.card(number: "4242424242424242", code: "5172")
        expired.fields[3].value = "2020-01"
        let invalid = SecureItemFixtures.card(number: "4000056655665557", code: "6390")
        let items = SecureItemFixtures.account([expired, invalid, SecureItemFixtures.address()], name: "Old cards")
        try await withVault(try Entries.all() + [items]) { f, store, access in
            let cards = try await store.autofillItems(vaultID: f.vaultID, kind: .cards, using: access)
            #expect(cards.picked == nil && cards.contacts.isEmpty)
            #expect(cards.cards.map(\.accountID) == [Entries.loginID, Entries.loginID])
            #expect(cards.cards.map(\.item) == [0, 4])
            #expect(cards.cards.map(\.network) == [.visa, .mastercard])
            #expect(cards.cards.map(\.lastFour) == ["5556", "4444"])
            #expect(cards.cards.map(\.cardholder) == ["Ada Lovelace", "Grace Hopper"])
            #expect(cards.cards.allSatisfy { $0.month == 7 && $0.year == 2031 })
            #expect(Mirror(reflecting: cards.cards[0]).children.map(\.label) == [
                "accountID", "item", "network", "lastFour", "cardholder", "month", "year",
            ])
            let leaks = Leak.paths(in: cards, texts: Sentinel.secrets + Sentinel.codes + ["5172", "6390", Sentinel.street])
            #expect(leaks.isEmpty, "a card row holds a secret-carrying value at \(leaks)")
            #expect(!Leak.prints(cards, Sentinel.secrets + [Sentinel.street]), "a card row prints a secret")
        }
    }

    @Test func contactRowsHoldATitleAndADetailOnly() async throws {
        let nameless = SecureItemFixtures.account([SecureItem(kind: .address, fields: [SecureItemFixtures.field("city", "Testville")])], name: nil)
        try await withVault(try Entries.all() + [nameless]) { f, store, access in
            let contacts = try await store.autofillItems(vaultID: f.vaultID, kind: .contacts, using: access)
            #expect(contacts.picked == nil && contacts.cards.isEmpty)
            #expect(contacts.contacts.map(\.accountID) == [Entries.contactID, nameless.id])
            #expect(contacts.contacts.map(\.item) == [0, 0])
            #expect(contacts.contacts.first?.title == "Home")
            #expect(contacts.contacts.first?.detail == "ada@example.test · \(Sentinel.street)")
            #expect(contacts.contacts.last?.title == nil && contacts.contacts.last?.detail == "")
            #expect(Mirror(reflecting: contacts.contacts[0]).children.map(\.label) == ["accountID", "item", "title", "detail"])
            let leaks = Leak.paths(in: contacts, texts: Sentinel.secrets + Sentinel.codes)
            #expect(leaks.isEmpty, "a contact row holds a secret-carrying value at \(leaks)")
            #expect(!Leak.prints(contacts, Sentinel.secrets), "a contact row prints a secret")
            #expect(!Leak.prints(contacts, ["Lovelace", "10000", "+385"]), "a contact row prints a value it does not show")
        }
    }

    /// A card pick holds the picked card's values and nothing of the credential's other card; a contact pick holds the contact.
    @Test func aPickHoldsThatRowsValuesOnly() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let list = try await store.autofillItems(vaultID: f.vaultID, kind: .cards, using: access)
            let second = try #require(list.cards.last)
            let picked = try await store.autofillItems(
                vaultID: f.vaultID, kind: .cards, accountID: second.accountID, item: second.item, expectedRevision: list.revision, using: access
            )
            #expect(picked.cards == [second] && picked.contacts.isEmpty)
            guard case .card(let card)? = picked.picked else {
                Issue.record("a card pick holds no card")
                return
            }
            let isThatCard = card.number == Sentinel.otherCardNumber && card.securityCode == Sentinel.otherCardCode
                && card.cardholder == "Grace Hopper" && card.month == 7 && card.year == 2031
            #expect(isThatCard, "a card pick does not hold the picked card's values")
            #expect(!Leak.prints(picked.cards, [Sentinel.cardNumber, Sentinel.otherCardNumber]))

            let contacts = try await store.autofillItems(vaultID: f.vaultID, kind: .contacts, using: access)
            let row = try #require(contacts.contacts.first)
            let contact = try await store.autofillItems(
                vaultID: f.vaultID, kind: .contacts, accountID: row.accountID, item: row.item, expectedRevision: contacts.revision, using: access
            )
            #expect(contact.contacts == [row] && contact.cards.isEmpty)
            guard case .contact(let values)? = contact.picked else {
                Issue.record("a contact pick holds no contact")
                return
            }
            let expected = try #require(AutofillContactValues(of: Entries.contact()))
            #expect(values == expected, "a contact pick does not hold the contact's values")
        }
    }

    /// A pick names a row its list showed, at the list's revision: another revision, credential or item is `staleRevision`, a card that
    /// is not one or a contact item that is not the row's too, and a pick without an item or a revision is `invalidData`.
    @Test func aPickMustNameARowAtTheListedRevision() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            func pick(_ kind: AutofillItemKind, _ accountID: UUID, item: Int?, revision: UInt64?) async -> String {
                name(await failure {
                    _ = try await store.autofillItems(
                        vaultID: f.vaultID, kind: kind, accountID: accountID, item: item, expectedRevision: revision, using: access
                    )
                })
            }
            let stale = name(CredentialVaultError.staleRevision), invalid = name(CredentialVaultError.invalidData)
            #expect(await pick(.cards, Entries.loginID, item: 0, revision: revision &+ 1) == stale)
            #expect(await pick(.cards, UUID(), item: 0, revision: revision) == stale)
            #expect(await pick(.cards, Entries.loginID, item: 1, revision: revision) == stale)  // a Wi-Fi network
            #expect(await pick(.cards, Entries.loginID, item: 9, revision: revision) == stale)
            #expect(await pick(.contacts, Entries.contactID, item: 1, revision: revision) == stale)
            #expect(await pick(.contacts, Entries.loginID, item: 0, revision: revision) == stale)  // holds no contact
            #expect(await pick(.cards, Entries.loginID, item: nil, revision: revision) == invalid)
            #expect(await pick(.cards, Entries.loginID, item: 0, revision: nil) == invalid)
            #expect(await pick(.cards, Entries.loginID, item: 0, revision: revision) == "none")
        }
    }

    // MARK: The app's rules, now the vault's

    private static let numbers = [
        "4000056655665556", "4242 4242-4242 4242", "4000056655665557", "6200000000000005", "6200000000000001", "378282246310005",
        "2223003122003222", "6011111111111117", "3530111333300000", "4917610000000000003", "4242", "abcd1234efgh", "٤٢٤٢٤٢٤٢٤٢٤٢٤٢٤٢",
        "0000000000000000", "42424242424242424242",
    ]

    /// The card check and the networks are `PaymentCard`'s; the year-month and expiry rules are `VaultItemAutofill`'s and `PaymentCard`'s.
    @Test func theCardCheckAndNetworksAreTheAppsOwn() throws {
        for number in Self.numbers {
            let digits = number.filter { $0 != " " && $0 != "-" }
            #expect(PaymentCardRules.isValidNumber(digits) == PaymentCard.isValidNumber(digits), "card check differs for case \(Self.numbers.firstIndex(of: number) ?? -1)")
            if PaymentCard.isValidNumber(digits) {
                let app = try PaymentCard(number: digits).network
                #expect((CardNetwork(number: digits).map(networkName) ?? String(localized: "Payment card")) == app)
            }
        }
        for text in ["2031-07", "2031-7", "2031", "x-7", "2031-07-15", "", "-", "2031-", "07-2031"] {
            let vault = PaymentCardRules.yearMonth(text), app = VaultItemAutofill.yearMonth(text)
            #expect(vault.year == app.year && vault.month == app.month, "\(text)")
        }
        #expect(PaymentCardRules.yearMonth(nil) == (nil, nil))
        let dates = [Date(timeIntervalSince1970: 1_906_502_400), Date(timeIntervalSince1970: 1_780_000_000), Date(timeIntervalSince1970: 0)]
        for date in dates {
            for (month, year) in [(7, 2031), (6, 2030), (1, 2026), (12, 2025), (nil, 2031), (7, nil)] as [(Int?, Int?)] {
                let app = try PaymentCard(number: "4242424242424242", month: month, year: year).isExpired(on: date)
                #expect(PaymentCardRules.isExpired(month: month, year: year, on: date) == app)
            }
        }
    }

    private static func card(number: String, code: String?, expiry: String?, holder: String?) -> SecureItem {
        var fields = [SecureItemFixtures.field("number", number)]
        if let holder {
            fields.append(SecureItemFixtures.field("fullName", holder))
        }
        if let code {
            fields.append(SecureItemFixtures.field("verificationNumber", code, type: .concealedString))
        }
        if let expiry {
            fields.append(SecureItemFixtures.field("expiryDate", expiry, type: .yearMonth))
        }
        return SecureItem(kind: .creditCard, fields: fields)
    }

    private static func cardItems() -> [SecureItem] {
        let holder = "  " + String(repeating: "A", count: 250) + "  "
        return numbers.map { card(number: $0, code: "123", expiry: "2031-07", holder: "Ada") } + [
            card(number: "4242424242424242", code: "12", expiry: "2031-13", holder: holder),
            card(number: "4242424242424242", code: " 1234 ", expiry: "1999-05", holder: nil),
            card(number: "4242424242424242", code: "12a4", expiry: "2031", holder: "\nAda\t"),
            card(number: "4242424242424242", code: "", expiry: "x-7", holder: ""),
            card(number: "4242424242424242", code: nil, expiry: nil, holder: nil),
            card(number: "4242424242424242", code: "12345", expiry: "2200-01", holder: "Ada"),
            SecureItemFixtures.wifi(), SecureItemFixtures.address(), SecureItem(kind: .creditCard, fields: []),
        ]
    }

    /// A card item fills with what `VaultItemAutofill.paymentCard` read from it: the same number, name, expiry and code, or nothing.
    @Test func aCardFillsAsTheAppReadIt() {
        for (index, item) in Self.cardItems().enumerated() {
            let vault = AutofillCardValues(item), app = VaultItemAutofill.paymentCard(item)
            let same = vault.map { [$0.number, $0.cardholder, $0.securityCode ?? "-", "\($0.month ?? 0)", "\($0.year ?? 0)"] }
                == app.map { [$0.number, $0.cardholder, $0.securityCode ?? "-", "\($0.month ?? 0)", "\($0.year ?? 0)"] }
            #expect(same, "card case \(index) reads differently")
        }
    }

    /// An item's fact names it as `SecureItem.title` does: a card's network and last four digits (a payment card when the number fails
    /// the check), a custom group's own title, else its kind.
    @Test func anItemFactNamesTheItemAsItsTitleDoes() {
        let items = Self.cardItems() + [
            SecureItemFixtures.custom(label: "Locker"), SecureItemFixtures.custom(label: ""), SecureItemFixtures.name(),
            SecureItem(kind: .creditCard, fields: [SecureItemFixtures.field("number", "123")]),
            SecureItem(kind: .passport, fields: [SecureItemFixtures.field("passportNumber", "X1234567")]),
        ]
        for (index, item) in items.enumerated() {
            #expect(title(of: AutofillItemFact(item)) == item.title, "item case \(index) is named differently")
        }
    }

    private static func contactAccounts() -> [CredentialAccount] {
        let long = String(repeating: "x", count: 501)
        let fullName = SecureItem(kind: .personName, fields: [
            SecureItemFixtures.field("given", "Ada"), SecureItemFixtures.field("given2", "Augusta"),
            SecureItemFixtures.field("surnamePrefix", "de"), SecureItemFixtures.field("surname", "Lovelace"),
        ])
        func entry(_ items: [SecureItem], name: String? = "Home") -> CredentialAccount {
            SecureItemFixtures.account(items, name: name)
        }
        return [
            entry([SecureItemFixtures.name(), SecureItemFixtures.address(), Entries.contactFields()]),
            entry([SecureItemFixtures.address()], name: nil),
            entry([SecureItem(kind: .address, fields: [SecureItemFixtures.field("city", "Testville")])], name: nil),
            entry([SecureItem(kind: .address, fields: [SecureItemFixtures.field("country", "Croatia")])]),
            entry([SecureItem(kind: .address, fields: [SecureItemFixtures.field("country", "hr"), SecureItemFixtures.field("city", "Zagreb")])]),
            entry([SecureItem(kind: .address, fields: [SecureItemFixtures.field("streetAddress", long)])]),
            entry([SecureItem(kind: .address, fields: [SecureItemFixtures.field("streetAddress", "1 Way\nFlat 2")])]),
            entry([fullName]),
            entry([Entries.contactFields(organization: "")], name: nil),
            entry([Entries.contactFields(email: "", organization: "")]),
            entry([SecureItemFixtures.custom()]),
            entry([SecureItemFixtures.wifi(), SecureItemFixtures.card()]),
            entry([SecureItem(kind: .address, fields: [SecureItemFixtures.field("city", "   ")])]),
        ]
    }

    /// An entry's contact is what `VaultItemAutofill.contact(of:)` made of it, and a row names it as the panel did.
    @Test func aContactFillsAndIsNamedAsTheAppReadIt() {
        for (index, account) in Self.contactAccounts().enumerated() {
            let vault = AutofillContactValues(of: account), app = VaultItemAutofill.contact(of: account)
            let values = vault.map {
                [$0.label, $0.givenName, $0.familyName, $0.organization, $0.email, $0.phone, $0.street, $0.city, $0.region, $0.postalCode, $0.countryCode]
            }
            let appValues = app.map {
                [$0.label, $0.givenName, $0.familyName, $0.organization, $0.email, $0.phone, $0.street, $0.city, $0.region, $0.postalCode, $0.countryCode]
            }
            #expect(values == appValues, "contact case \(index) reads differently")
            if let vault, let app {
                #expect((vault.title ?? String(localized: "Contact")) == app.title, "contact case \(index) is named differently")
                #expect(vault.detail == AutofillSuggestion(.contact(app)).detail, "contact case \(index) has another detail")
            }
        }
    }

    /// The rows list what the panel listed from whole entries (`VaultItemAutofill.cards` and `contacts`), in order, with the same text.
    @Test func rowsListWhatTheAppListedFromWholeEntries() async throws {
        var expired = SecureItemFixtures.card(number: "4242424242424242")
        expired.fields[3].value = "2020-01"
        let mixed = SecureItemFixtures.account([SecureItemFixtures.wifi(), expired, SecureItemFixtures.card(number: "378282246310005"), SecureItemFixtures.address()])
        let accounts = try Entries.all() + Self.contactAccounts() + [mixed]
        try await withVault(accounts) { f, store, access in
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            let cards = try await store.autofillItems(vaultID: f.vaultID, kind: .cards, using: access).cards
            let appCards = VaultItemAutofill.cards(in: snapshot.accounts, now: .now)
            #expect(cards.map { "\($0.accountID)/\($0.item)" } == appCards.map { "\($0.accountID)/\($0.item)" })
            for (row, offer) in zip(cards, appCards) {
                let shown = AutofillSuggestion(.card(offer.value))
                let title = "\(row.network.map(networkName) ?? String(localized: "Payment card")) •••• \(row.lastFour)"
                #expect(title == shown.title && row.cardholder == shown.detail && row.month == shown.month && row.year == shown.year)
            }
            let contacts = try await store.autofillItems(vaultID: f.vaultID, kind: .contacts, using: access).contacts
            let appContacts = VaultItemAutofill.contacts(in: snapshot.accounts)
            #expect(contacts.map { "\($0.accountID)/\($0.item)" } == appContacts.map { "\($0.accountID)/\($0.item)" })
            for (row, offer) in zip(contacts, appContacts) {
                let shown = AutofillSuggestion(.contact(offer.value))
                #expect((row.title ?? String(localized: "Contact")) == shown.title && row.detail == shown.detail)
            }
        }
    }
}
