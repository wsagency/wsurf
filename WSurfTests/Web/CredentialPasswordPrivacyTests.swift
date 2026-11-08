// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// Model-level checks of the device-owner prompt (Touch ID) before a saved password or verification code is shown or copied in the
// Credential Manager: every time from the list, once per editor (its History included), and before the vault is read. The prompt is
// a counting stub that can fail and can act while it is up; test-only in-memory unlock keys and a private pasteboard are used, so
// nothing here touches the general pasteboard, a real vault, the Keychain or a native ceremony. Every value is synthetic.

@MainActor
struct CredentialPasswordPrivacyTests {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// RFC 6238 appendix B SHA-1 seed; eight digits. At 59 s the code is 94287082.
    private static let rfcSeed = Data("12345678901234567890".utf8)

    /// The reasons the prompt gives, as the model words them.
    private enum Reason {
        static let showPassword = String(localized: "show a saved password")
        static let copyPassword = String(localized: "copy a saved password")
        static let showCode = String(localized: "show a verification code")
        static let copyCode = String(localized: "copy a verification code")
        static let editor = String(localized: "show or copy a saved password or verification code")
        static let items = String(localized: "show saved cards, documents and hidden fields")
        static let historyWithItems = String(localized: "show saved passwords, cards and documents")
    }

    /// Stands in for Touch ID: records each reason, fails when told to, and runs `whileAsking` once, as if while the prompt is up.
    @MainActor
    private final class Verifier {
        private(set) var reasons: [String] = []
        var failure: (any Error)?
        var whileAsking: (@MainActor () async throws -> Void)?

        var calls: Int {
            reasons.count
        }

        func verify(_ reason: String) async throws {
            reasons.append(reason)
            if let action = whileAsking {
                whileAsking = nil
                try await action()
            }
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
            let profile = Profile(id: UUID(), name: "Password privacy", symbol: "key", color: .blue)
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
            pasteboard.types?.contains(CredentialPasswordPrivacyTests.concealed) == true
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

    private var generator: TOTPGenerator {
        TOTPGenerator(secret: Self.rfcSeed, algorithm: .sha1, period: 30, digits: 8, issuer: "Example", userName: "ada")
    }

    private func login(
        id: UUID = UUID(), displayName: String? = nil, password: String?, totp: TOTPGenerator? = nil
    ) -> CredentialAccount {
        CredentialAccount(
            id: id, username: "ada", displayName: displayName, origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!], password: password, passkeys: [], totp: totp,
            exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    // MARK: - The list: every time, before the read

    @Test func everyShowAndCopyOfAPasswordOrCodeAsksEachTime() async throws {
        try await withFixture { f in
            let stored = login(password: "list-secret", totp: generator)
            try await f.seed([stored])

            try await f.model.revealPassword(accountID: stored.id)
            #expect(f.model.revealedPassword?.value == "list-secret")
            f.model.hideSecrets()
            try await f.model.revealPassword(accountID: stored.id)
            try await f.model.showTOTP(accountID: stored.id)
            #expect(f.model.totpCode(now: 59)?.value == "94287082")
            try await f.model.copyPassword(accountID: stored.id)
            #expect(f.text == "list-secret" && f.isConcealed)
            try await f.model.copyTOTP(accountID: stored.id) { 59 }
            #expect(f.text == "94287082" && f.isConcealed)
            try await f.model.copy(.password, of: .stored(stored.id))

            #expect(f.verifier.reasons == [
                Reason.showPassword, Reason.showPassword, Reason.showCode, Reason.copyPassword, Reason.copyCode, Reason.copyPassword,
            ])
            // What is not a password or a code still copies without a prompt.
            try await f.model.copy(.username, of: .stored(stored.id))
            try await f.model.copy(.codeLabel, of: .stored(stored.id))
            #expect(f.verifier.calls == 6)
        }
    }

    @Test func aRefusedPromptShowsAndCopiesNothing() async throws {
        try await withFixture { f in
            let stored = login(password: "refused-secret", totp: generator)
            try await f.seed([stored])
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed
            let sentinel = f.sentinel()

            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.revealPassword(accountID: stored.id) }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.showTOTP(accountID: stored.id) }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.copyPassword(accountID: stored.id) }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.copyTOTP(accountID: stored.id) { 59 } }
            #expect(f.verifier.calls == 4)
            #expect(f.model.revealedPassword == nil && f.model.shownTOTPAccountID == nil && f.model.totpCode(now: 59) == nil)
            #expect(f.text == sentinel && !f.isConcealed)
            #expect(f.model.notice == nil)
        }
    }

    /// A value changed while the prompt is up is the one that is copied: nothing was read before the answer.
    @Test func theVaultIsReadOnlyAfterTheAnswer() async throws {
        try await withFixture { f in
            let stored = login(password: "before-the-prompt", totp: generator)
            try await f.seed([stored])
            var changed = stored
            changed.password = "after-the-prompt"
            f.verifier.whileAsking = { [changed] in try await VaultManagerFixture.save([changed], in: f.vault) }
            try await f.model.copyPassword(accountID: stored.id)
            #expect(f.text == "after-the-prompt")

            var other = generator
            other.secret = Data("ABCDEFGHIJKLMNOPQRST".utf8)
            changed.totp = other
            f.verifier.whileAsking = { [changed] in try await VaultManagerFixture.save([changed], in: f.vault) }
            try await f.model.copyTOTP(accountID: stored.id) { 59 }
            let newCode = try TOTP.code(other, at: 59).value
            #expect(newCode != "94287082")
            #expect(f.text == newCode)
            #expect(f.verifier.calls == 2)
        }
    }

    @Test func aLockedVaultAsksForNothing() async throws {
        try await withFixture { f in
            let stored = login(password: "locked-secret", totp: generator)
            try await f.seed([stored])
            f.manager.lock(reason: .manual)
            let sentinel = f.sentinel()

            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.revealPassword(accountID: stored.id) }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.showTOTP(accountID: stored.id) }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copyPassword(accountID: stored.id) }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copyTOTP(accountID: stored.id) { 59 } }
            #expect(f.verifier.calls == 0)
            #expect(f.text == sentinel)
        }
    }

    /// An answer given under one unlock reads nothing under the next, and nothing at all once the vault locked.
    @Test func aLockOrANewUnlockWhileThePromptIsUpReadsNothing() async throws {
        try await withFixture { f in
            let stored = login(password: "lock-during-prompt")
            try await f.seed([stored])
            let sentinel = f.sentinel()

            f.verifier.whileAsking = { f.manager.lock(reason: .manual) }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copyPassword(accountID: stored.id) }
            #expect(f.text == sentinel)

            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            f.verifier.whileAsking = {
                f.manager.lock(reason: .manual)
                try await VaultManagerFixture.unlock(f.vault)
            }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.revealPassword(accountID: stored.id) }
            #expect(f.model.revealedPassword == nil)
            #expect(f.verifier.calls == 2)
        }
    }

    @Test func aCancelledTaskAsksForNothing() async throws {
        try await withFixture { f in
            let stored = login(password: "cancelled-secret", totp: generator)
            try await f.seed([stored])
            let model = f.model
            let operations: [@MainActor () async throws -> Void] = [
                { try await model.revealPassword(accountID: stored.id) },
                { try await model.showTOTP(accountID: stored.id) },
                { try await model.copyPassword(accountID: stored.id) },
                { try await model.copyTOTP(accountID: stored.id) { 59 } },
            ]
            for operation in operations {
                let task = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await operation()
                }
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            #expect(f.verifier.calls == 0)
        }
    }

    // MARK: - The editor: once per editor

    @Test func theEditorOfAStoredCredentialAsksOnceForItsPasswordAndCode() async throws {
        try await withFixture { f in
            let stored = login(password: "editor-secret", totp: generator)
            try await f.seed([stored])

            try await f.model.beginEditing(accountID: stored.id)
            #expect(f.verifier.calls == 0, "opening the editor asks for nothing")
            #expect(!f.model.editorIsVerified)

            try await f.model.copy(.password, of: .draft)
            #expect(f.text == "editor-secret" && f.isConcealed)
            #expect(f.model.editorIsVerified)
            try await f.model.copy(.code, of: .draft) { 59 }
            #expect(f.text == "94287082" && f.isConcealed)
            // The password field's Show and the code's Show Code ask through the same check.
            try await f.model.verifyEditor()
            #expect(f.verifier.reasons == [Reason.editor])

            // Typing stays in the same editor; closing it ends the answer.
            f.model.draft?.username = "typed"
            #expect(f.model.editorIsVerified)
            f.model.cancelEditing()
            try await f.model.beginEditing(accountID: stored.id)
            #expect(!f.model.editorIsVerified)
            try await f.model.copy(.password, of: .draft)
            #expect(f.verifier.calls == 2)
        }
    }

    @Test func aNewCredentialsEditorNeverAsks() async throws {
        try await withFixture { f in
            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            try await f.model.beginEditing(accountID: nil)
            f.model.draft?.password = "typed-for-a-new-credential"
            #expect(f.model.editorIsVerified)
            try await f.model.verifyEditor()
            try await f.model.copy(.password, of: .draft)
            #expect(f.text == "typed-for-a-new-credential")
            #expect(f.verifier.calls == 0)
        }
    }

    /// An edit can keep most of the stored password, so what the field holds asks like the stored value.
    @Test func aPasswordTypedInAStoredCredentialsEditorStillAsksOnce() async throws {
        try await withFixture { f in
            let stored = login(password: "stored-before-typing")
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            f.model.draft?.password = "stored-before-typin"
            try await f.model.copy(.password, of: .draft)
            #expect(f.text == "stored-before-typin")
            #expect(f.verifier.reasons == [Reason.editor])
        }
    }

    @Test func aRefusedEditorPromptCopiesNothingAndAsksAgainNextTime() async throws {
        try await withFixture { f in
            let stored = login(password: "refused-in-editor", totp: generator)
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed
            let sentinel = f.sentinel()

            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.copy(.password, of: .draft) }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.copy(.code, of: .draft) { 59 } }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.verifyEditor() }
            #expect(f.text == sentinel && !f.model.editorIsVerified)

            f.verifier.failure = nil
            try await f.model.verifyEditor()
            #expect(f.model.editorIsVerified && f.verifier.calls == 4)
        }
    }

    @Test func anEditorReplacedWhileThePromptIsUpIsNotVerified() async throws {
        try await withFixture { f in
            let stored = login(password: "replaced-during-prompt")
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            let sentinel = f.sentinel()
            f.verifier.whileAsking = {
                f.model.cancelEditing()
                try await f.model.beginEditing(accountID: stored.id)
            }

            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copy(.password, of: .draft) }
            #expect(f.text == sentinel)
            #expect(f.model.draft != nil && !f.model.editorIsVerified, "the editor that opened meanwhile was not asked for")
        }
    }

    /// The prompt that opened a card's editor is that editor's one prompt for its password and code as well.
    @Test func theEditorOfACardAsksOnceForItsCardsAndItsPassword() async throws {
        try await withFixture { f in
            var stored = login(password: "card-login-secret")
            stored.secureItems = [SecureItemFixtures.card(name: "Synthetic Holder")]
            try await f.seed([stored])

            try await f.model.beginEditing(accountID: stored.id)
            #expect(f.verifier.reasons == [Reason.items])
            #expect(f.model.editorIsVerified)
            try await f.model.copy(.password, of: .draft)
            #expect(f.text == "card-login-secret")
            #expect(f.verifier.calls == 1)
        }
    }

    // MARK: - History: the editor's prompt

    @Test func historySharesTheEditorsOnePrompt() async throws {
        try await withFixture { f in
            let id = UUID()
            try await f.seed([login(id: id, password: "history-old")])
            try await f.replace([login(id: id, password: "history-new")])
            try await f.model.openHistory(accountID: id)
            #expect(f.verifier.calls == 0)

            try await f.model.revealHistorySecrets()
            #expect(f.model.history?.revealsSecrets == true)
            #expect(f.verifier.reasons == [Reason.editor])
            f.model.hideHistorySecrets()
            try await f.model.revealHistorySecrets()
            try await f.model.copy(.password, of: .version)
            #expect(f.text == "history-old")
            try await f.model.copy(.password, of: .draft)
            #expect(f.text == "history-new")
            #expect(f.verifier.calls == 1)
        }
    }

    @Test func aCopyFromHistoryIsTheEditorsPromptToo() async throws {
        try await withFixture { f in
            let id = UUID()
            try await f.seed([login(id: id, password: "copied-old")])
            try await f.replace([login(id: id, password: "copied-new")])
            try await f.model.openHistory(accountID: id)

            try await f.model.copy(.password, of: .version)
            #expect(f.text == "copied-old")
            try await f.model.revealHistorySecrets()
            #expect(f.verifier.reasons == [Reason.editor])
        }
    }

    @Test func aRefusedHistoryPromptShowsNothing() async throws {
        try await withFixture { f in
            let id = UUID()
            try await f.seed([login(id: id, password: "refused-old")])
            try await f.replace([login(id: id, password: "refused-new")])
            try await f.model.openHistory(accountID: id)
            f.verifier.failure = WebsiteAuthenticatorError.notAllowed

            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.revealHistorySecrets() }
            #expect(f.model.history?.revealsSecrets == false && !f.model.editorIsVerified)
        }
    }

    /// One prompt covers an earlier card and the passwords, and a verified editor never stands in for the card the next time.
    @Test func historyWithACardAndAPasswordAsksOnceForBothAndForTheCardEachTime() async throws {
        try await withFixture { f in
            let id = UUID()
            var withCard = login(id: id, password: "card-era-password")
            withCard.secureItems = [SecureItemFixtures.card(name: "Synthetic Holder")]
            try await f.seed([withCard])
            // Now only a Wi-Fi network, which opens with the vault's unlock alone; an earlier version held the card.
            var withoutCard = login(id: id, password: "no-card-password")
            withoutCard.secureItems = [SecureItemFixtures.wifi()]
            try await f.replace([withoutCard])
            try await f.model.openHistory(accountID: id)
            #expect(f.verifier.calls == 0, "the stored credential holds no card, so the editor opened without a prompt")

            try await f.model.revealHistorySecrets()
            #expect(f.verifier.reasons == [Reason.historyWithItems])
            #expect(f.model.editorIsVerified)
            try await f.model.copy(.password, of: .draft)
            #expect(f.verifier.calls == 1)

            f.model.hideHistorySecrets()
            try await f.model.revealHistorySecrets()
            #expect(f.verifier.reasons == [Reason.historyWithItems, Reason.items])
        }
    }
}
