// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security
import Testing

@testable import WSurf

struct WebsiteAuthenticatorTests {
    let origin = "https://login.example.com"
    let rpID = "example.com"
    private let userHandle = Data([0x10, 0x00, 0xA5, 0x7F])
    private let externalPrivateKeyPKCS8 = Data(hex:
        "308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b020101042089d940b147446fc1fe57e75e828f2a351327611abb288e8938d09903" +
        "0b874c68a14403420004282b6dfdd53a378a5fc7ebb5beb7f20ac8be9de03280946d4e01ab8ec00e63dc3ff207b902d205d4eba699409e85aff42e138f2abd326f7e8772aafa5f57241f"
    )
    private let externalPublicKeyX963 = Data(hex: "04282b6dfdd53a378a5fc7ebb5beb7f20ac8be9de03280946d4e01ab8ec00e63dc3ff207b902d205d4eba699409e85aff42e138f2abd326f7e8772aafa5f57241f")

    func account(passkeys: [WebsitePasskey] = []) -> CredentialAccount {
        CredentialAccount(
            id: UUID(uuidString: "A643FD7D-4A22-4533-8C74-7C19D0E6C7F1")!,
            username: "ada@example.com",
            displayName: "Ada",
            origins: [origin],
            loginURLs: [],
            password: nil,
            passkeys: passkeys,
            totp: nil,
            exchangeAccountID: nil,
            exchangeItemID: nil
        )
    }

    func registrationRequest(
        challenge: Data = Data("registration challenge".utf8),
        excludeCredentials: [Data] = [],
        rpID: String? = "example.com",
        residentKey: WebAuthnResidentKeyRequirement = .required,
        userVerification: WebAuthnUserVerification = .preferred,
        userID: Data = Data([0x10, 0x00, 0xA5, 0x7F]),
        publicKeyAlgorithms: [Int] = [-7],
        deadline: ContinuousClock.Instant? = nil,
        attestation: WebAuthnAttestationConveyance = .none,
        credProps: Bool = true
    ) -> WebAuthnRequest {
        WebAuthnRequest(
            requestID: UUID(uuidString: "B8C801CF-492E-436F-AC0D-36D138FF2955")!,
            options: .creation(WebAuthnCreationOptions(
                challenge: challenge,
                rpID: rpID,
                userID: userID,
                userName: "ada@example.com",
                userDisplayName: "Ada",
                publicKeyAlgorithms: publicKeyAlgorithms,
                excludeCredentials: excludeCredentials,
                residentKey: residentKey,
                authenticatorAttachment: nil,
                userVerification: userVerification,
                attestation: attestation,
                extensions: .init(credProps: credProps)
            )),
            deadline: deadline ?? ContinuousClock.now.advanced(by: .seconds(60))
        )
    }

    func assertionRequest(
        challenge: Data = Data("assertion challenge".utf8),
        allowCredentials: [Data] = [],
        rpID: String? = "example.com",
        userVerification: WebAuthnUserVerification = .preferred,
        deadline: ContinuousClock.Instant? = nil
    ) -> WebAuthnRequest {
        WebAuthnRequest(
            requestID: UUID(uuidString: "2C8A5F4A-004C-48BE-9FB7-3B6A4D903702")!,
            options: .assertion(WebAuthnAssertionOptions(
                challenge: challenge,
                rpID: rpID,
                allowCredentials: allowCredentials,
                userVerification: userVerification
            )),
            deadline: deadline ?? ContinuousClock.now.advanced(by: .seconds(60))
        )
    }

    func client(
        topOrigin: String? = nil,
        crossOrigin: Bool = false,
        rpID: String = "example.com"
    ) -> WebAuthnClientData {
        WebAuthnClientData(
            origin: origin,
            topOrigin: topOrigin,
            crossOrigin: crossOrigin,
            rpID: rpID
        )
    }

    func passkey(
        credentialID: Data = Data([0xC0, 0x01]),
        userHandle: Data = Data([0x10, 0x00, 0xA5, 0x7F]),
        rpID: String = "example.com"
    ) -> WebsitePasskey {
        WebsitePasskey(
            id: UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!,
            credentialID: credentialID,
            rpID: rpID,
            userHandle: userHandle,
            userName: "ada@example.com",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: externalPrivateKeyPKCS8,
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
    }

    func consent(
        for request: WebAuthnRequest,
        userPresent: Bool = true,
        userVerified: Bool = false
    ) -> WebAuthnConsent {
        WebAuthnConsent(requestID: request.requestID, userPresent: userPresent, userVerified: userVerified)
    }

    @Test func rawRPIDUsesExactTrustedNativeOriginAndRejectsContradictions() throws {
        let omittedRawRPID = registrationRequest(rpID: nil)
        let nativeClient = client(rpID: "login.example.com")
        let registered = try WebsiteAuthenticator.makeRegistration(
            omittedRawRPID,
            client: nativeClient,
            account: account(),
            consent: consent(for: omittedRawRPID)
        )
        let attestationObject = try #require(registered.result.attestationObject)
        let verified = try WebAuthnVerifier.registration(
            attestationObject: attestationObject,
            clientDataJSON: registered.result.clientDataJSON,
            challenge: Data("registration challenge".utf8),
            origin: origin,
            topOrigin: nil,
            crossOrigin: false,
            rpID: "login.example.com"
        )
        #expect(verified.credentialID == registered.result.credentialID)
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: attestationObject,
                clientDataJSON: registered.result.clientDataJSON,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: "example.com"
            )
        }

        let contradictoryRPID = registrationRequest(rpID: "attacker.example")
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                contradictoryRPID,
                client: nativeClient,
                account: account(),
                consent: consent(for: contradictoryRPID)
            )
        }
    }

    @Test func independentVerifierAcceptsOnlyBoundCeremonies() throws {
        let create = registrationRequest()
        let registered = try WebsiteAuthenticator.makeRegistration(
            create,
            client: client(),
            account: account(),
            consent: consent(for: create)
        )
        let createResult = registered.result
        let attestationObject = try #require(createResult.attestationObject)
        let registeredPasskey = try #require(registered.account.passkeys.first)
        let verifiedRegistration = try WebAuthnVerifier.registration(
            attestationObject: attestationObject,
            clientDataJSON: createResult.clientDataJSON,
            challenge: Data("registration challenge".utf8),
            origin: origin,
            topOrigin: nil,
            crossOrigin: false,
            rpID: rpID
        )
        #expect(verifiedRegistration.credentialID == createResult.credentialID)
        #expect(verifiedRegistration.counter == 0)
        #expect(verifiedRegistration.authenticatorData[32] & 0x01 == 0x01)
        #expect(verifiedRegistration.authenticatorData[32] & 0x04 == 0)
        let authData = verifiedRegistration.authenticatorData
        #expect(authData.subdata(in: 37..<53) == Data(repeating: 0, count: 16))
        let registrationFlags = authData[32]
        #expect(registrationFlags & 0x01 != 0)
        #expect(registrationFlags & 0x04 == 0)
        #expect(registrationFlags & 0x40 != 0)
        #expect(registrationFlags & 0x80 == 0)
        #expect(registrationFlags & 0x10 == 0 || registrationFlags & 0x08 != 0)

        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: makeAttestationObject(authenticatorData: authData, duplicateFormatKey: true),
                clientDataJSON: createResult.clientDataJSON,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: rpID
            )
        }
        var nonzeroAAGUID = authData
        nonzeroAAGUID[37] = 1
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: makeAttestationObject(authenticatorData: nonzeroAAGUID),
                clientDataJSON: createResult.clientDataJSON,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: rpID
            )
        }
        var inconsistentBackupFlags = authData
        inconsistentBackupFlags[32] = (inconsistentBackupFlags[32] & 0xF7) | 0x10
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: makeAttestationObject(authenticatorData: inconsistentBackupFlags),
                clientDataJSON: createResult.clientDataJSON,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: rpID
            )
        }

        var clientDataWithUnexpectedTopOrigin = try #require(
            JSONSerialization.jsonObject(with: createResult.clientDataJSON) as? [String: Any]
        )
        clientDataWithUnexpectedTopOrigin["topOrigin"] = "https://embedder.example.net"
        let unexpectedTopOriginClientData = try JSONSerialization.data(withJSONObject: clientDataWithUnexpectedTopOrigin)
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: attestationObject,
                clientDataJSON: unexpectedTopOriginClientData,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: rpID
            )
        }

        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: attestationObject,
                clientDataJSON: createResult.clientDataJSON,
                challenge: Data("wrong challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: rpID
            )
        }
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: attestationObject,
                clientDataJSON: createResult.clientDataJSON,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: nil,
                crossOrigin: false,
                rpID: "attacker.example"
            )
        }

        try expectBoundAssertionVerifies(registeredPasskey: registeredPasskey, publicKey: verifiedRegistration.publicKey)
    }

    private func expectBoundAssertionVerifies(registeredPasskey: WebsitePasskey, publicKey: SecKey) throws {
        let get = assertionRequest(allowCredentials: [registeredPasskey.credentialID])
        let assertion = try WebsiteAuthenticator.makeAssertion(
            get,
            client: client(),
            passkey: registeredPasskey,
            consent: consent(for: get)
        )
        let signature = try #require(assertion.signature)
        let authenticatorData = try #require(assertion.authenticatorData)
        let assertionCounter = try WebAuthnVerifier.assertion(
            authenticatorData: authenticatorData,
            clientDataJSON: assertion.clientDataJSON,
            signature: signature,
            publicKey: publicKey,
            challenge: Data("assertion challenge".utf8),
            origin: .init(origin: origin),
            rpID: rpID,
            userHandle: assertion.userHandle
        )
        #expect(assertionCounter == 0)
        #expect(assertion.credentialID == registeredPasskey.credentialID)
        #expect(assertion.userHandle == userHandle)
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.assertion(
                authenticatorData: authenticatorData,
                clientDataJSON: assertion.clientDataJSON,
                signature: Data([0]),
                publicKey: publicKey,
                challenge: Data("assertion challenge".utf8),
                origin: .init(origin: origin),
                rpID: rpID,
                userHandle: assertion.userHandle
            )
        }
    }

    @Test func crossOriginRegistrationBindsTopOrigin() throws {
        let topOrigin = "https://embedder.example.net"
        let request = registrationRequest()
        let registered = try WebsiteAuthenticator.makeRegistration(
            request,
            client: client(topOrigin: topOrigin, crossOrigin: true),
            account: account(),
            consent: consent(for: request)
        )
        let attestationObject = try #require(registered.result.attestationObject)
        let verified = try WebAuthnVerifier.registration(
            attestationObject: attestationObject,
            clientDataJSON: registered.result.clientDataJSON,
            challenge: Data("registration challenge".utf8),
            origin: origin,
            topOrigin: topOrigin,
            crossOrigin: true,
            rpID: rpID
        )
        #expect(verified.credentialID == registered.result.credentialID)
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.registration(
                attestationObject: attestationObject,
                clientDataJSON: registered.result.clientDataJSON,
                challenge: Data("registration challenge".utf8),
                origin: origin,
                topOrigin: "https://different-embedder.example.net",
                crossOrigin: true,
                rpID: rpID
            )
        }
    }

    @Test func crossOriginAtoBtoAChainIsVerified() throws {
        let request = registrationRequest()
        // A top-level A → cross-origin B → caller A chain may have equal origins and crossOrigin=true.
        let registered = try WebsiteAuthenticator.makeRegistration(
            request,
            client: client(topOrigin: origin, crossOrigin: true),
            account: account(),
            consent: consent(for: request)
        )
        let verified = try WebAuthnVerifier.registration(
            attestationObject: try #require(registered.result.attestationObject),
            clientDataJSON: registered.result.clientDataJSON,
            challenge: Data("registration challenge".utf8),
            origin: origin,
            topOrigin: origin,
            crossOrigin: true,
            rpID: rpID
        )
        #expect(verified.credentialID == registered.result.credentialID)
    }

    @Test func registrationReturnsRequestedCredPropsAndSPKI() throws {
        let request = registrationRequest()
        let registered = try WebsiteAuthenticator.makeRegistration(
            request,
            client: client(),
            account: account(),
            consent: consent(for: request)
        )
        let result = registered.result
        let verified = try WebAuthnVerifier.registration(
            attestationObject: try #require(result.attestationObject),
            clientDataJSON: result.clientDataJSON,
            challenge: Data("registration challenge".utf8),
            origin: origin,
            topOrigin: nil,
            crossOrigin: false,
            rpID: rpID
        )
        #expect(result.clientExtensionResults?.credProps?.rk == true)
        #expect(result.publicKeyAlgorithm == -7)
        let spki = try #require(result.publicKeySPKI)
        let publicKey = try #require(SecKeyCopyExternalRepresentation(verified.publicKey, nil) as? Data)
        #expect(spki == Data(hex: "3059301306072a8648ce3d020106082a8648ce3d030107034200") + publicKey)

        let unrequested = registrationRequest(credProps: false)
        let unrequestedResult = try WebsiteAuthenticator.makeRegistration(
            unrequested,
            client: client(),
            account: account(),
            consent: consent(for: unrequested)
        ).result
        #expect(unrequestedResult.clientExtensionResults?.credProps == nil)
    }

    @Test func emptyChallengeIsBoundWithoutAnInventedLengthFloor() throws {
        let challenge = Data()
        let request = registrationRequest(challenge: challenge)
        let registered = try WebsiteAuthenticator.makeRegistration(
            request,
            client: client(),
            account: account(),
            consent: consent(for: request)
        )
        let attestationObject = try #require(registered.result.attestationObject)
        let verified = try WebAuthnVerifier.registration(
            attestationObject: attestationObject,
            clientDataJSON: registered.result.clientDataJSON,
            challenge: challenge,
            origin: origin,
            topOrigin: nil,
            crossOrigin: false,
            rpID: rpID
        )
        #expect(verified.credentialID == registered.result.credentialID)
    }

    @Test func registrationPreservesExistingAccountAndDoesNotGrantNewOrigin() throws {
        let savedOrigin = "https://saved.example.net"
        let storedMetadata = Data([0xFA, 0xCE])
        let storedPasskey = WebsitePasskey(
            id: UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!,
            credentialID: Data([0xD0, 0x01]),
            rpID: "saved.example.net",
            userHandle: userHandle,
            userName: "ada@example.com",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: externalPrivateKeyPKCS8,
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: storedMetadata
        )
        var existing = account(passkeys: [storedPasskey])
        existing.origins = [savedOrigin]
        existing.loginURLs = [URL(string: "https://saved.example.net/login")!]
        existing.password = "existing password"
        existing.totp = TOTPGenerator(
            secret: Data([0xA1, 0xB2, 0xC3]),
            algorithm: .sha256,
            period: 45,
            digits: 8,
            issuer: "Existing issuer",
            userName: "ada@example.com"
        )
        let request = registrationRequest()
        let registered = try WebsiteAuthenticator.makeRegistration(
            request,
            client: client(),
            account: existing,
            consent: consent(for: request)
        )

        #expect(registered.account.origins == existing.origins)
        #expect(!registered.account.origins.contains(origin))
        #expect(registered.account.loginURLs == existing.loginURLs)
        #expect(registered.account.password == existing.password)
        #expect(registered.account.totp?.secret == existing.totp?.secret)
        #expect(registered.account.totp?.algorithm == existing.totp?.algorithm)
        #expect(registered.account.totp?.period == existing.totp?.period)
        #expect(registered.account.totp?.digits == existing.totp?.digits)
        #expect(registered.account.totp?.issuer == existing.totp?.issuer)
        #expect(registered.account.totp?.userName == existing.totp?.userName)
        let preservedPasskey = try #require(registered.account.passkeys.first { $0.id == storedPasskey.id })
        #expect(preservedPasskey.credentialID == storedPasskey.credentialID)
        #expect(preservedPasskey.privateKeyPKCS8 == storedPasskey.privateKeyPKCS8)
        #expect(preservedPasskey.exchangeFIDO2Metadata == storedPasskey.exchangeFIDO2Metadata)
        #expect(registered.account.passkeys.count == existing.passkeys.count + 1)
    }

    @Test func registrationAcceptsNewPasskeyOnlyAccount() throws {
        var newAccount = account()
        newAccount.username = ""
        newAccount.displayName = nil
        newAccount.origins = []
        newAccount.loginURLs = []
        let request = registrationRequest()
        let registered = try WebsiteAuthenticator.makeRegistration(
            request,
            client: client(),
            account: newAccount,
            consent: consent(for: request)
        )
        #expect(registered.account.username.isEmpty)
        #expect(registered.account.passkeys.count == 1)
        try registered.account.validate()
    }

    @Test func allowExcludeAndUserHandleAreAuthoritative() throws {
        let create = registrationRequest()
        let first = try WebsiteAuthenticator.makeRegistration(
            create,
            client: client(),
            account: account(),
            consent: consent(for: create)
        )
        let firstPasskey = try #require(first.account.passkeys.first)
        let accountWithCredential = first.account
        let excludedRequest = registrationRequest(excludeCredentials: [firstPasskey.credentialID])
        // Only an actual exclusion hit is named as one, and only it becomes InvalidStateError.
        do {
            _ = try WebsiteAuthenticator.makeRegistration(
                excludedRequest, client: client(), account: accountWithCredential, consent: consent(for: excludedRequest)
            )
            Issue.record("registered an excluded credential")
        } catch WebsiteAuthenticatorError.credentialExcluded {
            #expect(WebAuthnWire.pageError(WebsiteAuthenticatorError.credentialExcluded).name == "InvalidStateError")
        } catch { Issue.record("wrong error \(error)") }
        #expect(accountWithCredential.passkeys.map(\.credentialID) == [firstPasskey.credentialID])

        let disallowedRequest = assertionRequest(allowCredentials: [Data([0xFF])])
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeAssertion(
                disallowedRequest,
                client: client(),
                passkey: firstPasskey,
                consent: consent(for: disallowedRequest)
            )
        }
        let discoverableRequest = assertionRequest()
        let discoverable = try WebsiteAuthenticator.makeAssertion(
            discoverableRequest,
            client: client(),
            passkey: firstPasskey,
            consent: consent(for: discoverableRequest)
        )
        #expect(discoverable.credentialID == firstPasskey.credentialID)
        #expect(discoverable.userHandle == userHandle)
        #expect(firstPasskey.userName == "ada@example.com")
        #expect(firstPasskey.userDisplayName == "Ada")
    }

    @Test func consentMustBeBoundToItsRequest() throws {
        let request = registrationRequest()
        let unrelatedConsent = WebAuthnConsent(
            requestID: UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!,
            userPresent: true,
            userVerified: false
        )
        // A consent for another request is a refusal, never the "already registered" signal.
        do {
            _ = try WebsiteAuthenticator.makeRegistration(request, client: client(), account: account(), consent: unrelatedConsent)
            Issue.record("registered with a consent for another request")
        } catch WebsiteAuthenticatorError.notAllowed {} catch { Issue.record("wrong error \(error)") }
        #expect(WebAuthnWire.pageError(WebsiteAuthenticatorError.notAllowed).name == "NotAllowedError")
    }

    @Test func requiredUVUsesRequestBoundConsentFlag() throws {
        let create = registrationRequest(userVerification: .required)
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeRegistration(
                create,
                client: client(),
                account: account(),
                consent: consent(for: create, userVerified: false)
            )
        }
        let registered = try WebsiteAuthenticator.makeRegistration(
            create,
            client: client(),
            account: account(),
            consent: consent(for: create, userVerified: true)
        )
        let registeredPasskey = try #require(registered.account.passkeys.first)
        let request = assertionRequest(
            allowCredentials: [registeredPasskey.credentialID],
            userVerification: .required
        )
        #expect(throws: (any Error).self) {
            try WebsiteAuthenticator.makeAssertion(
                request,
                client: client(),
                passkey: registeredPasskey,
                consent: consent(for: request, userVerified: false)
            )
        }
        let result = try WebsiteAuthenticator.makeAssertion(
            request,
            client: client(),
            passkey: registeredPasskey,
            consent: consent(for: request, userVerified: true)
        )
        let authData = try #require(result.authenticatorData)
        #expect(authData[32] & 0x04 == 0x04)
    }

    @Test func assertionUsesExternalP256KeyAndIndependentSignatureVerification() throws {
        let passkey = WebsitePasskey(
            id: UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!,
            credentialID: Data([0xC0, 0x01]),
            rpID: rpID,
            userHandle: userHandle,
            userName: "ada@example.com",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: externalPrivateKeyPKCS8,
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        let request = assertionRequest(challenge: Data("external P-256 key".utf8))
        let result = try WebsiteAuthenticator.makeAssertion(
            request,
            client: client(),
            passkey: passkey,
            consent: consent(for: request)
        )
        let authenticatorData = try #require(result.authenticatorData)
        let signature = try #require(result.signature)
        let publicKey = try WebAuthnVerifier.publicKey(x963: externalPublicKeyX963)
        let counter = try WebAuthnVerifier.assertion(
            authenticatorData: authenticatorData,
            clientDataJSON: result.clientDataJSON,
            signature: signature,
            publicKey: publicKey,
            challenge: Data("external P-256 key".utf8),
            origin: .init(origin: origin),
            rpID: rpID,
            userHandle: result.userHandle
        )
        #expect(counter == 0)
        #expect(result.credentialID == passkey.credentialID)
        #expect(result.userHandle == userHandle)

        var modifiedSignedData = authenticatorData
        modifiedSignedData[36] ^= 0x01
        #expect(throws: (any Error).self) {
            try WebAuthnVerifier.assertion(
                authenticatorData: modifiedSignedData,
                clientDataJSON: result.clientDataJSON,
                signature: signature,
                publicKey: publicKey,
                challenge: Data("external P-256 key".utf8),
                origin: .init(origin: origin),
                rpID: rpID,
                userHandle: result.userHandle
            )
        }
    }

    private func makeAttestationObject(
        authenticatorData: Data,
        duplicateFormatKey: Bool = false
    ) -> Data {
        var object = Data([duplicateFormatKey ? 0xA4 : 0xA3])
        object.append(cborText("fmt"))
        object.append(cborText("none"))
        if duplicateFormatKey {
            object.append(cborText("fmt"))
            object.append(cborText("none"))
        }
        object.append(cborText("attStmt"))
        object.append(0xA0)
        object.append(cborText("authData"))
        object.append(cborBytes(authenticatorData))
        return object
    }

    private func cborText(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        precondition(bytes.count < 24)
        return Data([0x60 | UInt8(bytes.count)]) + bytes
    }

    private func cborBytes(_ bytes: Data) -> Data {
        switch bytes.count {
        case 0..<24:
            return Data([0x40 | UInt8(bytes.count)]) + bytes
        case 24...255:
            return Data([0x58, UInt8(bytes.count)]) + bytes
        case 256...65_535:
            return Data([0x59, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + bytes
        default:
            preconditionFailure("Unexpected test attestation size")
        }
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
