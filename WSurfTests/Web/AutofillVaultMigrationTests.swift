// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import LocalAuthentication
import Testing

@testable import WSurf
@testable import WSurfVault

// Synthetic data only: test card numbers, invented names, example.test addresses. The old card list, contact list and save index live
// in `MemoryAutofillStorage`, the vault in a fixture vault of a throwaway profile, and the state in a throwaway defaults suite.
// Nothing here reaches the Keychain, the real vault or the app's own preferences.
@MainActor
struct AutofillVaultMigrationTests {
    private static let visa = "4242424242424242"
    private static let mastercard = "5555555555554444"

    private final class Harness {
        let profile: Profile
        let vault: FixtureVault
        var manager: CredentialManager {
            vault.manager
        }
        let cardStorage = MemoryAutofillStorage()
        let contactStorage = MemoryAutofillStorage()
        let indexStorage = MemoryAutofillStorage()
        let cards: PaymentCardVault
        let contacts: SecureAutofillVault<AutofillContact>
        let defaults: UserDefaults
        private let suiteName = AppDatabase.defaultsSuite("AutofillVaultMigrationTests.\(UUID().uuidString)")

        init(profile: Profile, vault: FixtureVault) throws {
            self.profile = profile
            self.vault = vault
            cards = PaymentCardVault(profileID: profile.id, storage: cardStorage)
            contacts = SecureAutofillVault<AutofillContact>(profileID: profile.id, kind: "contacts", reason: "Test", storage: contactStorage)
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        func migration() -> AutofillVaultMigration {
            var migration = AutofillVaultMigration(profile: profile, cards: cards, contacts: contacts, defaults: defaults)
            migration.indexStorage = indexStorage
            return migration
        }

        var epoch: UInt64 {
            get throws { try #require(manager.authorizationEpoch) }
        }

        func cleanUp() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        /// The old lists and their save index rows, as the previous builds wrote them.
        func seed(cards: [PaymentCard], contacts: [AutofillContact]) async throws {
            if !cards.isEmpty {
                try cardStorage.write(JSONEncoder().encode(cards), service: try await self.cards.service(), context: LAContext())
                try AutofillSaveIndex.replace(cards.map(AutofillSaveCandidate.card), kind: .card, profileID: profile.id, storage: indexStorage)
            }
            if !contacts.isEmpty {
                _ = try await self.contacts.update { _ in contacts }
                try AutofillSaveIndex.replace(
                    contacts.map(AutofillSaveCandidate.contact), kind: .contact, profileID: profile.id, storage: indexStorage
                )
            }
        }

        /// The save index item as stored, as text.
        func indexText() throws -> String {
            let data = try indexStorage.read(service: AutofillSaveIndex.service(profile.id), context: LAContext())
            return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        func sources() async throws -> AutofillVaultMigration.Sources {
            try await migration().sources(using: try await migration().makeSession())
        }
    }

    private func with(vaults: [VaultState] = [.unlocked], _ body: (Harness) async throws -> Void) async throws {
        try await VaultManagerFixture.with(vaults: vaults) { profile, _, vaults in
            let harness = try Harness(profile: profile, vault: vaults[0])
            defer { harness.cleanUp() }
            try await body(harness)
        }
    }

    private func card(_ number: String = Self.visa, holder: String = "Ada Lovelace", code: String? = "737") throws -> PaymentCard {
        try PaymentCard(number: number, cardholder: holder, month: 7, year: 2031, securityCode: code)
    }

    private func contact(street: String = "1 Synthetic Way", email: String = "ada@example.test") -> AutofillContact {
        var contact = AutofillContact()
        contact.label = "Home"
        contact.givenName = "Ada"
        contact.familyName = "Lovelace"
        contact.organization = "Analytical Engines"
        contact.email = email
        contact.phone = "+385 1 000 0000"
        contact.street = street + "\nFlat 4"
        contact.city = "Testville"
        contact.region = "Zagreb"
        contact.postalCode = "10000"
        contact.countryCode = "HR"
        return contact
    }

    // MARK: - Mapping

    @Test func aCardAndAContactBecomeEntriesThatFillExactlyAsBefore() throws {
        let card = try card()
        let entry = VaultItemAutofill.account(for: card)
        try entry.validate()
        #expect(entry.secureItems?.map(\.kind) == [.creditCard] && entry.username.isEmpty && entry.origins.isEmpty)
        #expect(entry.secureItems?.first?.value("expiryDate") == "2031-07")
        let storedCard = try #require(entry.secureItems?.first)
        let filled = try #require(VaultItemAutofill.paymentCard(storedCard))
        #expect(VaultItemAutofill.sameCard(filled, card))
        #expect(VaultItemAutofill.cards(in: [entry]).map(\.value.number) == [Self.visa])

        let contact = contact()
        let person = VaultItemAutofill.account(for: contact)
        try person.validate()
        #expect(person.displayName == "Home")
        #expect(person.secureItems?.map(\.kind) == [.personName, .address, .customFields])
        let ids = person.secureItems?.last?.fields.compactMap(\.field?.id)
        #expect(ids == [AutofillContactValues.emailFieldID, AutofillContactValues.organizationFieldID])
        let back = try #require(VaultItemAutofill.contact(of: person))
        #expect(AutofillSaveCandidate.contact(back).values == AutofillSaveCandidate.contact(contact).values && back.label == "Home")
        #expect(back.fields["email"] == "ada@example.test" && back.fields["organization"] == "Analytical Engines")

        // A contact saved for its email alone still fills as a contact.
        var emailOnly = AutofillContact()
        emailOnly.email = "only@example.test"
        let offers = VaultItemAutofill.contacts(in: [VaultItemAutofill.account(for: emailOnly)])
        #expect(offers.map(\.value.email) == ["only@example.test"])
    }

    // MARK: - Digest

    /// The confirmation compares the lists read again with the ones the person saw: the same lists must give the same digest every
    /// time, and any change of a value a different one.
    @Test func theDigestOfTheSameListsIsStableAndAnyChangeAltersIt() async throws {
        try await with { h in
            let cards = [try card(), try card(Self.mastercard, holder: "Charles Babbage", code: nil)]
            let contacts = [contact(), contact(street: "2 Other Road", email: "work@example.test")]
            try await h.seed(cards: cards, contacts: contacts)
            let first = try await h.sources()
            let second = try await h.sources()
            let digest = AutofillVaultMigration.digest(first)
            #expect(AutofillVaultMigration.digest(second) == digest, "two reads of the same lists")
            for _ in 0..<20 {
                let copy = try JSONDecoder().decode(AutofillVaultMigration.Sources.self, from: JSONEncoder().encode(first))
                #expect(AutofillVaultMigration.digest(copy) == digest, "a copy encoded and decoded again")
            }
            #expect(
                try await h.migration().report(for: first, in: h.manager, epoch: try h.epoch)
                    == h.migration().report(for: second, in: h.manager, epoch: try h.epoch)
            )

            var code = first
            code.cards[0].securityCode = "123"
            var city = first
            city.contacts[1].city = "Elsewhere"
            var label = first
            label.contacts[0].label = "Work"
            var fewer = first
            fewer.contacts.removeLast()
            let changed = [code, city, label, fewer].map(AutofillVaultMigration.digest)
            #expect(!changed.contains(digest), "every change gives another digest")
            #expect(Set(changed).count == changed.count)
        }
    }

    // MARK: - Detection

    @Test func nothingSavedOnThisMacIsDoneWithoutReadingAnything() async throws {
        try await with { h in
            let migration = h.migration()
            #expect(await migration.state() == .done)
            #expect(h.cardStorage.readCount == 0 && h.contactStorage.readCount == 0)
            #expect(h.cardStorage.existenceCheckCount == 1)
            #expect(h.indexStorage.writeCount == 0, "no index is created for a profile that never had one")
        }
        let privateMigration = AutofillVaultMigration(profile: .privateBrowsing())
        #expect(await privateMigration.state() == .done)
    }

    @Test func savedListsStayPendingAndAreNotReadUntilReview() async throws {
        try await with { h in
            try await h.seed(cards: [card()], contacts: [contact()])
            let reads = (h.cardStorage.readCount, h.contactStorage.readCount)
            #expect(await h.migration().state() == .pending)
            #expect(h.cardStorage.readCount == reads.0 && h.contactStorage.readCount == reads.1)
        }
    }

    // MARK: - Copy, verify, confirm, erase

    @Test func theMoveCopiesVerifiesAndErasesOnlyAfterConfirmation() async throws {
        try await with { h in
            let cards = [try card(), try card(Self.mastercard, holder: "Charles Babbage", code: nil)]
            let contacts = [contact(), contact(street: "2 Other Road", email: "work@example.test")]
            try await h.seed(cards: cards, contacts: contacts)
            let migration = h.migration()
            let sources = try await h.sources()
            #expect(sources.cards == cards && sources.contacts == contacts)

            let report = try await migration.move(sources, into: h.manager, epoch: try h.epoch)

            #expect(report.moved == 4 && report.alreadyThere == 0 && report.missing == 0)
            #expect(migration.storedState == .imported)
            let snapshot = try await h.manager.snapshot()
            #expect(snapshot.accounts.count == 4)
            #expect(Set(snapshot.accounts.map(\.id)) == migration.movedIDs(in: h.manager.vaultID))
            #expect(VaultItemAutofill.cards(in: snapshot.accounts).map(\.value.number).sorted() == [Self.visa, Self.mastercard].sorted())
            // The old copies are untouched until the confirmation.
            #expect(h.cardStorage.eraseCount == 0 && h.contactStorage.eraseCount == 0)
            #expect(try h.indexText().contains("Lovelace"), "the rows are still there, so the test can see them go")

            try await migration.erase(using: try await migration.makeSession(), confirmed: report, in: h.manager, epoch: try h.epoch)

            #expect(migration.storedState == .done)
            #expect(h.defaults.dictionary(forKey: AutofillVaultMigration.movedKey) == nil)
            #expect(h.cardStorage.itemCount == 0 && h.contactStorage.itemCount == 0)
            #expect(try await h.manager.snapshot().accounts.count == 4, "the vault keeps every entry")
            #expect(await migration.state() == .done)
        }
    }

    /// The erasure test: after the confirmation the save index item holds no card or contact field in plaintext, and none of their
    /// rows, while "Never for This Site" survives.
    @Test func noPlaintextCardOrContactFieldIsLeftInTheSaveIndex() async throws {
        try await with { h in
            try await h.seed(cards: [try card()], contacts: [contact()])
            let shop = "https://shop.example.test"
            try AutofillSaveIndex.block(kind: .card, origin: shop, profileID: h.profile.id, storage: h.indexStorage)
            // What the rows showed without a prompt: a card's network, last four digits and holder, a contact's email and street.
            let needles = ["4242", "Visa", "Ada Lovelace", "ada@example.test", "Synthetic Way"]
            let before = try h.indexText()
            #expect(needles.allSatisfy(before.contains), "the seeded rows hold every field the test looks for")
            let migration = h.migration()
            let report = try await migration.move(try await h.sources(), into: h.manager, epoch: try h.epoch)

            try await migration.erase(using: try await migration.makeSession(), confirmed: report, in: h.manager, epoch: try h.epoch)

            let after = try h.indexText()
            for needle in needles {
                #expect(!after.contains(needle), "the save index still holds \(needle)")
            }
            let stored = try #require(JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])
            for part in ["records", "suggestions"] {
                let kinds = Set((stored[part] as? [String: Any] ?? [:]).keys)
                #expect(kinds.isDisjoint(with: ["card", "contact"]), "a \(part) row of a card or contact is left, even an empty one")
            }
            #expect(try !AutofillSaveIndex.hasRows(of: [.card, .contact], profileID: h.profile.id, storage: h.indexStorage))
            #expect(try AutofillSaveIndex.isBlocked(kind: .card, origin: shop, profileID: h.profile.id, storage: h.indexStorage))
        }
    }

    // MARK: - Undo before confirmation

    @Test func undoBeforeConfirmationMovesTheEntriesToTrashAndKeepsTheOldCopies() async throws {
        try await with { h in
            try await h.seed(cards: [try card()], contacts: [contact()])
            let migration = h.migration()
            let report = try await migration.move(try await h.sources(), into: h.manager, epoch: try h.epoch)
            let moved = migration.movedIDs(in: h.manager.vaultID)
            #expect(moved.count == 2)

            try await migration.undo(in: h.manager, epoch: try h.epoch)

            #expect(try await h.manager.snapshot().accounts.isEmpty)
            let trash = try await h.manager.trashPage(after: nil).items
            #expect(Set(trash.map(\.ownerID)) == moved)
            #expect(migration.storedState == nil && migration.movedIDs(in: h.manager.vaultID).isEmpty)
            #expect(await migration.state() == .pending)
            #expect(h.cardStorage.eraseCount == 0 && h.contactStorage.eraseCount == 0 && h.cardStorage.itemCount == 1)
            #expect(try h.indexText().contains("Lovelace"))
            // Nothing is moved now, so nothing may be erased.
            await #expect(throws: AutofillVaultMigration.Failure.notImported) {
                try await migration.erase(using: try await migration.makeSession(), confirmed: report, in: h.manager, epoch: try h.epoch)
            }
            #expect(h.cardStorage.itemCount == 1 && h.contactStorage.itemCount == 1)
        }
    }

    // MARK: - Duplicates, reruns, refusals

    @Test func duplicatesAreSkippedAndARerunAfterACrashWritesNothingTwice() async throws {
        try await with { h in
            let held = try card()
            try await VaultManagerFixture.save([VaultItemAutofill.account(for: held), VaultItemAutofill.account(for: contact())], in: h.vault)
            // The vault holds the Visa with another holder: that card counts as already there, by number.
            try await h.seed(
                cards: [try card(holder: "Someone Else"), try card(Self.mastercard)],
                contacts: [contact(), contact(street: "2 Other Road")]
            )
            let sources = try await h.sources()
            #expect(AutofillVaultMigration.entries(for: sources, in: try await h.manager.snapshot().accounts).count == 2)

            let first = try await h.migration().move(sources, into: h.manager, epoch: try h.epoch)
            #expect(first.moved == 2 && first.alreadyThere == 2 && first.missing == 0)
            #expect(try await h.manager.snapshot().accounts.count == 4)

            // A crash after the commit but before the state was written: the move runs again from `pending`.
            h.defaults.removeObject(forKey: AutofillVaultMigration.stateKey)
            let again = try await h.migration().move(sources, into: h.manager, epoch: try h.epoch)

            #expect(again == first)
            #expect(try await h.manager.snapshot().accounts.count == 4, "nothing is written twice")
            #expect(h.migration().movedIDs(in: h.manager.vaultID).count == 2)
        }
    }

    @Test func eraseRefusesAfterAnyChangeAndErasesNothing() async throws {
        try await with { h in
            try await h.seed(cards: [try card()], contacts: [contact()])
            let migration = h.migration()
            let report = try await migration.move(try await h.sources(), into: h.manager, epoch: try h.epoch)

            // A moved entry was removed from the vault after the report was shown.
            let snapshot = try await h.manager.snapshot()
            let cardEntry = try #require(snapshot.accounts.first { $0.secureItems?.first?.kind == .creditCard })
            _ = try await h.manager.commitAccounts(
                [], removing: [cardEntry.id: try #require(snapshot.stamps[cardEntry.id])], authorizedEpoch: try h.epoch
            )
            await #expect(throws: AutofillVaultMigration.Failure.changed) {
                try await migration.erase(using: try await migration.makeSession(), confirmed: report, in: h.manager, epoch: try h.epoch)
            }

            // An old list changed after the report was shown.
            let fresh = try await migration.report(for: try await h.sources(), in: h.manager, epoch: try h.epoch)
            #expect(fresh.missing == 1)
            let added = contact(street: "3 New Lane")
            _ = try await h.contacts.update { $0 + [added] }
            await #expect(throws: AutofillVaultMigration.Failure.changed) {
                try await migration.erase(using: try await migration.makeSession(), confirmed: fresh, in: h.manager, epoch: try h.epoch)
            }

            #expect(h.cardStorage.eraseCount == 0 && h.contactStorage.eraseCount == 0)
            #expect(migration.storedState == .imported)
            #expect(try h.indexText().contains("Lovelace"))
        }
    }

    /// The largest old lists (500 cards, 1,000 contacts) move in one commit; ten of each that the vault already holds are skipped.
    @Test func theFullestListsMoveInOneCommitWithDuplicatesSkipped() async throws {
        try await with { h in
            func number(_ index: Int) -> String {
                let body = "4" + String(format: "%014d", index + 1)
                let sum = body.compactMap(\.wholeNumberValue).reversed().enumerated().reduce(0) { total, item in
                    let digit = item.offset.isMultiple(of: 2) ? item.element * 2 : item.element
                    return total + (digit > 9 ? digit - 9 : digit)
                }
                return body + String((10 - sum % 10) % 10)
            }
            let cards = try (0..<500).map { try PaymentCard(number: number($0), cardholder: "Holder \($0)", month: 1, year: 2040) }
            let contacts = (0..<1_000).map { contact(street: "\($0) Synthetic Way", email: "person\($0)@example.test") }
            let heldCards = cards.prefix(10).map { VaultItemAutofill.account(for: $0) }
            let held = heldCards + contacts.prefix(10).map { VaultItemAutofill.account(for: $0) }
            try await VaultManagerFixture.save(held, in: h.vault)
            try await h.seed(cards: cards, contacts: contacts)
            let before = try await h.manager.snapshot().revision

            let report = try await h.migration().move(try await h.sources(), into: h.manager, epoch: try h.epoch)

            #expect(report.moved == 1_480 && report.alreadyThere == 20 && report.missing == 0)
            let snapshot = try await h.manager.snapshot()
            #expect(snapshot.accounts.count == 1_500)
            #expect(snapshot.revision == before + 1, "one commit")
            #expect(h.migration().movedIDs(in: h.manager.vaultID).count == 1_480)
        }
    }

    @Test func aLockedVaultMovesNothing() async throws {
        try await with { h in
            try await h.seed(cards: [try card()], contacts: [])
            let epoch = try h.epoch
            let sources = try await h.sources()
            h.manager.lock(reason: .manual)

            await #expect(throws: (any Error).self) {
                try await h.migration().move(sources, into: h.manager, epoch: epoch)
            }

            #expect(h.migration().storedState == nil && h.migration().movedIDs(in: h.manager.vaultID).isEmpty)
            #expect(h.cardStorage.itemCount == 1)
        }
    }
}
