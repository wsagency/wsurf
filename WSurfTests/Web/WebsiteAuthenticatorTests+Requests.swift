// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security
import Testing

@testable import WSurf

extension WebsiteAuthenticatorTests {
    @Test func challengeAndUserHandleLimitsAreExact() throws {
        let maximumChallenge = Data(repeating: 0xC1, count: 1_024)
        let maximumUserID = Data(repeating: 0xD1, count: 64)
        let maximumRequest = registrationRequest(challenge: maximumChallenge, userID: maximumUserID)
        let maximumRegistration = try WebsiteAuthenticator.makeRegistration(
            maximumRequest,
            client: client(),
            account: account(),
            consent: consent(for: maximumRequest)
        )
        #expect(maximumRegistration.account.passkeys.first?.userHandle == maximumUserID)

        let minimumUserID = Data([0x01])
        let minimumRequest = registrationRequest(userID: minimumUserID)
        let minimumRegistration = try WebsiteAuthenticator.makeRegistration(
            minimumRequest,
            client: client(),
            account: account(),
            consent: consent(for: minimumRequest)
        )
        #expect(minimumRegistration.account.passkeys.first?.userHandle == minimumUserID)

        for invalidUserID in [Data(), Data(repeating: 0xD2, count: 65)] {
            let request = registrationRequest(userID: invalidUserID)
            #expect(throws: (any Error).self) {
                try WebsiteAuthenticator.makeRegistration(
                    request,
                    client: client(),
                    account: account(),
                    consent: consent(for: request)
                )
            }
        }

        let oversizedChallengeRequest = registrationRequest(challenge: Data(repeating: 0xC2, count: 1_025))
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                oversizedChallengeRequest,
                client: client(),
                account: account(),
                consent: consent(for: oversizedChallengeRequest)
            )
        }

        let maximalAssertionPasskey = passkey(userHandle: maximumUserID)
        let maximalAssertionRequest = assertionRequest(allowCredentials: [maximalAssertionPasskey.credentialID])
        let maximalAssertion = try WebsiteAuthenticator.makeAssertion(
            maximalAssertionRequest,
            client: client(),
            passkey: maximalAssertionPasskey,
            consent: consent(for: maximalAssertionRequest)
        )
        #expect(maximalAssertion.userHandle == maximumUserID)

        let minimalAssertionPasskey = passkey(userHandle: minimumUserID)
        let minimalAssertionRequest = assertionRequest(allowCredentials: [minimalAssertionPasskey.credentialID])
        let minimalAssertion = try WebsiteAuthenticator.makeAssertion(
            minimalAssertionRequest,
            client: client(),
            passkey: minimalAssertionPasskey,
            consent: consent(for: minimalAssertionRequest)
        )
        #expect(minimalAssertion.userHandle == minimumUserID)

        for invalidUserHandle in [Data(), Data(repeating: 0xD3, count: 65)] {
            let invalidPasskey = passkey(userHandle: invalidUserHandle)
            let request = assertionRequest(allowCredentials: [invalidPasskey.credentialID])
            #expect(throws: (any Error).self) {
                try WebsiteAuthenticator.makeAssertion(
                    request,
                    client: client(),
                    passkey: invalidPasskey,
                    consent: consent(for: request)
                )
            }
        }
    }

    @Test func credentialDescriptorCountAndIdentifierLimitsAreExact() throws {
        func identifiers(_ count: Int) -> [Data] {
            (0..<count).map { index in
                Data([0xB0, UInt8(index >> 8), UInt8(index & 0xFF)])
            }
        }

        let maximumExcludedIDs = [Data([0xA6]), Data(repeating: 0xA5, count: 1_024)] + identifiers(998)
        let maximumExcludeRequest = registrationRequest(excludeCredentials: maximumExcludedIDs)
        let maximumExcludeResult = try WebsiteAuthenticator.makeRegistration(
            maximumExcludeRequest,
            client: client(),
            account: account(),
            consent: consent(for: maximumExcludeRequest)
        )
        #expect(maximumExcludeResult.account.passkeys.count == 1)

        let tooManyExcludedIDs = identifiers(1_001)
        let tooManyExcludeRequest = registrationRequest(excludeCredentials: tooManyExcludedIDs)
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                tooManyExcludeRequest,
                client: client(),
                account: account(),
                consent: consent(for: tooManyExcludeRequest)
            )
        }
        for invalidIdentifier in [Data(), Data(repeating: 0xA7, count: 1_025)] {
            let request = registrationRequest(excludeCredentials: [invalidIdentifier])
            #expect(throws: (any Error).self) {
                try WebsiteAuthenticator.makeRegistration(
                    request,
                    client: client(),
                    account: account(),
                    consent: consent(for: request)
                )
            }
        }

        let maximumCredentialID = Data(repeating: 0xC5, count: 1_024)
        let allowedIDs = [maximumCredentialID, Data([0xA6])] + identifiers(998)
        let allowedPasskey = passkey(credentialID: maximumCredentialID, userHandle: Data([0x01]))
        let maximumAllowRequest = assertionRequest(allowCredentials: allowedIDs)
        let maximumAllowResult = try WebsiteAuthenticator.makeAssertion(
            maximumAllowRequest,
            client: client(),
            passkey: allowedPasskey,
            consent: consent(for: maximumAllowRequest)
        )
        #expect(maximumAllowResult.credentialID == maximumCredentialID)
        #expect(maximumAllowResult.userHandle == Data([0x01]))

        let targetPasskey = passkey()
        let tooManyAllowedIDs = [targetPasskey.credentialID] + identifiers(1_000)
        let tooManyAllowRequest = assertionRequest(allowCredentials: tooManyAllowedIDs)
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeAssertion(
                tooManyAllowRequest,
                client: client(),
                passkey: targetPasskey,
                consent: consent(for: tooManyAllowRequest)
            )
        }
        for invalidIdentifier in [Data(), Data(repeating: 0xA8, count: 1_025)] {
            let request = assertionRequest(allowCredentials: [targetPasskey.credentialID, invalidIdentifier])
            #expect(throws: (any Error).self) {
                try WebsiteAuthenticator.makeAssertion(
                    request,
                    client: client(),
                    passkey: targetPasskey,
                    consent: consent(for: request)
                )
            }
        }
    }

    @Test func totalRequestBudgetIsBounded() throws {
        let descriptors = (0..<256).map { index in
            var identifier = Data(repeating: 0, count: 1_024)
            identifier[0] = UInt8(index)
            return identifier
        }
        let request = registrationRequest(excludeCredentials: descriptors)
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                request,
                client: client(),
                account: account(),
                consent: consent(for: request)
            )
        }
    }

    @Test func assertionTotalRequestBudgetIsBounded() throws {
        let allowedCredential = Data(repeating: 0xA1, count: 1_024)
        let passkey = passkey(credentialID: allowedCredential)
        let descriptors = [allowedCredential] + (0..<255).map { _ in
            Data(repeating: 0xA2, count: 1_024)
        }
        let request = assertionRequest(allowCredentials: descriptors)
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeAssertion(
                request,
                client: client(),
                passkey: passkey,
                consent: consent(for: request)
            )
        }
    }

    @Test func ceremoniesRequireUserPresence() throws {
        let create = registrationRequest()
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                create,
                client: client(),
                account: account(),
                consent: consent(for: create, userPresent: false)
            )
        }

        let existingPasskey = passkey()
        let assertion = assertionRequest(allowCredentials: [existingPasskey.credentialID])
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeAssertion(
                assertion,
                client: client(),
                passkey: existingPasskey,
                consent: consent(for: assertion, userPresent: false)
            )
        }
    }

    @Test func registrationRequiresES256Negotiation() throws {
        let request = registrationRequest(publicKeyAlgorithms: [-257])
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                request,
                client: client(),
                account: account(),
                consent: consent(for: request)
            )
        }
    }

    @Test func nonNoneAttestationPreferencesMayReturnNoAttestation() throws {
        let preferences: [WebAuthnAttestationConveyance] = [.indirect, .direct, .enterprise]
        for preference in preferences {
            let request = registrationRequest(attestation: preference)
            let registered = try WebsiteAuthenticator.makeRegistration(
                request,
                client: client(),
                account: account(),
                consent: consent(for: request)
            )
            let verified = try WebAuthnVerifier.registration(
                attestationObject: try #require(registered.result.attestationObject),
                clientDataJSON: registered.result.clientDataJSON,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: rpID
            )
            #expect(verified.credentialID == registered.result.credentialID)
            #expect(verified.authenticatorData.subdata(in: 37..<53) == Data(repeating: 0, count: 16))
        }
    }

    @Test func emptyPubKeyCredParamsUsesWebAuthnDefaultAlgorithms() throws {
        let request = registrationRequest(publicKeyAlgorithms: [])
        let registered = try WebsiteAuthenticator.makeRegistration(
            request,
            client: client(),
            account: account(),
            consent: consent(for: request)
        )
        let verified = try WebAuthnVerifier.registration(
            attestationObject: try #require(registered.result.attestationObject),
            clientDataJSON: registered.result.clientDataJSON,
            challenge: Data("registration challenge".utf8),
            origin: origin,
            topOrigin: nil,
            crossOrigin: false,
            rpID: rpID
        )
        #expect(verified.credentialID == registered.result.credentialID)
        #expect(registered.result.publicKeyAlgorithm == -7)
    }

    @Test func expiredDeadlinesRejectRegistrationAndAssertion() throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(-1))
        let create = registrationRequest(deadline: deadline)
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                create,
                client: client(),
                account: account(),
                consent: consent(for: create)
            )
        }

        let existingPasskey = passkey()
        let assertion = assertionRequest(
            allowCredentials: [existingPasskey.credentialID],
            deadline: deadline
        )
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeAssertion(
                assertion,
                client: client(),
                passkey: existingPasskey,
                consent: consent(for: assertion)
            )
        }
    }

    /// A conditional get has no deadline: it signs however long it waited. Expiry stays the typed `.expired` for every
    /// bounded request.
    @Test func aRequestWithoutADeadlineNeverExpiresAndABoundedOneExpiresTyped() throws {
        let existingPasskey = passkey()
        var unbounded = assertionRequest(allowCredentials: [existingPasskey.credentialID])
        unbounded.deadline = nil
        try WebsiteAuthenticator.validateDeadline(unbounded)
        let signed = try WebsiteAuthenticator.makeAssertion(
            unbounded, client: client(), passkey: existingPasskey, consent: consent(for: unbounded)
        )
        #expect(signed.signature != nil)

        let expired = assertionRequest(allowCredentials: [existingPasskey.credentialID], deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        do {
            _ = try WebsiteAuthenticator.makeAssertion(expired, client: client(), passkey: existingPasskey, consent: consent(for: expired))
            Issue.record("a bounded request outlived its deadline")
        } catch WebsiteAuthenticatorError.expired {} catch { Issue.record("wrong error \(error)") }
    }
}
