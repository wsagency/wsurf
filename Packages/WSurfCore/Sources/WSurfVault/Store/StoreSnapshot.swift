// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// `version` and `digest` of one live account row, taken from the verified head `liveCatalog`.
nonisolated struct AccountStamp: Equatable, Sendable {
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
nonisolated struct StoreSnapshot: Sendable {
    let vaultID: UUID
    let revision: UInt64
    let accounts: [CredentialAccount]
    let blockedPasswordOrigins: Set<String>
    let stamps: [UUID: AccountStamp]
}

/// One active vault as the pre-unlock list shows it: `name` stays nil until the vault is unlocked (names are sealed in the head).
nonisolated struct VaultListing: Equatable, Sendable {
    let vaultID: UUID
    let ordinal: Int
    let name: String?
    let isUnlocked: Bool
    let isVerified: Bool
}

/// A fresh assertion (credential id and PRF output) for `authorize`.
nonisolated struct FreshAuthorization: Sendable {
    let credentialID: Data
    let prf: SymmetricKey
}
