// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

nonisolated enum PasskeyUnlockError: Error {
    case busy
    /// The provider created a credential; the user may need to remove it if setup could not finish.
    case registrationCompleted(credentialID: Data, underlying: any Error)
    /// Registration was cancelled after the provider request started; its result is unknown.
    case registrationOutcomeUnknown
    case appCancelled
    case unsupportedPRF(credentialID: Data?)
    case invalidNativeResult
    case failed(domain: String, code: Int)
}

nonisolated struct VaultUnlockRegistration: Sendable {
    let credentialID: Data
    let prfInput: Data
    let registrationOutput: SymmetricKey?

    func verifiedAssertion(_ assertion: VaultUnlockProof) throws -> VaultUnlockProof {
        guard assertion.credentialID == credentialID, assertion.prfInput == prfInput else {
            throw PasskeyUnlockError.invalidNativeResult
        }
        if let registrationOutput, registrationOutput != assertion.prf {
            throw PasskeyUnlockError.invalidNativeResult
        }
        return assertion
    }
}

/// Owns the AuthenticationServices ceremony lifetime for vault unlock passkeys on the controlled RP.
/// Results are never forwarded after `cancel()`; the vault key is only ever a real native PRF output.
@MainActor
final class PasskeyVaultUnlocker: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated static let relyingParty = "wsurf.app"
    private typealias PRFValues = ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues

    private final class Ceremony {
        let controller: ASAuthorizationController
        let anchor: ASPresentationAnchor
        private var continuation: CheckedContinuation<ASAuthorization, any Error>?

        init(controller: ASAuthorizationController, anchor: ASPresentationAnchor, continuation: CheckedContinuation<ASAuthorization, any Error>) {
            self.controller = controller
            self.anchor = anchor
            self.continuation = continuation
        }

        func finish(_ result: Result<ASAuthorization, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private var active: Ceremony?
    // A canceled controller stays retained until its own completion callback arrives.
    private var retired: [ObjectIdentifier: Ceremony] = [:]

    /// Creates an external passkey. Its PRF output is only a consistency check; unlock uses a fresh assertion.
    func register(in anchor: ASPresentationAnchor) async throws -> VaultUnlockRegistration {
        try Task.checkCancellation()
        let challenge = Self.random(), userID = Self.random(), prfInput = Self.random()
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
            .createCredentialRegistrationRequest(challenge: challenge, name: "WSurf Vault Unlock", userID: userID)
        request.displayName = "WSurf Vault Unlock"
        request.userVerificationPreference = .required
        request.prf = .inputValues(.init(saltInput1: prfInput, saltInput2: nil))

        let authorization: ASAuthorization
        do { authorization = try await perform(request, in: anchor) }
        catch PasskeyUnlockError.appCancelled { throw PasskeyUnlockError.registrationOutcomeUnknown }
        guard let result = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw PasskeyUnlockError.invalidNativeResult
        }
        let credentialID: Data = result.credentialID
        do {
            try Task.checkCancellation()
            guard (1...1_024).contains(credentialID.count) else { throw PasskeyUnlockError.invalidNativeResult }
            try Self.validateClientData(result.rawClientDataJSON, challenge: challenge, type: "webauthn.create")
            guard result.prf?.isSupported == true else { throw PasskeyUnlockError.unsupportedPRF(credentialID: credentialID) }
            let output = result.prf?.first
            if let output, output.bitCount != 256 {
                throw PasskeyUnlockError.unsupportedPRF(credentialID: credentialID)
            }
            return VaultUnlockRegistration(credentialID: credentialID, prfInput: prfInput, registrationOutput: output)
        } catch {
            throw PasskeyUnlockError.registrationCompleted(credentialID: credentialID, underlying: error)
        }
    }

    /// Confirms a registered credential with the same stable PRF input before its first vault write.
    func verifyRegistration(
        _ registration: VaultUnlockRegistration,
        in anchor: ASPresentationAnchor,
        beforeAssertion: () throws -> Void
    ) async throws -> VaultUnlockProof {
        do {
            try Task.checkCancellation()
            try beforeAssertion()
            let assertion = try await assert(
                among: [VaultUnlock(credentialID: registration.credentialID, prfInput: registration.prfInput)],
                in: anchor
            )
            return try registration.verifiedAssertion(assertion)
        } catch {
            throw PasskeyUnlockError.registrationCompleted(credentialID: registration.credentialID, underlying: error)
        }
    }

    /// One assertion where the provider picks any of `unlocks`; each credential keeps its own stable PRF input.
    func assert(among unlocks: [VaultUnlock], in anchor: ASPresentationAnchor) async throws -> VaultUnlockProof {
        guard let first = unlocks.first else { throw PasskeyUnlockError.invalidNativeResult }
        let challenge = Self.random()
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
            .createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = unlocks.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.credentialID) }
        request.userVerificationPreference = .required
        let perCredential = Dictionary(
            unlocks.map { ($0.credentialID, PRFValues(saltInput1: $0.prfInput, saltInput2: nil)) },
            uniquingKeysWith: { existing, _ in existing }
        )
        request.prf = .inputValues(PRFValues(saltInput1: first.prfInput, saltInput2: nil), perCredentialInputValues: perCredential)

        let authorization = try await perform(request, in: anchor)
        guard let result = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
              let unlock = unlocks.first(where: { $0.credentialID == result.credentialID }) else {
            throw PasskeyUnlockError.invalidNativeResult
        }
        try Self.validateClientData(result.rawClientDataJSON, challenge: challenge, type: "webauthn.get")
        let authenticatorData: Data = result.rawAuthenticatorData
        guard authenticatorData.count >= 37,
              Data(authenticatorData.prefix(32)) == Data(SHA256.hash(data: Data(Self.relyingParty.utf8))),
              authenticatorData[authenticatorData.startIndex + 32] & 0x05 == 0x05 else {
            throw PasskeyUnlockError.invalidNativeResult
        }
        guard let prf = result.prf?.first, prf.bitCount == 256 else {
            throw PasskeyUnlockError.unsupportedPRF(credentialID: result.credentialID)
        }
        return VaultUnlockProof(credentialID: unlock.credentialID, prfInput: unlock.prfInput, prf: prf)
    }

    /// Fails the pending call immediately; any late native result is discarded.
    func cancel() {
        guard let ceremony = active else { return }
        cancel(ceremony)
    }

    private func cancel(controllerID: ObjectIdentifier) {
        guard let ceremony = active, ObjectIdentifier(ceremony.controller) == controllerID else { return }
        cancel(ceremony)
    }

    private func cancel(_ ceremony: Ceremony) {
        guard active === ceremony else { return }
        active = nil
        retired[ObjectIdentifier(ceremony.controller)] = ceremony
        ceremony.finish(.failure(PasskeyUnlockError.appCancelled))
        ceremony.controller.cancel()
    }

    private func perform(_ request: ASAuthorizationRequest, in anchor: ASPresentationAnchor) async throws -> ASAuthorization {
        try Task.checkCancellation()
        guard active == nil else { throw PasskeyUnlockError.busy }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let controllerID = ObjectIdentifier(controller)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                active = Ceremony(controller: controller, anchor: anchor, continuation: continuation)
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel(controllerID: controllerID) }
        }
    }

    private func complete(_ controller: ASAuthorizationController, _ result: Result<ASAuthorization, any Error>) {
        if retired.removeValue(forKey: ObjectIdentifier(controller)) != nil {
            controller.delegate = nil
            controller.presentationContextProvider = nil
            return
        }
        guard let ceremony = active, ceremony.controller === controller else { return }
        active = nil
        controller.delegate = nil
        controller.presentationContextProvider = nil
        ceremony.finish(result)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        complete(controller, .success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let native = error as NSError
        // Provider error text may contain account details; keep only domain and code.
        let failure: any Error = native.domain == ASAuthorizationErrorDomain && native.code == ASAuthorizationError.canceled.rawValue
            ? CancellationError()
            : PasskeyUnlockError.failed(domain: native.domain, code: native.code)
        complete(controller, .failure(failure))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let ceremony = active, ceremony.controller === controller { return ceremony.anchor }
        guard let ceremony = retired[ObjectIdentifier(controller)] else {
            preconditionFailure("Authorization controller has no passkey ceremony")
        }
        return ceremony.anchor
    }

    private static func random() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func validateClientData(_ data: Data, challenge: Data, type: String) throws {
        let encodedChallenge = challenge.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard data.count <= 16_384,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == type,
              json["challenge"] as? String == encodedChallenge,
              json["origin"] as? String == "https://\(relyingParty)",
              (json["crossOrigin"] as? Bool) != true else { throw PasskeyUnlockError.invalidNativeResult }
    }
}
