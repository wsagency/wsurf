// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Bounded conversion between the page-facing JSON messages and the native authenticator types. Nothing here grants
/// authority: origin, frame, policy and profile come from native context, never from these messages.
nonisolated enum WebAuthnWire {
    enum Mediation: String, Sendable { case optional, required, conditional }

    struct Parsed: Sendable {
        let id: String
        let operation: WebAuthnOperation
        let mediation: Mediation
        let request: WebAuthnRequest
    }

    /// A malformed message maps to `TypeError`; the page script already rejects most of these before sending.
    struct Malformed: Error { let reason: String }

    struct PageError: Error, Sendable, Equatable {
        let name: String
        let message: String
    }

    static let maximumMessageBytes = 262_144
    static let minimumTimeout: Double = 10_000
    static let maximumTimeout: Double = 600_000
    static let defaultTimeout: Double = 300_000

    /// JSON `true`/`false` arrive as boolean `NSNumber`s, which a numeric cast still reads as 1 and 0; JSON `0`/`1` are
    /// ordinary numbers of the same Swift type, told apart only by their CoreFoundation type.
    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func base64URLDecode(_ value: Any?, maximum: Int = 65_536) throws -> Data {
        guard let value = value as? String, value.utf8.count <= maximum * 2,
              value.utf8.allSatisfy({ $0 != 0x2B && $0 != 0x2F && $0 != 0x3D }) else { throw Malformed(reason: "buffer") }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), data.count <= maximum,
              base64URL(data) == value else { throw Malformed(reason: "buffer") }
        return data
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Parses a relay `request` message. `now` is injectable so deadline arithmetic is testable.
    static func parse(
        _ body: [String: Any],
        now: ContinuousClock.Instant = .now
    ) throws -> Parsed {
        guard let id = body["id"] as? String, (1...80).contains(id.count),
              let operationName = body["operation"] as? String,
              let options = body["options"] as? [String: Any] else { throw Malformed(reason: "shape") }
        let operation: WebAuthnOperation
        switch operationName {
        case "create":
            operation = .create
        case "get":
            operation = .get
        default:
            throw Malformed(reason: "operation")
        }
        guard let mediation = Mediation(rawValue: body["mediation"] as? String ?? "optional") else { throw Malformed(reason: "mediation") }
        if operation == .create, mediation == .conditional { throw Malformed(reason: "mediation") }

        let timeout: Double
        if let raw = options["timeout"] {
            guard let number = raw as? Double, !isBoolean(raw), number.isFinite, number >= 0 else { throw Malformed(reason: "timeout") }
            timeout = min(maximumTimeout, max(minimumTimeout, number))
        } else {
            timeout = defaultTimeout
        }
        let isConditional = operation == .get && mediation == .conditional
        let deadline: ContinuousClock.Instant? = isConditional ? nil : now.advanced(by: .milliseconds(Int64(timeout)))
        let challenge = try base64URLDecode(options["challenge"], maximum: 1_024)
        let verification = try enumValue(WebAuthnUserVerification.self, options["userVerification"], default: .preferred)

        let parsed: WebAuthnRequestOptions
        switch operation {
        case .create:
            guard let rp = options["rp"] as? [String: Any], rp["name"] is String,
                  let user = options["user"] as? [String: Any],
                  let userName = user["name"] as? String, let displayName = user["displayName"] as? String else {
                throw Malformed(reason: "user")
            }
            let algorithms = (options["algorithms"] as? [Any]) ?? []
            guard algorithms.count <= 64 else { throw Malformed(reason: "algorithms") }
            let integers = try algorithms.map { value -> Int in
                guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue == Double(number.intValue) else { throw Malformed(reason: "algorithms") }
                return number.intValue
            }
            let attachment = try (options["authenticatorAttachment"] as? String).map { raw -> WebAuthnAuthenticatorAttachment in
                switch raw {
                case "platform":
                    return .platform
                case "cross-platform":
                    return .crossPlatform
                default:
                    throw Malformed(reason: "attachment")
                }
            }
            parsed = .creation(WebAuthnCreationOptions(
                challenge: challenge,
                rpID: rp["id"] as? String,
                userID: try base64URLDecode(user["id"], maximum: 64),
                userName: userName,
                userDisplayName: displayName,
                publicKeyAlgorithms: integers,
                excludeCredentials: try descriptors(options["excludeCredentials"]),
                residentKey: try enumValue(WebAuthnResidentKeyRequirement.self, options["residentKey"], default: .discouraged),
                authenticatorAttachment: attachment,
                userVerification: verification,
                attestation: try enumValue(WebAuthnAttestationConveyance.self, options["attestation"], default: .none),
                extensions: WebAuthnExtensionOptions(credProps: options["credProps"] as? Bool ?? false)
            ))
        case .get:
            parsed = .assertion(WebAuthnAssertionOptions(
                challenge: challenge,
                rpID: options["rpId"] as? String,
                allowCredentials: try descriptors(options["allowCredentials"]),
                userVerification: verification
            ))
        }
        return Parsed(
            id: id, operation: operation, mediation: mediation,
            request: WebAuthnRequest(requestID: UUID(), options: parsed, deadline: deadline)
        )
    }

    private static func enumValue<T: RawRepresentable>(_: T.Type, _ raw: Any?, default fallback: T) throws -> T where T.RawValue == String {
        guard let raw else { return fallback }
        guard let string = raw as? String, let value = T(rawValue: string) else { throw Malformed(reason: "enum") }
        return value
    }

    private static func descriptors(_ raw: Any?) throws -> [Data] {
        guard let raw else { return [] }
        guard let list = raw as? [[String: Any]], list.count <= 1_000 else { throw Malformed(reason: "descriptors") }
        return try list.map { try base64URLDecode($0["id"], maximum: 1_024) }
    }

    // MARK: Results

    /// The browser-facing payload for a successful ceremony: base64url buffers only, never key material.
    static func resultJSON(_ result: WebAuthnResult, operation: WebAuthnOperation) throws -> [String: Any] {
        let id = base64URL(result.credentialID)
        var response: [String: Any] = ["clientDataJSON": base64URL(result.clientDataJSON)]
        guard let authenticatorData = result.authenticatorData else { throw Malformed(reason: "result") }
        response["authenticatorData"] = base64URL(authenticatorData)
        switch operation {
        case .create:
            guard let attestation = result.attestationObject, let key = result.publicKeySPKI,
                  let algorithm = result.publicKeyAlgorithm else { throw Malformed(reason: "result") }
            response["attestationObject"] = base64URL(attestation)
            response["publicKey"] = base64URL(key)
            response["publicKeyAlgorithm"] = algorithm
        case .get:
            guard let signature = result.signature else { throw Malformed(reason: "result") }
            response["signature"] = base64URL(signature)
            if let handle = result.userHandle, !handle.isEmpty { response["userHandle"] = base64URL(handle) }
        }
        var extensions: [String: Any] = [:]
        if let properties = result.clientExtensionResults?.credProps { extensions["credProps"] = ["rk": properties.rk] }
        return [
            "operation": operation == .create ? "create" : "get",
            "id": id, "rawId": id, "type": "public-key", "authenticatorAttachment": "platform",
            "response": response, "clientExtensionResults": extensions,
        ]
    }

    // MARK: Errors

    /// DOMException name for a native failure. Context errors are mapped by the adapter, which knows their cases.
    static func pageError(_ error: any Error) -> PageError {
        switch error {
        case let error as PageError:
            return error
        case is Malformed:
            return PageError(name: "TypeError", message: "The request is malformed.")
        case is CancellationError:
            return PageError(name: "AbortError", message: "The request was cancelled.")
        case let error as WebsiteAuthenticatorError:
            switch error {
            case .invalidRequest:
                return PageError(name: "SecurityError", message: "The relying party is not valid for this origin.")
            case .invalidContext:
                return PageError(name: "SecurityError", message: "This page cannot use passkeys.")
            case .credentialExcluded:
                return PageError(name: "InvalidStateError", message: "The authenticator was not able to process the request.")
            case .unsupported:
                return PageError(name: "NotSupportedError", message: "No supported passkey option was requested.")
            case .notAllowed, .expired, .invalidCredential:
                return PageError(name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform.")
            case .savedNotDelivered:
                return PageError(name: "NotAllowedError", message: "The request could not be completed.")
            }
        default:
            return PageError(name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform.")
        }
    }
}
