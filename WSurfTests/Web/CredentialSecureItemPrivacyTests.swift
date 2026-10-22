// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// Model-level checks of the device-owner prompt (Touch ID) around a credential's cards and identity documents: showing their values,
// copying a hidden one, opening the editor and History. The prompt is a counting stub that can be told to fail; test-only in-memory
// unlock keys and a private pasteboard are used, so nothing here touches the general pasteboard, a real vault, the Keychain or a
// native ceremony. Every value is synthetic.

private nonisolated let secureItemLockReasons: [CredentialLockReason] = [.manual, .screenLock, .timeout]

@MainActor
struct CredentialSecureItemPrivacyTests {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    // Positions of the values in `SecureItemFixtures.card()` and `SecureItemFixtures.wifi()`.
    private static let numberPart = CredentialCopyPart.secureField(item: 0, field: 0)
    private static let holderPart = CredentialCopyPart.secureField(item: 0, field: 1)
    private static let codePart = CredentialCopyPart.secureField(item: 0, field: 2)
    private static let expiryPart = CredentialCopyPart.secureField(item: 0, field: 3)
    private static let networkPart = CredentialCopyPart.secureField(item: 0, field: 0)
    private static let passphrasePart = CredentialCopyPart.secureField(item: 0, field: 2)

    /// Stands in for Touch ID: counts how often the model asks, and fails when told to.
    @MainActor
    private final class Verifier {
        private(set) var reasons: [String] = []
        var failure: (any Error)?

        var calls: Int {
            reasons.count
        }

        func verify(_ reason: String) async throws {
            reasons.append(reason)
            if let failure {
                throw failure
            }
        }
    }

    private final class Fixture {
        let profile: Profile
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
        let vault: FixtureVault
        let verifier: Verifier
        let model: CredentialSettingsModel

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Secure items", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.locked]).vaults.first)
            self.profile = profile
            let verifier = Verifier()
            self.verifier = verifier
            model = CredentialSettingsModel(
                profile: profile, pasteboard: pasteboard, manager: vault.manager, verifyUser: { reason in try await verifier.verify(reason) }
            )
        }

        var manager: CredentialManager {
            vault.manager
        }

        /// The vault unlocked, holding `accounts`, and the page loaded.
        @MainActor func seed(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.unlock(vault)
            try await VaultManagerFixture.save(accounts, in: vault)
            await model.load()
        }

        /// A second write under the same unlock, which makes the first state an earlier version.
        @MainActor func replace(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.save(accounts, in: vault)
            await model.load()
        }

        @MainActor func sentinel() -> String {
            pasteboard.clearContents()
            pasteboard.setString("sentinel-not-a-secret", forType: .string)
            return "sentinel-not-a-secret"
        }

        var text: String? {
            pasteboard.string(forType: .string)
        }

        var isConcealed: Bool {
            pasteboard.types?.contains(CredentialSecureItemPrivacyTests.concealed) == true
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    private func cardAccount(id: UUID = UUID(), name: String? = "Synthetic card") -> CredentialAccount {
        SecureItemFixtures.account([SecureItemFixtures.card(name: "Synthetic Holder")], id: id, name: name)
    }

    private func wifiAccount(id: UUID = UUID(), passphrase: String = SecureItemFixtures.wifiPassphrase) -> CredentialAccount {
        SecureItemFixtures.account([SecureItemFixtures.wifi(passphrase: passphrase)], id: id, name: "Synthetic network")
    }

    // MARK: - Showing items

    @Test func showingAWifiOnlyCredentialNeverPromptsAndFillsRevealedItems() async throws {
        try await withFixture { f in
            let stored = wifiAccount()
            try await f.seed([stored])
            #expect(f.model.revealedItems == nil)

            try await f.model.revealSecureItems(accountID: stored.id)
            #expect(f.verifier.calls == 0)
            #expect(f.model.revealedItems?.accountID == stored.id)
            #expect(f.model.revealedItems?.items == stored.secureItems)
            #expect(f.model.revealedItems?.items.first?.value("passphrase") == SecureItemFixtures.wifiPassphrase)
        }
    }

    @Test func showingACardAsksOnceEachTimeAndFillsRevealedItems() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])

            try await f.model.revealSecureItems(accountID: stored.id)
            #expect(f.verifier.calls == 1)
            #expect(f.model.revealedItems?.accountID == stored.id)
            #expect(f.model.revealedItems?.items.first?.value("number") == SecureItemFixtures.cardNumber)
            #expect(f.model.revealedItems?.items.first?.value("verificationNumber") == SecureItemFixtures.cardCode)

            // Every Show asks again: nothing is remembered between two of them.
            f.model.hideSecrets()
            try await f.model.revealSecureItems(accountID: stored.id)
            #expect(f.verifier.calls == 2)
        }
    }

    @Test func aFailedVerificationShowsNothing() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed

            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.revealSecureItems(accountID: stored.id) }
            #expect(f.verifier.calls == 1)
            #expect(f.model.revealedItems == nil)

            // The page's own error path says nothing was shown.
            await f.model.attempt { try await f.model.revealSecureItems(accountID: stored.id) }
            #expect(f.model.error == String(localized: "Authentication didn’t finish. Nothing was shown or copied."))
            #expect(f.model.revealedItems == nil)

            // A failure is not remembered: answering the prompt later shows the card.
            f.verifier.failure = nil
            try await f.model.revealSecureItems(accountID: stored.id)
            #expect(f.model.revealedItems?.accountID == stored.id)
        }
    }

    // MARK: - Copying

    @Test func copyingAHiddenCardValueAsksEveryTimeAndStaysConcealed() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])

            try await f.model.copy(Self.numberPart, of: .stored(stored.id))
            #expect(f.text == SecureItemFixtures.cardNumber)
            #expect(f.isConcealed)
            #expect(f.verifier.calls == 1)

            try await f.model.copy(Self.numberPart, of: .stored(stored.id))
            #expect(f.verifier.calls == 2)

            try await f.model.copy(Self.codePart, of: .stored(stored.id))
            #expect(f.text == SecureItemFixtures.cardCode)
            #expect(f.isConcealed)
            #expect(f.verifier.calls == 3)
        }
    }

    @Test func aFailedVerificationCopiesNothing() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])
            let sentinel = f.sentinel()
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed

            for part in [Self.numberPart, Self.codePart] {
                await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.copy(part, of: .stored(stored.id)) }
            }
            #expect(f.verifier.calls == 2)
            #expect(f.text == sentinel)
            #expect(!f.isConcealed, "nothing was written, not even the marker")
            #expect(f.model.notice == nil)

            f.verifier.failure = nil
            try await f.model.copy(Self.numberPart, of: .stored(stored.id))
            #expect(f.text == SecureItemFixtures.cardNumber)
        }
    }

    @Test func aCardValueThatIsNotHiddenCopiesWithoutAPromptAndIsNotConcealed() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])

            for (part, expected) in [(Self.holderPart, "Synthetic Holder"), (Self.expiryPart, "2031-07")] {
                // A hidden value first, so a plain copy proves it takes the concealed marker off the pasteboard.
                try await f.model.copy(Self.numberPart, of: .stored(stored.id))
                #expect(f.isConcealed)
                let before = f.verifier.calls

                try await f.model.copy(part, of: .stored(stored.id))
                #expect(f.verifier.calls == before, "\(part) is not a hidden value")
                #expect(f.text == expected)
                #expect(!f.isConcealed, "\(part) is not a secret")
            }
        }
    }

    @Test func aHiddenWifiPasswordCopiesConcealedWithoutAPrompt() async throws {
        try await withFixture { f in
            let stored = wifiAccount()
            try await f.seed([stored])
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed

            try await f.model.copy(Self.passphrasePart, of: .stored(stored.id))
            #expect(f.text == SecureItemFixtures.wifiPassphrase)
            #expect(f.isConcealed, "hidden, so it carries the marker")
            try await f.model.copy(Self.networkPart, of: .stored(stored.id))
            #expect(f.text == "Synthetic-Net")
            #expect(!f.isConcealed)
            #expect(f.verifier.calls == 0, "only a card or an identity document adds a prompt")
        }
    }

    @Test func identityDocumentsAreGatedLikeCards() async throws {
        try await withFixture { f in
            let documents: [(kind: SecureItemKind, member: String)] = [
                (.driversLicense, "licenseNumber"), (.passport, "passportNumber"), (.identityDocument, "documentNumber"),
            ]
            let records = documents.map { document in
                SecureItemFixtures.account([SecureItem(kind: document.kind, fields: [SecureItemFixtures.field(document.member, "SYNTHETIC-DOC-0001")])])
            }
            try await f.seed(records)

            for record in records {
                var before = f.verifier.calls
                try await f.model.revealSecureItems(accountID: record.id)
                #expect(f.verifier.calls == before + 1)

                before = f.verifier.calls
                try await f.model.copy(Self.numberPart, of: .stored(record.id))
                #expect(f.verifier.calls == before + 1)
                #expect(f.text == "SYNTHETIC-DOC-0001")
                #expect(f.isConcealed)

                before = f.verifier.calls
                try await f.model.beginEditing(accountID: record.id)
                #expect(f.verifier.calls == before + 1)
                f.model.cancelEditing()
            }
        }
    }

    // MARK: - The editor

    @Test func openingTheEditorOfACardAsksForTouchID() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])

            try await f.model.beginEditing(accountID: stored.id)
            #expect(f.verifier.calls == 1)
            #expect(f.model.draft?.accountID == stored.id)
            f.model.cancelEditing()
            #expect(f.model.draft == nil)

            f.verifier.failure = WebsiteAuthenticatorError.notAllowed
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.beginEditing(accountID: stored.id) }
            #expect(f.verifier.calls == 2)
            #expect(f.model.draft == nil, "no editor opens, so no value is on the page")
        }
    }

    @Test func editingWithoutACardOrDocumentNeverPrompts() async throws {
        try await withFixture { f in
            let login = VaultFixtures.account()
            let address = SecureItemFixtures.account([SecureItemFixtures.address()])
            let records = [login, wifiAccount(), address]
            try await f.seed(records)
            // A stub that fails would show any prompt that was asked for.
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed

            for record in records {
                try await f.model.beginEditing(accountID: record.id)
                #expect(f.model.draft?.accountID == record.id)
                f.model.cancelEditing()
            }
            try await f.model.beginEditing(accountID: nil)
            #expect(f.model.draft?.isNew == true)
            #expect(f.verifier.calls == 0)
        }
    }

    @Test func copyingFromTheOpenEditorDoesNotPromptAgain() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            #expect(f.verifier.calls == 1)
            // Any further prompt would fail.
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed

            try await f.model.copy(Self.numberPart, of: .draft)
            #expect(f.text == SecureItemFixtures.cardNumber)
            #expect(f.isConcealed)
            try await f.model.copy(Self.codePart, of: .draft)
            #expect(f.text == SecureItemFixtures.cardCode)
            #expect(f.isConcealed)

            // What is typed and not yet saved copies too, from the draft rather than the vault.
            f.model.draft?.secureItems[0].fields[1].value = "Typed Holder"
            try await f.model.copy(Self.holderPart, of: .draft)
            #expect(f.text == "Typed Holder")
            #expect(!f.isConcealed)
            #expect(f.verifier.calls == 1)
        }
    }

    // MARK: - History

    @Test func historyAsksBeforeShowingOrCopyingAnEarlierCard() async throws {
        try await withFixture { f in
            let id = UUID()
            // Now only a Wi-Fi network; an earlier version held the card.
            try await f.seed([cardAccount(id: id)])
            try await f.replace([wifiAccount(id: id)])

            try await f.model.openHistory(accountID: id)
            #expect(f.verifier.calls == 0, "the stored credential holds nothing sensitive, so the editor opened without a prompt")
            #expect(f.model.history?.revealsSecrets == false)

            try await f.model.revealHistorySecrets()
            #expect(f.verifier.calls == 1)
            #expect(f.model.history?.revealsSecrets == true)

            try await f.model.copy(Self.numberPart, of: .version)
            #expect(f.verifier.calls == 2)
            #expect(f.text == SecureItemFixtures.cardNumber)
            #expect(f.isConcealed)

            // A failed answer shows and copies nothing.
            f.model.hideHistorySecrets()
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed
            let sentinel = f.sentinel()
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.revealHistorySecrets() }
            #expect(f.model.history?.revealsSecrets == false)
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.copy(Self.numberPart, of: .version) }
            #expect(f.text == sentinel)
            #expect(!f.isConcealed)
        }
    }

    @Test func historyOfACredentialWithoutACardNeverPrompts() async throws {
        try await withFixture { f in
            let id = UUID()
            try await f.seed([wifiAccount(id: id, passphrase: "synthetic-old-passphrase")])
            try await f.replace([wifiAccount(id: id)])
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed

            try await f.model.openHistory(accountID: id)
            try await f.model.revealHistorySecrets()
            #expect(f.model.history?.revealsSecrets == true)
            try await f.model.copy(Self.passphrasePart, of: .version)
            #expect(f.text == "synthetic-old-passphrase")
            #expect(f.isConcealed)
            #expect(f.verifier.calls == 0)
        }
    }

    // MARK: - Hiding and locking

    @Test func hidingSecretsClearsTheRevealedItems() async throws {
        try await withFixture { f in
            let stored = wifiAccount()
            try await f.seed([stored])
            try await f.model.revealSecureItems(accountID: stored.id)
            #expect(f.model.revealedItems != nil)

            f.model.hideSecrets()
            #expect(f.model.revealedItems == nil)
        }
    }

    @Test(arguments: secureItemLockReasons)
    func aLockDropsTheRevealedItems(reason: CredentialLockReason) async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])
            try await f.model.revealSecureItems(accountID: stored.id)
            #expect(f.model.revealedItems != nil)

            f.manager.lock(reason: reason)
            #expect(f.model.revealedItems == nil)
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.revealSecureItems(accountID: stored.id) }
            #expect(f.verifier.calls == 1, "a locked vault asks for nothing")

            // A new unlock is a new authorization: nothing shown before the lock may reappear.
            try await VaultManagerFixture.unlock(f.vault)
            #expect(f.model.revealedItems == nil)
            await f.model.load()
            #expect(f.model.revealedItems == nil)
        }
    }

    @Test func lockingFromThePageDropsTheRevealedItems() async throws {
        try await withFixture { f in
            let stored = cardAccount()
            try await f.seed([stored])
            try await f.model.revealSecureItems(accountID: stored.id)
            #expect(f.model.revealedItems != nil)

            f.model.lock()
            #expect(f.model.revealedItems == nil)
            #expect(!f.manager.isUnlocked)
        }
    }
}
