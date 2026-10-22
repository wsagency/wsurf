// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// A card or an address typed into a form is saved into the vault through the save offer, and filled back from it. Real managers in
/// the registry, the real session and the vault's ordinary per-entry write; only the page's document proof is replaced. Synthetic
/// test card numbers and example.test addresses only.
@MainActor
struct AutofillVaultSaveTests {
    private static let page = "https://shop.example.test"

    private func card(year: Int = 2031, code: String? = "737") throws -> PaymentCard {
        try PaymentCard(number: "4242424242424242", cardholder: "Ada Lovelace", month: 7, year: year, securityCode: code)
    }

    private func contact() -> AutofillContact {
        var contact = AutofillContact()
        contact.givenName = "Ada"
        contact.familyName = "Lovelace"
        contact.organization = "Analytical Engines"
        contact.email = "ada@example.test"
        contact.street = "1 Synthetic Way"
        contact.city = "Testville"
        contact.postalCode = "10000"
        contact.countryCode = "HR"
        return contact
    }

    /// A session attached to a page of `page`, shown in a window, of a context on a profile with `vaults`.
    private func withSession(
        vaults: [VaultState] = [.unlocked],
        _ body: (AutofillSaveSession, Profile, [FixtureVault]) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: vaults) { profile, _, vaults in
            let context = BrowserProfileContext(profile: profile)
            let configuration = WebViewPool.makeConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = BrowserPage(webKit: WKWebView(frame: .zero, configuration: configuration), context: context)
            page.url = URL(string: Self.page + "/checkout")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = page
            let session = AutofillSaveSession()
            AutofillSaveCoordinator.shared.install(in: page, session: session)
            session.liveness = { _, _, _ in true }
            do {
                try await body(session, profile, vaults)
            } catch {
                window.contentView = nil
                window.close()
                await page.close()
                throw error
            }
            window.contentView = nil
            window.close()
            await page.close()
        }
    }

    // MARK: - Save offer

    @Test(.boundedWebViews) func aSubmittedCardIsOfferedAndOnlySaveWritesItIntoTheVault() async throws {
        try await withSession { session, _, vaults in
            let manager = vaults[0].manager
            let before = try await manager.snapshot().revision

            await session.offer(.card(try card()), origin: Self.page)

            let offer = try #require(session.current)
            #expect(offer.candidate.kind == .card && !offer.isUpdate && session.isPopoverPresented)
            #expect(try await manager.snapshot().revision == before, "offering writes nothing")

            await session.save(offer)

            #expect(session.current == nil && session.error == nil)
            let accounts = try await manager.snapshot().accounts
            #expect(accounts.count == 1 && accounts[0].secureItems?.map(\.kind) == [.creditCard])
            let filled = try #require(VaultItemAutofill.cards(in: accounts).first)
            #expect(VaultItemAutofill.sameCard(filled.value, try card()) && filled.accountID == accounts[0].id)
        }
    }

    @Test(.boundedWebViews) func aSubmittedAddressIsSavedAsOneEntryThatFillsBack() async throws {
        try await withSession { session, _, vaults in
            await session.offer(.contact(contact()), origin: Self.page)
            let offer = try #require(session.current)

            await session.save(offer)

            let accounts = try await vaults[0].manager.snapshot().accounts
            #expect(accounts.count == 1)
            let filled = try #require(VaultItemAutofill.contacts(in: accounts).first?.value)
            #expect(AutofillSaveCandidate.contact(filled).values == AutofillSaveCandidate.contact(contact()).values)
            #expect(filled.fields["email"] == "ada@example.test" && filled.fields["organization"] == "Analytical Engines")
        }
    }

    @Test(.boundedWebViews) func whatTheVaultHoldsIsNotOfferedAgainAndARenewedCardUpdatesItsEntry() async throws {
        try await withSession { session, _, vaults in
            let manager = vaults[0].manager
            let held = VaultItemAutofill.account(for: try card())
            try await VaultManagerFixture.save([held, VaultItemAutofill.account(for: contact())], in: vaults[0])

            await session.offer(.card(try card(code: nil)), origin: Self.page)
            #expect(session.current == nil, "the same card (number, name and expiry) is not offered")
            await session.offer(.contact(contact()), origin: Self.page)
            #expect(session.current == nil, "the same address is not offered")

            await session.offer(.card(try card(year: 2032, code: nil)), origin: Self.page)
            let offer = try #require(session.current)
            #expect(offer.isUpdate && offer.managerEpoch == manager.authorizationEpoch)

            await session.save(offer)

            let accounts = try await manager.snapshot().accounts
            #expect(accounts.count == 2, "the entry is updated, not copied")
            let item = try #require(accounts.first { $0.id == held.id }?.secureItems?.first)
            #expect(item.value("expiryDate") == "2032-07")
            #expect(item.value("verificationNumber") == "737", "a form without a security code keeps the saved one")
        }
    }

    // MARK: - Locked vault

    @Test(.boundedWebViews) func aLockedVaultIsOfferedTheSaveButNothingIsReadOrWrittenBeforeSave() async throws {
        try await withSession(vaults: [.locked]) { session, profile, vaults in
            await session.offer(.card(try card()), origin: Self.page)

            let offer = try #require(session.current)
            #expect(!offer.isUpdate && offer.managerEpoch == nil, "the vault is chosen and unlocked on Save")
            // A card field of this profile is offered only the unlock row.
            let locked = await AutofillSuggestions.allVaultsLocked(of: profile)
            #expect(AutofillSuggestions.vaultItemRows(kind: .card, underAssistantControl: false, allVaultsLocked: locked) == .unlock)

            session.dismiss(offer)
            try await VaultManagerFixture.unlock(vaults[0])
            #expect(try await vaults[0].manager.snapshot().accounts.isEmpty)
        }
    }

    // MARK: - Assistant and connected apps

    @Test(.boundedWebViews) func aTabUnderAssistantControlIsOfferedNothingAndSavesNothing() async throws {
        try await withSession { session, _, vaults in
            let manager = vaults[0].manager
            let before = try await manager.snapshot().revision
            session.isUnderAssistantControl = { true }

            await session.offer(.card(try card()), origin: Self.page)
            await session.offer(.contact(contact()), origin: Self.page)
            #expect(session.current == nil)

            // An offer made before the assistant took the tab saves nothing after.
            session.isUnderAssistantControl = { false }
            await session.offer(.card(try card()), origin: Self.page)
            let offer = try #require(session.current)
            session.isUnderAssistantControl = { true }
            await session.save(offer)

            #expect(session.current == nil)
            #expect(try await manager.snapshot().revision == before)
        }
    }

    @Test func cardAndAddressFieldsAreOfferedNothingUnderAssistantControlAndOnlyUnlockWhileLocked() {
        typealias Rows = AutofillSuggestions.VaultItemRows
        for kind in [AutofillSaveKind.card, .contact] {
            #expect(AutofillSuggestions.vaultItemRows(kind: kind, underAssistantControl: false, allVaultsLocked: false) == Rows.items)
            #expect(AutofillSuggestions.vaultItemRows(kind: kind, underAssistantControl: false, allVaultsLocked: true) == Rows.unlock)
            #expect(AutofillSuggestions.vaultItemRows(kind: kind, underAssistantControl: true, allVaultsLocked: false) == Rows.none)
            #expect(AutofillSuggestions.vaultItemRows(kind: kind, underAssistantControl: true, allVaultsLocked: true) == Rows.none)
        }
        // A login field has its own rows and its own unlock row.
        #expect(AutofillSuggestions.vaultItemRows(kind: .password, underAssistantControl: false, allVaultsLocked: true) == Rows.none)
    }
}
