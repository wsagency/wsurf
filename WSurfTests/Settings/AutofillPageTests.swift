// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// The Autofill page's structure: a vault picker, the Vault and Settings tabs, the Vault tab's sections, every Settings search result
// and deep link landing on a tab and section, and switching vaults with the picker. Pure values and a source scan, plus one model over
// two fixture vaults with test-only in-memory unlock keys. Every value is synthetic.

@MainActor
struct AutofillPageTests {
    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: relative), encoding: .utf8)
    }

    private func entry(_ name: String, _ items: [SecureItem]) -> CredentialSummary {
        CredentialSummary(SecureItemFixtures.account(items, name: name))
    }

    // MARK: - Deep links

    @Test func everyAutofillSearchResultLandsOnATabAndSection() throws {
        let autofill = SettingsIndex.all.filter { $0.category == .autofill }
        #expect(autofill.count >= 6, "a missing entry would pass for the wrong reason")
        let expected: [String: AutofillDestination] = [
            "autofill.credentials": .vault(.all),
            "autofill.inputHistory": .inputHistory,
            "autofill.passwords": .settings,
            "autofill.cards": .settings,
            "autofill.applePay": .settings,
            "autofill.contacts": .settings,
        ]
        for entry in autofill {
            let destination = AutofillDestination(anchor: entry.targetAnchor)
            #expect(destination != nil, "\(entry.id) lands nowhere")
            #expect(destination == expected[entry.id], "\(entry.id)")
        }
        #expect(AutofillDestination(anchor: nil) == nil)
        #expect(AutofillDestination(anchor: "general.sleepTabs") == nil)
        #expect(AutofillDestination(anchor: InputHistoryBadge.anchor) == .inputHistory, "the toolbar button opens Input History")
    }

    /// The anchor each result highlights is on the view of the tab it lands on: the switches on the Settings tab, Input History and
    /// the vault on the Vault tab. One place each, so the highlight is never on a view the page does not show.
    @Test func eachAnchorIsOnTheTabItsDestinationShows() throws {
        let places: [String: String] = [
            "autofill.passwords": "WSurf/Settings/Pages/AutofillOptions.swift",
            "autofill.cards": "WSurf/Settings/Pages/AutofillOptions.swift",
            "autofill.contacts": "WSurf/Settings/Pages/AutofillOptions.swift",
            "autofill.applePay": "WSurf/Settings/Pages/AutofillOptions.swift",
            "autofill.inputHistory": "WSurf/Settings/Pages/InputHistorySettings.swift",
            "autofill.credentials": "WSurf/Settings/Pages/CredentialSettings.swift",
        ]
        let directory = repositoryRoot.appending(path: "WSurf/Settings/Pages").path(percentEncoded: false)
        let pages = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".swift") }
        #expect(pages.count > 20)
        for (anchor, file) in places {
            let marker = ".settingsAnchor(\"\(anchor)\")"
            #expect(try source(file).components(separatedBy: marker).count == 2, "\(anchor) in \(file)")
            let elsewhere = try pages.filter { name in
                let path = "WSurf/Settings/Pages/\(name)"
                return try path != file && source(path).contains(marker)
            }
            #expect(elsewhere.isEmpty, "\(anchor) also in \(elsewhere)")
        }
        // The page shows the switches on its Settings tab and Input History on its Vault tab.
        let page = try source("WSurf/Settings/Pages/CredentialSettings.swift")
        #expect(
            page.contains("AutofillOptions(context: context)")
                && page.contains("InputHistorySettings(context: context, vaults: model.vaults, selectedVaultID: model.selectedVaultID)")
        )
    }

    // MARK: - The Vault tab's sections

    @Test func theVaultTabAlwaysOffersItsSectionsInOrder() {
        let always: [CredentialListFilter] = [.all, .logins, .passkeys, .codes, .identities, .cards, .addresses, .contacts, .notes]
        // Locked, or no vault yet: no counts, and the sections are still there so the cards and addresses on this Mac can be reached.
        #expect(CredentialListFilter.chips(counts: nil, selected: .all) == always)
        let empty = CredentialListFilter.counts([])
        #expect(CredentialListFilter.chips(counts: empty, selected: .all) == always)
        // A narrower kind shows while an entry holds one, or while it is in use; Files stays hidden until an entry holds a file.
        var some = empty
        some[.documents] = 2
        #expect(CredentialListFilter.chips(counts: some, selected: .all) == always + [.documents])
        #expect(CredentialListFilter.chips(counts: empty, selected: .otherItems) == always + [.otherItems])
        #expect(!CredentialListFilter.chips(counts: empty, selected: .all).contains(.files))
        #expect(Set(CredentialListFilter.allCases.map { String(localized: $0.title) }).count == CredentialListFilter.allCases.count)
    }

    @Test func identitiesContactsAndAddressesSelectTheirEntries() {
        var namedLogin = VaultFixtures.account()
        namedLogin.displayName = "Login with a name"
        namedLogin.secureItems = [SecureItemFixtures.name()]
        let all = [
            entry("Child", [SecureItemFixtures.name(), SecureItemFixtures.custom(values: [("OIB", "00000000001", true)])]),
            entry("Neighbour", [SecureItemFixtures.name(), SecureItemFixtures.address()]),
            entry("Home", [SecureItemFixtures.address()]),
            entry("Passport", [SecureItem(kind: .passport, fields: [])]),
            entry("Locker", [SecureItemFixtures.custom()]),
            CredentialSummary(namedLogin),
        ]
        func titles(_ filter: CredentialListFilter) -> [String] {
            CredentialListFilter.visible(all, query: "", filter: filter).map(\.title)
        }
        #expect(titles(.identities) == ["Child", "Neighbour", "Passport"], "no sign-in, and a name or a document")
        #expect(titles(.contacts) == ["Neighbour"], "a name with an address")
        #expect(titles(.addresses) == ["Neighbour", "Home"])
        #expect(titles(.files).isEmpty)
        #expect(titles(.otherItems) == ["Child", "Locker"])
        #expect(titles(.logins) == ["Login with a name"])
    }

    // MARK: - Switching vaults

    @Test func theVaultPickerSwitchesTheEntriesAndKeepsInputHistoryOpen() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let model = CredentialSettingsModel(profile: profile)
            await model.load()
            let first = try #require(model.selectedVaultID)
            let home = try #require(vaults.first { $0.vaultID == first })
            let other = try #require(vaults.first { $0.vaultID != first })
            try await VaultManagerFixture.save([VaultFixtures.account()], in: home)
            try await VaultManagerFixture.save(
                [SecureItemFixtures.account([SecureItemFixtures.name()], name: "Synthetic Child")], in: other
            )
            await model.load()
            #expect(model.vaults.count == 2, "the picker beside the tabs is shown only when there is a choice")

            let list = CredentialListState()
            list.filter = .identities
            list.refresh(model.summaries)
            #expect(list.counts?[.identities] == 0 && list.counts?[.logins] == 1)
            list.showsInputHistory = true

            // What the page does when the picker changes the vault: the search and section start over, Input History stays open.
            await model.select(vaultID: other.vaultID)
            #expect(model.selectedVaultID == other.vaultID && model.isUnlocked)
            list.reset()
            list.refresh(model.summaries)
            #expect(list.filter == .all && list.query.isEmpty)
            #expect(list.showsInputHistory, "Input History belongs to the profile, not to a vault")
            #expect(list.counts?[.identities] == 1 && list.counts?[.logins] == 0)
            #expect(model.summaries.map(\.title) == ["Synthetic Child"])

            await model.select(vaultID: first)
            list.reset()
            list.refresh(model.summaries)
            #expect(list.counts?[.identities] == 0 && list.counts?[.logins] == 1, "coming back shows the first vault again")
        }
    }
}
