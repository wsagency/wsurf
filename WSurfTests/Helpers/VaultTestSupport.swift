// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

@testable import WSurf

// @unchecked: every field is an immutable `let`; Foundation documents UserDefaults as thread-safe and TestClock is itself checked
// `Sendable` (Mutex-guarded). The SDK just does not annotate UserDefaults `Sendable`.
nonisolated struct VaultTestEnvironment: @unchecked Sendable {
    let directory: URL
    let defaults: UserDefaults
    let clock: TestClock
    let profileID: UUID
    private let suiteName: String

    static func make() throws -> VaultTestEnvironment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // An absolute path keeps the domain's plist in the temporary folder rather than the user's ~/Library/Preferences.
        let suiteName = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        return VaultTestEnvironment(
            directory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            clock: TestClock(),
            profileID: UUID(),
            suiteName: suiteName
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: suiteName + ".plist")
        try? FileManager.default.removeItem(at: directory)
    }
}

nonisolated enum VaultFixtures {
    static func proof(_ n: UInt8 = 1) -> VaultUnlockProof {
        VaultUnlockProof(
            credentialID: Data(repeating: n, count: 32),
            prfInput: Data(repeating: n &+ 1, count: 32),
            prf: SymmetricKey(size: .bits256)
        )
    }

    static func account(
        id: UUID = UUID(),
        username: String = "ada",
        password: String? = "secret",
        origin: String = "https://example.test",
        passkeys: [WebsitePasskey] = []
    ) -> CredentialAccount {
        CredentialAccount(
            id: id,
            username: username,
            displayName: nil,
            origins: [origin],
            loginURLs: [URL(string: origin + "/login")!],
            password: password,
            passkeys: passkeys,
            totp: nil,
            exchangeAccountID: nil,
            exchangeItemID: nil
        )
    }

    static func passkey(rpID: String = "example.test", credentialID: Data = Data(repeating: 1, count: 32)) throws -> WebsitePasskey {
        WebsitePasskey(
            id: UUID(),
            credentialID: credentialID,
            rpID: rpID,
            userHandle: Data([1]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
    }
}

/// Fixed fixtures for the content-hash and diff suites. Every value is chosen so the expected canonical bytes can be
/// written down by hand (see the golden vectors in `VaultContentTests`).
nonisolated extension VaultFixtures {
    typealias ExchangeMetadata = CredentialExchangeCodec.ExchangeMetadata
    typealias ExchangeCollection = CredentialExchangeCodec.ExchangeCollection
    typealias ExchangeLink = CredentialExchangeCodec.ExchangeLink

    static let fixedAccountID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let fixedPasskeyID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let fixedScalar = Data((1...32).map { UInt8($0) })
    static let fixedCredentialID = Data((0xA0...0xAF).map { UInt8($0) })

    static func reference(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// The P-256 key with scalar 0x01...0x20 as PKCS#8. `embeddingPublicKey: false` is the same key spelled without
    /// the optional `[0]` curve and `[1]` public-key fields (still accepted by `PasskeyKeyEncoding.importPKCS8`).
    static func fixedPKCS8(embeddingPublicKey: Bool = true) throws -> Data {
        if embeddingPublicKey {
            return try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey(rawRepresentation: fixedScalar))
        }
        let algorithm = der(0x30, der(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]))
            + der(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])))
        let ecPrivateKey = der(0x30, der(0x02, Data([1])) + der(0x04, fixedScalar))
        return der(0x30, der(0x02, Data([0])) + algorithm + der(0x04, ecPrivateKey))
    }

    private static func der(_ tag: UInt8, _ contents: Data) -> Data {
        precondition(contents.count < 128, "fixture DER uses short lengths only")
        return Data([tag, UInt8(contents.count)]) + contents
    }

    static func fixedPasskey(rpID: String = "example.test") throws -> WebsitePasskey {
        WebsitePasskey(
            id: fixedPasskeyID,
            credentialID: fixedCredentialID,
            rpID: rpID,
            userHandle: Data([1, 2, 3]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try fixedPKCS8(),
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
    }

    static func exchangeMetadata() -> ExchangeMetadata {
        let sub = ExchangeCollection(
            id: Data([5]),
            created: reference(50),
            lastModified: reference(60),
            title: "Sub",
            subtitle: "S",
            items: [],
            subcollections: []
        )
        let top = ExchangeCollection(
            id: Data([1]),
            created: reference(10),
            lastModified: reference(20),
            title: "Top",
            subtitle: nil,
            items: [ExchangeLink(item: Data([2]), account: Data([3])), ExchangeLink(item: Data([4]), account: nil)],
            subcollections: [sub]
        )
        return ExchangeMetadata(
            accountName: "ada@example.test",
            email: "ada@example.test",
            fullName: "Ada L",
            collections: [top],
            subtitle: "Work login",
            created: reference(1_000),
            lastModified: reference(2_000),
            favorite: true,
            tags: ["a", "b"]
        )
    }

    /// The persisted-payload convention (`CredentialVaultCrypto.encodePayload`): sorted keys, default strategies.
    static func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func totp() -> TOTPGenerator {
        TOTPGenerator(secret: Data([1, 2, 3, 4, 5]), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: nil)
    }

    /// password `s3cret`, TOTP, one passkey, exchange metadata and ids: one account that holds every part.
    static func richAccount() throws -> CredentialAccount {
        CredentialAccount(
            id: fixedAccountID,
            username: "ada",
            displayName: "Work",
            origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!],
            password: "s3cret",
            passkeys: [try fixedPasskey()],
            totp: totp(),
            exchangeAccountID: Data([9]),
            exchangeItemID: Data([8]),
            exchangeMetadata: try sortedJSON(exchangeMetadata())
        )
    }
}
