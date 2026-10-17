// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// How the native ceremony ends when the request is not the vault's to answer: the vault has no passkey for it, or the user chose
// "Use Another Device or Key…" on one of our sheets. The fixture, the scripted user and the helpers live in
// `WebsiteAuthenticatorCeremonyTests`.
@MainActor
extension WebsiteAuthenticatorCeremonyTests {
    /// Whether `ceremony` ended as a hand-off to the system's authenticator, and not as a refusal or a result.
    private func endsInHandOff(_ ceremony: () async throws -> Void) async -> Bool {
        do {
            try await ceremony()
            return false
        } catch WebsiteAuthenticatorError.handOff {
            return true
        } catch {
            return false
        }
    }

    /// How a ceremony ended, as a page-visible class: an instance of the answer, never of what the vault holds.
    private func ending(_ ceremony: () async throws -> Void) async -> String {
        do {
            try await ceremony()
            return "result"
        } catch WebsiteAuthenticatorError.handOff {
            return "handOff"
        } catch WebsiteAuthenticatorError.notAllowed {
            return "notAllowed"
        } catch WebsiteAuthenticatorError.expired {
            return "expired"
        } catch is CancellationError {
            return "cancelled"
        } catch {
            return "other \(error)"
        }
    }

    /// The answers a user can give a step that has nothing to approve, and the page-visible ending each has: only the explicit
    /// choice of the system's authenticator goes anywhere; dismissing it, expiring and cancelling are the refusals they always are.
    private static let answers: [(WebAuthnDecision, String)] = [
        (.declined, "notAllowed"), (.expired, "expired"), (.cancelled, "cancelled"), (.handOff, "handOff"),
        // Nothing here is approvable, whatever a (scripted) approval names.
        (.approved(choice: nil), "notAllowed"), (.approved(choice: UUID()), "notAllowed"),
    ]

    /// A vault with no matching passkey must not answer instantly, nor hand the request on by itself: either would let a page
    /// probe for credentials with no native step. The step (here the scripted user, with the origin and relying party) comes
    /// first, has nothing to approve, and the page hears of the system's authenticator only if the user chose it. Every answer
    /// ends the ceremony exactly as it ends one that had an account to use.
    @Test(.boundedWebViews) func aGetWithNoMatchingPasskeyAsksFirstAndHandsOffOnlyOnTheChoice() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            let stored = try #require(try await passkeys(fixture).first)
            let before = try fixture.bytes()

            for (decision, expected) in Self.answers {
                let user = User()
                user.respond = { _ in decision }
                #expect(await ending { try await get(fixture, user, request: assertion(allow: [Data([0xFF])])) } == expected, "\(decision)")
                #expect(user.prompts.count == 1, "the user is asked before any ending: \(decision)")
                let prompt = try #require(user.prompts.first)
                #expect(prompt.operation == .get && prompt.choices.isEmpty && !prompt.offersNewAccount)
                #expect(prompt.origin == fixture.origin && prompt.rpID == rpID)
                #expect(user.verifications == 0 && user.offers.isEmpty)
            }
            // Approving a real passkey of this vault does not make the request match.
            let wrong = User()
            wrong.respond = { _ in .approved(choice: stored.id) }
            #expect(await ending { try await get(fixture, wrong, request: assertion(allow: [Data([0xFF])])) } == "notAllowed")
            #expect(try fixture.bytes() == before)

            // The same answers end a get that does match in the same way, after the same single step.
            for (decision, expected) in Self.answers {
                let user = User()
                user.respond = { _ in decision }
                #expect(await ending { try await get(fixture, user) } == expected, "\(decision)")
                #expect(user.prompts.count == 1 && user.offers.isEmpty && user.verifications == 0)
            }
            #expect(try fixture.bytes() == before)
            let matching = User()
            matching.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            try await get(fixture, matching)
            #expect(matching.prompts.count == 1 && matching.offers.isEmpty)
        }
    }

    /// A profile with no vault asks the user the same question, in the same words, and has the same endings. The request is
    /// checked first exactly as a vault's ceremony checks it, and nothing is read, written, unlocked or verified.
    @Test(.boundedWebViews, arguments: [WebAuthnPrompt.Operation.get, .create])
    func aProfileWithNoVaultAsksTheSameQuestionAndHandsOffOnlyOnTheChoice(operation: WebAuthnPrompt.Operation) async throws {
        try await withFixture { fixture in
            let before = try fixture.bytes()
            let request = operation == .get ? assertion() : creation()
            let context = try await fixture.context(operation == .get ? .get : .create)

            for (decision, expected) in Self.answers {
                let user = User()
                user.respond = { _ in decision }
                let ended = await ending {
                    try await WebsiteAuthenticator.offerSystemAuthenticator(request, context: context, in: NSWindow(), interaction: user)
                }
                #expect(ended == expected, "\(decision)")
                #expect(user.prompts.count == 1 && user.offers.isEmpty && user.verifications == 0)
                let prompt = try #require(user.prompts.first)
                #expect(prompt.operation == operation && prompt.choices.isEmpty && !prompt.offersNewAccount)
                #expect(prompt.origin == fixture.origin && prompt.rpID == rpID)
            }
            // The step is bounded like the vault's own: the deadline, or none for a discovery.
            let bounded = User()
            bounded.respond = { _ in .declined }
            _ = await ending {
                try await WebsiteAuthenticator.offerSystemAuthenticator(request, context: context, in: NSWindow(), interaction: bounded)
            }
            #expect(bounded.deadlines.count == 1 && bounded.deadlines.allSatisfy { $0 != nil })
            #expect(try fixture.bytes() == before)
        }
    }

    /// A request a vault's ceremony refuses before any step fails the same way, with no step, when there is no vault.
    @Test(.boundedWebViews) func aMalformedRequestFailsTheSameWayWithOrWithoutAVault() async throws {
        try await withFixture { fixture in
            let foreign = WebAuthnRequest(
                requestID: UUID(),
                options: .assertion(WebAuthnAssertionOptions(
                    challenge: Data("c".utf8), rpID: "example.org", allowCredentials: [], userVerification: .discouraged
                )),
                deadline: ContinuousClock.now.advanced(by: .seconds(60))
            )
            let context = try await fixture.context(.get)
            let withVault = User(), withoutVault = User()
            let first = await ending { try await WebsiteAuthenticator.perform(foreign, context: context, manager: fixture.manager, in: NSWindow(), interaction: withVault) }
            let second = await ending {
                try await WebsiteAuthenticator.offerSystemAuthenticator(foreign, context: context, in: NSWindow(), interaction: withoutVault)
            }
            #expect(first.hasPrefix("other") && first == second, "\(first) / \(second)")
            #expect(withVault.prompts.isEmpty && withoutVault.prompts.isEmpty && withVault.offers.isEmpty)

            // A Mac that cannot verify refuses `required` before any step, in both.
            let cannot = User(), alsoCannot = User()
            cannot.canVerify = false
            alsoCannot.canVerify = false
            let required = assertion(userVerification: .required)
            #expect(await ending { try await WebsiteAuthenticator.perform(required, context: context, manager: fixture.manager, in: NSWindow(), interaction: cannot) } == "notAllowed")
            #expect(await ending { try await WebsiteAuthenticator.offerSystemAuthenticator(required, context: context, in: NSWindow(), interaction: alsoCannot) } == "notAllowed")
            #expect(cannot.prompts.isEmpty && alsoCannot.prompts.isEmpty)
        }
    }

    /// "Use Another Device or Key…" ends the ceremony at whichever of our sheets it is chosen on, before anything is verified,
    /// signed, written or unlocked. It is not a refusal: the caller hands the request to the system's authenticator.
    @Test(.boundedWebViews) func choosingAnotherDeviceOrKeyEndsTheCeremonyWithNothingDone() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            let before = try fixture.bytes()

            let onTheAccountSheet = User()
            onTheAccountSheet.respond = { _ in .handOff }
            #expect(await endsInHandOff { try await get(fixture, onTheAccountSheet) })
            #expect(onTheAccountSheet.prompts.count == 1 && onTheAccountSheet.verifications == 0)

            let onTheCreateSheet = User()
            onTheCreateSheet.respond = { _ in .handOff }
            #expect(await endsInHandOff { try await create(fixture, onTheCreateSheet, request: creation(userVerification: .required)) })
            #expect(onTheCreateSheet.prompts.count == 1 && onTheCreateSheet.verifications == 0)
            #expect(try fixture.bytes() == before)

            // On the offer a locked vault shows first, it is chosen before the vault is unlocked, so it never is.
            fixture.manager.lock(reason: .manual)
            for conditional in [false, true] {
                let onTheOffer = User()
                onTheOffer.offer = { _ in .handOff }
                #expect(await endsInHandOff {
                    try await get(fixture, onTheOffer, request: assertion(deadline: conditional ? nil : .seconds(60)), conditional: conditional)
                })
                #expect(onTheOffer.offers == [true] && onTheOffer.prompts.isEmpty && onTheOffer.verifications == 0)
                #expect(!fixture.manager.isUnlocked)
            }
            let onTheCreateOffer = User()
            onTheCreateOffer.offer = { _ in .handOff }
            #expect(await endsInHandOff { try await create(fixture, onTheCreateOffer) })
            #expect(onTheCreateOffer.offers == [true] && !fixture.manager.isUnlocked)
            #expect(try fixture.bytes() == before)
        }
    }
}
