// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// The fill dropdown's order (`CredentialAccountSelection.listed`, the list `AutofillSuggestions` shows): a username the person typed
/// exactly first, then the credential last used on the page's website, then every other credential saved for that website in the order
/// it always had, and nothing else. Synthetic credentials and vault keys; the record is a fresh profile's file in the per-process test
/// directory.
@MainActor
struct AutofillLastUsedTests {
    private static let site = "https://login.example.test"
    private static let other = "https://shop.elsewhere.test"
    private let vault = UUID()
    /// The vault's key for its uses, as an unlocked vault derives it (`ImportMemoryKey`).
    private let key = ImportMemoryKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: UUID())

    private func account(_ username: String, origins: [String] = [Self.site]) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: origins, loginURLs: [], password: "dummy-\(username)", passkeys: [],
            totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func store() -> AutofillLastUsed {
        AutofillLastUsed(file: Profile(id: UUID(), name: "Last used", symbol: "key", color: .blue).autofillLastUsedFile)
    }

    private func date(_ minute: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + minute * 60)
    }

    /// The dropdown's list for one vault's `accounts` on `origin`, as account ids.
    private func list(
        _ accounts: [CredentialAccount], on origin: String = Self.site, entered: String? = nil, store: AutofillLastUsed
    ) -> [UUID] {
        CredentialAccountSelection.listed(
            in: [(id: vault, label: nil, accounts: accounts)], origin: origin, pageURL: nil, entered: entered, field: .password
        ) { _, account in store.date(key, account: account, origin: origin) }.map(\.account)
    }

    @Test func ofSeveralCredentialsForOneWebsiteTheLastUsedIsFirst() {
        let ada = account("ada"), bob = account("bob"), cy = account("cy")
        let lastUsed = store()
        #expect(list([cy, bob, ada], store: lastUsed) == [ada.id, bob.id, cy.id], "never used: the order it always had")

        lastUsed.record(key, account: cy.id, origin: Self.site, at: date(1))
        #expect(list([cy, bob, ada], store: lastUsed) == [cy.id, ada.id, bob.id])

        lastUsed.record(key, account: bob.id, origin: Self.site, at: date(2))
        #expect(list([cy, bob, ada], store: lastUsed) == [bob.id, ada.id, cy.id], "the rest keep their order")

        // Several vaults: their rows in vault order, each naming its vault, and the one used last, in whichever vault, leads.
        let second = UUID(), secondKey = ImportMemoryKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: second)
        let dee = account("dee")
        lastUsed.record(secondKey, account: dee.id, origin: Self.site, at: date(3))
        let rows = CredentialAccountSelection.listed(
            in: [(id: vault, label: "Home", accounts: [ada, bob]), (id: second, label: "Work", accounts: [dee])],
            origin: Self.site, pageURL: nil, entered: nil, field: .password
        ) { vault, account in lastUsed.date(vault == second ? secondKey : key, account: account, origin: Self.site) }
        #expect(rows.map(\.account) == [dee.id, ada.id, bob.id], "one row moves up; the others keep their order")
        #expect(rows.map(\.vault) == [second, vault, vault] && rows.map(\.detail) == ["Work", "Home", "Home"])
    }

    @Test func aCredentialUsedOnAnotherWebsiteDoesNotJumpTheQueue() {
        let ada = account("ada"), bob = account("bob"), mia = account("mia", origins: [Self.site, Self.other])
        let lastUsed = store()
        lastUsed.record(key, account: bob.id, origin: Self.site, at: date(1))
        lastUsed.record(key, account: mia.id, origin: Self.other, at: date(2))

        #expect(list([mia, ada, bob], store: lastUsed) == [bob.id, ada.id, mia.id])
        #expect(list([mia, ada, bob], on: Self.other, store: lastUsed) == [mia.id], "on the other website only its own credential")
    }

    @Test func everyMatchIsShownAndNoOtherCredentialEver() {
        let here = (0..<7).map { account("user\($0)") }
        let elsewhere = account("away", origins: [Self.other]), sibling = account("near", origins: ["https://www.example.test"])
        // Used here once, then this website was taken off it: a record never brings it back.
        var moved = account("moved")
        let lastUsed = store()
        lastUsed.record(key, account: here[4].id, origin: Self.site, at: date(1))
        lastUsed.record(key, account: elsewhere.id, origin: Self.other, at: date(2))
        lastUsed.record(key, account: moved.id, origin: Self.site, at: date(3))
        moved.origins = [Self.other]

        let ids = list(here.reversed() + [elsewhere, sibling, moved], store: lastUsed)
        #expect(ids == [here[4].id] + here.map(\.id).filter { $0 != here[4].id })
        #expect(Set(ids).isDisjoint(with: [elsewhere.id, sibling.id, moved.id]))
    }

    /// What the person typed exactly is what they meant: it stays first, and the keyboard's first choice fills it. Typing that names no
    /// account exactly, or nothing typed, leaves the one used last in the lead.
    @Test func aUsernameTypedExactlyStaysFirst() {
        let ada = account("ada"), adam = account("adam"), bob = account("bob")
        let lastUsed = store()
        lastUsed.record(key, account: adam.id, origin: Self.site, at: date(1))

        #expect(list([bob, adam, ada], entered: "ada", store: lastUsed) == [ada.id, adam.id])
        #expect(list([bob, adam, ada], entered: "ad", store: lastUsed) == [adam.id, ada.id])
        #expect(list([bob, adam, ada], entered: "", store: lastUsed) == [adam.id, ada.id, bob.id])
        #expect(list([bob, adam, ada], store: lastUsed) == [adam.id, ada.id, bob.id])

        // Typed exactly in the second vault, it still leads the first vault's rows.
        let adamo = account("adamo"), second = UUID()
        let rows = CredentialAccountSelection.listed(
            in: [(id: vault, label: nil, accounts: [adamo, adam]), (id: second, label: nil, accounts: [ada])],
            origin: Self.site, pageURL: nil, entered: "ada", field: .password
        ) { vault, account in vault == second ? nil : lastUsed.date(key, account: account, origin: Self.site) }
        #expect(rows.map(\.account) == [ada.id, adam.id, adamo.id])
    }

    /// Nothing fills without a choice: Return alone still goes to the page. The keyboard's first choice, Down then Return, is the
    /// credential used last here, or the one typed exactly.
    @Test func theKeyboardsFirstChoiceIsTheLastUsed() {
        let ada = account("ada"), adam = account("adam")
        let lastUsed = store()
        lastUsed.record(key, account: adam.id, origin: Self.site, at: date(1))
        func firstChoice(entered: String?) -> AutofillSuggestionSearch.Effect {
            let ids = list([ada, adam], entered: entered, store: lastUsed)
            let rows = ids.map { AutofillSuggestion(id: $0, title: "", detail: "", origin: Self.site) }
            let index = AutofillSuggestionSearch.Index(rows, searchable: true)
            let start = AutofillSuggestionSearch.State(rowCount: rows.count)
            #expect(AutofillSuggestionSearch.reduce(start, .enter, index: index, typeToSearch: false).1 == .dismissAndPass)
            let down = AutofillSuggestionSearch.reduce(start, .down, index: index, typeToSearch: false).0
            return AutofillSuggestionSearch.reduce(down, .enter, index: index, typeToSearch: false).1
        }

        #expect(firstChoice(entered: nil) == .choose(adam.id))
        #expect(firstChoice(entered: "ada") == .choose(ada.id))
    }

    @Test func aUseSurvivesARelaunchAndTheFileNamesNoWebsiteOrCredential() async throws {
        let ada = account("ada"), bob = account("bob")
        let file = Profile(id: UUID(), name: "Relaunch", symbol: "key", color: .blue).autofillLastUsedFile
        await AutofillLastUsed(file: file).record(key, account: bob.id, origin: Self.site, at: date(1))?.value

        let relaunched = AutofillLastUsed(file: file)
        #expect(list([ada, bob], store: relaunched) == [bob.id, ada.id])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("example") && !text.contains(bob.id.uuidString) && !text.contains(vault.uuidString))

        // Only the vault's own key finds a use: another vault's, or none (a vault that gave no key), finds nothing.
        let another = ImportMemoryKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: UUID())
        #expect(relaunched.date(another, account: bob.id, origin: Self.site) == nil)
        #expect(relaunched.date(nil, account: bob.id, origin: Self.site) == nil)

        // A private window keeps nothing.
        let unsaved = FileManager.default.temporaryDirectory.appending(path: "AutofillLastUsed-\(UUID()).json")
        #expect(AutofillLastUsed(file: unsaved, persists: false).record(key, account: bob.id, origin: Self.site) == nil)
        #expect(!FileManager.default.fileExists(atPath: unsaved.path))
    }

    @Test func theOldestUseGoesPastTheLimit() {
        let lastUsed = AutofillLastUsed(file: URL(filePath: "/dev/null"), persists: false)
        let ids = (0...AutofillLastUsed.limit).map { _ in UUID() }
        for (minute, id) in ids.enumerated() {
            lastUsed.record(key, account: id, origin: Self.site, at: date(Double(minute)))
        }
        #expect(lastUsed.date(key, account: ids[0], origin: Self.site) == nil)
        #expect(lastUsed.date(key, account: ids[1], origin: Self.site) == date(1))
    }
}
