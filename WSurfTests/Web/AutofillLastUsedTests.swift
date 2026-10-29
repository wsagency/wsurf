// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// The fill dropdown's order: the credential last used on the page's website first, every other credential saved for that website
/// after it in the order it always had, and nothing else. The list is built as `AutofillSuggestions.managerSuggestions` builds it
/// (`CredentialAccountSelection.suggestions` per vault, then `lastUsedFirst`). Synthetic credentials; the record is a fresh
/// profile's file in the per-process test directory.
@MainActor
struct AutofillLastUsedTests {
    private static let site = "https://login.example.test"
    private static let other = "https://shop.elsewhere.test"
    private let vault = UUID()

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

    /// The dropdown's rows for one vault's `accounts` on `origin`.
    private func list(_ accounts: [CredentialAccount], on origin: String = Self.site, store: AutofillLastUsed) -> [AutofillSuggestion] {
        let rows = CredentialAccountSelection.suggestions(accounts, origin: origin, pageURL: nil, entered: nil, field: .password)
        return CredentialAccountSelection.lastUsedFirst(rows) { store.date(vault: vault, account: $0.id, origin: origin) }
    }

    @Test func ofSeveralCredentialsForOneWebsiteTheLastUsedIsFirst() {
        let ada = account("ada"), bob = account("bob"), cy = account("cy")
        let lastUsed = store()
        #expect(list([cy, bob, ada], store: lastUsed).map(\.id) == [ada.id, bob.id, cy.id], "never used: the order it always had")

        lastUsed.record(vault: vault, account: cy.id, origin: Self.site, at: date(1))
        #expect(list([cy, bob, ada], store: lastUsed).map(\.id) == [cy.id, ada.id, bob.id])

        lastUsed.record(vault: vault, account: bob.id, origin: Self.site, at: date(2))
        #expect(list([cy, bob, ada], store: lastUsed).map(\.id) == [bob.id, ada.id, cy.id], "the rest keep their order")

        // Several vaults: their rows in vault order, and the one used last, in whichever vault, leads.
        let second = UUID(), dee = account("dee")
        lastUsed.record(vault: second, account: dee.id, origin: Self.site, at: date(3))
        let first: [(vault: UUID, row: AutofillSuggestion)] = list([ada, bob], store: lastUsed).map { (vault: vault, row: $0) }
        let other: [(vault: UUID, row: AutofillSuggestion)] = CredentialAccountSelection.suggestions(
            [dee], origin: Self.site, pageURL: nil, entered: nil, field: .password
        ).map { (vault: second, row: $0) }
        let ordered = CredentialAccountSelection.lastUsedFirst(first + other) { lastUsed.date(vault: $0.vault, account: $0.row.id, origin: Self.site) }
        #expect(ordered.map { $0.row.id } == [dee.id, bob.id, ada.id])
    }

    @Test func aCredentialUsedOnAnotherWebsiteDoesNotJumpTheQueue() {
        let ada = account("ada"), bob = account("bob"), mia = account("mia", origins: [Self.site, Self.other])
        let lastUsed = store()
        lastUsed.record(vault: vault, account: bob.id, origin: Self.site, at: date(1))
        lastUsed.record(vault: vault, account: mia.id, origin: Self.other, at: date(2))

        #expect(list([mia, ada, bob], store: lastUsed).map(\.id) == [bob.id, ada.id, mia.id])
        #expect(list([mia, ada, bob], on: Self.other, store: lastUsed).map(\.id) == [mia.id], "on the other website only its own credential")
    }

    @Test func everyMatchIsShownAndNoOtherCredentialEver() {
        let here = (0..<7).map { account("user\($0)") }
        let elsewhere = account("away", origins: [Self.other]), sibling = account("near", origins: ["https://www.example.test"])
        // Used here once, then this website was taken off it: a record never brings it back.
        var moved = account("moved")
        let lastUsed = store()
        lastUsed.record(vault: vault, account: here[4].id, origin: Self.site, at: date(1))
        lastUsed.record(vault: vault, account: elsewhere.id, origin: Self.other, at: date(2))
        lastUsed.record(vault: vault, account: moved.id, origin: Self.site, at: date(3))
        moved.origins = [Self.other]

        let ids = list(here.reversed() + [elsewhere, sibling, moved], store: lastUsed).map(\.id)
        #expect(ids == [here[4].id] + here.map(\.id).filter { $0 != here[4].id })
        #expect(Set(ids).isDisjoint(with: [elsewhere.id, sibling.id, moved.id]))
    }

    /// Nothing fills without a choice: Return alone still goes to the page. The keyboard's first choice, Down then Return, is the
    /// credential used last here.
    @Test func theKeyboardsFirstChoiceIsTheLastUsed() {
        let ada = account("ada"), bob = account("bob")
        let lastUsed = store()
        lastUsed.record(vault: vault, account: bob.id, origin: Self.site, at: date(1))
        let rows = list([ada, bob], store: lastUsed)
        let index = AutofillSuggestionSearch.Index(rows, searchable: true)
        let start = AutofillSuggestionSearch.State(rowCount: rows.count)

        #expect(AutofillSuggestionSearch.reduce(start, .enter, index: index, typeToSearch: false).1 == .dismissAndPass)
        let down = AutofillSuggestionSearch.reduce(start, .down, index: index, typeToSearch: false).0
        #expect(AutofillSuggestionSearch.reduce(down, .enter, index: index, typeToSearch: false).1 == .choose(bob.id))
    }

    @Test func aUseSurvivesARelaunchAndTheFileNamesNoWebsiteOrCredential() async throws {
        let ada = account("ada"), bob = account("bob")
        let file = Profile(id: UUID(), name: "Relaunch", symbol: "key", color: .blue).autofillLastUsedFile
        await AutofillLastUsed(file: file).record(vault: vault, account: bob.id, origin: Self.site, at: date(1))?.value

        let relaunched = AutofillLastUsed(file: file)
        #expect(list([ada, bob], store: relaunched).map(\.id) == [bob.id, ada.id])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("example") && !text.contains(bob.id.uuidString) && !text.contains(vault.uuidString))

        // A private window keeps nothing.
        let unsaved = FileManager.default.temporaryDirectory.appending(path: "AutofillLastUsed-\(UUID()).json")
        #expect(AutofillLastUsed(file: unsaved, persists: false).record(vault: vault, account: bob.id, origin: Self.site) == nil)
        #expect(!FileManager.default.fileExists(atPath: unsaved.path))
    }

    @Test func theOldestUseGoesPastTheLimit() {
        let lastUsed = AutofillLastUsed(file: URL(filePath: "/dev/null"), persists: false)
        let ids = (0...AutofillLastUsed.limit).map { _ in UUID() }
        for (minute, id) in ids.enumerated() {
            lastUsed.record(vault: vault, account: id, origin: Self.site, at: date(Double(minute)))
        }
        #expect(lastUsed.date(vault: vault, account: ids[0], origin: Self.site) == nil)
        #expect(lastUsed.date(vault: vault, account: ids[1], origin: Self.site) == date(1))
    }
}
