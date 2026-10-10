// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The client data is a wire format: a relying party that cannot parse JSON verifies it by prefix
/// (WebAuthn Level 3 §5.8.1.2), so the field order and escaping are part of the contract.
extension WebsiteAuthenticatorTests {
    private static let embedder = "https://embedder.example.net"

    @Test(arguments: [false, true])
    func clientDataOfBothCeremoniesPassesLimitedVerification(crossOrigin: Bool) throws {
        let topOrigin = crossOrigin ? Self.embedder : nil
        let sites = [
            ("https://login.example.com", "example.com"),
            ("https://login.example.com:8443", "example.com"),
            ("http://localhost:8080", "localhost"),
        ]
        for (siteOrigin, siteRPID) in sites {
            let client = WebAuthnClientData(origin: siteOrigin, topOrigin: topOrigin, crossOrigin: crossOrigin, rpID: siteRPID)
            let create = registrationRequest(rpID: siteRPID)
            let registered = try WebsiteAuthenticator.makeRegistration(
                create, client: client, account: account(), consent: consent(for: create)
            )
            #expect(WebAuthnVerifier.limitedClientDataVerifies(
                registered.result.clientDataJSON,
                type: "webauthn.create",
                challenge: Data("registration challenge".utf8),
                origin: siteOrigin,
                topOrigin: topOrigin
            ))

            let passkey = try #require(registered.account.passkeys.first)
            let get = assertionRequest(allowCredentials: [passkey.credentialID], rpID: siteRPID)
            let assertion = try WebsiteAuthenticator.makeAssertion(get, client: client, passkey: passkey, consent: consent(for: get))
            #expect(WebAuthnVerifier.limitedClientDataVerifies(
                assertion.clientDataJSON,
                type: "webauthn.get",
                challenge: Data("assertion challenge".utf8),
                origin: siteOrigin,
                topOrigin: topOrigin
            ))
        }
    }

    /// The origin strings here are never produced by the native side (it canonicalizes them first); the encoder is
    /// exercised directly so the escaping rules are checked against the specification, not against one caller.
    @Test(arguments: [
        "https://login.example.com",
        #"https://a"b.example"#,
        #"https://a\b.example"#,
        "https://a\u{01}b.example",
        "https://a\u{7F}b.example",
        "https://bücher.example",
        "https://\u{1F512}.example",
    ])
    func clientDataEscapesOnlyWhatTheSpecificationRequires(origin: String) throws {
        // These bytes encode to a base64url string that uses both "-" and "_".
        let challenge = Data([0xFB, 0xFF, 0xBF, 0xFE])
        let client = WebAuthnClientData(origin: origin, topOrigin: Self.embedder, crossOrigin: true, rpID: "example.com")
        let bytes = WebAuthnEncoding.clientDataJSON(type: "webauthn.get", challenge: challenge, client: client)

        #expect(WebAuthnVerifier.limitedClientDataVerifies(
            bytes, type: "webauthn.get", challenge: challenge, origin: origin, topOrigin: Self.embedder
        ))
        let parsed = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(parsed["origin"] as? String == origin)
        #expect(parsed["challenge"] as? String == "-_-__g")
        #expect(parsed["topOrigin"] as? String == Self.embedder)
    }

    @Test func theIndependentVerifierRejectsAClientDataOriginThatIsNotTheExpectedOne() throws {
        let create = registrationRequest()
        let registered = try WebsiteAuthenticator.makeRegistration(
            create, client: client(), account: account(), consent: consent(for: create)
        )
        let attestationObject = try #require(registered.result.attestationObject)
        let challenge = Data("registration challenge".utf8)
        let verified = try WebAuthnVerifier.registration(
            attestationObject: attestationObject,
            clientDataJSON: registered.result.clientDataJSON,
            challenge: challenge,
            origin: origin,
            topOrigin: nil,
            crossOrigin: false,
            rpID: rpID
        )

        let passkey = try #require(registered.account.passkeys.first)
        let get = assertionRequest(allowCredentials: [passkey.credentialID])
        let assertion = try WebsiteAuthenticator.makeAssertion(get, client: client(), passkey: passkey, consent: consent(for: get))
        let signature = try #require(assertion.signature)
        let authenticatorData = try #require(assertion.authenticatorData)

        for wrong in ["https://attacker.example", "http://login.example.com", "https://login.example.com:8443", "https://example.com"] {
            #expect(throws: (any Error).self) {
                try WebAuthnVerifier.registration(
                    attestationObject: attestationObject,
                    clientDataJSON: registered.result.clientDataJSON,
                    challenge: challenge,
                    origin: wrong,
                    topOrigin: nil,
                    crossOrigin: false,
                    rpID: rpID
                )
            }
            #expect(throws: (any Error).self) {
                try WebAuthnVerifier.assertion(
                    authenticatorData: authenticatorData,
                    clientDataJSON: assertion.clientDataJSON,
                    signature: signature,
                    publicKey: verified.publicKey,
                    challenge: Data("assertion challenge".utf8),
                    origin: .init(origin: wrong),
                    rpID: rpID,
                    userHandle: assertion.userHandle
                )
            }
        }
    }
}
