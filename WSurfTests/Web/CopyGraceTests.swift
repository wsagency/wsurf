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

    /// The auto-lock timeout (`.timeout`) with the popover closed and nobody watching: the vault locks itself and the window goes with
    /// it, by name. The window's own clock is not advanced, so only the lock can have ended it. A shortened auto-lock time that has
    /// already passed locks through the same `lock(reason: .timeout)` the lease timer calls (the timer itself sleeps on the real clock).
    @Test func theAutoLockTimeoutEndsTheWindowWhileThePopoverIsClosed() async throws {
        let vault = try await VaultManagerFixture.standalone()
        defer { ProfileSettingsStore.forget(vault.profile.id) }
        do {
            let (prompt, graceClock) = (Prompt(), TestClock())
            let grace = CopyGrace(now: { graceClock.now })
            let account = VaultFixtures.account(password: "pw-secret")
            try await VaultManagerFixture.save([account], in: vault.vault)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let model = CredentialSettingsModel(
                profile: vault.profile, pasteboard: pasteboard, manager: vault.manager, verifyUser: { try await prompt.verify($0) },
                clock: graceClock
            )
            model.copyGrace = grace
            await model.load()
            try await model.copy(.password, of: .stored(account.id))
            #expect(prompt.calls == 1 && grace.holds(vault.vault.vaultID))

            // The popover is closed: no model call, no copy. Time passes on the manager's clock and the one minute chosen runs out.
            vault.clock.advance(by: .seconds(60))
            try vault.manager.setAutoLock(.oneMinute)

            #expect(!vault.manager.isUnlocked)
            #expect(vault.manager.lastLockReason == .timeout)
            #expect(!grace.holds(vault.vault.vaultID), "the timeout lock cancels the window, it is not left to run out")

            // Unlocked again, the next copy is a new confirmation.
            try await VaultManagerFixture.unlock(vault.vault)
            await model.load()
            try await model.copy(.password, of: .stored(account.id))
            #expect(prompt.calls == 2)
        } catch {
            await vault.cleanup()
            throw error
        }
        await vault.cleanup()
    }

    /// A lease past its deadline whose timer has not locked the vault yet: the window is still there and unexpired by its own clock,
    /// but the vault no longer has an authorization epoch, so nothing is copied and nothing is asked.
    @Test func aLeasePastItsDeadlineCopiesNothingBeforeTheTimerLocks() async throws {
        let vault = try await VaultManagerFixture.standalone()
        defer { ProfileSettingsStore.forget(vault.profile.id) }
        do {
            let (prompt, graceClock) = (Prompt(), TestClock())
            let grace = CopyGrace(now: { graceClock.now })
            let account = VaultFixtures.account(password: "pw-secret")
            try await VaultManagerFixture.save([account], in: vault.vault)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let model = CredentialSettingsModel(
                profile: vault.profile, pasteboard: pasteboard, manager: vault.manager, verifyUser: { try await prompt.verify($0) },
                clock: graceClock
            )
            model.copyGrace = grace
            await model.load()
            try await model.copy(.password, of: .stored(account.id))
            pasteboard.clearContents()

            vault.clock.advance(by: .seconds(301))
            #expect(vault.manager.authorizationEpoch == nil)

            await #expect(throws: CredentialVaultError.unauthorized) { try await model.copy(.password, of: .stored(account.id)) }
            #expect(prompt.calls == 1, "an expired lease is refused without a prompt")
            #expect(pasteboard.string(forType: .string) == nil)
        } catch {
            await vault.cleanup()
            throw error
        }
        await vault.cleanup()
    }

    // MARK: Where it begins and where it does not apply

    /// The window is a vault's own: a confirmation in vault A leaves vault B asking, and locking A leaves B's window running.
    @Test func aConfirmationInOneVaultDoesNotOpenTheWindowForAnother() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (prompt, clock) = (Prompt(), TestClock())
            let grace = CopyGrace(now: { clock.now })
            let accounts = [VaultFixtures.account(password: "pw-in-a"), VaultFixtures.account(password: "pw-in-b")]
            var models: [CredentialSettingsModel] = []
            var pasteboards: [NSPasteboard] = []
            for (vault, account) in zip(vaults, accounts) {
                try await VaultManagerFixture.save([account], in: vault)
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
                pasteboards.append(pasteboard)
                let model = CredentialSettingsModel(
                    profile: profile, pasteboard: pasteboard, manager: vault.manager, verifyUser: { try await prompt.verify($0) }, clock: clock
                )
                model.copyGrace = grace
                await model.load()
                models.append(model)
            }
            defer { pasteboards.forEach { $0.releaseGlobally() } }

            try await models[0].copy(.password, of: .stored(accounts[0].id))
            #expect(prompt.calls == 1 && grace.holds(vaults[0].vaultID) && !grace.holds(vaults[1].vaultID))

            clock.advance(by: .seconds(5))
            try await models[1].copy(.password, of: .stored(accounts[1].id))
            #expect(prompt.calls == 2, "vault B asks although vault A was confirmed 5 s ago")
            #expect(pasteboards[1].string(forType: .string) == "pw-in-b")
            #expect(grace.holds(vaults[1].vaultID))

            vaults[0].manager.lock(reason: .manual)
            #expect(!grace.holds(vaults[0].vaultID) && grace.holds(vaults[1].vaultID), "locking A does not end B's window")
        }
    }

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
