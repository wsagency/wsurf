// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

nonisolated enum WebAuthnResidentKeyRequirement: String, Sendable {
    case required
    case preferred
    case discouraged
}

nonisolated enum WebAuthnUserVerification: String, Sendable {
    case required
    case preferred
    case discouraged
}

nonisolated enum WebAuthnAuthenticatorAttachment: String, Sendable {
    case platform
    case crossPlatform
}

nonisolated enum WebAuthnAttestationConveyance: String, Sendable {
    case none
    case indirect
    case direct
    case enterprise
}

nonisolated struct WebAuthnExtensionOptions: Sendable {
    var credProps: Bool
}

nonisolated struct WebAuthnCreationOptions: Sendable {
    var challenge: Data
    var rpID: String?
    var userID: Data
    var userName: String
    var userDisplayName: String
    var publicKeyAlgorithms: [Int]
    var excludeCredentials: [Data]
    var residentKey: WebAuthnResidentKeyRequirement
    var authenticatorAttachment: WebAuthnAuthenticatorAttachment?
    var userVerification: WebAuthnUserVerification
    var attestation: WebAuthnAttestationConveyance
    var extensions: WebAuthnExtensionOptions
}

nonisolated struct WebAuthnAssertionOptions: Sendable {
    var challenge: Data
    var rpID: String?
    var allowCredentials: [Data]
    var userVerification: WebAuthnUserVerification
}

nonisolated enum WebAuthnRequestOptions: Sendable {
    case creation(WebAuthnCreationOptions)
    case assertion(WebAuthnAssertionOptions)
}

/// `deadline` is nil only for a conditional assertion, whose lifetime is unbounded (WebAuthn L3: the timer is infinite);
/// it then ends only by abort, navigation, lock or provider change. Every other request has a finite deadline.
nonisolated struct WebAuthnRequest: Sendable {
    var requestID: UUID
    var options: WebAuthnRequestOptions
    var deadline: ContinuousClock.Instant?
}

nonisolated struct WebAuthnClientData: Sendable {
    var origin: String
    var topOrigin: String?
    var crossOrigin: Bool
    var rpID: String
}

nonisolated struct WebAuthnConsent: Sendable {
    var requestID: UUID
    var userPresent: Bool
    var userVerified: Bool
}

nonisolated struct WebAuthnCredentialProperties: Sendable {
    var rk: Bool
}

nonisolated struct WebAuthnClientExtensionResults: Sendable {
    var credProps: WebAuthnCredentialProperties?
}

nonisolated struct WebAuthnResult: Sendable {
    var credentialID: Data
    var clientDataJSON: Data
    var attestationObject: Data?
    var authenticatorData: Data?
    var signature: Data?
    var userHandle: Data?
    var clientExtensionResults: WebAuthnClientExtensionResults?
    var publicKeySPKI: Data?
    var publicKeyAlgorithm: Int?
}

nonisolated struct WebsiteRegistration: Sendable {
    var result: WebAuthnResult
    var account: CredentialAccount
}

nonisolated enum WebsiteAuthenticatorError: Error, Sendable {
    case invalidRequest
    case invalidContext
    /// The request's `excludeCredentials` names a passkey this authenticator already holds for the relying party.
    case credentialExcluded
    case notAllowed
    case unsupported
    case expired
    case invalidCredential
    /// The registration is durably saved but could not be delivered to the page (cancelled, navigated, locked or expired
    /// after the commit). The vault revision is the receipt; the page must still see a failure.
    case savedNotDelivered(revision: UInt64)
}

nonisolated enum WebsiteAuthenticator {
    private static let maximumRequestBytes = 256 * 1_024
    private static let maximumChallengeBytes = 1_024
    private static let maximumUserHandleBytes = 64
    private static let maximumDescriptors = 1_000
    private static let maximumCredentialIDBytes = 1_024
    private static let maximumUserNameBytes = 2_048

    static func makeRegistration(
        _ request: WebAuthnRequest,
        client: WebAuthnClientData,
        account: CredentialAccount,
        consent: WebAuthnConsent
    ) throws -> WebsiteRegistration {
        guard case let .creation(options) = request.options else { throw WebsiteAuthenticatorError.invalidRequest }
        try validateDeadline(request)
        try validateConsent(consent, request: request, userVerification: options.userVerification)
        let context = try validateClient(client, rawRPID: options.rpID)
        try validateCreation(options)
        try validateRequestBudget(options, client: client)
        // An empty list defaults to ES256 and RS256; this authenticator supports ES256.
        guard options.publicKeyAlgorithms.isEmpty || options.publicKeyAlgorithms.contains(-7) else {
            throw WebsiteAuthenticatorError.unsupported
        }
        if options.authenticatorAttachment == .crossPlatform {
            throw WebsiteAuthenticatorError.unsupported
        }
        guard !options.excludeCredentials.contains(where: { excludedID in
            account.passkeys.contains { $0.rpID == context.rpID && $0.credentialID == excludedID }
        }) else { throw WebsiteAuthenticatorError.credentialExcluded }

        let privateKey = P256.Signing.PrivateKey()
        let credentialID = Self.randomCredentialID()
        guard !account.passkeys.contains(where: { $0.credentialID == credentialID }) else {
            throw WebsiteAuthenticatorError.notAllowed
        }
        let privateKeyPKCS8 = try PasskeyKeyEncoding.exportPKCS8(privateKey)
        let passkey = WebsitePasskey(
            id: UUID(),
            credentialID: credentialID,
            rpID: context.rpID,
            userHandle: options.userID,
            userName: options.userName,
            userDisplayName: options.userDisplayName,
            algorithm: -7,
            privateKeyPKCS8: privateKeyPKCS8,
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        try passkey.validate()

        let clientDataJSON = WebAuthnEncoding.clientDataJSON(
            type: "webauthn.create",
            challenge: options.challenge,
            client: client
        )
        let authenticatorData = try WebAuthnEncoding.registrationAuthenticatorData(
            rpID: context.rpID,
            userVerified: consent.userVerified,
            credentialID: credentialID,
            publicKey: privateKey.publicKey
        )
        let publicKeySPKI = try WebAuthnEncoding.subjectPublicKeyInfo(privateKey.publicKey)
        // No attestation key is available, so any conveyance preference returns fmt=none.
        let attestationObject = WebAuthnEncoding.noneAttestationObject(authenticatorData: authenticatorData)
        var updatedAccount = account
        updatedAccount.passkeys.append(passkey)
        try updatedAccount.validate()
        try validateDeadline(request)

        return WebsiteRegistration(
            result: WebAuthnResult(
                credentialID: credentialID,
                clientDataJSON: clientDataJSON,
                attestationObject: attestationObject,
                authenticatorData: authenticatorData,
                signature: nil,
                userHandle: nil,
                clientExtensionResults: options.extensions.credProps
                    ? WebAuthnClientExtensionResults(credProps: WebAuthnCredentialProperties(rk: true))
                    : nil,
                publicKeySPKI: publicKeySPKI,
                publicKeyAlgorithm: -7
            ),
            account: updatedAccount
        )
    }

    static func makeAssertion(
        _ request: WebAuthnRequest,
        client: WebAuthnClientData,
        passkey: WebsitePasskey,
        consent: WebAuthnConsent
    ) throws -> WebAuthnResult {
        guard case let .assertion(options) = request.options else { throw WebsiteAuthenticatorError.invalidRequest }
        try validateDeadline(request)
        try validateConsent(consent, request: request, userVerification: options.userVerification)
        let context = try validateClient(client, rawRPID: options.rpID)
        try validateAssertion(options)
        try validateRequestBudget(options, client: client)
        try passkey.validate()
        guard passkey.rpID == context.rpID else { throw WebsiteAuthenticatorError.invalidCredential }
        guard options.allowCredentials.isEmpty || options.allowCredentials.contains(passkey.credentialID) else {
            throw WebsiteAuthenticatorError.notAllowed
        }

        let privateKey = try PasskeyKeyEncoding.importPKCS8(passkey.privateKeyPKCS8)
        let clientDataJSON = WebAuthnEncoding.clientDataJSON(
            type: "webauthn.get",
            challenge: options.challenge,
            client: client
        )
        let authenticatorData = WebAuthnEncoding.assertionAuthenticatorData(
            rpID: context.rpID,
            userVerified: consent.userVerified,
            backupEligible: passkey.backupEligible,
            backupState: passkey.backupState
        )
        var signedData = authenticatorData
        signedData.append(Data(SHA256.hash(data: clientDataJSON)))
        let signature = try privateKey.signature(for: signedData).derRepresentation
        try validateDeadline(request)

        return WebAuthnResult(
            credentialID: passkey.credentialID,
            clientDataJSON: clientDataJSON,
            attestationObject: nil,
            authenticatorData: authenticatorData,
            signature: signature,
            userHandle: passkey.userHandle,
            clientExtensionResults: nil,
            publicKeySPKI: nil,
            publicKeyAlgorithm: nil
        )
    }

    static func validateDeadline(_ request: WebAuthnRequest) throws {
        guard let deadline = request.deadline else { return }
        guard ContinuousClock.now < deadline else { throw WebsiteAuthenticatorError.expired }
    }

    private static func validateConsent(
        _ consent: WebAuthnConsent,
        request: WebAuthnRequest,
        userVerification: WebAuthnUserVerification
    ) throws {
        guard consent.requestID == request.requestID else { throw WebsiteAuthenticatorError.notAllowed }
        guard consent.userPresent else { throw WebsiteAuthenticatorError.notAllowed }
        if userVerification == .required && !consent.userVerified {
            throw WebsiteAuthenticatorError.notAllowed
        }
    }

    static func validateClient(_ client: WebAuthnClientData, rawRPID: String?) throws -> (origin: URL, rpID: String) {
        let origin = try canonicalOrigin(client.origin)
        let resolvedRPID: String
        do {
            resolvedRPID = try RelyingPartyPolicy.validate(rpID: client.rpID, origin: origin)
        } catch {
            throw WebsiteAuthenticatorError.invalidContext
        }
        guard resolvedRPID == client.rpID else { throw WebsiteAuthenticatorError.invalidContext }
        let requestedRPID: String
        do {
            requestedRPID = try RelyingPartyPolicy.validate(rpID: rawRPID, origin: origin)
        } catch {
            throw WebsiteAuthenticatorError.invalidRequest
        }
        guard requestedRPID == client.rpID else { throw WebsiteAuthenticatorError.invalidRequest }

        if client.crossOrigin {
            guard let topOrigin = client.topOrigin else {
                throw WebsiteAuthenticatorError.invalidContext
            }
            let top = try canonicalOrigin(topOrigin)
            do {
                _ = try RelyingPartyPolicy.validate(rpID: nil, origin: top)
            } catch {
                throw WebsiteAuthenticatorError.invalidContext
            }
        } else if client.topOrigin != nil {
            throw WebsiteAuthenticatorError.invalidContext
        }
        return (origin, resolvedRPID)
    }

    private static func canonicalOrigin(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let canonicalHost = RelyingPartyPolicy.canonicalDomain(host) else {
            throw WebsiteAuthenticatorError.invalidContext
        }

        components.scheme = scheme
        components.host = canonicalHost
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard components.string == value, let canonicalURL = components.url else {
            throw WebsiteAuthenticatorError.invalidContext
        }
        return canonicalURL
    }
    private static func validateCreation(_ options: WebAuthnCreationOptions) throws {
        guard options.challenge.count <= maximumChallengeBytes,
              (1...maximumUserHandleBytes).contains(options.userID.count),
              options.userName.utf8.count <= maximumUserNameBytes,
              options.userDisplayName.utf8.count <= maximumUserNameBytes,
              options.publicKeyAlgorithms.count <= maximumRequestBytes / MemoryLayout<Int>.size,
              options.excludeCredentials.count <= maximumDescriptors else {
            throw WebsiteAuthenticatorError.invalidRequest
        }
        try validateDescriptors(options.excludeCredentials)
    }

    private static func validateAssertion(_ options: WebAuthnAssertionOptions) throws {
        guard options.challenge.count <= maximumChallengeBytes,
              options.allowCredentials.count <= maximumDescriptors else {
            throw WebsiteAuthenticatorError.invalidRequest
        }
        try validateDescriptors(options.allowCredentials)
    }

    private static func validateDescriptors(_ identifiers: [Data]) throws {
        guard identifiers.count <= maximumDescriptors,
              identifiers.allSatisfy({ (1...maximumCredentialIDBytes).contains($0.count) }) else {
            throw WebsiteAuthenticatorError.invalidRequest
        }
    }

    private static func validateRequestBudget(_ options: WebAuthnCreationOptions, client: WebAuthnClientData) throws {
        var bytes = 512 // Request ID and fixed WebAuthn option fields.
        try add(options.challenge.count, to: &bytes)
        try add(options.rpID?.utf8.count ?? 0, to: &bytes)
        try add(options.userID.count, to: &bytes)
        try add(options.userName.utf8.count, to: &bytes)
        try add(options.userDisplayName.utf8.count, to: &bytes)
        try add(client.origin.utf8.count, to: &bytes)
        try add(client.rpID.utf8.count, to: &bytes)
        try add(client.topOrigin?.utf8.count ?? 0, to: &bytes)
        let (algorithmBytes, overflow) = options.publicKeyAlgorithms.count.multipliedReportingOverflow(by: MemoryLayout<Int>.size)
        guard !overflow else { throw WebsiteAuthenticatorError.invalidRequest }
        try add(algorithmBytes, to: &bytes)
        for identifier in options.excludeCredentials {
            try add(8, to: &bytes) // Array element framing.
            try add(identifier.count, to: &bytes)
        }
    }

    private static func validateRequestBudget(_ options: WebAuthnAssertionOptions, client: WebAuthnClientData) throws {
        var bytes = 512
        try add(options.challenge.count, to: &bytes)
        try add(options.rpID?.utf8.count ?? 0, to: &bytes)
        try add(client.origin.utf8.count, to: &bytes)
        try add(client.rpID.utf8.count, to: &bytes)
        try add(client.topOrigin?.utf8.count ?? 0, to: &bytes)
        for identifier in options.allowCredentials {
            try add(8, to: &bytes)
            try add(identifier.count, to: &bytes)
        }
    }

    private static func add(_ count: Int, to total: inout Int) throws {
        let (sum, overflow) = total.addingReportingOverflow(count)
        guard !overflow, sum <= maximumRequestBytes else { throw WebsiteAuthenticatorError.invalidRequest }
        total = sum
    }

    private static func randomCredentialID() -> Data {
        let randomBytes = SymmetricKey(size: .bits256)
        return randomBytes.withUnsafeBytes { Data($0) }
    }
}
