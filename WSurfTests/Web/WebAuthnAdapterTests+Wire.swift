// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

extension WebAuthnAdapterTests {
    // MARK: Wire

    @Test func wireParsesBoundedRequestsAndClampsTimeouts() throws {
        func body(_ options: [String: Any], operation: String = "get", mediation: String = "optional") throws -> [String: Any] {
            try bridged(["id": "r1", "operation": operation, "mediation": mediation, "options": options])
        }
        let challenge = WebAuthnWire.base64URL(Data([1, 2, 3]))
        let now = ContinuousClock.now

        let short = try WebAuthnWire.parse(body(["challenge": challenge, "timeout": 5]), now: now)
        #expect(short.request.deadline == now.advanced(by: .milliseconds(10_000)))
        let long = try WebAuthnWire.parse(body(["challenge": challenge, "timeout": 9_999_999]), now: now)
        #expect(long.request.deadline == now.advanced(by: .milliseconds(600_000)))
        let unspecified = try WebAuthnWire.parse(body(["challenge": challenge]), now: now)
        #expect(unspecified.request.deadline == now.advanced(by: .milliseconds(300_000)))

        for bad: [String: Any] in [
            ["challenge": "not+base64url"], ["challenge": challenge, "timeout": -1], ["challenge": challenge, "userVerification": "maybe"],
            ["challenge": WebAuthnWire.base64URL(Data(repeating: 0, count: 1_025))],
        ] {
            #expect(throws: (any Error).self) { try WebAuthnWire.parse(body(bad)) }
        }
        #expect(throws: (any Error).self) { try WebAuthnWire.parse(body(["challenge": challenge], operation: "create", mediation: "conditional")) }
        #expect(throws: (any Error).self) { try WebAuthnWire.parse(["id": "", "operation": "get", "options": ["challenge": challenge]]) }
        // Padding or the standard alphabet is not base64url.
        #expect(throws: (any Error).self) { try WebAuthnWire.base64URLDecode("AQID=") }
        #expect(throws: (any Error).self) { try WebAuthnWire.base64URLDecode("+/8") }
        #expect(try WebAuthnWire.base64URLDecode(challenge) == Data([1, 2, 3]))
    }

    /// JSON `true`/`false` cross the script-message bridge as `NSNumber` booleans, which a numeric cast still reads as 1 and
    /// 0. They are booleans, never a timeout or an algorithm; the real numbers 0 and 1 are not booleans and stay valid.
    @Test func wireNeverReadsJSONBooleansAsNumbers() throws {
        let now = ContinuousClock.now
        func parse(_ extra: [String: Any]) throws -> WebAuthnRequest {
            var options: [String: Any] = [
                "challenge": WebAuthnWire.base64URL(Data([1])), "rp": ["name": "x"],
                "user": ["id": WebAuthnWire.base64URL(Data([9])), "name": "a", "displayName": "A"],
            ]
            options.merge(extra) { _, new in new }
            return try WebAuthnWire.parse(
                bridged(["id": "r1", "operation": "create", "mediation": "optional", "options": options]), now: now
            ).request
        }
        for rejected: [String: Any] in [
            ["timeout": true], ["timeout": false], ["timeout": "5"],
            ["algorithms": [true]], ["algorithms": [false]], ["algorithms": [-7, true]], ["algorithms": [5.5]],
        ] {
            #expect(throws: WebAuthnWire.Malformed.self, "\(rejected)") { try parse(rejected) }
        }
        for (timeout, milliseconds): (Double, Int64) in [(0, 10_000), (1, 10_000), (5.5, 10_000), (20_000, 20_000)] {
            #expect(try parse(["timeout": timeout]).deadline == now.advanced(by: .milliseconds(milliseconds)), "timeout \(timeout)")
        }
        guard case .creation(let created) = try parse(["algorithms": [0, 1, -7, -257]]).options else {
            Issue.record("not a creation request"); return
        }
        #expect(created.publicKeyAlgorithms == [0, 1, -7, -257])
    }

    @Test func wireCreationOptionsCarryEveryAuthoritativeField() throws {
        let handle = Data([4, 5, 6]), excluded = Data([7, 7])
        let parsed = try WebAuthnWire.parse([
            "id": "c1", "operation": "create", "mediation": "optional",
            "options": [
                "challenge": WebAuthnWire.base64URL(Data([1])),
                "rp": ["name": "Example", "id": "example.com"],
                "user": ["id": WebAuthnWire.base64URL(handle), "name": "ada", "displayName": "Ada"],
                "algorithms": [-7, -257],
                "excludeCredentials": [["id": WebAuthnWire.base64URL(excluded)]],
                "authenticatorAttachment": "platform", "residentKey": "required", "userVerification": "required",
                "attestation": "direct", "credProps": true,
            ] as [String: Any],
        ])
        guard case let .creation(options) = parsed.request.options else { Issue.record("not a creation request"); return }
        #expect(options.rpID == "example.com" && options.userID == handle && options.userName == "ada")
        #expect(options.publicKeyAlgorithms == [-7, -257] && options.excludeCredentials == [excluded])
        #expect(options.residentKey == .required && options.userVerification == .required)
        #expect(options.authenticatorAttachment == .platform && options.attestation == .direct && options.extensions.credProps)
    }

    @Test func nativeFailuresMapToTheDOMExceptionsTheSpecDefines() {
        let cases: [(any Error, String)] = [
            (WebsiteAuthenticatorError.invalidRequest, "SecurityError"), (WebsiteAuthenticatorError.invalidContext, "SecurityError"),
            (WebsiteAuthenticatorError.credentialExcluded, "InvalidStateError"), (WebsiteAuthenticatorError.notAllowed, "NotAllowedError"),
            (WebsiteAuthenticatorError.unsupported, "NotSupportedError"), (WebsiteAuthenticatorError.expired, "NotAllowedError"),
            (WebsiteAuthenticatorError.savedNotDelivered(revision: 3), "NotAllowedError"),
            (CancellationError(), "AbortError"), (WebAuthnWire.Malformed(reason: "x"), "TypeError"),
        ]
        for (error, name) in cases {
            #expect(WebAuthnWire.pageError(error).name == name)
        }
    }
}
