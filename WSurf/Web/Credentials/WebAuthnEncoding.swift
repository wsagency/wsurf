// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

nonisolated enum WebAuthnEncoding {
    static func clientDataJSON(type: String, challenge: Data, client: WebAuthnClientData) throws -> Data {
        var object: [String: Any] = [
            "type": type,
            "challenge": base64URL(challenge),
            "origin": client.origin,
            "crossOrigin": client.crossOrigin
        ]
        if client.crossOrigin, let topOrigin = client.topOrigin {
            object["topOrigin"] = topOrigin
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func subjectPublicKeyInfo(_ publicKey: P256.Signing.PublicKey) throws -> Data {
        let x963 = publicKey.x963Representation
        guard x963.count == 65, x963.first == 0x04 else {
            throw WebsiteAuthenticatorError.invalidCredential
        }
        var spki = Data([
            0x30, 0x59, 0x30, 0x13,
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        ])
        spki.append(x963)
        return spki
    }

    static func registrationAuthenticatorData(
        rpID: String,
        userVerified: Bool,
        credentialID: Data,
        publicKey: P256.Signing.PublicKey
    ) throws -> Data {
        guard !credentialID.isEmpty, credentialID.count <= 1_024,
              credentialID.count <= Int(UInt16.max) else { throw WebsiteAuthenticatorError.invalidRequest }
        let key = publicKey.x963Representation
        guard key.count == 65, key.first == 0x04 else { throw WebsiteAuthenticatorError.invalidCredential }

        var data = rpIDHash(rpID)
        data.reserveCapacity(135 + credentialID.count)
        var flags: UInt8 = 0x01 | 0x08 | 0x40 // UP, BE, AT; software credentials are not backed up.
        if userVerified { flags |= 0x04 }
        data.append(flags)
        appendCounter(0, to: &data)
        data.append(contentsOf: repeatElement(0, count: 16)) // No attestation identity.
        data.append(UInt8(credentialID.count >> 8))
        data.append(UInt8(credentialID.count & 0xFF))
        data.append(credentialID)
        appendCosePublicKey(key, to: &data)
        return data
    }

    static func assertionAuthenticatorData(
        rpID: String,
        userVerified: Bool,
        backupEligible: Bool,
        backupState: Bool
    ) -> Data {
        var data = rpIDHash(rpID)
        var flags: UInt8 = 0x01 // UP
        if userVerified { flags |= 0x04 }
        if backupEligible { flags |= 0x08 }
        if backupState { flags |= 0x10 }
        data.append(flags)
        appendCounter(0, to: &data)
        return data
    }

    static func noneAttestationObject(authenticatorData: Data) -> Data {

        var result = Data()
        result.reserveCapacity(authenticatorData.count + 24)
        appendHead(major: 5, value: 3, to: &result)
        appendText("fmt", to: &result)
        appendText("none", to: &result)
        appendText("attStmt", to: &result)
        result.append(0xA0)
        appendText("authData", to: &result)
        appendBytes(authenticatorData, to: &result)
        return result
    }

    private static func rpIDHash(_ rpID: String) -> Data {
        Data(SHA256.hash(data: Data(rpID.utf8)))
    }

    private static func appendCosePublicKey(_ x963: Data, to data: inout Data) {
        appendHead(major: 5, value: 5, to: &data)
        appendInteger(1, to: &data); appendInteger(2, to: &data) // kty: EC2
        appendInteger(3, to: &data); appendInteger(-7, to: &data) // alg: ES256
        appendInteger(-1, to: &data); appendInteger(1, to: &data) // crv: P-256
        appendInteger(-2, to: &data)
        appendHead(major: 2, value: 32, to: &data)
        data.append(contentsOf: x963[1..<33])
        appendInteger(-3, to: &data)
        appendHead(major: 2, value: 32, to: &data)
        data.append(contentsOf: x963[33..<65])
    }

    private static func appendCounter(_ counter: UInt32, to data: inout Data) {
        data.append(UInt8((counter >> 24) & 0xFF))
        data.append(UInt8((counter >> 16) & 0xFF))
        data.append(UInt8((counter >> 8) & 0xFF))
        data.append(UInt8(counter & 0xFF))
    }

    private static func appendInteger(_ value: Int, to data: inout Data) {
        if value >= 0 {
            appendHead(major: 0, value: UInt64(value), to: &data)
        } else {
            appendHead(major: 1, value: UInt64(-1 - value), to: &data)
        }
    }

    private static func appendText(_ value: String, to data: inout Data) {
        appendHead(major: 3, value: UInt64(value.utf8.count), to: &data)
        data.append(contentsOf: value.utf8)
    }

    private static func appendBytes(_ value: Data, to data: inout Data) {
        appendHead(major: 2, value: UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendHead(major: UInt8, value: UInt64, to data: inout Data) {
        let prefix = major << 5
        switch value {
        case 0..<24:
            data.append(prefix | UInt8(value))
        case 24...UInt64(UInt8.max):
            data.append(prefix | 24)
            data.append(UInt8(value))
        case 256...UInt64(UInt16.max):
            data.append(prefix | 25)
            data.append(UInt8(value >> 8))
            data.append(UInt8(value & 0xFF))
        case 65_536...UInt64(UInt32.max):
            data.append(prefix | 26)
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        default:
            data.append(prefix | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
    }
}
