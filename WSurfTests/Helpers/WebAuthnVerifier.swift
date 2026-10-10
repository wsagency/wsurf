// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import CryptoKit
import Foundation
import Security

nonisolated enum WebAuthnVerifier {
    struct Registration {
        let credentialID: Data
        let publicKey: SecKey
        let authenticatorData: Data
        let counter: UInt32
    }

    /// The client-data origin an assertion must carry: its origin, and the top-level origin when cross-origin.
    struct ExpectedClientOrigin {
        let origin: String
        var topOrigin: String?
        var crossOrigin = false
    }

    static func registration(
        attestationObject: Data,
        clientDataJSON: Data,
        challenge: Data,
        origin: String,
        topOrigin: String?,
        crossOrigin: Bool,
        rpID: String
    ) throws -> Registration {
        try verifyClientData(
            clientDataJSON,
            type: "webauthn.create",
            challenge: challenge,
            origin: origin,
            topOrigin: topOrigin,
            crossOrigin: crossOrigin
        )
        var reader = CBORReader(attestationObject)
        let attestation = try reader.readMap()
        guard reader.isAtEnd,
              attestation[.text("fmt")] == .text("none"),
              attestation[.text("attStmt")] == .map([]),
              let authData = attestation[.text("authData")]?.bytes,
              authData.count >= 55,
              authData.prefix(32) == Data(SHA256.hash(data: Data(rpID.utf8))) else {
            throw VerificationError.invalid
        }
        let flags = authData[32]
        guard flags & 0x01 != 0,
              flags & 0x40 != 0,
              flags & 0x80 == 0,
              flags & 0x10 == 0 || flags & 0x08 != 0,
              authData[37..<53].allSatisfy({ $0 == 0 }) else {
            throw VerificationError.invalid
        }
        let counter = authData[33..<37].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let credentialLength = Int(authData[53]) << 8 | Int(authData[54])
        let credentialEnd = 55 + credentialLength
        guard credentialLength > 0, credentialEnd < authData.count else { throw VerificationError.invalid }
        let credentialID = Data(authData[55..<credentialEnd])
        var coseReader = CBORReader(Data(authData[credentialEnd...]))
        let cose = try coseReader.readMap()
        guard coseReader.isAtEnd,
              cose[.integer(1)] == .integer(2),
              cose[.integer(3)] == .integer(-7),
              cose[.integer(-1)] == .integer(1),
              let x = cose[.integer(-2)]?.bytes, x.count == 32,
              let y = cose[.integer(-3)]?.bytes, y.count == 32 else {
            throw VerificationError.invalid
        }
        var point = Data([0x04])
        point.append(x)
        point.append(y)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let publicKey = SecKeyCreateWithData(point as CFData, attributes as CFDictionary, nil) else {
            throw VerificationError.invalid
        }
        return Registration(credentialID: credentialID, publicKey: publicKey, authenticatorData: authData, counter: counter)
    }

    static func assertion(
        authenticatorData: Data,
        clientDataJSON: Data,
        signature: Data,
        publicKey: SecKey,
        challenge: Data,
        origin expected: ExpectedClientOrigin,
        rpID: String,
        userHandle: Data?
    ) throws -> UInt32 {
        try verifyClientData(
            clientDataJSON,
            type: "webauthn.get",
            challenge: challenge,
            origin: expected.origin,
            topOrigin: expected.topOrigin,
            crossOrigin: expected.crossOrigin
        )
        guard authenticatorData.count == 37,
              authenticatorData.prefix(32) == Data(SHA256.hash(data: Data(rpID.utf8))) else {
            throw VerificationError.invalid
        }
        let flags = authenticatorData[32]
        guard flags & 0x01 != 0,
              flags & 0x80 == 0,
              flags & 0x10 == 0 || flags & 0x08 != 0 else { throw VerificationError.invalid }
        let clientHash = Data(SHA256.hash(data: clientDataJSON))
        var signedData = authenticatorData
        signedData.append(clientHash)
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, signedData as CFData, signature as CFData, &error) else {
            if let error {
                throw error.takeRetainedValue()
            }
            throw VerificationError.invalid
        }
        if let userHandle, userHandle.isEmpty {
            throw VerificationError.invalid
        }
        return authenticatorData[33..<37].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func publicKey(x963: Data) throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let publicKey = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, nil) else {
            throw VerificationError.invalid
        }
        return publicKey
    }

    private static func verifyClientData(
        _ data: Data,
        type: String,
        challenge: Data,
        origin: String,
        topOrigin: String?,
        crossOrigin: Bool
    ) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == type,
              json["challenge"] as? String == base64URL(challenge),
              json["origin"] as? String == origin,
              json["crossOrigin"] as? Bool == crossOrigin else { throw VerificationError.invalid }
        if crossOrigin {
            guard let topOrigin, json["topOrigin"] as? String == topOrigin else { throw VerificationError.invalid }
        } else {
            guard topOrigin == nil, json["topOrigin"] == nil else { throw VerificationError.invalid }
        }
        // Every relying party accepts a JSON parse; only the specified serialization also passes the prefix check.
        guard limitedClientDataVerifies(data, type: type, challenge: challenge, origin: origin, topOrigin: topOrigin) else {
            throw VerificationError.invalid
        }
    }

    /// WebAuthn Level 3 §5.8.1.2, literally: what a relying party without a JSON parser checks. The client data must
    /// begin with the specified serialization of `type`, `challenge`, `origin`, `crossOrigin` and, when a top-level
    /// origin is expected, `topOrigin` (required here), followed by `}` or `,`. Written from the specification
    /// text, not from the production encoder.
    static func limitedClientDataVerifies(
        _ clientDataJSON: Data,
        type: String,
        challenge: Data,
        origin: String,
        topOrigin: String?
    ) -> Bool {
        var expected = Data(#"{"type":"#.utf8)
        expected.append(ccdString(type))
        expected.append(Data(#","challenge":"#.utf8))
        expected.append(ccdString(base64URL(challenge)))
        expected.append(Data(#","origin":"#.utf8))
        expected.append(ccdString(origin))
        expected.append(Data(#","crossOrigin":"#.utf8))
        if let topOrigin {
            expected.append(Data("true".utf8))
            expected.append(Data(#","topOrigin":"#.utf8))
            expected.append(ccdString(topOrigin))
        } else {
            expected.append(Data("false".utf8))
        }
        let bytes = [UInt8](clientDataJSON)
        guard bytes.starts(with: expected), bytes.count > expected.count else { return false }
        return bytes[expected.count] == 0x7D || bytes[expected.count] == 0x2C
    }

    /// `CCDToString` (§5.8.1.1): only `"`, `\` and code points below U+0020 are escaped, so `/` stays literal.
    private static func ccdString(_ value: String) -> Data {
        var encoded = Data([0x22])
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x20, 0x21, 0x23...0x5B, 0x5D...0x10FFFF:
                encoded.append(contentsOf: String(scalar).utf8)
            case 0x22:
                encoded.append(contentsOf: [0x5C, 0x22])
            case 0x5C:
                encoded.append(contentsOf: [0x5C, 0x5C])
            default:
                encoded.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
            }
        }
        encoded.append(0x22)
        return encoded
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private enum VerificationError: Error { case invalid }

    private enum CBORValue: Hashable {
        case integer(Int)
        case text(String)
        case bytes(Data)
        case map([(CBORValue, CBORValue)])

        static func == (lhs: CBORValue, rhs: CBORValue) -> Bool {
            switch (lhs, rhs) {
            case let (.integer(a), .integer(b)):
                a == b
            case let (.text(a), .text(b)):
                a == b
            case let (.bytes(a), .bytes(b)):
                a == b
            case let (.map(a), .map(b)):
                a.elementsEqual(b, by: ==)
            default:
                false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case let .integer(value):
                hasher.combine(0)
                hasher.combine(value)
            case let .text(value):
                hasher.combine(1)
                hasher.combine(value)
            case let .bytes(value):
                hasher.combine(2)
                hasher.combine(value)
            case let .map(value):
                hasher.combine(3)
                for pair in value {
                    hasher.combine(pair.0)
                    hasher.combine(pair.1)
                }
            }
        }

        var bytes: Data? {
            if case let .bytes(value) = self {
                value
            } else {
                nil
            }
        }
    }

    private struct CBORReader {
        private let data: Data
        private var offset = 0
        var isAtEnd: Bool {
            offset == data.count
        }

        init(_ data: Data) {
            self.data = data
        }

        mutating func readMap() throws -> [CBORValue: CBORValue] {
            let initial = try readByte()
            guard initial >> 5 == 5 else { throw VerificationError.invalid }
            let count = try length(additional: initial & 0x1f)
            var values: [CBORValue: CBORValue] = [:]
            for _ in 0..<count {
                let key = try readValue()
                let value = try readValue()
                guard values.updateValue(value, forKey: key) == nil else { throw VerificationError.invalid }
            }
            return values
        }

        private mutating func readValue() throws -> CBORValue {
            let initial = try readByte()
            let major = initial >> 5
            let value = try length(additional: initial & 0x1f)
            switch major {
            case 0:
                return .integer(value)
            case 1:
                return .integer(-1 - value)
            case 2:
                return .bytes(try readData(value))
            case 3:
                guard let text = String(data: try readData(value), encoding: .utf8) else { throw VerificationError.invalid }
                return .text(text)
            case 5:
                var pairs: [(CBORValue, CBORValue)] = []
                for _ in 0..<value {
                    pairs.append((try readValue(), try readValue()))
                }
                return .map(pairs)
            default:
                throw VerificationError.invalid
            }
        }

        private mutating func length(additional: UInt8) throws -> Int {
            switch additional {
            case 0...23:
                Int(additional)
            case 24:
                Int(try readByte())
            case 25:
                Int(try readByte()) << 8 | Int(try readByte())
            case 26:
                Int(try readByte()) << 24 | Int(try readByte()) << 16 | Int(try readByte()) << 8 | Int(try readByte())
            default:
                throw VerificationError.invalid
            }
        }

        private mutating func readByte() throws -> UInt8 {
            guard offset < data.count else { throw VerificationError.invalid }
            defer { offset += 1 }
            return data[offset]
        }

        private mutating func readData(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw VerificationError.invalid }
            defer { offset += count }
            return Data(data[offset..<offset + count])
        }
    }
}
