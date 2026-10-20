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
    /// The notes in order. Each keeps the exporter's field description while its text is edited; an empty one is dropped on save.
    var notes: [CredentialNote]
    /// The cards, addresses and other items in order. A new item has an empty value for each member so it can be typed; empty values,
    /// and items left with nothing, are dropped on save.
    var secureItems: [SecureItem]
    private(set) var totp: TOTPGenerator?
    private(set) var passkeys: [WebsitePasskey]
    let revision: UInt64
    let usernameIsConcealed: Bool
    /// The creation date the other app reported for an imported credential (spec §12.2). Decoded once, when the draft opens.
    let reportedCreatedAt: Date?
    private let base: CredentialAccount?
    private let originalWebsites: String
    private let originalExtraOrigins: String
    private let originalSecureItems: [SecureItem]

    init(editing account: CredentialAccount?, revision: UInt64) {
        let loginOrigins = Set(account?.loginURLs.compactMap { CredentialAccount.origin(for: $0) } ?? [])
        let websites = account?.loginURLs.map(\.absoluteString).joined(separator: "\n") ?? ""
        let extras = (account?.origins ?? []).filter { !loginOrigins.contains($0) }.joined(separator: "\n")
        base = account
        username = account?.username ?? ""
        displayName = account?.displayName
        password = account?.password
        totp = account?.totp
        notes = account?.notes ?? []
        secureItems = account?.secureItems ?? []
        originalSecureItems = account?.secureItems ?? []
        passkeys = account?.passkeys ?? []
        usernameIsConcealed = account?.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        reportedCreatedAt = account.flatMap { try? CredentialContent.exchangeMetadata($0) }?.created
        self.websites = websites
        extraOrigins = extras
        originalWebsites = websites
        originalExtraOrigins = extras
        self.revision = revision
    }

    var accountID: UUID? {
        base?.id
    }
    /// The credential as it was stored when the editor opened; `nil` for a new one.
    var original: CredentialAccount? {
        base
    }
    var isNew: Bool {
        base == nil
    }

    /// When the stored credential was added and last changed; `nil` for a new one.
    var dates: CredentialDates? {
        base.map(CredentialDates.init)
    }

    /// The editor's date lines: what WSurf recorded, then what the other app reported, each saying whose it is.
    var dateLines: [String] {
        var lines: [String] = []
        if let caption = dates?.caption(style: .editor), !caption.isEmpty {
            lines.append(caption)
        }
        if let reportedCreatedAt {
            let when = reportedCreatedAt.formatted(date: .abbreviated, time: .shortened)
            lines.append(String(localized: "Reported by the other app: created \(when)"))
        }
        return lines
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

    mutating func addNote() {
        notes.append(CredentialNote(text: "", field: nil))
    }

    mutating func removeNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        notes.remove(at: index)
    }

    mutating func addSecureItem(_ kind: SecureItemKind) {
        guard secureItems.count < SecureItem.itemLimit else { return }
        secureItems.append(.empty(kind))
    }

    mutating func removeSecureItem(at index: Int) {
        guard secureItems.indices.contains(index) else { return }
        secureItems.remove(at: index)
    }

    /// Adds an empty value of `member` to the item at `index`, when the item has none: a member the exporter left out.
    mutating func addMember(_ member: SecureItemMember, toItem index: Int) {
        guard secureItems.indices.contains(index), !member.isPlain, !secureItems[index].fields.contains(where: { $0.name == member.name })
        else { return }
        secureItems[index].fields.append(
            SecureItemField(name: member.name, value: "", field: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: member.type))
        )
    }

    /// Adds an empty custom field to the custom-fields item at `index`.
    mutating func addCustomField(toItem index: Int) {
        guard secureItems.indices.contains(index), secureItems[index].kind == .customFields,
              secureItems[index].fields.count < SecureItem.fieldLimit else { return }
        secureItems[index].fields.append(SecureItemField(name: "", value: "", field: .init(id: nil, label: "", fieldType: .string)))
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

    /// Whether leaving the editor now would lose something: an edit to a stored credential, or anything typed into a new one.
    var hasUnsavedChanges: Bool {
        if base != nil {
            return !changesNothing
        }
        let blank = { (text: String) in text.allSatisfy(\.isWhitespace) }
        return !(username.isEmpty && displayName == nil && password == nil && blank(websites) && blank(extraOrigins)
            && totp == nil && passkeys.isEmpty && notes.allSatisfy { $0.text.isEmpty } && Self.keptItems(secureItems).isEmpty)
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
        let kept = notes.filter { !$0.text.isEmpty }
        result.notes = kept.isEmpty ? nil : kept
        // Untouched items stay exactly as stored, so an imported item is never rewritten by a save that changed something else.
        if base == nil || secureItems != originalSecureItems {
            let items = Self.keptItems(secureItems)
            result.secureItems = items.isEmpty ? nil : items
        }
        try result.validate()
        return result
    }

    /// The items as they are saved: no empty value, no empty custom-fields title, and no item left with nothing.
    private static func keptItems(_ items: [SecureItem]) -> [SecureItem] {
        items.compactMap { item in
            var kept = item
            kept.fields.removeAll { $0.value.isEmpty }
            if kept.label?.isEmpty == true {
                kept.label = nil
            }
            return kept.fields.isEmpty && kept.label == nil ? nil : kept
        }
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

// MARK: - Copying from an earlier version

extension CredentialDraft {
    /// Puts one part of an earlier version into the draft, as typing it would. Nothing is stored until Save, and then the value it
    /// replaces becomes an earlier version. The basic-authentication field descriptions stay as the credential has them:
    /// `account()` keeps them consistent with the copied username and password.
    mutating func take(_ field: CredentialHistoryField, from version: CredentialAccount) {
        switch field {
        case .name:
            displayName = version.displayName
        case .login:
            username = version.username
            password = version.password
        case .websites:
            let lines = CredentialHistory.websites(of: version)
            websites = lines.filter { !$0.isOtherOrigin }.map(\.text).joined(separator: "\n")
            extraOrigins = lines.filter(\.isOtherOrigin).map(\.text).joined(separator: "\n")
        case .website(let url):
            websites = Self.appending(url.absoluteString, to: websites)
        case .origin(let origin):
            extraOrigins = Self.appending(origin, to: extraOrigins)
        case .code:
            if let generator = version.totp {
                totp = generator
            }
        case .notes:
            notes = version.notes ?? []
        case .note(let index):
            guard let held = version.notes, held.indices.contains(index), !notes.contains(where: { $0.text == held[index].text }),
                notes.count < CredentialAccount.noteLimit
            else { return }
            let note = held[index]
            notes.append(note)
        case .secureItems:
            secureItems = version.secureItems ?? []
        }
    }

    private static func appending(_ line: String, to text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.contains(line) ? text : (lines + [line]).joined(separator: "\n")
    }
}
