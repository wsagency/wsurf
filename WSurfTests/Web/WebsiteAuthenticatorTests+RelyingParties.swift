// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

// What real relying parties check in an assertion besides the signature: the backup state the provider registered (GitHub), the
// FIDO AppID extension sent for old U2F keys (GitHub), and how RP IDs and credential IDs match (Hetzner). The public key is
// derived from the stored PKCS#8 by CryptoKit's own parser, not WSurf's, and the signature is checked by the Security framework.
extension WebsiteAuthenticatorTests {
    private var gitHub: WebAuthnClientData {
        WebAuthnClientData(origin: "https://github.com", topOrigin: nil, crossOrigin: false, rpID: "github.com")
    }

    private func gitHubRequest(appID: String? = nil, allow: [Data] = [], userVerification: WebAuthnUserVerification = .required) -> WebAuthnRequest {
        WebAuthnRequest(
            requestID: UUID(),
            options: .assertion(WebAuthnAssertionOptions(
                challenge: Data("github challenge".utf8), rpID: "github.com", allowCredentials: allow,
                userVerification: userVerification, appID: appID
            )),
            deadline: ContinuousClock.now.advanced(by: .seconds(60))
        )
    }

    private func gitHubPasskey(_ source: WebsitePasskeySource?) -> WebsitePasskey {
        var stored = passkey(rpID: "github.com")
        stored.source = source
        return stored
    }

    @Test func anImportedPasskeyKeepsTheBackupStateItsProviderRegisteredAndAWSurfOneDoesNot() throws {
        let expected: [(WebsitePasskeySource?, UInt8)] = [(.imported, 0x01 | 0x04 | 0x08 | 0x10), (.created, 0x01 | 0x04 | 0x08), (nil, 0x01 | 0x04 | 0x08)]
        for (source, flags) in expected {
            let request = gitHubRequest()
            let stored = gitHubPasskey(source)
            let result = try WebsiteAuthenticator.makeAssertion(
                request, client: gitHub, passkey: stored, consent: consent(for: request, userVerified: true)
            )
            let authenticatorData = try #require(result.authenticatorData)
            #expect(authenticatorData[32] == flags, "UP, UV, BE always; BS only for a passkey its provider still syncs: \(String(describing: source))")
            let original = try P256.Signing.PrivateKey(derRepresentation: stored.privateKeyPKCS8)
            _ = try WebAuthnVerifier.assertion(
                authenticatorData: authenticatorData, clientDataJSON: result.clientDataJSON, signature: try #require(result.signature),
                publicKey: WebAuthnVerifier.publicKey(x963: original.publicKey.x963Representation), challenge: Data("github challenge".utf8),
                origin: .init(origin: "https://github.com"), rpID: "github.com", userHandle: result.userHandle
            )
            #expect(result.userHandle == stored.userHandle && result.credentialID == stored.credentialID)
        }
    }

    @Test func anAppIDRequestIsAnsweredFalseAndSignedUnderTheRPIDItself() throws {
        // GitHub's two-factor step: the listed keys, the U2F AppID, and no verification asked.
        let request = gitHubRequest(appID: "https://github.com/u2f/trusted_facets", allow: [Data([0xC0, 0x01])], userVerification: .discouraged)
        let result = try WebsiteAuthenticator.makeAssertion(request, client: gitHub, passkey: gitHubPasskey(.imported), consent: consent(for: request))
        let authenticatorData = try #require(result.authenticatorData)
        #expect(authenticatorData.prefix(32) == Data(SHA256.hash(data: Data("github.com".utf8))), "the RP ID hash, never the AppID's")
        #expect(authenticatorData[32] & 0x04 == 0, "no verification ran, so UV is not claimed")
        #expect(result.clientExtensionResults?.appid == false)
        #expect(try WebAuthnWire.resultJSON(result, operation: .get)["clientExtensionResults"] as? [String: Bool] == ["appid": false])

        // A request without appid gets no appid output.
        let plain = gitHubRequest()
        let unextended = try WebsiteAuthenticator.makeAssertion(
            plain, client: gitHub, passkey: gitHubPasskey(.imported), consent: consent(for: plain, userVerified: true)
        )
        #expect(try WebAuthnWire.resultJSON(unextended, operation: .get)["clientExtensionResults"] as? [String: Bool] == [:])
    }

    @Test func theWireCarriesAnAppIDAsTextOnly() throws {
        func parsed(_ extra: [String: Any]) throws -> WebAuthnAssertionOptions? {
            var options: [String: Any] = ["challenge": WebAuthnWire.base64URL(Data([1, 2, 3]))]
            for (key, value) in extra {
                options[key] = value
            }
            guard case .assertion(let assertion) = try WebAuthnWire.parse(["id": "r1", "operation": "get", "options": options]).request.options else {
                return nil
            }
            return assertion
        }
        #expect(try parsed(["appid": "https://github.com/u2f/trusted_facets"])?.appID == "https://github.com/u2f/trusted_facets")
        #expect(try parsed([:])?.appID == nil)
        #expect(throws: (any Error).self) { try parsed(["appid": 7]) }
        #expect(throws: (any Error).self) { try parsed(["appid": ""]) }
    }

    @Test func aPasskeyMatchesExactlyTheRPIDItWasRegisteredFor() throws {
        let origin = try #require(URL(string: "https://accounts.hetzner.com"))
        #expect(try RelyingPartyPolicy.validate(rpID: "hetzner.com", origin: origin) == "hetzner.com")
        #expect(try RelyingPartyPolicy.validate(rpID: nil, origin: origin) == "accounts.hetzner.com")
        #expect(try RelyingPartyPolicy.validate(rpID: "Accounts.Hetzner.COM", origin: origin) == "accounts.hetzner.com")
        #expect(throws: (any Error).self) { try RelyingPartyPolicy.validate(rpID: "robot.hetzner.com", origin: origin) }
        #expect(throws: (any Error).self) { try RelyingPartyPolicy.validate(rpID: "com", origin: origin) }

        // An ID whose base64 and base64url differ ("+/" against "-_") reaches native as the same bytes the page listed.
        let id = Data([0xFB, 0xFF, 0xBF, 0xFB])
        let wire: [String: Any] = [
            "challenge": WebAuthnWire.base64URL(Data([1])), "allowCredentials": [["id": WebAuthnWire.base64URL(id)]],
        ]
        guard case .assertion(let options) = try WebAuthnWire.parse(["id": "r1", "operation": "get", "options": wire]).request.options else {
            Issue.record("not a get")
            return
        }
        #expect(options.allowCredentials == [id])

        let apex = passkey(credentialID: id, rpID: "hetzner.com")
        var sub = passkey(credentialID: Data([1]), rpID: "accounts.hetzner.com")
        sub.id = UUID()
        let accounts = [account(passkeys: [apex, sub])]
        func matched(_ rpID: String, _ allowed: [Data]) -> [Data] {
            WebsiteAuthenticator.assertionCandidates(accounts, rpID: rpID, allowed: allowed).map(\.passkey.credentialID)
        }
        #expect(matched("hetzner.com", [id]) == [id])
        #expect(matched("hetzner.com", []) == [id], "discoverable: every passkey of the RP ID")
        #expect(matched("accounts.hetzner.com", [id]).isEmpty, "WebAuthn scopes a credential to exactly its RP ID")
        #expect(matched("hetzner.com", [Data([1])]).isEmpty, "a listed ID of another RP ID does not match")
        #expect(matched("accounts.hetzner.com", []) == [Data([1])])
    }
}
