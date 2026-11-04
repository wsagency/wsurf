// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Contacts
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// Cards from a Safari export and contacts from Contacts are imported into the vault only: a review by title, one commit, Undo. The
/// real settings model over a fixture vault; synthetic test card numbers and example.test details only.
@MainActor
struct AutofillVaultImportTests {
    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        init() async throws {
            let profile = Profile(id: UUID(), name: "Import", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await model.load()
        }

        func snapshot() async throws -> StoreSnapshot {
            try await vault.manager.snapshot()
        }

        /// A Safari export of `cards` (number, holder), as PaymentCards.json.
        func safariExport(_ cards: [(String, String)]) throws -> URL {
            let records = cards.map { number, holder in
                ["card_number": number, "cardholder_name": holder, "card_expiration_month": 9, "card_expiration_year": 2034] as [String: Any]
            }
            let file = directory.appendingPathComponent("PaymentCards.json")
            try JSONSerialization.data(withJSONObject: ["metadata": ["data_type": "payment_cards"], "payment_cards": records]).write(to: file)
            return file
        }

        func cleanup() async {
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    @Test func aSafariExportIsReviewedByTitleThenImportedInOneCommitWithUndo() async throws {
        try await withFixture { f in
            let held = try PaymentCard(number: "5555555555554444", cardholder: "Charles Babbage", month: 9, year: 2034)
            try await VaultManagerFixture.save([VaultItemAutofill.account(for: held)], in: f.vault)
            await f.model.load()
            let file = try f.safariExport([("4242 4242 4242 4242", "Ada Lovelace"), ("5555555555554444", "Charles Babbage"), ("bad", "")])
            let before = try await f.snapshot().revision

            let read = try await CredentialSettingsModel.safariCards(from: file)
            let plan = try #require(await f.model.planAutofillImport(read.sources, skipped: read.skipped))

            #expect(plan.titles.count == 2 && plan.writes == 1 && plan.skipped == 1)
            #expect(plan.titles.contains { $0.hasSuffix("•••• 4242") })
            #expect(!plan.titles.contains { $0.contains("4242424242424242") || $0.contains("Lovelace") }, "the review shows titles only")
            #expect(try await f.snapshot().revision == before, "the review writes nothing")

            await f.model.commitAutofillImport(plan)

            let after = try await f.snapshot()
            #expect(after.revision == before + 1, "one commit")
            #expect(after.accounts.count == 2)
            let heldID = try #require(after.accounts.first { VaultItemAutofill.cards(in: [$0]).first?.value.number == held.number }?.id)
            let imported = try #require(after.accounts.first { $0.id != heldID })
            let item = try #require(imported.secureItems?.first)
            // The vault's Touch ID rules: a card is sensitive, its number is hidden until revealed.
            #expect(item.kind == .creditCard && item.isSensitive)
            let number = try #require(item.fields.first { $0.name == "number" })
            #expect(item.isConcealed(number) && number.value == "4242424242424242")
            #expect(f.model.notice?.text == String(localized: "Added 1 entry to the vault.") && f.model.notice?.offersUndo == true)

            await f.model.undo()

            #expect(try await f.snapshot().accounts.map(\.id) == [heldID])
            #expect(try await f.vault.manager.trashPage(after: nil).items.map(\.ownerID) == [imported.id])
        }
    }

    @Test func aContactFromContactsBecomesOneEntryAndIsNotImportedTwice() async throws {
        try await withFixture { f in
            let source = CNMutableContact()
            source.givenName = "Ada"
            source.familyName = "Lovelace"
            source.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "ada@example.test" as NSString)]
            let address = CNMutablePostalAddress()
            address.street = "1 Synthetic Way"
            address.city = "Testville"
            address.isoCountryCode = "hr"
            source.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
            let contact = AutofillContact(contact: source)
            let sources = AutofillVaultMigration.Sources(cards: [], contacts: [contact])

            let plan = try #require(await f.model.planAutofillImport(sources))
            #expect(plan.writes == 1 && plan.titles == [contact.title])
            await f.model.commitAutofillImport(plan)

            let accounts = try await f.snapshot().accounts
            let filled = try #require(VaultItemAutofill.contacts(in: accounts).first?.value)
            #expect(AutofillSaveCandidate.contact(filled).values == AutofillSaveCandidate.contact(contact).values)
            #expect(filled.email == "ada@example.test" && filled.countryCode == "HR")
            let again = try #require(await f.model.planAutofillImport(sources))
            #expect(again.writes == 0, "a contact the vault holds is not imported again")
        }
    }

    private static func contact(_ given: String, _ family: String, email: String) -> CNMutableContact {
        let source = CNMutableContact()
        source.givenName = given
        source.familyName = family
        source.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        return source
    }

    @Test func severalContactsAreReviewedTogetherThenImportedInOneCommitWithOneUndo() async throws {
        try await withFixture { f in
            let ada = Self.contact("Ada", "Lovelace", email: "ada@example.test")
            let grace = Self.contact("Grace", "Hopper", email: "grace@example.test")
            let alan = Self.contact("Alan", "Turing", email: "alan@example.test")
            let again = Self.contact("Ada", "Lovelace", email: "ada@example.test")
            let empty = CNMutableContact()
            try await VaultManagerFixture.save([VaultItemAutofill.account(for: AutofillContact(contact: alan))], in: f.vault)
            await f.model.load()
            let before = try await f.snapshot()

            // A contact without usable details and one with the same details as an earlier pick are left out of the review.
            let sources = try #require(AutofillImportRows.contactSources([ada, grace, alan, again, empty]))
            #expect(sources.contacts.count == 3 && sources.cards.isEmpty)
            #expect(AutofillImportRows.contactSources([empty]) == nil)
            let plan = try #require(await f.model.planAutofillImport(sources))
            #expect(plan.titles == sources.contacts.map(\.title) && plan.writes == 2, "Alan is already in the vault")
            #expect(!plan.titles.contains { $0.contains("@example.test") }, "the review shows titles only")
            #expect(try await f.snapshot().revision == before.revision, "the review writes nothing")

            await f.model.commitAutofillImport(plan)

            let after = try await f.snapshot()
            #expect(after.revision == before.revision + 1, "one commit")
            #expect(after.accounts.count == 3)
            #expect(f.model.notice?.text == String(localized: "Added 2 entries to the vault.") && f.model.notice?.offersUndo == true)
            let imported = Set(after.accounts.map(\.id)).subtracting(before.accounts.map(\.id))
            #expect(imported.count == 2)

            await f.model.undo()

            #expect(try await f.snapshot().accounts.map(\.id) == before.accounts.map(\.id), "one Undo takes both back")
            #expect(Set(try await f.vault.manager.trashPage(after: nil).items.map(\.ownerID)) == imported)
        }
    }

    @Test func thePickerCollectsEveryContactClickedAndHandsThemOverOnceWhenItCloses() {
        var delivered: [[String]] = []
        let coordinator = ContactImportButton.Coordinator { contacts in delivered.append(contacts.map(\.givenName)) }
        let ada = Self.contact("Ada", "Lovelace", email: "ada@example.test")
        let grace = Self.contact("Grace", "Hopper", email: "grace@example.test")

        coordinator.contactPicker(coordinator.picker, didSelect: ada)
        coordinator.contactPicker(coordinator.picker, didSelect: grace)
        coordinator.contactPicker(coordinator.picker, didSelect: ada)
        #expect(delivered.isEmpty, "nothing is reviewed while the picker is open")
        coordinator.contactPickerDidClose(coordinator.picker)
        #expect(delivered == [["Ada", "Grace"]], "every contact once, in the order clicked")

        // Closed without a click: nothing to review.
        coordinator.contactPickerDidClose(coordinator.picker)
        #expect(delivered.count == 1 && coordinator.picked.isEmpty)
    }

    @Test func aVaultThatChangedSinceTheReviewWritesNothing() async throws {
        try await withFixture { f in
            let card = try PaymentCard(number: "4242424242424242", cardholder: "Ada Lovelace", month: 9, year: 2034)
            let plan = try #require(await f.model.planAutofillImport(AutofillVaultMigration.Sources(cards: [card], contacts: [])))
            try await VaultManagerFixture.save([VaultItemAutofill.account(for: card)], in: f.vault)
            let before = try await f.snapshot()

            await f.model.commitAutofillImport(plan)

            #expect(try await f.snapshot().revision == before.revision)
            #expect(f.model.error != nil, "the person is told to review again")
        }
    }

    /// No import path names the old Keychain lists or the save index, so an import can never leave a plaintext row there.
    @Test func importsNeverWriteTheKeychainListsOrTheSaveIndex() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["WSurf/Web/Credentials/CredentialSettingsModel+AutofillImport.swift", "WSurf/Settings/Pages/AutofillImportRows.swift"]
        for file in files {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for needle in ["AutofillSaveIndex", "PaymentCardVault", "AutofillVaults", "SecureAutofillVault", "AutofillKeychainStorage", "SecItem"] {
                #expect(!text.contains(needle), "\(file) names \(needle)")
            }
        }
        try await withFixture { f in
            let card = try PaymentCard(number: "4242424242424242", cardholder: "Ada Lovelace", month: 9, year: 2034)
            let plan = try #require(await f.model.planAutofillImport(AutofillVaultMigration.Sources(cards: [card], contacts: [])))
            await f.model.commitAutofillImport(plan)
            #expect(try await f.snapshot().accounts.count == 1)
            // The profile's own save index (this test run's Keychain namespace) holds no card or contact row.
            #expect((try? AutofillSaveIndex.hasRows(of: [.card, .contact], profileID: f.profile.id)) != true)
        }
    }

    @Test func withNoVaultTheImportRowsOfferToCreateOne() async throws {
        typealias Action = AutofillImportRows.Action
        #expect(Action.of(vaultExists: false, isUnlocked: false, canCreateVault: true) == .createVault)
        #expect(Action.of(vaultExists: true, isUnlocked: false, canCreateVault: true) == .unavailable, "a locked vault: unlock first")
        #expect(Action.of(vaultExists: nil, isUnlocked: false, canCreateVault: true) == .unavailable, "unknown: nothing is offered")
        #expect(Action.of(vaultExists: true, isUnlocked: true, canCreateVault: false) == .importItems)
        try await VaultManagerFixture.with(vaults: []) { profile, _, _ in
            let model = CredentialSettingsModel(profile: profile)
            await model.load()
            #expect(model.vaultExists == false)
            #expect(Action.of(vaultExists: model.vaultExists, isUnlocked: model.isUnlocked, canCreateVault: true) == .createVault)
        }
    }
}
