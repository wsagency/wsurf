// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated enum CredentialEditableFieldType: String, Codable, Sendable {
    case string
    case concealedString
    case email
}

nonisolated struct CredentialEditableFieldMetadata: Codable, Sendable, Equatable {
    var id: Data?
    var label: String?
    var fieldType: CredentialEditableFieldType

    func validate() throws {
        guard (id?.count ?? 0) <= 1_024,
              (label?.utf8.count ?? 0) <= 2_048 else { throw CredentialVaultError.invalidData }
    }
}

nonisolated struct CredentialBasicAuthenticationMetadata: Codable, Sendable, Equatable {
    var username: CredentialEditableFieldMetadata?
    var password: CredentialEditableFieldMetadata?
}

/// Observations that never change a credential's content hash (§11.1 "never" row).
nonisolated struct CredentialEvents: Codable, Equatable, Sendable {
    var lastImportedAt: Date?
    var lastExportHandoffAt: Date?
    var remoteLastObservedAt: Date?
    /// `CredentialContent.hash` of the part last handed to the system exchange sheet. Local handoff evidence only: never an
    /// accepted remote base, so it advances no `*Base` and no content/history state.
    var lastExportHandoffHash: Data?

    func validate() throws {
        guard lastExportHandoffHash == nil || lastExportHandoffHash?.count == 32 else { throw CredentialVaultError.invalidData }
    }
}

/// The accepted remote observation of a credential (§13.2a): its content hash and the remote item it came from.
nonisolated struct ExchangeBase: Codable, Equatable, Sendable {
    var contentHash: Data
    var itemID: Data?
}

nonisolated extension CredentialAccount {
    /// A freshly created account: `createdAt` and `modifiedAt` are `now`; migration and import paths leave both nil.
    func stampingCreation(at now: Date) -> CredentialAccount {
        var account = self
        account.createdAt = now
        account.modifiedAt = now
        return account
    }
}

/// One free-text note. `field` keeps how the exporter described it (id, label, type) so a note round-trips unchanged.
nonisolated struct CredentialNote: Codable, Sendable, Equatable {
    var text: String
    var field: CredentialEditableFieldMetadata?

    func validate() throws {
        guard !text.isEmpty, text.utf8.count <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.invalidData }
        try field?.validate()
    }
}

nonisolated struct CredentialAccount: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var username: String
    var displayName: String?
    var origins: [String]
    var loginURLs: [URL]
    var password: String?
    var passkeys: [WebsitePasskey]
    var totp: TOTPGenerator?
    /// Free-text notes, in order. `nil` means none: an empty array is never stored. Notes can hold secrets, so they live in
    /// their own encrypted part with their own history, never in `exchangeMetadata`.
    var notes: [CredentialNote]?
    var exchangeAccountID: Data?
    var exchangeItemID: Data?
    var exchangeMetadata: Data?
    var basicAuthenticationMetadata: CredentialBasicAuthenticationMetadata?
    var createdAt: Date?
    var modifiedAt: Date?
    var migratedAt: Date?
    var passwordEvents: CredentialEvents?
    var totpEvents: CredentialEvents?
    var passwordBase: ExchangeBase?
    var totpBase: ExchangeBase?

    func validate() throws {
        guard !username.isEmpty || password != nil || !passkeys.isEmpty || totp != nil || notes != nil,
              username.utf8.count <= CredentialVaultLimits.payloadBytes,
              (displayName?.utf8.count ?? 0) <= CredentialVaultLimits.payloadBytes,
              (password?.utf8.count ?? 0) <= 4_096,
              (exchangeMetadata?.count ?? 0) <= CredentialVaultLimits.payloadBytes,
              origins.count <= Self.websiteLimit, loginURLs.count <= Self.websiteLimit, passkeys.count <= 1_000,
              Set(origins).count == origins.count,
              Set(passkeys.map(\.id)).count == passkeys.count else { throw CredentialVaultError.invalidData }

        if let metadata = basicAuthenticationMetadata {
            guard (metadata.password != nil) == (password != nil) else { throw CredentialVaultError.invalidData }
            let fields = [metadata.username, metadata.password].compactMap({ $0 })
            let identifiers = fields.compactMap(\.id)
            guard Set(identifiers).count == identifiers.count else { throw CredentialVaultError.invalidData }
            for field in fields {
                try field.validate()
            }
        }

        for origin in origins {
            guard let url = URL(string: origin), Self.origin(for: url) == origin else { throw CredentialVaultError.invalidData }
        }
        for url in loginURLs {
            let sanitized = try Self.sanitizedLoginURL(url)
            guard sanitized.absoluteString == url.absoluteString,
                  let origin = Self.origin(for: sanitized), origins.contains(origin) else {
                throw CredentialVaultError.invalidData
            }
        }
        for passkey in passkeys {
            try passkey.validate()
        }
        if let totp {
            try totp.validate()
        }
        if let notes {
            guard !notes.isEmpty, notes.count <= CredentialAccount.noteLimit else { throw CredentialVaultError.invalidData }
            for note in notes {
                try note.validate()
            }
        }
        try passwordEvents?.validate()
        try totpEvents?.validate()
        for data in [exchangeAccountID, exchangeItemID].compactMap({ $0 }) where data.count > CredentialVaultLimits.payloadBytes {
            throw CredentialVaultError.invalidData
        }
    }

    /// Most notes one credential keeps.
    static let noteLimit = 64

    /// Most websites (origins, and login addresses) one account keeps.
    static let websiteLimit = 64

    static func origin(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 {
            components.port = nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string
    }

    static func sanitizedLoginURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { throw CredentialVaultError.invalidData }
        components.scheme = "https"
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        if components.port == 443 {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        guard let sanitized = components.url, Self.origin(for: sanitized) != nil else { throw CredentialVaultError.invalidData }
        return sanitized
    }
}

nonisolated struct WebsitePasskey: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var credentialID: Data
    var rpID: String
    var userHandle: Data
    var userName: String
    var userDisplayName: String
    var algorithm: Int
    var privateKeyPKCS8: Data
    var backupEligible: Bool
    var backupState: Bool
    var exchangeFIDO2Metadata: Data?
    var createdAt: Date?
    var source: WebsitePasskeySource?
    var lastSignedAt: Date?
    var events: CredentialEvents?
    var base: ExchangeBase?

    static let credentialIDLimit = 1_024
    /// The most bytes WSurf keeps in a user handle, the same bound as a credential ID. WebAuthn tells a relying party to keep
    /// the handle to 64 bytes or fewer, and CTAP2 only requires an authenticator to hold that many. Real relying parties send
    /// more (PayPal's passkey in Apple Passwords has one), so WSurf accepts up to this bound on import, on registration and
    /// on the way back out in an assertion or an export. A handle is stored and hashed length-prefixed, so no format depends on it.
    static let userHandleLimit = 1_024
    /// The most UTF-8 bytes in a user name or a display name.
    static let nameLimit = 2_048

    /// The first field `validate` refuses. It names the field and never a value.
    enum Problem: Equatable, Sendable {
        case credentialID, userHandleMissing, userHandleTooLong, relyingParty, name, key, extensions
    }

    var problem: Problem? {
        if credentialID.isEmpty || credentialID.count > Self.credentialIDLimit {
            return .credentialID
        }
        if userHandle.isEmpty {
            return .userHandleMissing
        }
        if userHandle.count > Self.userHandleLimit {
            return .userHandleTooLong
        }
        if rpID.isEmpty || rpID.utf8.count > 253 || rpID != rpID.lowercased()
            || rpID.contains("/") || rpID.contains(":") || rpID.contains(" ")
            || RelyingPartyPolicy.canonicalDomain(rpID) != rpID {
            return .relyingParty
        }
        if userName.utf8.count > Self.nameLimit || userDisplayName.utf8.count > Self.nameLimit {
            return .name
        }
        if privateKeyPKCS8.count > PasskeyKeyEncoding.maximumDERBytes
            || (try? PasskeyKeyEncoding.importPKCS8(privateKeyPKCS8)) == nil {
            return .key
        }
        if let metadata = exchangeFIDO2Metadata, metadata.count > CredentialVaultLimits.payloadBytes {
            return .extensions
        }
        return nil
    }

    func validate() throws {
        guard algorithm == -7, backupEligible || !backupState, problem == nil else {
            throw CredentialVaultError.invalidData
        }
        try events?.validate()
    }
}

nonisolated enum WebsitePasskeySource: String, Codable, Sendable, Equatable {
    case created
    case imported
}

extension UUID {
    nonisolated func shortestUniquePrefix(in identifiers: [UUID]) -> String {
        let value = uuidString
        var length = 4
        while length < value.count,
              identifiers.contains(where: { $0 != self && $0.uuidString.prefix(length) == value.prefix(length) }) {
            length += 1
        }
        return String(value.prefix(length))
    }
}

nonisolated enum TOTPAlgorithm: String, Codable, Sendable {
    case sha1
    case sha256
    case sha512
}

nonisolated struct TOTPGenerator: Codable, Sendable, Equatable {
    var secret: Data
    var algorithm: TOTPAlgorithm
    var period: UInt16
    var digits: UInt16
    var issuer: String?
    var userName: String?

    func validate() throws {
        let limit = CredentialVaultLimits.payloadBytes
        guard !secret.isEmpty, secret.count <= limit,
              period > 0, (6...10).contains(digits),
              (issuer?.utf8.count ?? 0) <= limit,
              (userName?.utf8.count ?? 0) <= limit else {
            throw CredentialVaultError.invalidData
        }
    }
}
