// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

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
            #expect(user.offers == [true] && user.prompts.count == 1 && user.verifications == 1)
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
            #expect(await ending({ _ in .handOff }) == [], "the adapter records where a hand-off went")
            #expect(await ending(pick, request: assertion(userVerification: .required), verifyFailure: WebsiteAuthenticatorError.notAllowed)
                == ["verification-failed"])
            #expect(await ending({ _ in .declined }, request: assertion(allow: [Data([0xFF])])) == ["no-match", "user-declined"])
            #expect(await ending(pick) == [], "a signed assertion is no refusal")
        }
    }
}
