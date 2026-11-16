// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// One Touch ID confirmation, then 30 seconds in which the Passwords popover and window copy without asking again (`CopyGrace`). The
/// confirmation is a fake that counts; no test reaches Touch ID. Everything that is not a copy from the list asks as before.
@MainActor
@Suite(.serialized)
struct CopyGraceTests {
    private final class Prompt {
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

    private struct Rig {
        let prompt: Prompt
        let clock: TestClock
        let pasteboard: NSPasteboard
        let grace: CopyGrace
        let model: CredentialSettingsModel
        let vault: FixtureVault
        let account: CredentialAccount

        var text: String? {
            pasteboard.string(forType: .string)
        }

        var holds: Bool {
            grace.holds(vault.vaultID)
        }
    }

    private static let seed = Data("12345678901234567890".utf8)

    /// A rig over an unlocked fixture vault with one login that has a password and a code. `withGrace: false` is a model like the
    /// settings tests' and autofill's: no window.
    private func withRig(
        withGrace: Bool = true, unlocked: Bool = true, _ body: (Rig, Profile) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, _, vaults in
            let vault = try #require(vaults.first)
            var account = VaultFixtures.account(password: "pw-secret")
            account.totp = TOTPGenerator(secret: Self.seed, algorithm: .sha1, period: 30, digits: 8, issuer: "Example", userName: "ada")
            let prompt = Prompt()
            let clock = TestClock()
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let grace = CopyGrace(now: { clock.now })
            let model = CredentialSettingsModel(
                profile: profile, pasteboard: pasteboard, manager: vault.manager, verifyUser: { try await prompt.verify($0) }, clock: clock
            )
            if withGrace {
                model.copyGrace = grace
            }
            if unlocked {
                try await VaultManagerFixture.unlock(vault)
                try await VaultManagerFixture.save([account], in: vault)
            }
            await model.load()
            let rig = Rig(prompt: prompt, clock: clock, pasteboard: pasteboard, grace: grace, model: model, vault: vault, account: account)
            try await body(rig, profile)
        }
    }

    private func copyPassword(_ rig: Rig) async throws {
        try await rig.model.copy(.password, of: .stored(rig.account.id))
    }

    // MARK: One confirmation, then the window

    @Test func oneConfirmationThenCopiesWithinThirtySecondsAskNothing() async throws {
        try await withRig { rig, _ in
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 1)
            #expect(rig.text == "pw-secret")

            // The username (the second copy a login needs), the password again, a code: all inside the window.
            rig.clock.advance(by: .seconds(5))
            try await rig.model.copy(.username, of: .stored(rig.account.id))
            #expect(rig.text == "ada")
            rig.clock.advance(by: .seconds(5))
            try await copyPassword(rig)
            #expect(rig.text == "pw-secret")
            try await rig.model.copy(.code, of: .stored(rig.account.id)) { 59 }
            #expect(rig.text == "94287082")

            #expect(rig.prompt.calls == 1, "one prompt for the whole run")
        }
    }

    @Test func aCopyAfterThirtyOneSecondsAsksAgain() async throws {
        try await withRig { rig, _ in
            try await copyPassword(rig)
            rig.clock.advance(by: .seconds(29))
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 1, "29 s: still inside")

            rig.clock.advance(by: .seconds(2))
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 2, "31 s after the confirmation: asks")
            #expect(rig.text == "pw-secret")
        }
    }

    /// The window is fixed: a copy inside it does not push its end out.
    @Test func aCopyInsideTheWindowDoesNotExtendIt() async throws {
        try await withRig { rig, _ in
            try await copyPassword(rig)
            rig.clock.advance(by: .seconds(20))
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 1)

            rig.clock.advance(by: .seconds(11))
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 2, "31 s after the confirmation, though a copy was made at 20 s")
        }
    }

    @Test func aRefusedConfirmationBeginsNoWindow() async throws {
        try await withRig { rig, _ in
            rig.prompt.failure = WebsiteAuthenticatorError.notAllowed
            await #expect(throws: WebsiteAuthenticatorError.self) { try await copyPassword(rig) }
            #expect(!rig.holds)

            rig.prompt.failure = nil
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 2)
            #expect(rig.holds)
        }
    }

    @Test func aModelWithoutAWindowAsksEveryTime() async throws {
        try await withRig(withGrace: false) { rig, _ in
            try await copyPassword(rig)
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 2)
            #expect(!rig.holds)
        }
    }

    // MARK: Ending the window

    /// The window ends the moment the vault locks, by name and not only by its epoch: it is gone before anything is copied.
    @Test(arguments: LockTrigger.allCases)
    func everyLockEventEndsTheWindowAtOnce(trigger: LockTrigger) async throws {
        try await VaultManagerFixture.exclusive {
            try await withRig { rig, profile in
                try await copyPassword(rig)
                #expect(rig.holds && rig.prompt.calls == 1)

                trigger.fire(for: profile)

                let locked = await waitUntil { !rig.vault.manager.isUnlocked }
                #expect(locked)
                #expect(!rig.holds, "\(trigger): the window is cancelled, not left to run out")

                // Unlocked again, the next copy is a new confirmation.
                try await VaultManagerFixture.unlock(rig.vault)
                await rig.model.load()
                try await copyPassword(rig)
                #expect(rig.prompt.calls == 2, "\(trigger): asks again")
            }
        }
    }

    /// A window of an unlock that is gone is never honoured, even if nothing ended it by name.
    @Test func aWindowIsBoundToTheUnlockItWasGivenUnder() async throws {
        try await withRig { rig, _ in
            try await copyPassword(rig)
            let old = try #require(rig.vault.manager.authorizationEpoch)
            rig.vault.manager.lock(reason: .manual)
            // Put back a window of the old unlock, as a lock that missed the hook would leave it.
            rig.grace.begin(for: rig.vault.manager, epoch: old)
            try await VaultManagerFixture.unlock(rig.vault)
            await rig.model.load()

            try await copyPassword(rig)

            #expect(rig.prompt.calls == 2)
        }
    }

    // MARK: Where it begins and where it does not apply

    @Test func aSuccessfulUnlockInThePasswordsUIIsTheConfirmation() async throws {
        try await withRig(unlocked: false) { rig, _ in
            await rig.model.unlock(in: VaultManagerFixture.anchor())
            #expect(rig.vault.manager.isUnlocked && rig.holds)
            try await VaultManagerFixture.save([rig.account], in: rig.vault)
            await rig.model.load()

            try await copyPassword(rig)

            #expect(rig.prompt.calls == 0, "the passkey with user verification just confirmed")
            #expect(rig.text == "pw-secret")
        }
    }

    /// Show, export, health, cards and the editor are not copies from the list: an open window neither covers them nor is begun by
    /// them.
    @Test func showAndOtherPromptsAskAsBeforeWhileTheWindowIsOpen() async throws {
        try await withRig { rig, _ in
            try await copyPassword(rig)
            #expect(rig.prompt.calls == 1)

            try await rig.model.revealPassword(accountID: rig.account.id)
            try await rig.model.showTOTP(accountID: rig.account.id)

            #expect(rig.prompt.calls == 3, "Show Password and Show Code still ask under an open window")
        }
        try await withRig { rig, _ in
            try await rig.model.revealPassword(accountID: rig.account.id)
            #expect(!rig.holds, "a Show does not begin the window")
        }
    }

    /// The window lives only in the Passwords UI's own models. The autofill, MCP, assistant and WebAuthn code never names it.
    @Test func noAutofillMCPOrAssistantSourceNamesTheWindow() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var scanned = 0
        for relative in ["WSurf/Web/Autofill", "WSurf/MCP", "WSurf/Agent", "WSurf/Web/Assistant"] {
            let enumerator = try #require(FileManager.default.enumerator(at: root.appending(path: relative), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8).lowercased()
                #expect(!text.contains("copygrace"), "\(url.lastPathComponent) names the copy window")
            }
        }
        #expect(scanned > 40)
        // The Passwords UI's models are the ones given one.
        for relative in ["WSurf/App/PasswordsStatusItem.swift", "WSurf/Settings/Pages/PasswordsWindowContent.swift"] {
            let text = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
            #expect(text.contains("copyGrace: .shared") || text.contains("copyGrace = .shared"), "\(relative) gives its model the window")
        }
    }
}
