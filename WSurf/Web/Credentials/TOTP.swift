// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

nonisolated struct TOTPCode: Sendable, Equatable {
    let value: String
    let remainingSeconds: TimeInterval
    let expiresAt: TimeInterval
}

nonisolated enum TOTP {
    private static let maximumSetupBytes = CredentialVaultLimits.payloadBytes

    static func parse(
        _ input: String,
        algorithm: TOTPAlgorithm = .sha1,
        period: UInt16 = 30,
        digits: UInt16 = 6
    ) throws -> TOTPGenerator {
        guard input.utf8.count <= maximumSetupBytes, !input.isEmpty else {
            throw CredentialVaultError.invalidData
        }

        let generator: TOTPGenerator
        if String(input.prefix(8)).lowercased() == "otpauth:" {
            generator = try parseURI(input, algorithm: algorithm, period: period, digits: digits)
        } else {
            guard !input.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                throw CredentialVaultError.invalidData
            }
            generator = TOTPGenerator(
                secret: try decodeBase32(input),
                algorithm: algorithm,
                period: period,
                digits: digits,
                issuer: nil,
                userName: nil
            )
        }
        try generator.validate()
        return generator
    }

    static func code(_ generator: TOTPGenerator, at unixTime: TimeInterval) throws -> TOTPCode {
        try generator.validate()
        guard unixTime.isFinite, unixTime >= 0 else { throw CredentialVaultError.invalidData }
        let period = TimeInterval(generator.period)

        // Double(UInt64.max) rounds to 2^64; divide the exact integer seconds before narrowing.
        guard unixTime < Double(UInt128.max) else { throw CredentialVaultError.invalidData }
        let counterValue = UInt128(unixTime) / UInt128(generator.period)
        guard counterValue <= UInt128(UInt64.max) else { throw CredentialVaultError.invalidData }
        let counter = UInt64(counterValue)
        let key = SymmetricKey(data: generator.secret)
        let truncated: UInt32
        switch generator.algorithm {
        case .sha1:
            truncated = dynamicTruncate(Insecure.SHA1.self, key: key, counter: counter)
        case .sha256:
            truncated = dynamicTruncate(SHA256.self, key: key, counter: counter)
        case .sha512:
            truncated = dynamicTruncate(SHA512.self, key: key, counter: counter)
        }
        let modulus = (0..<generator.digits).reduce(UInt64(1)) { value, _ in value * 10 }
        let digits = String(UInt64(truncated) % modulus)
        let value = String(repeating: "0", count: Int(generator.digits) - digits.count) + digits

        let remainder = unixTime.truncatingRemainder(dividingBy: period)
        let remaining = remainder == 0 ? period : period - remainder
        let expiresAt = unixTime + remaining
        guard remaining.isFinite, expiresAt.isFinite else { throw CredentialVaultError.invalidData }
        return TOTPCode(value: value, remainingSeconds: remaining, expiresAt: expiresAt)
    }

    private static func dynamicTruncate<Hash: HashFunction>(
        _ hash: Hash.Type,
        key: SymmetricKey,
        counter: UInt64
    ) -> UInt32 {
        var hmac = HMAC<Hash>(key: key)
        var bigEndianCounter = counter.bigEndian
        withUnsafeBytes(of: &bigEndianCounter) { bytes in
            let message = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                count: bytes.count,
                deallocator: .none
            )
            hmac.update(data: message)
        }
        let digest = hmac.finalize()
        return digest.withUnsafeBytes { bytes in
            let offset = Int(bytes[bytes.count - 1] & 0x0f)
            return UInt32(bytes[offset] & 0x7f) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }

    private static func parseURI(
        _ input: String,
        algorithm defaultAlgorithm: TOTPAlgorithm,
        period defaultPeriod: UInt16,
        digits defaultDigits: UInt16
    ) throws -> TOTPGenerator {
        guard input.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }),
              let components = URLComponents(string: input),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/"), components.percentEncodedPath.count > 1,
              !components.percentEncodedPath.dropFirst().contains("/"),
              let label = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding, !label.isEmpty,
              let query = components.percentEncodedQuery, !query.isEmpty else {
            throw CredentialVaultError.invalidData
        }

        var parameters: [String: String] = [:]
        var start = query.startIndex
        while true {
            let end = query[start...].firstIndex(of: "&") ?? query.endIndex
            let item = query[start..<end]
            guard !item.isEmpty, let separator = item.firstIndex(of: "=") else {
                throw CredentialVaultError.invalidData
            }
            let name = String(item[..<separator])
            let encodedValue = item[item.index(after: separator)...]
            guard name == "secret" || name == "issuer" || name == "algorithm" || name == "digits" || name == "period",
                  parameters[name] == nil,
                  let value = encodedValue.removingPercentEncoding, !value.isEmpty else {
                throw CredentialVaultError.invalidData
            }
            parameters[name] = value
            if end == query.endIndex {
                break
            }
            start = query.index(after: end)
        }
        guard let secret = parameters["secret"] else { throw CredentialVaultError.invalidData }

        let labelParts = label.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let labelIssuer: String?
        let userName: String
        if labelParts.count == 2 {
            guard !labelParts[0].isEmpty, !labelParts[1].isEmpty else { throw CredentialVaultError.invalidData }
            labelIssuer = String(labelParts[0])
            userName = String(labelParts[1])
        } else {
            labelIssuer = nil
            userName = label
        }
        if let labelIssuer, let queryIssuer = parameters["issuer"], labelIssuer != queryIssuer {
            throw CredentialVaultError.invalidData
        }

        let algorithm = try parameters["algorithm"].map(parseAlgorithm) ?? defaultAlgorithm
        let period = try parameters["period"].map(parseUInt16) ?? defaultPeriod
        let digits = try parameters["digits"].map(parseUInt16) ?? defaultDigits
        return TOTPGenerator(
            secret: try decodeBase32(secret),
            algorithm: algorithm,
            period: period,
            digits: digits,
            issuer: parameters["issuer"] ?? labelIssuer,
            userName: userName
        )
    }

    private static func parseAlgorithm(_ value: String) throws -> TOTPAlgorithm {
        guard value.utf8.count <= 6, value.utf8.allSatisfy({ $0 < 128 }) else {
            throw CredentialVaultError.invalidData
        }
        return switch value.uppercased() {
        case "SHA1":
            .sha1
        case "SHA256":
            .sha256
        case "SHA512":
            .sha512
        default:
            throw CredentialVaultError.invalidData
        }
    }

    private static func parseUInt16(_ value: String) throws -> UInt16 {
        guard value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = UInt16(value) else {
            throw CredentialVaultError.invalidData
        }
        return number
    }

    private static func decodeBase32(_ string: String) throws -> Data {
        let bytes = string.utf8
        let byteCount = bytes.count
        guard byteCount > 0, byteCount <= maximumSetupBytes else { throw CredentialVaultError.invalidData }

        let paddingStart = bytes.firstIndex(of: 61) ?? bytes.endIndex
        let contentCount = bytes.distance(from: bytes.startIndex, to: paddingStart)
        let paddingCount = byteCount - contentCount
        let remainder = contentCount % 8
        let requiredPadding: Int
        switch remainder {
        case 0:
            requiredPadding = 0
        case 2:
            requiredPadding = 6
        case 4:
            requiredPadding = 4
        case 5:
            requiredPadding = 3
        case 7:
            requiredPadding = 1
        default:
            throw CredentialVaultError.invalidData
        }
        guard contentCount > 0,
              paddingCount == 0 || (byteCount % 8 == 0 && paddingCount == requiredPadding),
              bytes[paddingStart...].allSatisfy({ $0 == 61 }),
              (contentCount * 5) / 8 <= CredentialVaultLimits.payloadBytes else {
            throw CredentialVaultError.invalidData
        }

        var output = Data()
        output.reserveCapacity((contentCount * 5) / 8)
        var accumulator: UInt32 = 0
        var bitCount = 0
        for byte in bytes[..<paddingStart] {
            let value: UInt8
            switch byte {
            case 65...90:
                value = byte - 65
            case 97...122:
                value = byte - 97
            case 50...55:
                value = byte - 50 + 26
            default:
                throw CredentialVaultError.invalidData
            }
            accumulator = (accumulator << 5) | UInt32(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((accumulator >> bitCount) & 0xff))
                accumulator &= (1 << bitCount) - 1
            }
        }
        guard accumulator == 0, !output.isEmpty else { throw CredentialVaultError.invalidData }
        return output
    }
}
