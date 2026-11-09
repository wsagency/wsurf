// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Synchronization
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

    /// The calendar date the stores here date a card's expiry by: mid-June 2030 in every time zone, before the fixtures' cards end
    /// (2031-07), so no check depends on the day it runs.
    static let today = Date(timeIntervalSince1970: 1_907_755_200)

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
            || value is AutofillCardValues || value is AutofillContactValues || value is AutofillItemPick
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
    case locked, revoked, expired, unknownVault, tamperedRow, tamperedHead
}

/// A store's clock that, once armed, counts the store's reads of it and revokes the access it was armed with at the third, as
/// `CredentialManager.lock` revokes an access at once and locks the store after. The verified read, and a pick's read of its own row
/// (`pickedAccount`), read the clock twice (a check before the operation lock and one under it), so the third read is the check a
/// method makes after the read. The instant it returns is always inside the access's deadline, so a refusal here is the revocation's,
/// never the deadline's.
private nonisolated final class ArmedClock: Sendable {
    private let state = Mutex<(access: VaultAccess?, reads: Int)>((nil, 0))

    func now() -> ContinuousClock.Instant {
        let revoking = state.withLock { state -> VaultAccess? in
            guard let access = state.access else { return nil }
            state.reads += 1
            return state.reads == 3 ? access : nil
        }
        revoking?.revoke()
        return ContinuousClock().now
    }

    /// Counts the store's reads from zero; the third revokes `access`. Armed only after the unlock, which reads the clock while it
    /// holds the access's lock.
    func arm(revoking access: VaultAccess) {
        state.withLock { $0 = (access, 0) }
    }

    /// The store's reads of the clock since `arm`.
    var reads: Int {
        state.withLock { $0.reads }
    }
}

/// One read the re-check test makes with an armed clock: the store, the vault, the access and the revision its list was read at.
private typealias ArmedRead = (ProfileVaultStore, UUID, VaultAccess, UInt64) async throws -> Void

/// A calendar clock a test moves: the store dates a card's expiry by it.
private nonisolated final class MovableWall: Sendable {
    private let current: Mutex<Date>

    init(_ date: Date) {
        current = Mutex(date)
    }

    func now() -> Date {
        current.withLock { $0 }
    }

    func move(to date: Date) {
        current.withLock { $0 = date }
    }
}

struct VaultAutofillReadTests {
    private static let candidateFields = [
        "id", "username", "usernameIsConcealed", "displayName", "origins", "loginURLs", "hasPassword", "hasTOTP", "passkeyCount", "items",
    ]
    private static let factFields = ["kind", "customTitle", "cardLastFour", "cardNetwork"]

    private func withVault(
        _ accounts: [CredentialAccount], blockedOrigins: [String] = [],
        _ body: (VaultStoreFixture, ProfileVaultStore, VaultAccess) async throws -> Void
    ) async throws {
        try await VaultStoreFixture.with(accounts: accounts, blockedOrigins: blockedOrigins) { f in
            let (store, access) = try await f.unlocked(wall: { Entries.today })
            try await body(f, store, access)
        }
    }

    // MARK: V1 Shape

    @Test func aCandidateHoldsIdentityFlagsAndItemNamesOnly() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let candidates = try await store.autofillCandidates(vaultID: f.vaultID, using: access)
            #expect(Mirror(reflecting: candidates).children.map(\.label) == ["vaultID", "revision", "candidates", "blockedPasswordOrigins"])
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
            var isACardAndAContact = false
            if case (.card, .contact) = (card, contact) {
                isACardAndAContact = true
            }
            let holdsEach = login.password != nil && code.code != nil && isACardAndAContact
            #expect(holdsEach, "a pick holds no value, or another kind's")

            let loginRedacted = "\(login)" == "AutofillLogin" && String(reflecting: login) == "AutofillLogin"
                && Mirror(reflecting: login).children.map(\.label) == ["candidate"]
            #expect(loginRedacted, "a password pick prints or mirrors a field")
            let passwordPrinted = Leak.prints(login, [Sentinel.password])
            #expect(!passwordPrinted, "a password pick prints its password")
            let codeSource = try #require(code.code)
            let sourceRedacted = "\(codeSource)" == "TOTPCodeSource" && Mirror(reflecting: codeSource).children.isEmpty
            #expect(sourceRedacted, "a code source prints or mirrors its seed")
            let seedMirrored = !Leak.paths(in: code, texts: []).isEmpty
            #expect(!seedMirrored, "a code pick mirrors its seed")

            let picksRedacted = [card, contact].allSatisfy { pick in
                Mirror(reflecting: pick).children.isEmpty && "\(pick)" == "AutofillItemPick" && String(reflecting: pick) == "AutofillItemPick"
            }
            #expect(picksRedacted, "a card or contact pick prints or mirrors a field")
            if case .card(_, let values) = card {
                let cardRedacted = Mirror(reflecting: values).children.isEmpty && "\(values)" == "AutofillCardValues"
                #expect(cardRedacted, "a card's values print or mirror a field")
            }
            if case .contact(_, let values) = contact {
                let contactRedacted = Mirror(reflecting: values).children.isEmpty && "\(values)" == "AutofillContactValues"
                #expect(contactRedacted, "a contact's values print or mirror a field")
            }
            let numberPrinted = Leak.prints(card, [Sentinel.cardNumber])
            #expect(!numberPrinted, "a card pick prints its number")
            // The name, city and phone exist only in the values, which never print.
            let valuePrinted = Leak.prints(contact, ["Lovelace", "Testville", "+385"])
            #expect(!valuePrinted, "a contact pick prints a value its row does not show")
            let codeHidden = Leak.textPaths(in: card, texts: Sentinel.codes).isEmpty
            #expect(codeHidden, "a card pick mirrors its security code")
        }
    }

    // MARK: V2 Candidates

    @Test func candidatesAreTheVerifiedReadProjected() async throws {
        try await withVault(try Entries.all(), blockedOrigins: ["https://never.example.test"]) { f, store, access in
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            let read = try await store.autofillCandidates(vaultID: f.vaultID, using: access)
            #expect(read.vaultID == f.vaultID && read.revision == snapshot.revision)
            #expect(read.candidates.map(\.id) == snapshot.accounts.map(\.id))
            // An offer to add a website reads the excluded websites here, not from the whole vault.
            #expect(read.blockedPasswordOrigins == ["https://never.example.test"] && snapshot.blockedPasswordOrigins == read.blockedPasswordOrigins)

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
    /// head changed on disk `integrityFailure`. Nothing is returned. A row changed on disk (the contact's) is `integrityFailure` for
    /// every read that reads it: the verified read, the three lists and that row's own pick. A pick of another row reads only its own
    /// row (D5 PR-6) and still returns, and the next list refuses the change. That the lists stay full reads is what bounds the
    /// single-row pick's trade-off, and this case pins it. The tamper cases of the pick are in `VaultPickReadTests`.
    @Test(arguments: Refusal.allCases)
    private func everyReadRefusesWhatTheVerifiedReadRefuses(_ refusal: Refusal) async throws {
        try await VaultStoreFixture.with(accounts: try Entries.all()) { f in
            let clock = ManualClock()
            let store = f.makeStore(now: { clock.now() }, wall: { Entries.today })
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
            case .tamperedHead:
                try f.mutate { db in
                    guard let stored = try StoreTables.head(db, vaultID: f.vaultID) else { throw CredentialStoreError.malformed }
                    try StoreTables.putHead(db, vaultID: f.vaultID, revision: stored.revision, sealed: VaultStoreFixture.flipped(stored.sealed))
                }
            }
            let expected = name(await failure { _ = try await store.snapshot(vaultID: vaultID, using: access) })
            // Each read with whether it reads the contact's row: the lists and the password health report read every row, a pick
            // its own row only.
            let reads: [(String, Bool, () async throws -> Void)] = [
                ("candidates", true, { _ = try await store.autofillCandidates(vaultID: vaultID, using: access) }),
                ("password health", true, { _ = try await store.passwordHealth(vaultID: vaultID, expectedRevision: revision, using: access) }),
                ("password", false, {
                    _ = try await store.autofillLogin(
                        vaultID: vaultID, accountID: Entries.loginID, field: .password, expectedRevision: revision, using: access
                    )
                }),
                ("code", false, {
                    _ = try await store.autofillLogin(vaultID: vaultID, accountID: Entries.codeID, field: .totp, expectedRevision: revision, using: access)
                }),
                ("cards", true, { _ = try await store.autofillItems(vaultID: vaultID, kind: .cards, using: access) }),
                ("contacts", true, { _ = try await store.autofillItems(vaultID: vaultID, kind: .contacts, using: access) }),
                ("card pick", false, {
                    _ = try await store.autofillItems(
                        vaultID: vaultID, kind: .cards, accountID: Entries.loginID, item: 0, expectedRevision: revision, using: access
                    )
                }),
                ("contact pick", true, {
                    _ = try await store.autofillItems(
                        vaultID: vaultID, kind: .contacts, accountID: Entries.contactID, item: 0, expectedRevision: revision, using: access
                    )
                }),
            ]
            for (label, readsTheContactRow, read) in reads {
                let outcome = name(await failure(read))
                if refusal == .tamperedRow, !readsTheContactRow {
                    #expect(outcome == "none", "\(label) read another row than its own")
                } else {
                    #expect(outcome == expected, "\(label)")
                }
            }
            switch refusal {
            case .locked, .revoked, .unknownVault:
                #expect(expected == name(CredentialVaultError.unauthorized))
            case .expired:
                #expect(expected == name(CredentialVaultError.expired))
            case .tamperedRow, .tamperedHead:
                #expect(expected.contains("integrityFailure"))
            }
        }
    }

    /// A lock that lands while a read runs leaves that read with nothing. `CredentialManager.lock` revokes the access at once and
    /// locks the store after, so each method checks the grant once more after the verified read and its projection, right before it
    /// returns. Here the store's clock revokes the access at its third read, after the two the verified read makes: the verified read
    /// alone still returns, and every autofill read, list or pick, is `unauthorized` at exactly that third read.
    @Test func aRevocationDuringTheReadLeavesTheReadWithNothing() async throws {
        let reads: [(String, ArmedRead)] = [
            ("candidates", { store, vaultID, access, _ in _ = try await store.autofillCandidates(vaultID: vaultID, using: access) }),
            ("password health", { store, vaultID, access, revision in
                _ = try await store.passwordHealth(vaultID: vaultID, expectedRevision: revision, using: access)
            }),
            ("password", { store, vaultID, access, revision in
                _ = try await store.autofillLogin(
                    vaultID: vaultID, accountID: Entries.loginID, field: .password, expectedRevision: revision, using: access
                )
            }),
            ("code", { store, vaultID, access, revision in
                _ = try await store.autofillLogin(
                    vaultID: vaultID, accountID: Entries.codeID, field: .totp, expectedRevision: revision, using: access
                )
            }),
            ("cards", { store, vaultID, access, _ in _ = try await store.autofillItems(vaultID: vaultID, kind: .cards, using: access) }),
            ("contacts", { store, vaultID, access, _ in _ = try await store.autofillItems(vaultID: vaultID, kind: .contacts, using: access) }),
            ("card pick", { store, vaultID, access, revision in
                _ = try await store.autofillItems(
                    vaultID: vaultID, kind: .cards, accountID: Entries.loginID, item: 0, expectedRevision: revision, using: access
                )
            }),
            ("contact pick", { store, vaultID, access, revision in
                _ = try await store.autofillItems(
                    vaultID: vaultID, kind: .contacts, accountID: Entries.contactID, item: 0, expectedRevision: revision, using: access
                )
            }),
        ]
        try await VaultStoreFixture.with(accounts: try Entries.all()) { f in
            let control = try await armed(f) { store, vaultID, access, _ in _ = try await store.snapshot(vaultID: vaultID, using: access) }
            #expect(control.outcome == "none", "the verified read is refused before the third read of the clock")
            #expect(control.reads == 2, "the verified read no longer reads the clock exactly twice")
            for (label, read) in reads {
                let result = try await armed(f, read)
                #expect(result.outcome == name(CredentialVaultError.unauthorized), "\(label)")
                #expect(result.reads == 3, "\(label)")
            }
        }
    }

    /// `read` on a store of its own, unlocked and listed before the clock is armed (a revocation sticks to its access): what it threw,
    /// and the clock's reads since arming.
    private func armed(_ f: VaultStoreFixture, _ read: ArmedRead) async throws -> (outcome: String, reads: Int) {
        let clock = ArmedClock()
        let store = f.makeStore(now: { clock.now() }, wall: { Entries.today })
        let access = f.beginAccess()
        #expect(await unlockResult(f, store, access: access) == nil)
        let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
        clock.arm(revoking: access)
        var outcome = "none"
        do {
            try await read(store, f.vaultID, access, revision)
        } catch {
            outcome = name(error)
        }
        let reads = clock.reads
        await store.lock(vaultID: f.vaultID)
        return (outcome, reads)
    }

    // MARK: V3 Pick of a login or a code

    @Test func aPasswordPickHoldsItsCandidateAndPasswordAndNoCode() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let list = try await store.autofillCandidates(vaultID: f.vaultID, using: access)
            let login = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.loginID, field: .password, expectedRevision: list.revision, using: access
            )
            let sameCandidate = login.candidate == list.candidates.first { $0.id == Entries.loginID }
            #expect(sameCandidate, "a password pick holds another candidate")
            let isThePassword = login.password == Sentinel.password
            #expect(isThePassword, "the pick does not hold the credential's password")
            let holdsNoCode = login.code == nil
            #expect(holdsNoCode, "a password pick holds a code source")

            let noPassword = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.codeID, field: .password, expectedRevision: list.revision, using: access
            )
            let holdsNothing = noPassword.password == nil && noPassword.code == nil && noPassword.candidate.username == "grace"
            #expect(holdsNothing, "a password pick of a credential without one holds a value")
        }
    }

    @Test func aCodePickMakesTheCodeAtDeliveryAndHoldsNoPassword() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            let code = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.codeID, field: .totp, expectedRevision: revision, using: access
            )
            let holdsNoPassword = code.password == nil && code.candidate.id == Entries.codeID
            #expect(holdsNoPassword, "a code pick holds a password")
            let makesTheRFCCodes = code.code?.code(at: Date(timeIntervalSince1970: 59)) == "94287082"
                && code.code?.code(at: Date(timeIntervalSince1970: 1_111_111_109)) == "07081804"
            #expect(makesTheRFCCodes, "a code pick does not make RFC 6238's codes")

            let login = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.loginID, field: .totp, expectedRevision: revision, using: access
            )
            let codeOnly = login.password == nil && login.code != nil
            #expect(codeOnly, "a code pick holds the password, or no code source")

            let noCode = try await store.autofillLogin(
                vaultID: f.vaultID, accountID: Entries.contactID, field: .totp, expectedRevision: revision, using: access
            )
            let holdsNothing = noCode.code == nil && noCode.password == nil
            #expect(holdsNothing, "a code pick of a credential without a code holds a value")
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
            let freshHolds = fresh.password != nil
            #expect(freshHolds, "a pick at the current revision holds no password")
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
            // A list's type has no field a value could reach (owner decision Q3): its rows and the revision they were read at.
            #expect(Mirror(reflecting: cards).children.map(\.label) == ["vaultID", "revision", "cards", "contacts"])
            #expect(cards.contacts.isEmpty, "a card list holds contacts")
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
            let printed = Leak.prints(cards, Sentinel.secrets + [Sentinel.street])
            #expect(!printed, "a card row prints a secret")
        }
    }

    @Test func contactRowsHoldATitleAndADetailOnly() async throws {
        let nameless = SecureItemFixtures.account([SecureItem(kind: .address, fields: [SecureItemFixtures.field("city", "Testville")])], name: nil)
        try await withVault(try Entries.all() + [nameless]) { f, store, access in
            let contacts = try await store.autofillItems(vaultID: f.vaultID, kind: .contacts, using: access)
            #expect(contacts.cards.isEmpty, "a contact list holds cards")
            #expect(contacts.contacts.map(\.accountID) == [Entries.contactID, nameless.id])
            #expect(contacts.contacts.map(\.item) == [0, 0])
            #expect(contacts.contacts.first?.title == "Home")
            let detailed = contacts.contacts.first?.detail == "ada@example.test · \(Sentinel.street)"
            #expect(detailed, "a contact row's detail is not its email and street")
            #expect(contacts.contacts.last?.title == nil && contacts.contacts.last?.detail == "")
            #expect(Mirror(reflecting: contacts.contacts[0]).children.map(\.label) == ["accountID", "item", "title", "detail"])
            let leaks = Leak.paths(in: contacts, texts: Sentinel.secrets + Sentinel.codes)
            #expect(leaks.isEmpty, "a contact row holds a secret-carrying value at \(leaks)")
            let printed = Leak.prints(contacts, Sentinel.secrets)
            #expect(!printed, "a contact row prints a secret")
            let unshownPrinted = Leak.prints(contacts, ["Lovelace", "10000", "+385"])
            #expect(!unshownPrinted, "a contact row prints a value it does not show")
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
            guard case .card(let pickedRow, let card) = picked else {
                Issue.record("a card pick holds no card")
                return
            }
            let thatRow = pickedRow == second
            #expect(thatRow, "a card pick holds another row")
            let isThatCard = card.number == Sentinel.otherCardNumber && card.securityCode == Sentinel.otherCardCode
                && card.cardholder == "Grace Hopper" && card.month == 7 && card.year == 2031
            #expect(isThatCard, "a card pick does not hold the picked card's values")
            let numberPrinted = Leak.prints(pickedRow, [Sentinel.cardNumber, Sentinel.otherCardNumber])
            #expect(!numberPrinted, "a card pick's row prints a number")

            let contacts = try await store.autofillItems(vaultID: f.vaultID, kind: .contacts, using: access)
            let row = try #require(contacts.contacts.first)
            let contact = try await store.autofillItems(
                vaultID: f.vaultID, kind: .contacts, accountID: row.accountID, item: row.item, expectedRevision: contacts.revision, using: access
            )
            guard case .contact(let pickedContactRow, let values) = contact else {
                Issue.record("a contact pick holds no contact")
                return
            }
            let thatContactRow = pickedContactRow == row
            #expect(thatContactRow, "a contact pick holds another row")
            let isThatContact = AutofillContactValues(of: Entries.contact()) == values
            #expect(isThatContact, "a contact pick does not hold the contact's values")
        }
    }

    /// A pick names a row its list showed, at the list's revision: another revision, credential or item is `staleRevision`, and so is a
    /// card that is not one or a contact item that is not the row's. A pick without an item or a revision cannot be written (Q3).
    @Test func aPickMustNameARowAtTheListedRevision() async throws {
        try await withVault(try Entries.all()) { f, store, access in
            let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            func pick(_ kind: AutofillItemKind, _ accountID: UUID, item: Int, revision: UInt64) async -> String {
                name(await failure {
                    _ = try await store.autofillItems(
                        vaultID: f.vaultID, kind: kind, accountID: accountID, item: item, expectedRevision: revision, using: access
                    )
                })
            }
            let stale = name(CredentialVaultError.staleRevision)
            #expect(await pick(.cards, Entries.loginID, item: 0, revision: revision &+ 1) == stale)
            #expect(await pick(.cards, UUID(), item: 0, revision: revision) == stale)
            #expect(await pick(.cards, Entries.loginID, item: 1, revision: revision) == stale)  // a Wi-Fi network
            #expect(await pick(.cards, Entries.loginID, item: 9, revision: revision) == stale)
            #expect(await pick(.contacts, Entries.contactID, item: 1, revision: revision) == stale)
            #expect(await pick(.contacts, Entries.loginID, item: 0, revision: revision) == stale)  // holds no contact
            #expect(await pick(.cards, Entries.loginID, item: 0, revision: revision) == "none")
        }
    }

    /// A card is listed through the month it ends and not after, by the store's calendar clock (moved here by the test). A pick of a
    /// card that has ended since its list is `staleRevision`, as a row that is no longer there is, though nothing was written.
    @Test func aCardThatEndsAfterItsListIsStale() async throws {
        var lastMonth = SecureItemFixtures.card(number: "5112345678901235")
        lastMonth.fields[3].value = "2031-06"
        let cards = SecureItemFixtures.account([SecureItemFixtures.card(), lastMonth], name: "Cards")
        let wall = MovableWall(Date(timeIntervalSince1970: 1_941_883_200))  // mid-July 2031: the first card ends this month
        try await VaultStoreFixture.with(accounts: [cards]) { f in
            let (store, access) = try await f.unlocked(wall: { wall.now() })
            let july = try await store.autofillItems(vaultID: f.vaultID, kind: .cards, using: access)
            #expect(july.cards.map(\.item) == [0])
            let picked = try await store.autofillItems(
                vaultID: f.vaultID, kind: .cards, accountID: cards.id, item: 0, expectedRevision: july.revision, using: access
            )
            var sameRow = false
            if case .card(let row, _) = picked {
                sameRow = [row] == july.cards
            }
            #expect(sameRow, "a pick of a card that ends this month holds another row")

            wall.move(to: Date(timeIntervalSince1970: 1_944_561_600))  // mid-August 2031
            let stale = await failure {
                _ = try await store.autofillItems(
                    vaultID: f.vaultID, kind: .cards, accountID: cards.id, item: 0, expectedRevision: july.revision, using: access
                )
            }
            #expect(name(stale) == name(CredentialVaultError.staleRevision))
            let august = try await store.autofillItems(vaultID: f.vaultID, kind: .cards, using: access)
            #expect(august.revision == july.revision && august.cards.isEmpty)
        }
    }

    // MARK: The app's rules, now the vault's

    /// Numbers that pass the card check at the edges of the network prefixes (Mastercard 51-55 and 2221-2720, American Express 34,
    /// Discover 65), and just outside them, where no network is named.
    private static let networkEdges: [(number: String, network: CardNetwork?)] = [
        ("5112345678901235", .mastercard), ("5212345678901234", .mastercard), ("5312345678901233", .mastercard),
        ("5412345678901232", .mastercard), ("5512345678901231", .mastercard), ("341234567890127", .americanExpress),
        ("6512345678901239", .discover), ("2221123456789014", .mastercard), ("2720123456789010", .mastercard),
        ("2220123456789015", nil), ("2721123456789019", nil), ("5012345678901236", nil), ("5612345678901230", nil),
    ]

    private static let numbers = [
        "4000056655665556", "4242 4242-4242 4242", "4000056655665557", "6200000000000005", "6200000000000001", "378282246310005",
        "2223003122003222", "6011111111111117", "3530111333300000", "4917610000000000003", "4242", "abcd1234efgh", "٤٢٤٢٤٢٤٢٤٢٤٢٤٢٤٢",
        "0000000000000000", "42424242424242424242",
    ] + networkEdges.map(\.number)

    /// The card check and the networks are `PaymentCard`'s; the year-month and expiry rules are `VaultItemAutofill`'s and `PaymentCard`'s.
    @Test func theCardCheckAndNetworksAreTheAppsOwn() throws {
        for (index, edge) in Self.networkEdges.enumerated() {
            let named = PaymentCardRules.isValidNumber(edge.number) && CardNetwork(number: edge.number) == edge.network
            #expect(named, "network edge \(index) fails the card check or names another network")
        }
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

    /// Longer than 200 characters, with a space as its 200th (#76 N5): a name cut there ends in that space until it is trimmed again.
    private static let holderCutInASpace = String(repeating: "A", count: 199) + " Byron"

    private static func cardItems() -> [SecureItem] {
        let holder = "  " + String(repeating: "A", count: 250) + "  "
        return numbers.map { card(number: $0, code: "123", expiry: "2031-07", holder: "Ada") } + [
            card(number: "4242424242424242", code: "12", expiry: "2031-13", holder: holder),
            card(number: "4242424242424242", code: "123", expiry: "2031-07", holder: holderCutInASpace),
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

    /// The name on a card that is cut inside a space (#76 N5) shows in its row as its pick fills it: the cut, trimmed. Reading the name
    /// again changes nothing.
    @Test func aCardholderCutInASpaceShowsAsItFills() throws {
        let cut = String(repeating: "A", count: 199)
        let item = Self.card(number: "4242424242424242", code: nil, expiry: nil, holder: Self.holderCutInASpace)
        let values = try #require(AutofillCardValues(item))
        let row = AutofillCardRow(accountID: UUID(), item: 0, values)
        let filled = try #require(VaultItemAutofill.paymentCard(values))
        let names = [PaymentCardRules.cardholder(Self.holderCutInASpace), values.cardholder, row.cardholder, filled.cardholder]
        let readTheCut = names.allSatisfy { $0 == cut }
        #expect(readTheCut, "the row or the fill keeps the space the cut ends in")
        for name in [Self.holderCutInASpace, "  Ada  ", "\nAda\t", "", "  ", String(repeating: "B", count: 250), cut + " \u{00A0}"] {
            let once = PaymentCardRules.cardholder(name)
            let isStable = PaymentCardRules.cardholder(once) == once && once.count <= 200
            #expect(isStable, "a name of \(name.count) characters changes when it is read again")
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
            let named = title(of: AutofillItemFact(item)) == item.title
            #expect(named, "item case \(index) is named differently")
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
            let same = values == appValues
            #expect(same, "contact case \(index) reads differently")
            if let vault, let app {
                let named = (vault.title ?? String(localized: "Contact")) == app.title
                #expect(named, "contact case \(index) is named differently")
                let detailed = vault.rowDetail == AutofillSuggestion(.contact(app)).detail
                #expect(detailed, "contact case \(index) has another row detail")
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
            let appCards = VaultItemAutofill.cards(in: snapshot.accounts, now: Entries.today)
            #expect(cards.map { "\($0.accountID)/\($0.item)" } == appCards.map { "\($0.accountID)/\($0.item)" })
            for (index, (row, offer)) in zip(cards, appCards).enumerated() {
                let shown = AutofillSuggestion(.card(offer.value))
                let title = "\(row.network.map(networkName) ?? String(localized: "Payment card")) •••• \(row.lastFour)"
                let same = title == shown.title && row.cardholder == shown.detail && row.month == shown.month && row.year == shown.year
                #expect(same, "card row \(index) shows other text")
            }
            let contacts = try await store.autofillItems(vaultID: f.vaultID, kind: .contacts, using: access).contacts
            let appContacts = VaultItemAutofill.contacts(in: snapshot.accounts)
            #expect(contacts.map { "\($0.accountID)/\($0.item)" } == appContacts.map { "\($0.accountID)/\($0.item)" })
            for (index, (row, offer)) in zip(contacts, appContacts).enumerated() {
                let shown = AutofillSuggestion(.contact(offer.value))
                let same = (row.title ?? String(localized: "Contact")) == shown.title && row.detail == shown.detail
                #expect(same, "contact row \(index) shows other text")
            }
        }
    }
}
