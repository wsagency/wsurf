// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

nonisolated enum PasskeyKeyEncoding {
    static let maximumDERBytes = 4_096

    private static let ecPublicKeyOID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    private static let p256OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])

    static func importPKCS8(_ data: Data) throws -> P256.Signing.PrivateKey {
        guard !data.isEmpty, data.count <= maximumDERBytes else { throw CredentialVaultError.invalidData }
        do {
            var document = DERReader(data)
            let sequence = try document.read(0x30)
            try document.requireEnd()

            var privateKeyInfo = DERReader(sequence)
            guard try privateKeyInfo.read(0x02) == Data([0]) else { throw CredentialVaultError.invalidData }
            let algorithmBytes = try privateKeyInfo.read(0x30)
            var algorithm = DERReader(algorithmBytes)
            guard try algorithm.read(0x06) == ecPublicKeyOID,
                  try algorithm.read(0x06) == p256OID else { throw CredentialVaultError.invalidData }
            try algorithm.requireEnd()

            let ecPrivateKeyBytes = try privateKeyInfo.read(0x04)
            try privateKeyInfo.requireEnd()
            var ecDocument = DERReader(ecPrivateKeyBytes)
            let ecSequence = try ecDocument.read(0x30)
            try ecDocument.requireEnd()
            var ecPrivateKey = DERReader(ecSequence)
            guard try ecPrivateKey.read(0x02) == Data([1]) else { throw CredentialVaultError.invalidData }
            let scalar = try ecPrivateKey.read(0x04)
            guard scalar.count == 32 else { throw CredentialVaultError.invalidData }

            var embeddedPublicKey: Data?
            var embeddedCurve: Data?
            var lastOptionalTag: UInt8 = 0x9F
            while !ecPrivateKey.isAtEnd {
                let (tag, contents) = try ecPrivateKey.readAny()
                guard tag == 0xA0 || tag == 0xA1, tag > lastOptionalTag else {
                    throw CredentialVaultError.invalidData
                }
                lastOptionalTag = tag
                switch tag {
                case 0xA0:
                    guard embeddedCurve == nil else { throw CredentialVaultError.invalidData }
                    var parameters = DERReader(contents)
                    embeddedCurve = try parameters.read(0x06)
                    try parameters.requireEnd()
                    guard embeddedCurve == p256OID else { throw CredentialVaultError.invalidData }
                case 0xA1:
                    guard embeddedPublicKey == nil else { throw CredentialVaultError.invalidData }
                    var bitStringDER = DERReader(contents)
                    let bitString = try bitStringDER.read(0x03)
                    try bitStringDER.requireEnd()
                    guard bitString.count == 66, bitString.first == 0 else { throw CredentialVaultError.invalidData }
                    embeddedPublicKey = Data(bitString.dropFirst())
                default:
                    throw CredentialVaultError.invalidData
                }
            }

            let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
            if let embeddedPublicKey, embeddedPublicKey != key.publicKey.x963Representation {
                throw CredentialVaultError.invalidData
            }
            return key
        } catch {
            throw CredentialVaultError.invalidData
        }
    }

    static func exportPKCS8(_ key: P256.Signing.PrivateKey) throws -> Data {
        let scalar = key.rawRepresentation
        let publicKey = key.publicKey.x963Representation
        guard scalar.count == 32, publicKey.count == 65 else { throw CredentialVaultError.invalidData }

        var algorithm = Data()
        algorithm.append(derValue(0x06, ecPublicKeyOID))
        algorithm.append(derValue(0x06, p256OID))

        var ecPrivateKey = Data()
        ecPrivateKey.append(derValue(0x02, Data([1])))
        ecPrivateKey.append(derValue(0x04, scalar))
        ecPrivateKey.append(derValue(0xA0, derValue(0x06, p256OID)))
        var bitString = Data([0])
        bitString.append(publicKey)
        ecPrivateKey.append(derValue(0xA1, derValue(0x03, bitString)))

        var contents = Data()
        contents.append(derValue(0x02, Data([0])))
        contents.append(derValue(0x30, algorithm))
        contents.append(derValue(0x04, derValue(0x30, ecPrivateKey)))
        let result = derValue(0x30, contents)
        guard result.count <= maximumDERBytes else { throw CredentialVaultError.invalidData }
        return result
    }

    private static func derValue(_ tag: UInt8, _ contents: Data) -> Data {
        var result = Data()
        result.reserveCapacity(1 + 5 + contents.count)
        result.append(tag)
        let count = contents.count
        if count < 128 {
            result.append(UInt8(count))
        } else if count <= 0xFF {
            result.append(0x81)
            result.append(UInt8(count))
        } else if count <= 0xFFFF {
            result.append(0x82)
            result.append(UInt8(count >> 8))
            result.append(UInt8(count & 0xFF))
        } else {
            result.append(0x83)
            result.append(UInt8((count >> 16) & 0xFF))
            result.append(UInt8((count >> 8) & 0xFF))
            result.append(UInt8(count & 0xFF))
        }
        result.append(contents)
        return result
    }
}

nonisolated struct DERReader {
    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }
    var isAtEnd: Bool {
        offset == data.endIndex
    }

    mutating func read(_ expectedTag: UInt8) throws -> Data {
        let (tag, contents) = try readAny()
        guard tag == expectedTag else { throw CredentialVaultError.invalidData }
        return contents
    }

    mutating func readAny() throws -> (UInt8, Data) {
        guard offset < data.endIndex else { throw CredentialVaultError.invalidData }
        let tag = data[offset]
        offset = data.index(after: offset)
        guard offset < data.endIndex else { throw CredentialVaultError.invalidData }
        let firstLengthByte = data[offset]
        offset = data.index(after: offset)
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard lengthByteCount > 0, lengthByteCount <= 4,
                  lengthByteCount <= data.distance(from: offset, to: data.endIndex),
                  data[offset] != 0 else { throw CredentialVaultError.invalidData }
            var parsedLength = 0
            for _ in 0..<lengthByteCount {
                let next = Int(data[offset])
                guard parsedLength <= (Int.max - next) / 256 else { throw CredentialVaultError.invalidData }
                parsedLength = parsedLength * 256 + next
                offset = data.index(after: offset)
            }
            guard parsedLength >= 128,
                  lengthByteCount == 1 || parsedLength >= (1 << (8 * (lengthByteCount - 1))) else {
                throw CredentialVaultError.invalidData
            }
            length = parsedLength
        }
        guard length <= data.distance(from: offset, to: data.endIndex) else { throw CredentialVaultError.invalidData }
        let end = data.index(offset, offsetBy: length)
        let contents = data[offset..<end]
        offset = end
        return (tag, contents)
    }

    func requireEnd() throws {
        guard isAtEnd else { throw CredentialVaultError.invalidData }
    }
}
