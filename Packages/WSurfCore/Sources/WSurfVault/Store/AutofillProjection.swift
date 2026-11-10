// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

// What autofill reads of a vault (`ProfileVaultStore+Autofill.swift`). A list gets identities, flags and row text only, never a
// secret value; a pick gets one credential's value for one field, or one card's or contact's values, and that value never prints.

/// What an autofill list may know about one live credential before the person picks it: who it is, where it belongs, which kinds of
/// secret it holds and what its items are called. Never a password, code seed, passkey key, note or item value. Only the vault makes
/// one (`ProfileVaultStore.autofillCandidates`); a secret is read only for a pick (`autofillLogin`).
public nonisolated struct AutofillCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// As the vault holds it: matched exactly and shown, also when the exporter marked it hidden.
    public let username: String
    /// The exporter marked the username hidden (`basicAuthenticationMetadata`), so Pick Credential… neither shows nor searches it.
    public let usernameIsConcealed: Bool
    public let displayName: String?
    public let origins: [String]
    /// For path ranking and a row's detail.
    public let loginURLs: [URL]
    public let hasPassword: Bool
    public let hasTOTP: Bool
    public let passkeyCount: Int
    /// What each of its items is called, in order, so Pick Credential… keeps item titles and their search.
    public let items: [AutofillItemFact]

    init(_ account: CredentialAccount) {
        id = account.id
        username = account.username
        usernameIsConcealed = account.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        displayName = account.displayName
        origins = account.origins
        loginURLs = account.loginURLs
        hasPassword = account.password != nil
        hasTOTP = account.totp != nil
        passkeyCount = account.passkeys.count
        items = (account.secureItems ?? []).map(AutofillItemFact.init)
    }
}

/// What a list may call one item of a credential (the app's `SecureItem.title`): its kind, a custom group's own title, and for a card
/// its network and last four digits. Never a value: no number, security code, key, password or field.
public nonisolated struct AutofillItemFact: Equatable, Sendable {
    public let kind: SecureItemKind
    /// Custom fields only: the group's own title, when it has one.
    public let customTitle: String?
    /// A card only: the last four of the digits in its number, when it has four.
    public let cardLastFour: String?
    /// A card with `cardLastFour` only: the network its number names, when the number passes the card check and the prefix is known.
    public let cardNetwork: CardNetwork?

    public init(_ item: SecureItem) {
        kind = item.kind
        customTitle = item.kind == .customFields ? item.label.flatMap { $0.isEmpty ? nil : $0 } : nil
        let digits = item.kind == .creditCard ? item.value("number")?.filter(\.isNumber) : nil
        if let digits, digits.count >= 4 {
            cardLastFour = String(digits.suffix(4))
            cardNetwork = PaymentCardRules.isValidNumber(digits) ? CardNetwork(number: digits) : nil
        } else {
            cardLastFour = nil
            cardNetwork = nil
        }
    }
}

/// The candidates of one unlocked vault, read at `revision`: the revision a pick must still find.
public nonisolated struct AutofillCandidates: Sendable {
    public let vaultID: UUID
    public let revision: UInt64
    public let candidates: [AutofillCandidate]
    /// The websites the person excluded from password save offers ("Never for This Site"), which no offer to add a website names.
    public let blockedPasswordOrigins: Set<String>
}

/// A passkey as routing sees it (`ProfileVaultStore.passkeyRoutes`): the relying party, the algorithm and the credential ID that a
/// request's allow list names. No key, no user handle and no user name: enough to tell which vault can answer, nothing to sign with.
public nonisolated struct PasskeyRoute: Equatable, Sendable {
    public let rpID: String
    public let algorithm: Int
    public let credentialID: Data
}

/// The passkeys of one unlocked vault as routing sees them, read at `revision`.
public nonisolated struct PasskeyRoutes: Sendable {
    public let vaultID: UUID
    public let revision: UInt64
    public let passkeys: [PasskeyRoute]
}

/// What saving a password needs to know of one unlocked vault (`ProfileVaultStore.passwordMatches`): its credentials as a list sees
/// them, read at `revision`, and which of those with the submitted username hold exactly its password. Ids only: never a stored
/// password.
public nonisolated struct AutofillPasswordMatches: Sendable {
    public let vaultID: UUID
    public let revision: UInt64
    /// The vault's credentials as `autofillCandidates` lists them.
    public let accounts: [AutofillCandidate]
    /// The websites the person excluded from password save offers ("Never for This Site").
    public let blockedPasswordOrigins: Set<String>
    /// The credentials with the username asked about whose password equals the one asked about (`String` equality, as the save offer
    /// compared before).
    public let samePassword: Set<UUID>
}

/// What a pick fills: a password field (the username and its password) or a verification-code field.
public nonisolated enum AutofillLoginField: Sendable {
    case password, totp
}

/// One picked credential for one field: its candidate, read again at the revision the list was read at, and that field's secret only.
/// It prints and mirrors without the secret.
public nonisolated struct AutofillLogin: Sendable {
    public let candidate: AutofillCandidate
    /// `.password` only: the password, when the credential has one.
    public let password: String?
    /// `.totp` only: makes the code when it is delivered; the seed stays inside.
    public let code: TOTPCodeSource?

    init(_ account: CredentialAccount, field: AutofillLoginField) {
        candidate = AutofillCandidate(account)
        switch field {
        case .password:
            password = account.password
            code = nil
        case .totp:
            password = nil
            code = account.totp.map(TOTPCodeSource.init)
        }
    }
}

/// Makes a picked credential's verification code at the moment it is delivered. The seed is private to it and never prints.
public nonisolated struct TOTPCodeSource: Sendable {
    private let generator: TOTPGenerator

    init(_ generator: TOTPGenerator) {
        self.generator = generator
    }

    /// The code at `date`, or nil when the seed makes none.
    public func code(at date: Date) -> String? {
        try? TOTP.code(generator, at: date.timeIntervalSince1970).value
    }
}

/// Which items a card or address field lists.
public nonisolated enum AutofillItemKind: Sendable {
    case cards, contacts
}

/// The cards or contacts of one unlocked vault as a fill list shows them, read at `revision`
/// (`ProfileVaultStore.autofillItems(vaultID:kind:using:)`). The type holds rows only, so no card number, security code or contact
/// value beyond a row's text can reach a list: the compiler, not a test, keeps them out.
public nonisolated struct AutofillItemRows: Sendable {
    public let vaultID: UUID
    public let revision: UInt64
    /// `.cards`: every card that can fill (its number passes the card check and it has not expired), in vault order.
    public let cards: [AutofillCardRow]
    /// `.contacts`: one row for each credential that holds a contact, in vault order.
    public let contacts: [AutofillContactRow]
}

/// One picked row and what it fills with
/// (`ProfileVaultStore.autofillItems(vaultID:kind:accountID:item:expectedRevision:using:)`): the row as its list showed it and that
/// row's values, exactly one card's or one contact's, read at the revision its list was read at. It prints and mirrors without
/// them.
public nonisolated enum AutofillItemPick: Sendable {
    case card(AutofillCardRow, AutofillCardValues)
    case contact(AutofillContactRow, AutofillContactValues)
}

/// A card as a fill row shows it: its network, last four digits, the name on it and its expiry. Never its number or security code.
public nonisolated struct AutofillCardRow: Equatable, Sendable {
    public let accountID: UUID
    /// The card's position among its credential's items: what a pick names.
    public let item: Int
    /// Nil for a prefix the card rules do not know: the app calls it a payment card.
    public let network: CardNetwork?
    public let lastFour: String
    public let cardholder: String
    public let month: Int?
    public let year: Int?

    init(accountID: UUID, item: Int, _ card: AutofillCardValues) {
        self.accountID = accountID
        self.item = item
        network = card.network
        lastFour = card.lastFour
        cardholder = card.cardholder
        month = card.month
        year = card.year
    }
}

/// A contact as a fill row shows it: its title (nil: the app's word for a contact) and its email and street. No other value.
public nonisolated struct AutofillContactRow: Equatable, Sendable {
    public let accountID: UUID
    /// The position of the credential's first address, name, email or organization item: what a pick names.
    public let item: Int
    public let title: String?
    public let detail: String

    init(accountID: UUID, item: Int, _ contact: AutofillContactValues) {
        self.accountID = accountID
        self.item = item
        title = contact.title
        detail = contact.rowDetail
    }
}

// A secret never prints, in a log line, a failed assertion or a dump: these describe and mirror without it.

nonisolated extension AutofillLogin: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AutofillLogin"
    }

    public var debugDescription: String {
        "AutofillLogin"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["candidate": candidate], displayStyle: .struct)
    }
}

nonisolated extension TOTPCodeSource: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "TOTPCodeSource"
    }

    public var debugDescription: String {
        "TOTPCodeSource"
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }
}

nonisolated extension AutofillItemPick: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AutofillItemPick"
    }

    public var debugDescription: String {
        "AutofillItemPick"
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}
