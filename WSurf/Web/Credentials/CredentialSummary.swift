// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Value types

nonisolated struct PasskeySummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let rpID: String
    let userName: String
    let createdAt: Date?
    let source: WebsitePasskeySource?
    let lastSignedAt: Date?

    init(_ passkey: WebsitePasskey) {
        id = passkey.id
        rpID = passkey.rpID
        userName = passkey.userName
        createdAt = passkey.createdAt
        source = passkey.source
        lastSignedAt = passkey.lastSignedAt
    }
}

/// Everything a row needs and nothing secret: passwords, TOTP seeds and passkey keys never leave the vault
/// snapshot. A `.concealedString` imported username is withheld until the user reveals it.
nonisolated struct CredentialSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let username: String?
    let usernameIsConcealed: Bool
    let displayName: String?
    let origins: [String]
    let hasPassword: Bool
    /// A stored login record: a password, or a username with or without one. The exchange codec's rule.
    let hasLogin: Bool
    let hasTOTP: Bool
    let passkeys: [PasskeySummary]

    init(_ account: CredentialAccount) {
        id = account.id
        usernameIsConcealed = account.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        username = usernameIsConcealed || account.username.isEmpty ? nil : account.username
        displayName = account.displayName
        origins = account.origins
        hasPassword = account.password != nil
        hasLogin = account.password != nil || account.basicAuthenticationMetadata != nil || !account.username.isEmpty
        hasTOTP = account.totp != nil
        passkeys = account.passkeys.map { PasskeySummary($0) }
    }

    /// What a row, a removal prompt or an import review calls this credential. An empty imported title counts as none.
    var title: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return origins.lazy.compactMap { URL(string: $0)?.host }.first ?? username ?? String(localized: "Credential")
    }
}

nonisolated struct RevealedPassword: Equatable, Sendable {
    let accountID: UUID
    let value: String
}

nonisolated struct RevealedUsername: Equatable, Sendable {
    let accountID: UUID
    let value: String
}

/// A removal the user was shown, with the revision and authorization epoch it was shown at. It lives in the
/// epoch-bound session, so a lock or re-unlock discards it, and a confirmation carrying an old value is rejected.
nonisolated struct PendingRemoval: Equatable, Sendable {
    let summary: CredentialSummary
    let revision: UInt64
    let epoch: UInt64
}

nonisolated struct PendingUnlockRemoval: Equatable, Sendable {
    let credentialID: Data
    let epoch: UInt64
    /// How many unlock passkeys the vault keeps once this one is gone; the removal is confirmed with one of them.
    let remaining: Int

    /// What the confirmation says, from the same value that decides what it will do.
    var text: String {
        String(localized: """
            You’ll confirm with one of the \(remaining) remaining unlock passkeys. The passkey itself stays in your passkey \
            provider. Removing it does not change the vault’s encryption key. Someone with that passkey and an older vault \
            file can still decrypt later copies of this vault they obtain.
            """)
    }
}
