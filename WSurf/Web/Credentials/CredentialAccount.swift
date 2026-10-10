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

nonisolated struct CredentialAccount: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var username: String
    var displayName: String?
    var origins: [String]
    var loginURLs: [URL]
    var password: String?
    var passkeys: [WebsitePasskey]
    var totp: TOTPGenerator?
    var exchangeAccountID: Data?
    var exchangeItemID: Data?
    var exchangeMetadata: Data?
    var basicAuthenticationMetadata: CredentialBasicAuthenticationMetadata?

    func validate() throws {
        guard !username.isEmpty || password != nil || !passkeys.isEmpty || totp != nil,
              username.utf8.count <= CredentialVaultLimits.payloadBytes,
              (displayName?.utf8.count ?? 0) <= CredentialVaultLimits.payloadBytes,
              (password?.utf8.count ?? 0) <= 4_096,
              (exchangeMetadata?.count ?? 0) <= CredentialVaultLimits.payloadBytes,
              origins.count <= 64, loginURLs.count <= 64, passkeys.count <= 1_000,
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
        for data in [exchangeAccountID, exchangeItemID].compactMap({ $0 }) where data.count > CredentialVaultLimits.payloadBytes {
            throw CredentialVaultError.invalidData
        }
    }

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

    func validate() throws {
        guard algorithm == -7,
              !credentialID.isEmpty, credentialID.count <= 1_024,
              !userHandle.isEmpty, userHandle.count <= 64,
              !rpID.isEmpty, rpID.utf8.count <= 253,
              rpID == rpID.lowercased(),
              !rpID.contains("/"), !rpID.contains(":"), !rpID.contains(" "),
              userName.utf8.count <= 2_048, userDisplayName.utf8.count <= 2_048,
              privateKeyPKCS8.count <= PasskeyKeyEncoding.maximumDERBytes,
              backupEligible || !backupState else {
            throw CredentialVaultError.invalidData
        }
        guard RelyingPartyPolicy.canonicalDomain(rpID) == rpID else {
            throw CredentialVaultError.invalidData
        }
        _ = try PasskeyKeyEncoding.importPKCS8(privateKeyPKCS8)
        if let metadata = exchangeFIDO2Metadata, metadata.count > CredentialVaultLimits.payloadBytes {
            throw CredentialVaultError.invalidData
        }
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
