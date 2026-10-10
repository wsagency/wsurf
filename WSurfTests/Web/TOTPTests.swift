// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

struct TOTPTests {
    private struct Vector {
        let time: TimeInterval
        let sha1: String
        let sha256: String
        let sha512: String
    }

    private let vectors = [
        Vector(time: 59, sha1: "94287082", sha256: "46119246", sha512: "90693936"),
        Vector(time: 1_111_111_109, sha1: "07081804", sha256: "68084774", sha512: "25091201"),
        Vector(time: 1_111_111_111, sha1: "14050471", sha256: "67062674", sha512: "99943326"),
        Vector(time: 1_234_567_890, sha1: "89005924", sha256: "91819424", sha512: "93441116"),
        Vector(time: 2_000_000_000, sha1: "69279037", sha256: "90698825", sha512: "38618901"),
        Vector(time: 20_000_000_000, sha1: "65353130", sha256: "77737706", sha512: "47863826"),
    ]

    private func generator(_ seed: String, algorithm: TOTPAlgorithm, digits: UInt16 = 8, period: UInt16 = 30) -> TOTPGenerator {
        TOTPGenerator(secret: Data(seed.utf8), algorithm: algorithm, period: period, digits: digits, issuer: nil, userName: nil)
    }

    @Test func rfc6238VectorsMatchAllAlgorithmsAtPublishedTimes() throws {
        let generators = [
            generator("12345678901234567890", algorithm: .sha1),
            generator("12345678901234567890123456789012", algorithm: .sha256),
            generator("1234567890123456789012345678901234567890123456789012345678901234", algorithm: .sha512),
        ]

        for vector in vectors {
            #expect(try TOTP.code(generators[0], at: vector.time).value == vector.sha1)
            #expect(try TOTP.code(generators[1], at: vector.time).value == vector.sha256)
            #expect(try TOTP.code(generators[2], at: vector.time).value == vector.sha512)
        }
    }

    @Test func numericBoundariesPreserveLeadingZerosAndTenDigits() throws {
        let sixDigits = generator("12345678901234567890", algorithm: .sha1, digits: 6)
        #expect(try TOTP.code(sixDigits, at: 59).value == "287082")

        let tenDigits = generator("12345678901234567890", algorithm: .sha1, digits: 10)
        #expect(try TOTP.code(tenDigits, at: 59).value == "1094287082")

        let oneSecond = generator("12345678901234567890", algorithm: .sha1, digits: 6, period: 1)
        let thirtySeconds = generator("12345678901234567890", algorithm: .sha1, digits: 6, period: 30)
        let maximumPeriod = generator("12345678901234567890", algorithm: .sha1, digits: 6, period: 65_535)
        #expect(try TOTP.code(oneSecond, at: 0).remainingSeconds == 1)
        #expect(try TOTP.code(thirtySeconds, at: 59.999).expiresAt == 60)
        #expect(try TOTP.code(thirtySeconds, at: 60).expiresAt == 90)
        #expect(try TOTP.code(maximumPeriod, at: 65_534).remainingSeconds == 1)
        #expect(try TOTP.code(maximumPeriod, at: 65_535).expiresAt == 131_070)
    }

    @Test func parsingRawBase32AndURIPreservesSupportedParametersAndIdentity() throws {
        let paddedFoo = try TOTP.parse("MZXW6===")
        #expect(paddedFoo.secret == Data("foo".utf8))
        let raw = try TOTP.parse("JBSWY3DPEHPK3PXP")
        #expect(raw.secret == Data([0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0xde, 0xad, 0xbe, 0xef]))
        #expect(raw.algorithm == .sha1)
        #expect(raw.period == 30)
        #expect(raw.digits == 6)

        let issuerWithoutPrefix = try TOTP.parse("otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&issuer=Example")
        #expect(issuerWithoutPrefix.issuer == "Example")
        #expect(issuerWithoutPrefix.userName == "alice")
        let uri = try TOTP.parse("otpauth://totp/Issuer%2BName:alice%2Btag?secret=JBSWY3DPEHPK3PXP&issuer=Issuer%2BName&algorithm=SHA256&digits=10&period=65535")
        #expect(uri.secret == raw.secret)
        #expect(uri.algorithm == .sha256)
        #expect(uri.period == 65_535)
        #expect(uri.digits == 10)
        #expect(uri.issuer == "Issuer+Name")
        #expect(uri.userName == "alice+tag")
    }

    @Test func codeLifetimeReportsFreshStepAtEachRequestedTime() throws {
        let value = generator("12345678901234567890", algorithm: .sha1, digits: 6)
        let before = try TOTP.code(value, at: 59.5)
        let after = try TOTP.code(value, at: 60)
        #expect(before.expiresAt == 60)
        #expect(before.remainingSeconds == 0.5)
        #expect(after.expiresAt == 90)
        #expect(after.remainingSeconds == 30)
        #expect(before.value != after.value)
    }

    @Test func malformedSetupAndCounterInputsAreRejected() throws {
        let invalidSetups = [
            "", "JBSWY3DP!", "MZ", "MZXW6==", "MZXW6==A", "123456", "otpauth://hotp/example?secret=JBSWY3DPEHPK3PXP&counter=1",
            "https://example.test/secret", "otpauth://totp/example?secret=", "otpauth://totp/example",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&secret=JBSWY3DPEHPK3PXP",
            "otpauth://totp/IssuerA:Label?secret=JBSWY3DPEHPK3PXP&issuer=IssuerB",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&algorithm=MD5",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&vendor=value",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&period=0",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&period=65536",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&digits=5",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&digits=11",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&algorithm=SHA1&algorithm=SHA256",
            "otpauth://totp/example?secret=JBSWY3DPEHPK3PXP&counter=1",
        ]
        for input in invalidSetups {
            #expect(throws: (any Error).self) { try TOTP.parse(input) }
        }

        for time in [TimeInterval.nan, .infinity, -.infinity, -0.01, 1e30] {
            #expect(throws: (any Error).self) { try TOTP.code(generator("12345678901234567890", algorithm: .sha1), at: time) }
        }
        let longRunning = generator("12345678901234567890", algorithm: .sha1)
        let post2038 = try TOTP.code(longRunning, at: 2_147_483_648)
        #expect(post2038.value == "24703886")
        let largeInRange = try TOTP.code(longRunning, at: Double(UInt64.max))
        #expect(largeInRange.value == "28277486")
        #expect(largeInRange.remainingSeconds.isFinite && (0...30).contains(largeInRange.remainingSeconds))
        #expect(largeInRange.expiresAt.isFinite)
        #expect(throws: (any Error).self) {
            try TOTP.code(generator("12345678901234567890", algorithm: .sha1, period: 1), at: Double(UInt64.max))
        }

        #expect(throws: (any Error).self) { try TOTP.parse("JBSWY3DPEHPK3PXP", period: 0) }
        #expect(throws: (any Error).self) { try TOTP.parse("JBSWY3DPEHPK3PXP", digits: 5) }
        #expect(throws: (any Error).self) { try TOTP.parse("JBSWY3DPEHPK3PXP", digits: 11) }
    }
}
