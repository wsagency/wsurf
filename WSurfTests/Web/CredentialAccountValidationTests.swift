// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

/// Account/passkey/TOTP validation and the v1 envelope field decoders: pure value checks with no vault, store or manager.
struct CredentialAccountValidationTests {
    private func validTestPasskey(rpID: String) throws -> WebsitePasskey {
        try VaultFixtures.passkey(rpID: rpID)
    }

    @Test func accountValidationKeepsOriginsCanonicalAndLoginURLsPathOnly() throws {
        var record = VaultFixtures.account()
        record.origins = ["https://EXAMPLE.test:443"]
        #expect(throws: (any Error).self) { try record.validate() }

        let sanitized = try CredentialAccount.sanitizedLoginURL(URL(string: "https://ada:secret@example.test:443/login?token=private#section")!)
        #expect(sanitized.absoluteString == "https://example.test/login")
        #expect(CredentialAccount.origin(for: URL(string: "http://example.test/login")!) == nil)
        #expect(CredentialAccount.origin(for: URL(string: "https://user@example.test/login")!) == nil)
    }

    @Test func invalidTOTPAndPKCS8InputsAreRejected() throws {
        for (period, digits) in [(UInt16(0), UInt16(6)), (UInt16(30), UInt16(5)), (UInt16(30), UInt16(11))] {
            let generator = TOTPGenerator(secret: Data([1, 2, 3]), algorithm: .sha1, period: period, digits: digits, issuer: nil, userName: nil)
            #expect(throws: (any Error).self) { try generator.validate() }
        }

        let oversized = Data(repeating: 0, count: 4_000_001)
        let key = P256.Signing.PrivateKey()
        let valid = try PasskeyKeyEncoding.exportPKCS8(key)
        let imported = try PasskeyKeyEncoding.importPKCS8(valid)
        #expect(imported.rawRepresentation == key.rawRepresentation)
        let message = Data("key-use fixture".utf8)
        let signature = try imported.signature(for: message)
        #expect(key.publicKey.isValidSignature(signature, for: message))
        var wrongCurve = valid
        let p256OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        if let oidRange = wrongCurve.range(of: p256OID) {
            wrongCurve[oidRange.upperBound - 1] = 0x22
        } else {
            Issue.record("PKCS#8 fixture did not contain the P-256 curve OID")
        }
        var contradictoryPublicKey = valid
        if let publicKeyRange = contradictoryPublicKey.range(of: key.publicKey.x963Representation) {
            contradictoryPublicKey[publicKeyRange.upperBound - 1] ^= 1
        } else {
            Issue.record("PKCS#8 fixture did not contain its public key")
        }
        var nonminimalLength = valid
        let lengthByte = nonminimalLength[1]
        if lengthByte & 0x80 == 0 {
            nonminimalLength[1] = 0x81
            nonminimalLength.insert(lengthByte, at: 2)
        } else {
            nonminimalLength[1] += 1
            nonminimalLength.insert(0, at: 2)
        }
        for der in [Data(), Data([0x30, 0x82, 0x01]), wrongCurve, contradictoryPublicKey, nonminimalLength, oversized] {
            #expect(throws: (any Error).self) { try PasskeyKeyEncoding.importPKCS8(der) }
        }
    }

    @Test func pkcs8ImportAcceptsNonzeroStartIndexDataSlice() throws {
        let key = P256.Signing.PrivateKey()
        let encoded = try PasskeyKeyEncoding.exportPKCS8(key)
        let padded = Data([0xFF]) + encoded + Data([0xFF])
        let start = padded.index(after: padded.startIndex)
        let end = padded.index(before: padded.endIndex)
        let slice = padded[start..<end]

        #expect(slice.startIndex == start)
        #expect(try PasskeyKeyEncoding.importPKCS8(slice).rawRepresentation == key.rawRepresentation)
    }

    @Test func canonicalRelyingPartyIDsAreUsableByStoredPasskeys() throws {
        let idna = try RelyingPartyPolicy.validate(
            rpID: "bücher.de",
            origin: URL(string: "https://login.bücher.de")!
        )
        #expect(idna == "xn--bcher-kva.de")
        try validTestPasskey(rpID: idna).validate()

        let trailingDot = try RelyingPartyPolicy.validate(
            rpID: "example.com.",
            origin: URL(string: "https://login.example.com.")!
        )
        #expect(trailingDot == "example.com.")
        try validTestPasskey(rpID: trailingDot).validate()
    }

    @Test func publicSuffixAndIPAddressRelyingPartiesRemainRejectedForCeremonies() throws {
        for rpID in ["com", "127.0.0.1"] {
            #expect(throws: (any Error).self) {
                try RelyingPartyPolicy.validate(rpID: rpID, origin: URL(string: "https://\(rpID)")!)
            }
        }
        #expect(throws: (any Error).self) { try validTestPasskey(rpID: "127.0.0.1").validate() }
    }

    @Test func passwordWithoutApprovedOriginRemainsValidForManualAssociation() throws {
        var unscoped = VaultFixtures.account()
        unscoped.origins = []
        unscoped.loginURLs = []
        try unscoped.validate()
        #expect(unscoped.origins.isEmpty && unscoped.loginURLs.isEmpty)
    }

    @Test func backupStateRequiresBackupEligibility() throws {
        var passkey = try validTestPasskey(rpID: "example.test")
        passkey.backupEligible = false
        try passkey.validate()

        passkey.backupState = true
        #expect(throws: (any Error).self) { try passkey.validate() }
    }

    @Test func envelopeFieldDecodersRejectOutOfBoundsDataWhileDecoding() throws {
        func wrapper(
            id: Int = 32, prf: Int = 32, nonce: Int = 12, ciphertext: Int = 32, tag: Int = 16
        ) -> CredentialKeyWrapper {
            CredentialKeyWrapper(
                credentialID: Data(repeating: 1, count: id), prfInput: Data(repeating: 2, count: prf),
                nonce: Data(repeating: 3, count: nonce), ciphertext: Data(repeating: 4, count: ciphertext),
                tag: Data(repeating: 5, count: tag)
            )
        }
        func sealed(nonce: Int = 12, ciphertext: Int = 32, tag: Int = 16) -> CredentialSealedData {
            CredentialSealedData(
                nonce: Data(repeating: 3, count: nonce), ciphertext: Data(repeating: 4, count: ciphertext),
                tag: Data(repeating: 5, count: tag)
            )
        }
        func decode<T: Codable>(_ value: T) throws -> T {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try PropertyListDecoder().decode(T.self, from: encoder.encode(value))
        }
        let limit = CredentialVaultCrypto.maximumUnlockFieldBytes

        // Valid boundary values keep their wire shape.
        #expect(try decode(wrapper(id: limit, prf: 1)).credentialID.count == limit)
        #expect(try decode(sealed(ciphertext: CredentialVaultLimits.payloadBytes)).ciphertext.count == CredentialVaultLimits.payloadBytes)

        for invalid in [
            wrapper(id: 0), wrapper(id: limit + 1), wrapper(prf: 0), wrapper(prf: limit + 1),
            wrapper(nonce: 11), wrapper(nonce: 13), wrapper(ciphertext: 31), wrapper(ciphertext: 33),
            wrapper(tag: 15), wrapper(tag: 17),
        ] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
        for invalid in [
            sealed(nonce: 11), sealed(nonce: 13), sealed(ciphertext: CredentialVaultLimits.payloadBytes + 1),
            sealed(tag: 15), sealed(tag: 17),
        ] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
    }

    @Test func basicAuthenticationMetadataPreservesEmptyAndAbsentPasswords() throws {
        let usernameField = CredentialEditableFieldMetadata(id: Data([1]), label: "Login", fieldType: .string)
        let passwordField = CredentialEditableFieldMetadata(id: Data([2]), label: "Password", fieldType: .concealedString)
        var presentEmpty = VaultFixtures.account(password: "")
        presentEmpty.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(username: usernameField, password: passwordField)
        try presentEmpty.validate()
        #expect(presentEmpty.password == "")

        var absent = VaultFixtures.account(password: nil)
        absent.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(username: usernameField, password: nil)
        try absent.validate()
        #expect(absent.password == nil)

        absent.password = ""
        #expect(throws: (any Error).self) { try absent.validate() }
        presentEmpty.basicAuthenticationMetadata?.password = nil
        #expect(throws: (any Error).self) { try presentEmpty.validate() }
        presentEmpty.basicAuthenticationMetadata?.password = CredentialEditableFieldMetadata(id: Data([1]), label: "Password", fieldType: .email)
        #expect(throws: (any Error).self) { try presentEmpty.validate() }
    }

    @Test func basicAuthenticationMetadataContributesToPayloadBudget() throws {
        let id = Data(repeating: 7, count: 1_024)
        let label = String(repeating: "x", count: 2_048)
        var record = VaultFixtures.account(username: String(repeating: "a", count: 3_994_000), password: "")
        record.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: id, label: label, fieldType: .string),
            password: CredentialEditableFieldMetadata(id: Data(repeating: 8, count: 1_024), label: label, fieldType: .concealedString)
        )
        record.basicAuthenticationMetadata?.username?.id = Data(repeating: 7, count: 1_025)
        #expect(throws: (any Error).self) { try record.validate() }
        record.basicAuthenticationMetadata?.username?.id = id
        record.basicAuthenticationMetadata?.username?.label = String(repeating: "x", count: 2_049)
        #expect(throws: (any Error).self) { try record.validate() }
        record.basicAuthenticationMetadata?.username?.label = label
        let payload = CredentialVaultPayload(revision: 0, accounts: [record], blockedPasswordOrigins: [])
        #expect(throws: (any Error).self) { try CredentialVaultCrypto.validate(payload) }

        record.username = "ada"
        record.basicAuthenticationMetadata?.password?.id = id
        #expect(throws: (any Error).self) { try record.validate() }
    }
}
