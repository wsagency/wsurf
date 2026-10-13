// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The one editor state. It starts from the stored account and only overwrites what the form exposes, so
/// passkeys, exchange metadata, descriptor ids/labels and nil-versus-empty passwords survive an edit.
nonisolated struct CredentialDraft: Sendable {
    var username: String
    var displayName: String?
    var password: String?
    var websites: String
    var extraOrigins: String
    private(set) var totp: TOTPGenerator?
    private(set) var passkeys: [WebsitePasskey]
    let revision: UInt64
    let usernameIsConcealed: Bool
    private let base: CredentialAccount?
    private let originalWebsites: String
    private let originalExtraOrigins: String

    init(editing account: CredentialAccount?, revision: UInt64) {
        let loginOrigins = Set(account?.loginURLs.compactMap { CredentialAccount.origin(for: $0) } ?? [])
        let websites = account?.loginURLs.map(\.absoluteString).joined(separator: "\n") ?? ""
        let extras = (account?.origins ?? []).filter { !loginOrigins.contains($0) }.joined(separator: "\n")
        base = account
        username = account?.username ?? ""
        displayName = account?.displayName
        password = account?.password
        totp = account?.totp
        passkeys = account?.passkeys ?? []
        usernameIsConcealed = account?.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        self.websites = websites
        extraOrigins = extras
        originalWebsites = websites
        originalExtraOrigins = extras
        self.revision = revision
    }

    var accountID: UUID? {
        base?.id
    }
    var isNew: Bool {
        base == nil
    }

    var passkeySummaries: [PasskeySummary] {
        passkeys.map { PasskeySummary($0) }
    }

    mutating func removePasskey(_ id: UUID) {
        passkeys.removeAll { $0.id == id }
    }

    mutating func removeTOTP() {
        totp = nil
    }

    /// Leaves the current generator untouched when `input` is not a valid secret or otpauth URI.
    mutating func setUpTOTP(
        _ input: String,
        algorithm: TOTPAlgorithm = .sha1,
        period: UInt16 = 30,
        digits: UInt16 = 6
    ) throws {
        totp = try TOTP.parse(
            input.trimmingCharacters(in: .whitespacesAndNewlines),
            algorithm: algorithm,
            period: period,
            digits: digits
        )
    }

    /// Whether saving would write the stored account back exactly as it is.
    var changesNothing: Bool {
        guard let base, let built = try? account() else { return false }
        return built == base
    }

    func account() throws -> CredentialAccount {
        var result = base ?? CredentialAccount(
            id: UUID(), username: "", displayName: nil, origins: [], loginURLs: [],
            password: nil, passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        if base == nil || websites != originalWebsites || extraOrigins != originalExtraOrigins {
            (result.origins, result.loginURLs) = try Self.parseSites(websites: websites, extraOrigins: extraOrigins)
        }

        let hadUsername = !(base?.username.isEmpty ?? true)
        let hadPassword = base?.password != nil
        if var metadata = base?.basicAuthenticationMetadata {
            if username.isEmpty, hadUsername {
                metadata.username = nil
            } else if !username.isEmpty, !hadUsername, metadata.username == nil {
                metadata.username = CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .string)
            }
            if password == nil, hadPassword {
                metadata.password = nil
            } else if password != nil, !hadPassword, metadata.password == nil {
                metadata.password = CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
            }
            result.basicAuthenticationMetadata = metadata
        }

        result.username = username
        result.displayName = displayName
        result.password = password
        result.passkeys = passkeys
        result.totp = totp
        try result.validate()
        return result
    }

    private static func parseSites(websites: String, extraOrigins: String) throws -> (origins: [String], loginURLs: [URL]) {
        var origins: [String] = []
        var loginURLs: [URL] = []
        for line in lines(websites) {
            guard let url = URL(string: line) else { throw CredentialVaultError.invalidData }
            let sanitized = try CredentialAccount.sanitizedLoginURL(url)
            guard let origin = CredentialAccount.origin(for: sanitized) else { throw CredentialVaultError.invalidData }
            if !loginURLs.contains(sanitized) {
                loginURLs.append(sanitized)
            }
            if !origins.contains(origin) {
                origins.append(origin)
            }
        }
        for line in lines(extraOrigins) {
            guard let url = URL(string: line), let origin = CredentialAccount.origin(for: url) else {
                throw CredentialVaultError.invalidData
            }
            if !origins.contains(origin) {
                origins.append(origin)
            }
        }
        return (origins, loginURLs)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
