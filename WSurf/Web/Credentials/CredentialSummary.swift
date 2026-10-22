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
    let hasNotes: Bool
    /// The kinds of the credential's cards, addresses and other items, in order, each once.
    let itemKinds: [SecureItemKind]
    /// What each item is called (`SecureItem.title`): a card's network and last four digits, else its kind. Never another value.
    let itemTitles: [String]
    /// It holds a card or an identity document: showing or copying their hidden values, and editing it, needs Touch ID.
    let hasSensitiveItems: Bool
    /// The hidden values of its items that the row's menu offers to copy, by name.
    let hiddenItemFields: [SecureFieldReference]
    let passkeys: [PasskeySummary]
    let dates: CredentialDates
    /// What a search looks in, built once here so a keystroke never rebuilds it: the title, the username (unless concealed) and
    /// every website's host, folded so a search ignores case and accents. Never a password, note, code seed or passkey key.
    let searchKey: String

    init(_ account: CredentialAccount) {
        id = account.id
        let concealed = account.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        let visibleUsername = concealed || account.username.isEmpty ? nil : account.username
        usernameIsConcealed = concealed
        username = visibleUsername
        displayName = account.displayName
        origins = account.origins
        hasPassword = account.password != nil
        hasLogin = account.password != nil || account.basicAuthenticationMetadata != nil || !account.username.isEmpty
        hasTOTP = account.totp != nil
        hasNotes = account.notes != nil
        let items = account.secureItems ?? []
        var kinds: [SecureItemKind] = []
        for item in items where !kinds.contains(item.kind) {
            kinds.append(item.kind)
        }
        itemKinds = kinds
        itemTitles = items.map(\.title)
        hasSensitiveItems = kinds.contains { $0.isSensitive }
        hiddenItemFields = items.enumerated().flatMap { index, item -> [SecureFieldReference] in
            item.fields.enumerated().compactMap { position, field -> SecureFieldReference? in
                item.isConcealed(field) ? SecureFieldReference(item: index, field: position, label: item.label(of: field)) : nil
            }
        }
        passkeys = account.passkeys.map { PasskeySummary($0) }
        dates = CredentialDates(account)
        let title = Self.title(displayName: account.displayName, origins: account.origins, username: visibleUsername, items: itemTitles)
        let hosts = account.origins.compactMap { URL(string: $0)?.host }
        searchKey = Self.folded(([title] + [visibleUsername].compactMap { $0 } + hosts + itemTitles).joined(separator: "\n"))
    }

    /// Case and accents do not matter to a search: the key and the query both go through this.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Equal when everything a row, a prompt or the export sheet shows is equal. `dates` is left out on purpose: it moves with
    /// every semantic change, even a secret-only one that no other field shows, and the export review leaves such changes to the
    /// vault's stamps. `searchKey` is left out because it is built from fields compared here. Compare every other new field here.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id, lhs.username == rhs.username, lhs.usernameIsConcealed == rhs.usernameIsConcealed,
              lhs.displayName == rhs.displayName, lhs.origins == rhs.origins, lhs.hasPassword == rhs.hasPassword,
              lhs.hasLogin == rhs.hasLogin, lhs.hasTOTP == rhs.hasTOTP, lhs.hasNotes == rhs.hasNotes,
              lhs.itemKinds == rhs.itemKinds, lhs.itemTitles == rhs.itemTitles, lhs.hasSensitiveItems == rhs.hasSensitiveItems,
              lhs.hiddenItemFields == rhs.hiddenItemFields else { return false }
        return lhs.passkeys == rhs.passkeys
    }

    /// What a row, a removal prompt or an import review calls this credential. An empty imported title counts as none.
    var title: String {
        Self.title(displayName: displayName, origins: origins, username: username, items: itemTitles)
    }

    private static func title(displayName: String?, origins: [String], username: String?, items: [String]) -> String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return origins.lazy.compactMap { URL(string: $0)?.host }.first ?? username ?? items.first ?? String(localized: "Credential")
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
