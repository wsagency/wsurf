// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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

    /// A vault with no passkey for the request has nothing to offer, so the ceremony asks the user nothing and answers the page
    /// nothing: the request goes to the system's authenticator, with no sheet of ours in front of it. Nothing is verified,
    /// signed or written, whatever the request allows.
    @Test(.boundedWebViews) func aGetWithNoMatchingPasskeyHandsOffWithoutAnySheetOrWrite() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            let before = try fixture.bytes()

            for allow in [[Data([0xFF])], [Data([0xFF]), Data([0xFE])]] {
                let user = User()
                #expect(await endsInHandOff { try await get(fixture, user, request: assertion(allow: allow)) })
                #expect(user.prompts.isEmpty && user.offers.isEmpty && user.verifications == 0, "no sheet of ours, no verification")
            }
            #expect(try fixture.bytes() == before)

            // A vault with nothing at all behaves the same, and a request that does match is still exactly one prompt.
            let matching = User()
            matching.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            try await get(fixture, matching)
            #expect(matching.prompts.count == 1 && matching.offers.isEmpty)
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
