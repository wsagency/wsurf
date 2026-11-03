// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation

/// `version` and `digest` of one live account row, taken from the verified head `liveCatalog`.
public nonisolated struct AccountStamp: Equatable, Sendable {
    let version: UInt64
    let digest: Data
}

/// What one live row decrypted to the last time this grant read it: the SHA-256 of the plaintext and the account decoded from it. A
/// row whose plaintext has the same digest decodes to the same account, so the next read skips only the JSON decode; it still reads,
/// hashes and decrypts the row. A write compares a proposed account's canonical JSON with the same digest.
nonisolated struct DecodedRow: Sendable {
    let plaintextDigest: Data
    let account: CredentialAccount
}

/// The v2 snapshot of one unlocked vault.
public nonisolated struct StoreSnapshot: Sendable {
    public let vaultID: UUID
    public let revision: UInt64
    public let accounts: [CredentialAccount]
    public let blockedPasswordOrigins: Set<String>
    public let stamps: [UUID: AccountStamp]
}

/// One active vault as the pre-unlock list shows it: `name` stays nil until the vault is unlocked (names are sealed in the head).
public nonisolated struct VaultListing: Equatable, Sendable {
    public let vaultID: UUID
    public let ordinal: Int
    public let name: String?
    let isUnlocked: Bool
    public let isVerified: Bool

    public init(vaultID: UUID, ordinal: Int, name: String?, isUnlocked: Bool, isVerified: Bool) {
        self.vaultID = vaultID
        self.ordinal = ordinal
        self.name = name
        self.isUnlocked = isUnlocked
        self.isVerified = isVerified
    }
}

/// A fresh assertion (credential id and PRF output) for `authorize`.
public nonisolated struct FreshAuthorization: Sendable {
    let credentialID: Data
    let prf: SymmetricKey

    public init(credentialID: Data, prf: SymmetricKey) {
        self.credentialID = credentialID
        self.prf = prf
    }
}
