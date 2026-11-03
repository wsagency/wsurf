// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// How the native ceremony ends when the vault has nothing to approve: it has no passkey for the request, or the profile has no
// vault. The fixture, the scripted user and the helpers live in `WebsiteAuthenticatorCeremonyTests`.
@MainActor
extension WebsiteAuthenticatorCeremonyTests {
    /// How a ceremony ended, as a page-visible class: an instance of the answer, never of what the vault holds.
    private func ending(_ ceremony: () async throws -> Void) async -> String {
        do {
            try await ceremony()
            return "result"
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

    /// The answers a user can give a step that has nothing to approve, and the page-visible ending each has: dismissing it,
    /// expiring and cancelling are the refusals they always are.
    private static let answers: [(WebAuthnDecision, String)] = [
        (.declined, "notAllowed"), (.expired, "expired"), (.cancelled, "cancelled"),
        // Nothing here is approvable, whatever a (scripted) approval names.
        (.approved(choice: nil), "notAllowed"), (.approved(choice: UUID()), "notAllowed"),
    ]

    /// A vault with no matching passkey must not answer instantly: that would let a page probe for credentials with no native step.
    /// The step (here the scripted user, with the origin and relying party) comes first and has nothing to approve. Every answer
    /// ends the ceremony exactly as it ends one that had an account to use.
    @Test(.boundedWebViews) func aGetWithNoMatchingPasskeyAsksFirst() async throws {
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
    func aProfileWithNoVaultAsksTheSameQuestion(operation: WebAuthnPrompt.Operation) async throws {
        try await withFixture { fixture in
            let before = try fixture.bytes()
            let request = operation == .get ? assertion() : creation()
            let context = try await fixture.context(operation == .get ? .get : .create)

            for (decision, expected) in Self.answers {
                let user = User()
                user.respond = { _ in decision }
                let ended = await ending {
                    try await WebsiteAuthenticator.askWithNothingToOffer(request, context: context, in: NSWindow(), interaction: user)
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
                try await WebsiteAuthenticator.askWithNothingToOffer(request, context: context, in: NSWindow(), interaction: bounded)
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
                try await WebsiteAuthenticator.askWithNothingToOffer(foreign, context: context, in: NSWindow(), interaction: withoutVault)
            }
            #expect(first.hasPrefix("other") && first == second, "\(first) / \(second)")
            #expect(withVault.prompts.isEmpty && withoutVault.prompts.isEmpty && withVault.offers.isEmpty)

            // A Mac that cannot verify refuses `required` before any step, in both.
            let cannot = User(), alsoCannot = User()
            cannot.canVerify = false
            alsoCannot.canVerify = false
            let required = assertion(userVerification: .required)
            #expect(await ending { try await WebsiteAuthenticator.perform(required, context: context, manager: fixture.manager, in: NSWindow(), interaction: cannot) } == "notAllowed")
            #expect(await ending { try await WebsiteAuthenticator.askWithNothingToOffer(required, context: context, in: NSWindow(), interaction: alsoCannot) } == "notAllowed")
            #expect(cannot.prompts.isEmpty && alsoCannot.prompts.isEmpty)
        }
    }
}
