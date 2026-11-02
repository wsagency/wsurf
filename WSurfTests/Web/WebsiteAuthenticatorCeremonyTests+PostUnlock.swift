// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WSurfVault

@testable import WSurf

// What happens after the vault's own unlock, and how every refusal is recorded. The system's passkey sheet is the fixture's
// stand-in (`VaultPasskeys`); a window that reports a sheet stands in for its dismissal, which AppKit finishes after the answer.
@MainActor
extension WebsiteAuthenticatorCeremonyTests {
    /// A window whose attached sheet the test sets, the way the system's unlock sheet stays attached while it closes.
    final class SheetWindow: NSWindow {
        var attached: NSWindow?
        override var attachedSheet: NSWindow? {
            attached
        }
    }

    private func recording(_ fixture: Fixture, _ body: () async throws -> Void) async rethrows -> [String] {
        WebAuthnRefusal.recordedForTesting[fixture.profile.id] = []
        defer { WebAuthnRefusal.recordedForTesting[fixture.profile.id] = nil }
        try await body()
        return WebAuthnRefusal.recordedForTesting[fixture.profile.id] ?? []
    }

    /// GitHub's shape, a discoverable passkey (no allowCredentials) as a modal request and as a discovery: the account step
    /// comes once the unlock sheet has closed, never refused because it was still closing.
    @Test(.boundedWebViews, arguments: [false, true])
    func afterAnUnlockTheAccountStepWaitsForTheSystemSheetToClose(conditional: Bool) async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            fixture.manager.lock(reason: .manual)
            let window = SheetWindow()
            fixture.passkeys.beforeAssert = {
                window.attached = NSWindow()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    window.attached = nil
                }
            }
            let user = User()
            user.respond = { prompt in
                window.attached == nil ? .approved(choice: prompt.choices.first?.id) : .unavailable
            }
            let logged = try await recording(fixture) {
                let outcome = try await WebsiteAuthenticator.perform(
                    assertion(userVerification: .required, deadline: conditional ? nil : .seconds(60)), context: fixture.context(.get),
                    manager: fixture.manager, in: window, conditional: conditional, interaction: user
                )
                #expect(outcome.result.signature != nil)
            }
            #expect(fixture.passkeys.assertions.count == 1, "the vault was unlocked by the system sheet")
            #expect(user.offers == (conditional ? [] : [true]) && user.prompts.count == 1 && user.verifications == 1)
            #expect(logged.isEmpty, "nothing was refused: \(logged)")
        }
    }

    @Test(.boundedWebViews) func anUnlockSheetThatStaysUpIsALoggedRefusalNotAQueue() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            fixture.manager.lock(reason: .manual)
            let window = SheetWindow()
            fixture.passkeys.beforeAssert = { window.attached = NSWindow() }
            let user = User()
            let logged = await recording(fixture) {
                await #expect(throws: WebsiteAuthenticatorError.self) {
                    try await WebsiteAuthenticator.perform(
                        assertion(), context: fixture.context(.get), manager: fixture.manager, in: window, interaction: user
                    )
                }
            }
            #expect(user.prompts.isEmpty && user.verifications == 0)
            #expect(logged == ["interaction-refused"])
        }
    }

    /// Every way a step can refuse is recorded by its case; a cancel is recorded by whoever cancelled (the adapter).
    @Test(.boundedWebViews) func everyRefusedStepIsLoggedByItsCase() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            @MainActor func ending(_ answer: @escaping (WebAuthnPrompt) -> WebAuthnDecision, request: WebAuthnRequest? = nil,
                                   verifyFailure: (any Error)? = nil) async -> [String] {
                let user = User()
                user.respond = answer
                user.verifyFailure = verifyFailure
                return await recording(fixture) { _ = try? await get(fixture, user, request: request) }
            }
            let pick: (WebAuthnPrompt) -> WebAuthnDecision = { .approved(choice: $0.choices.first?.id) }

            #expect(await ending({ _ in .declined }) == ["user-declined"])
            #expect(await ending({ _ in .expired }) == ["timeout"])
            #expect(await ending({ _ in .unavailable }) == ["interaction-refused"])
            #expect(await ending({ _ in .cancelled }) == [])
            #expect(await ending(pick, request: assertion(userVerification: .required), verifyFailure: WebsiteAuthenticatorError.notAllowed)
                == ["verification-failed"])
            #expect(await ending({ _ in .declined }, request: assertion(allow: [Data([0xFF])])) == ["no-match", "user-declined"])
            #expect(await ending(pick) == [], "a signed assertion is no refusal")
        }
    }

    // MARK: How much one sign-in asks

    private func flags(_ outcome: WebAuthnCeremonyOutcome) throws -> UInt8 {
        try #require(outcome.result.authenticatorData)[32]
    }

    /// The count of one sign-in with one matching passkey. A locked vault: its one unlock (the system's sheet), after one offer
    /// only when a page asked. Then one prompt and one verification, nothing else; an unlocked vault asks for neither offer nor unlock.
    /// Raising any of these numbers is the owner's "asked 3-4 times for one login".
    @Test(.boundedWebViews, arguments: [(false, false), (false, true), (true, false), (true, true)])
    func oneSignInAsksForOneConfirmation(locked: Bool, conditional: Bool) async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            if locked {
                fixture.manager.lock(reason: .manual)
            }
            let epoch = fixture.manager.authorizationEpoch
            let user = User()
            user.respond = { prompt in .approved(choice: prompt.choices.first?.id) }
            let outcome = try await get(fixture, user, request: assertion(userVerification: .required), conditional: conditional)
            #expect(try flags(outcome) & 0x04 != 0)
            #expect(user.offers == (locked && !conditional ? [true] : []))
            #expect(fixture.passkeys.assertions.count == (locked ? 1 : 0))
            #expect(user.prompts.count == 1 && user.verifications == 1)
            if !locked {
                #expect(fixture.manager.authorizationEpoch == epoch, "an unlocked vault is used as it is")
            }
        }
    }

    /// The sensor on the sheet is the ceremony's verification: no second one, and the UV flag follows only from it.
    @Test(.boundedWebViews) func aVerificationOnTheSheetIsTheOnlyOne() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            let user = User()
            user.respond = { prompt in .verified(choice: prompt.choices.first?.id) }
            let outcome = try await get(fixture, user, request: assertion(challenge: "s", userVerification: .required))
            #expect(user.verifications == 0)
            #expect(try flags(outcome) & 0x04 != 0)

            // A request that plans no verification gets no UV flag from a scripted answer.
            let plain = User()
            plain.respond = { prompt in .verified(choice: prompt.choices.first?.id) }
            let unverified = try await get(fixture, plain, request: assertion(challenge: "d", userVerification: .discouraged))
            #expect(try flags(unverified) & 0x04 == 0)
        }
    }

    /// Find names the keys that cannot answer and offers no way to use them: even an answer naming one is refused.
    @Test(.boundedWebViews) func findNamesOtherPasskeysButNoneOfThemCanSign() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1, userName: "ada@example.com")
            try await seed(fixture, 2, userName: "grace@example.com")
            let stored = try await passkeys(fixture)
            let usable = try #require(stored.first { $0.userName == "ada@example.com" })
            let other = try #require(stored.first { $0.userName == "grace@example.com" })

            let user = User()
            user.respond = { _ in .verified(choice: other.id) }
            await #expect(throws: WebsiteAuthenticatorError.self) {
                try await get(fixture, user, request: assertion(userVerification: .required, allow: [usable.credentialID]))
            }
            let prompt = try #require(user.prompts.first)
            #expect(prompt.choices.map(\.id) == [usable.id])
            #expect(prompt.otherPasskeys.map(\.userName) == ["grace@example.com"])
            #expect(user.verifications == 0)

            // A key of another relying party: never a candidate, always listed with its own relying party.
            let accounts = try await fixture.manager.snapshot().accounts
            let foreign = WebsiteAuthenticator.assertionCandidates(accounts, rpID: "other.example", allowed: [])
            #expect(foreign.isEmpty)
            let listed = WebsiteAuthenticator.otherPasskeys(accounts, excluding: foreign)
            #expect(listed.count == 2 && listed.allSatisfy { $0.rpID == rpID })
            #expect(PasskeyFindField.matches(listed, query: "GRACE").count == 1)
            #expect(PasskeyFindField.text(listed, query: "nobody") == String(localized: "No other passkey matches."))
        }
    }

    /// Return in Find is the search's own: it never presses the sheet's default button.
    @Test func returnInFindDoesNotAnswerTheSheet() throws {
        let find = try #require(PasskeyFindField([WebAuthnPromptOther(title: "Ada", userName: "ada", rpID: "other.example")]))
        #expect(find.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!find.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(PasskeyFindField(([] as [WebAuthnPromptOther])) == nil)
    }
}
