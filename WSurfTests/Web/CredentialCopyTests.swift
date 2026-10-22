// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CryptoKit
import Foundation
import Testing

@testable import WSurf

// Model-level checks of copying a credential's values from the list, the editor and History. Test-only in-memory unlock keys and a
// private pasteboard; nothing here touches the general pasteboard, a real vault or a native ceremony.

@MainActor
struct CredentialCopyTests {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// RFC 6238 appendix B SHA-1 seed; eight digits. At 59 s the code is 94287082.
    private static let rfcSeed = Data("12345678901234567890".utf8)

    private final class Fixture {
        let profile: Profile
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
        let vault: FixtureVault
        let model: CredentialSettingsModel

        @MainActor init(noticeDuration: Duration = .seconds(60), undoNoticeDuration: Duration = .seconds(60)) async throws {
            let profile = Profile(id: UUID(), name: "Copy", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.locked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(
                profile: profile, pasteboard: pasteboard, manager: vault.manager, noticeDuration: noticeDuration,
                undoNoticeDuration: undoNoticeDuration
            )
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
            pasteboard.types?.contains(CredentialCopyTests.concealed) == true
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(
        noticeDuration: Duration = .seconds(60), undoNoticeDuration: Duration = .seconds(60), _ body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture(noticeDuration: noticeDuration, undoNoticeDuration: undoNoticeDuration)
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private var generator: TOTPGenerator {
        TOTPGenerator(secret: Self.rfcSeed, algorithm: .sha1, period: 30, digits: 8, issuer: "Example", userName: "ada")
    }

    private func account(
        id: UUID = UUID(), username: String = "ada", displayName: String? = nil, password: String? = "pw",
        passkeys: [WebsitePasskey] = [], totp: TOTPGenerator? = nil
    ) -> CredentialAccount {
        CredentialAccount(
            id: id, username: username, displayName: displayName, origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!], password: password, passkeys: passkeys, totp: totp,
            exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func passkey(_ seed: UInt8) throws -> WebsitePasskey {
        WebsitePasskey(
            id: UUID(), credentialID: Data(repeating: seed, count: 32), rpID: "example.test", userHandle: Data([seed]), userName: "grace",
            userDisplayName: "Grace", algorithm: -7, privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: true, backupState: false, exchangeFIDO2Metadata: nil
        )
    }

    // MARK: - Stored credential (the list row)

    @Test func everyPartOfAStoredCredentialCopiesItsOwnValue() async throws {
        try await withFixture { f in
            let key = try passkey(1)
            var stored = account(displayName: "Work", password: "s3cret", passkeys: [key], totp: generator)
            stored.origins.append("https://cdn.example.test")
            stored.notes = [CredentialNote(text: "recovery note", field: nil)]
            try await f.seed([stored])

            let plain: [(CredentialCopyPart, String)] = [
                (.name, "Work"), (.username, "ada"), (.website(0), "https://example.test/login"),
                (.website(1), "https://cdn.example.test"), (.codeLabel, "Example · ada"),
                (.passkeyUser(key.id), "grace"), (.passkeyWebsite(key.id), "example.test"),
            ]
            for (part, expected) in plain {
                // A secret first, so a plain copy proves it takes the concealed marker off the pasteboard.
                try await f.model.copy(.password, of: .stored(stored.id))
                #expect(f.isConcealed)
                try await f.model.copy(part, of: .stored(stored.id))
                #expect(f.text == expected, "\(part)")
                #expect(!f.isConcealed, "\(part) is not a secret")
            }

            let secrets: [(CredentialCopyPart, String)] = [(.password, "s3cret"), (.note(0), "recovery note"), (.code, "94287082")]
            for (part, expected) in secrets {
                try await f.model.copy(part, of: .stored(stored.id)) { 59 }
                #expect(f.text == expected, "\(part)")
                #expect(f.isConcealed, "\(part) is a secret")
            }
        }
    }

    @Test func aConcealedUsernameCopiesAsASecret() async throws {
        try await withFixture { f in
            var stored = account(username: "ada@corp", password: "pw")
            let field = CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
            stored.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(username: field, password: field)
            try await f.seed([stored])

            try await f.model.copy(.username, of: .stored(stored.id))
            #expect(f.text == "ada@corp")
            #expect(f.isConcealed)
        }
    }

    @Test func theExistingPasswordAndCodeCopiesStillUseTheSharedPath() async throws {
        try await withFixture { f in
            let stored = account(password: "second-password", totp: generator)
            try await f.seed([stored])

            try await f.model.copyPassword(accountID: stored.id)
            #expect(f.text == "second-password" && f.isConcealed)
            try await f.model.copyTOTP(accountID: stored.id) { 59 }
            #expect(f.text == "94287082" && f.isConcealed)
        }
    }

    @Test func aPartTheCredentialLacksCopiesNothing() async throws {
        try await withFixture { f in
            let stored = account(password: nil)
            try await f.seed([stored])
            let sentinel = f.sentinel()

            let missing: [CredentialCopyPart] = [
                .name, .password, .website(7), .note(0), .code, .codeLabel, .passkeyUser(UUID()), .passkeyWebsite(UUID()),
            ]
            for part in missing {
                await #expect(throws: CredentialVaultError.invalidData) { try await f.model.copy(part, of: .stored(stored.id)) }
            }
            await #expect(throws: CredentialVaultError.invalidData) { try await f.model.copy(.username, of: .stored(UUID())) }
            #expect(f.text == sentinel)
        }
    }

    // MARK: - Locked and stale

    @Test func aLockedVaultCopiesNothingFromAnySource() async throws {
        try await withFixture { f in
            let stored = account()
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            f.vault.manager.lock(reason: .manual)
            let sentinel = f.sentinel()

            for source in [CredentialCopySource.stored(stored.id), .draft, .version] {
                await #expect(throws: (any Error).self) { try await f.model.copy(.username, of: source) }
                await #expect(throws: (any Error).self) { try await f.model.copy(.password, of: source) }
            }
            #expect(f.text == sentinel)
            #expect(f.model.notice == nil)
        }
    }

    @Test func aDraftOrVersionFromAnEarlierUnlockCopiesNothing() async throws {
        try await withFixture { f in
            let id = UUID()
            try await f.seed([account(id: id, password: "old")])
            try await f.replace([account(id: id, password: "new")])
            try await f.model.openHistory(accountID: id)
            #expect(f.model.history != nil)

            // A new unlock is a new authorization: the session that held the draft and History is gone, so neither copies,
            // even though the vault is open again.
            f.vault.manager.lock(reason: .manual)
            try await VaultManagerFixture.unlock(f.vault)
            let sentinel = f.sentinel()
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copy(.password, of: .draft) }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copy(.password, of: .version) }
            #expect(f.text == sentinel)
        }
    }

    @Test func anAuthorizationThatEndsWhileTheValueIsProducedNeverReachesThePasteboard() async throws {
        try await withFixture { f in
            let stored = account(totp: generator)
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            let sentinel = f.sentinel()
            let manager = f.vault.manager

            // The clock is read while the code is produced, after every suspension; the vault locks there.
            for source in [CredentialCopySource.stored(stored.id), .draft] {
                await #expect(throws: CredentialVaultError.unauthorized) {
                    try await f.model.copy(.code, of: source) {
                        manager.lock(reason: .manual)
                        return 59
                    }
                }
                #expect(f.text == sentinel)
                try await VaultManagerFixture.unlock(f.vault)
                await f.model.load()
                try await f.model.beginEditing(accountID: stored.id)
            }
            #expect(f.model.notice == nil)
        }
    }

    @Test func aCancelledCopyLeavesThePasteboardAlone() async throws {
        try await withFixture { f in
            let stored = account()
            try await f.seed([stored])
            let sentinel = f.sentinel()
            let model = f.model

            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try await model.copy(.username, of: .stored(stored.id))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(f.text == sentinel)
        }
    }

    // MARK: - Editor draft

    @Test func theEditorCopiesWhatIsTypedBeforeItIsSaved() async throws {
        try await withFixture { f in
            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            try await f.model.beginEditing(accountID: nil)
            f.model.draft?.displayName = "Typed"
            f.model.draft?.username = "typed-user"
            f.model.draft?.password = "typed-pw"
            f.model.draft?.websites = "https://a.test/x\n  https://b.test  "
            f.model.draft?.extraOrigins = "https://c.test"
            f.model.draft?.addNote()
            f.model.draft?.notes[0].text = "typed note"

            let plain: [(CredentialCopyPart, String)] = [
                (.name, "Typed"), (.username, "typed-user"), (.website(0), "https://a.test/x"), (.website(1), "https://b.test"),
                (.website(2), "https://c.test"),
            ]
            for (part, expected) in plain {
                try await f.model.copy(part, of: .draft)
                #expect(f.text == expected)
                #expect(!f.isConcealed)
            }
            for (part, expected) in [(CredentialCopyPart.password, "typed-pw"), (.note(0), "typed note")] {
                try await f.model.copy(part, of: .draft)
                #expect(f.text == expected)
                #expect(f.isConcealed)
            }
            // Nothing was stored by copying.
            #expect(try await f.vault.manager.snapshot().accounts.isEmpty)
        }
    }

    @Test func theEditorCopiesTheCurrentCodeOfItsDraft() async throws {
        try await withFixture { f in
            let stored = account(totp: generator)
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)

            try await f.model.copy(.code, of: .draft) { 1_111_111_109 }
            #expect(f.text == "07081804" && f.isConcealed)
            try await f.model.copy(.codeLabel, of: .draft)
            #expect(f.text == "Example · ada" && !f.isConcealed)
        }
    }

    // MARK: - History

    @Test func historyCopiesEverythingItShowsAndAddsNothingToTheVault() async throws {
        try await withFixture { f in
            let id = UUID()
            let kept = [CredentialNote(text: "old note", field: nil)]
            var first = account(id: id, displayName: "Old name", password: "old")
            first.notes = kept
            var second = account(id: id, displayName: "New name", password: "new")
            second.notes = kept
            try await f.seed([first])
            try await f.replace([second])
            try await f.model.openHistory(accountID: id)
            let before = try await f.vault.manager.snapshot()

            let plain: [(CredentialCopyPart, String)] = [
                (.name, "Old name"), (.username, "ada"), (.website(0), "https://example.test/login"),
            ]
            for (part, expected) in plain {
                try await f.model.copy(part, of: .version)
                #expect(f.text == expected)
                #expect(!f.isConcealed)
            }
            // Masked or shown, a secret is read under the current unlock and carries the concealed marker.
            for shown in [false, true] {
                if shown {
                    try await f.model.revealHistorySecrets()
                }
                try await f.model.copy(.password, of: .version)
                #expect(f.text == "old" && f.isConcealed)
                try await f.model.copy(.note(0), of: .version)
                #expect(f.text == "old note" && f.isConcealed)
            }
            // The "Current" lines are the draft's values.
            try await f.model.copy(.password, of: .draft)
            #expect(f.text == "new" && f.isConcealed)
            try await f.model.copy(.name, of: .draft)
            #expect(f.text == "New name" && !f.isConcealed)

            let after = try await f.vault.manager.snapshot()
            #expect(after.revision == before.revision && after.accounts == before.accounts)
            #expect(f.model.history?.shown?.account.password == "old", "copying does not change what History shows")
        }
    }

    @Test func historyNeverCopiesAVerificationCodeOrItsSetupKey() async throws {
        try await withFixture { f in
            let id = UUID()
            var other = generator
            other.secret = Data("ABCDEFGHIJKLMNOPQRST".utf8)
            try await f.seed([account(id: id, totp: generator)])
            try await f.replace([account(id: id, totp: other)])
            try await f.model.openHistory(accountID: id)
            #expect(f.model.history?.shown?.account.totp == generator, "the earlier version does hold the old key")
            try await f.model.revealHistorySecrets()

            let sentinel = f.sentinel()
            await #expect(throws: CredentialVaultError.invalidData) { try await f.model.copy(.code, of: .version) { 59 } }
            #expect(f.text == sentinel)

            let seed = String(decoding: Self.rfcSeed, as: UTF8.self)
            var copied: [String] = []
            let parts: [CredentialCopyPart] = [.name, .username, .password, .website(0), .note(0), .codeLabel, .code]
            for part in parts {
                _ = try? await f.model.copy(part, of: .version) { 59 }
                copied.append(f.text ?? "")
            }
            #expect(copied.allSatisfy { !$0.contains(seed) && $0 != "94287082" })
            #expect(copied.contains("Example · ada"), "only the issuer and account can be copied")
        }
    }

    // MARK: - Confirmation

    @Test func aCopyConfirmsBrieflyByNameAndNeverShowsTheValue() async throws {
        try await withFixture(noticeDuration: .milliseconds(1)) { f in
            let stored = account(password: "very-secret-value")
            try await f.seed([stored])
            #expect(f.model.notice == nil)

            try await f.model.copyPassword(accountID: stored.id)
            #expect(f.model.notice?.text == String(localized: "Password Copied"))
            #expect(f.model.notice?.text.contains("very-secret-value") == false)
            #expect(await waitUntil { f.model.notice == nil })

            await #expect(throws: (any Error).self) { try await f.model.copy(.name, of: .stored(stored.id)) }
            #expect(f.model.notice == nil, "a refused copy confirms nothing")
        }
    }

    @Test func theLatestCopyWinsTheConfirmation() async throws {
        try await withFixture { f in
            let stored = account()
            try await f.seed([stored])

            try await f.model.copy(.password, of: .stored(stored.id))
            try await f.model.copy(.website(0), of: .stored(stored.id))
            #expect(f.model.notice?.text == String(localized: "Website Copied"))
        }
    }

    @Test func aNoticeThatOffersUndoIsShownLongerAndTheLatestNoticeWins() async throws {
        try await withFixture(noticeDuration: .milliseconds(1)) { f in
            f.model.showNotice("Moved 2 credentials to Trash.", undo: true)
            #expect(f.model.notice?.offersUndo == true)
            #expect(f.model.notice?.text == String(localized: "Moved 2 credentials to Trash."))
            // It lasts the undo time (a minute here), not the copy time (a millisecond).
            f.model.showNotice("Moved 3 credentials to Trash.", undo: true)
            #expect(f.model.notice?.text == String(localized: "Moved 3 credentials to Trash."))
            f.model.showNotice("Website Copied")
            #expect(f.model.notice?.offersUndo == false, "a copy notice never offers Undo")
            #expect(await waitUntil { f.model.notice == nil })
            f.model.showNotice("Gone soon", undo: true, duration: .milliseconds(1))
            #expect(await waitUntil { f.model.notice == nil })
        }
    }

    // MARK: - Parts without a vault

    @Test func theEditorsWebsiteLinesKeepTheirOrderAndDropBlanks() {
        var draft = CredentialDraft(editing: nil, revision: 0)
        draft.websites = " https://a.test/x \n\nhttps://b.test"
        draft.extraOrigins = "\nhttps://c.test\n"
        #expect(CredentialCopyParts.websiteLines(of: draft) == ["https://a.test/x", "https://b.test", "https://c.test"])
    }

    @Test func partsSayWhichValuesAreSecrets() throws {
        var stored = account(displayName: "Work", password: "pw", totp: generator)
        stored.notes = [CredentialNote(text: "note", field: nil)]
        let parts = CredentialCopyParts(stored)
        let expected: [(CredentialCopyPart, Bool)] = [
            (.name, false), (.username, false), (.password, true), (.website(0), false), (.note(0), true), (.code, true), (.codeLabel, false),
        ]
        for (part, secret) in expected {
            #expect(try parts.value(of: part) { 59 }.isSecret == secret, "\(part)")
        }
    }

    @Test func anEarlierVersionCarriesNoSetupKeyToCopy() throws {
        let stored = account(totp: generator)
        let version = CredentialCopyParts(stored, allowsCode: false)
        #expect(throws: CredentialVaultError.invalidData) { try version.value(of: .code) { 59 } }
        #expect(try version.value(of: .codeLabel) { 59 } == CredentialCopyValue(text: "Example · ada", isSecret: false))
        #expect(try CredentialCopyParts(stored).value(of: .code) { 59 }.text == "94287082")
    }
}
