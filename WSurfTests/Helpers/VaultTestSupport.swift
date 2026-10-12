// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

@testable import WSurf

nonisolated struct VaultTestEnvironment {
    let directory: URL
    let defaults: UserDefaults
    let clock: TestClock
    let profile: Profile
    private let suiteName: String

    static func make() throws -> VaultTestEnvironment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = UUID().uuidString
        return VaultTestEnvironment(
            directory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            clock: TestClock(),
            profile: Profile(id: UUID(), name: "Test", symbol: "key", color: .blue),
            suiteName: suiteName
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
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
