// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The raw values are the persisted format (hashed into a credential's content), not the Credential Exchange's: the exchange's are
/// kebab-case, and `init(exchange:)` and `exchangeType` map between the two. Logins and notes keep only the first three; the values
/// of a `SecureItem` keep any of them.
public nonisolated enum CredentialEditableFieldType: String, Codable, Sendable {
    case string
    case concealedString
    case email
    case number
    case boolean
    case date
    case yearMonth
    case wifiNetworkSecurityType
    case countryCode
    case subdivisionCode
}

public nonisolated struct CredentialEditableFieldMetadata: Codable, Sendable, Equatable {
    public var id: Data?
    public var label: String?
    public var fieldType: CredentialEditableFieldType

    public init(id: Data? = nil, label: String? = nil, fieldType: CredentialEditableFieldType) {
        self.id = id
        self.label = label
        self.fieldType = fieldType
    }

    func validate() throws {
        guard (id?.count ?? 0) <= 1_024,
              (label?.utf8.count ?? 0) <= 2_048 else { throw CredentialVaultError.invalidData }
    }
}

public nonisolated struct CredentialBasicAuthenticationMetadata: Codable, Sendable, Equatable {
    public var username: CredentialEditableFieldMetadata?
    public var password: CredentialEditableFieldMetadata?
}

/// Observations that never change a credential's content hash (§11.1 "never" row).
public nonisolated struct CredentialEvents: Codable, Equatable, Sendable {
    public var lastImportedAt: Date?
    public var lastExportHandoffAt: Date?
    var remoteLastObservedAt: Date?
    /// `CredentialContent.hash` of the part last handed to the system exchange sheet. Local handoff evidence only: never an
    /// accepted remote base, so it advances no `*Base` and no content/history state.
    public var lastExportHandoffHash: Data?

    public init(
        lastImportedAt: Date? = nil,
        lastExportHandoffAt: Date? = nil,
        remoteLastObservedAt: Date? = nil,
        lastExportHandoffHash: Data? = nil
    ) {
        self.lastImportedAt = lastImportedAt
        self.lastExportHandoffAt = lastExportHandoffAt
        self.remoteLastObservedAt = remoteLastObservedAt
        self.lastExportHandoffHash = lastExportHandoffHash
    }

    func validate() throws {
        guard lastExportHandoffHash == nil || lastExportHandoffHash?.count == 32 else { throw CredentialVaultError.invalidData }
    }
}

/// The accepted remote observation of a credential (§13.2a): its content hash and the remote item it came from.
public nonisolated struct ExchangeBase: Codable, Equatable, Sendable {
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

    /// Whether `removed`, a credential that left the vault, was merged into this account: its own id, or the item of the other app it
    /// held, is one of this account's merged items. Restoring it would put a second holder of that item beside this one.
    func holdsMergedItem(of removed: CredentialAccount) -> Bool {
        mergedFrom?.contains { $0.accountID == removed.id || (removed.exchangeItemID != nil && $0.exchangeItemID == removed.exchangeItemID) }
            ?? false
    }

    /// This account with every observed base put back as `old` had it: the login's and the code's, and those of the items merged
    /// into it. What is left differs from `old` only in what an import changed besides recording bases.
    public func withBases(of old: CredentialAccount) -> CredentialAccount {
        var result = self
        result.passwordBase = old.passwordBase
        result.totpBase = old.totpBase
        result.secureItemsBase = old.secureItemsBase
        result.importTrace = old.importTrace
        result.mergedFrom = mergedFrom?.map { link in
            var restored = link
            if let before = old.mergedFrom?.first(where: { $0.identity == link.identity }) {
                restored.passwordBase = before.passwordBase
                restored.totpBase = before.totpBase
                restored.trace = before.trace
            }
            return restored
        }
        return result
    }
}

/// An item of the other app that was merged into this credential, and what this credential remembers of it. A later import of that
/// item finds this credential through `exchangeAccountID` and `exchangeItemID`, and tells what changed since the merge by the bases:
/// the content hash the other app last sent for the item's login and for its code. Passkeys carry their own `base`, and notes keep
/// none. The identity is the one the item was exported under (`CredentialExchangeCodec.externalItemID`): the stored ids, else the ones
/// its own id gives.
public nonisolated struct MergedItemLink: Codable, Sendable, Equatable {
    /// The merged credential's own id, which names its entry in the Trash.
    public var accountID: UUID
    var exchangeAccountID: Data
    var exchangeItemID: Data
    var passwordBase: ExchangeBase?
    var totpBase: ExchangeBase?
    /// What the merged credential stood for when it was merged (`ImportMemoryKey.trace`), so an import of it finds this credential even
    /// after its Trash entry is gone, and on a Mac that never held it. Set by the store in the merge's commit.
    public var trace: ImportTrace?

    public init(
        accountID: UUID,
        exchangeAccountID: Data,
        exchangeItemID: Data,
        passwordBase: ExchangeBase? = nil,
        totpBase: ExchangeBase? = nil
    ) {
        self.accountID = accountID
        self.exchangeAccountID = exchangeAccountID
        self.exchangeItemID = exchangeItemID
        self.passwordBase = passwordBase
        self.totpBase = totpBase
    }

    func validate() throws {
        guard !exchangeAccountID.isEmpty, !exchangeItemID.isEmpty,
              exchangeAccountID.count <= CredentialVaultLimits.payloadBytes,
              exchangeItemID.count <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.invalidData }
        try trace?.validate()
    }

    /// The merged credential had no item of another app (saved here or from a file): its identity is the one its own id gives.
    public var hasNoExporterItem: Bool {
        exchangeItemID == (try? CredentialExchangeCodec.externalID(nil, fallback: accountID))
    }

    public var identity: CredentialExchangeCodec.ExternalItemID {
        CredentialExchangeCodec.ExternalItemID(account: exchangeAccountID, item: exchangeItemID)
    }
}

/// One free-text note. `field` keeps how the exporter described it (id, label, type) so a note round-trips unchanged.
public nonisolated struct CredentialNote: Codable, Sendable, Equatable {
    public var text: String
    var field: CredentialEditableFieldMetadata?

    public init(text: String, field: CredentialEditableFieldMetadata? = nil) {
        self.text = text
        self.field = field
    }

    func validate() throws {
        guard !text.isEmpty, text.utf8.count <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.invalidData }
        try field?.validate()
    }
}

public nonisolated struct CredentialAccount: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var username: String
    public var displayName: String?
    public var origins: [String]
    public var loginURLs: [URL]
    public var password: String?
    public var passkeys: [WebsitePasskey]
    public var totp: TOTPGenerator?
    /// Free-text notes, in order. `nil` means none: an empty array is never stored. Notes can hold secrets, so they live in
    /// their own encrypted part with their own history, never in `exchangeMetadata`.
    public var notes: [CredentialNote]?
    /// Cards, addresses, Wi-Fi networks, keys and the other `SecureItemKind`s, in order. `nil` means none: an empty array is never
    /// stored. Like notes, they are one encrypted part with their own history.
    public var secureItems: [SecureItem]?
    public var exchangeAccountID: Data?
    public var exchangeItemID: Data?
    public var exchangeMetadata: Data?
    public var basicAuthenticationMetadata: CredentialBasicAuthenticationMetadata?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var migratedAt: Date?
    public var passwordEvents: CredentialEvents?
    public var totpEvents: CredentialEvents?
    public var passwordBase: ExchangeBase?
    public var totpBase: ExchangeBase?
    /// What the other app last sent for this credential's items (`secureItems`), like `totpBase` for its code.
    var secureItemsBase: ExchangeBase?
    /// The other app's items that were merged into this credential. `nil` means none: an empty array is never stored.
    public var mergedFrom: [MergedItemLink]?
    /// Files kept with the entry, in order: references to encrypted files in the vault's folder, never the bytes. `nil` means none: an
    /// empty array is never stored. A store holding any is `StoreFormat.fileSchema`, so a build that would drop them refuses it.
    public var attachments: [CredentialAttachment]?
    /// What an import last brought for this credential, as keyed digests (`ImportTrace`). `nil` for one no import has written since
    /// imports began to record it. Not content: it raises no History version and no sync upload, and travels with the login and notes.
    public var importTrace: ImportTrace?

    public init(
        id: UUID,
        username: String,
        displayName: String? = nil,
        origins: [String],
        loginURLs: [URL],
        password: String? = nil,
        passkeys: [WebsitePasskey],
        totp: TOTPGenerator? = nil,
        notes: [CredentialNote]? = nil,
        secureItems: [SecureItem]? = nil,
        exchangeAccountID: Data? = nil,
        exchangeItemID: Data? = nil,
        exchangeMetadata: Data? = nil,
        basicAuthenticationMetadata: CredentialBasicAuthenticationMetadata? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        migratedAt: Date? = nil,
        passwordEvents: CredentialEvents? = nil,
        totpEvents: CredentialEvents? = nil,
        passwordBase: ExchangeBase? = nil,
        totpBase: ExchangeBase? = nil,
        secureItemsBase: ExchangeBase? = nil,
        mergedFrom: [MergedItemLink]? = nil,
        attachments: [CredentialAttachment]? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.origins = origins
        self.loginURLs = loginURLs
        self.password = password
        self.passkeys = passkeys
        self.totp = totp
        self.notes = notes
        self.secureItems = secureItems
        self.exchangeAccountID = exchangeAccountID
        self.exchangeItemID = exchangeItemID
        self.exchangeMetadata = exchangeMetadata
        self.basicAuthenticationMetadata = basicAuthenticationMetadata
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.migratedAt = migratedAt
        self.passwordEvents = passwordEvents
        self.totpEvents = totpEvents
        self.passwordBase = passwordBase
        self.totpBase = totpBase
        self.secureItemsBase = secureItemsBase
        self.mergedFrom = mergedFrom
        self.attachments = attachments
    }

    public func validate() throws {
        guard !username.isEmpty || password != nil || !passkeys.isEmpty || totp != nil || notes != nil || secureItems != nil
                || attachments != nil,
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
        if let secureItems {
            guard !secureItems.isEmpty, secureItems.count <= SecureItem.itemLimit else { throw CredentialVaultError.invalidData }
            for item in secureItems {
                try item.validate()
            }
        }
        try validateAttachments()
        try passwordEvents?.validate()
        try totpEvents?.validate()
        try validateMergedFrom()
        try importTrace?.validate()
        for data in [exchangeAccountID, exchangeItemID].compactMap({ $0 }) where data.count > CredentialVaultLimits.payloadBytes {
            throw CredentialVaultError.invalidData
        }
    }

    /// At most 64 distinct files, each a valid record.
    private func validateAttachments() throws {
        guard let attachments else { return }
        guard !attachments.isEmpty, attachments.count <= CredentialAttachment.entryLimit,
              Set(attachments.map(\.id)).count == attachments.count else { throw CredentialVaultError.invalidData }
        for file in attachments {
            try file.validate()
        }
    }

    /// The merged items must be distinct from each other and from this credential, or a later import could not tell which one it met.
    private func validateMergedFrom() throws {
        guard let mergedFrom else { return }
        guard !mergedFrom.isEmpty, mergedFrom.count <= Self.mergedFromLimit else { throw CredentialVaultError.invalidData }
        var seen = Set([try CredentialExchangeCodec.externalItemID(for: self)])
        var ids = Set([id])
        for link in mergedFrom {
            try link.validate()
            guard seen.insert(link.identity).inserted, ids.insert(link.accountID).inserted else {
                throw CredentialVaultError.duplicateIdentifier
            }
        }
    }

    /// Most notes one credential keeps.
    public static let noteLimit = 64

    /// Most websites (origins, and login addresses) one account keeps.
    public static let websiteLimit = 64

    /// Most items of the other app one credential remembers as merged into it.
    public static let mergedFromLimit = 64

    public static func origin(for url: URL) -> String? {
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

    public static func sanitizedLoginURL(_ url: URL) throws -> URL {
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

public nonisolated struct WebsitePasskey: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var credentialID: Data
    public var rpID: String
    public var userHandle: Data
    public var userName: String
    public var userDisplayName: String
    public var algorithm: Int
    public var privateKeyPKCS8: Data
    public var backupEligible: Bool
    var backupState: Bool
    var exchangeFIDO2Metadata: Data?
    public var createdAt: Date?
    public var source: WebsitePasskeySource?
    public var lastSignedAt: Date?
    public var events: CredentialEvents?
    var base: ExchangeBase?

    public init(
        id: UUID,
        credentialID: Data,
        rpID: String,
        userHandle: Data,
        userName: String,
        userDisplayName: String,
        algorithm: Int,
        privateKeyPKCS8: Data,
        backupEligible: Bool,
        backupState: Bool,
        exchangeFIDO2Metadata: Data? = nil,
        createdAt: Date? = nil,
        source: WebsitePasskeySource? = nil,
        lastSignedAt: Date? = nil,
        events: CredentialEvents? = nil,
        base: ExchangeBase? = nil
    ) {
        self.id = id
        self.credentialID = credentialID
        self.rpID = rpID
        self.userHandle = userHandle
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.algorithm = algorithm
        self.privateKeyPKCS8 = privateKeyPKCS8
        self.backupEligible = backupEligible
        self.backupState = backupState
        self.exchangeFIDO2Metadata = exchangeFIDO2Metadata
        self.createdAt = createdAt
        self.source = source
        self.lastSignedAt = lastSignedAt
        self.events = events
        self.base = base
    }

    /// The BS flag an assertion reports. A passkey imported from another provider (Apple Passwords) is still kept there, synced,
    /// so it is backed up whatever this vault does, and the provider registered it with BS set: some relying parties refuse an
    /// assertion whose backup state changed from that.
    public var isBackedUp: Bool {
        backupEligible && (backupState || source == .imported)
    }

    static let credentialIDLimit = 1_024
    /// The most bytes WSurf keeps in a user handle, the same bound as a credential ID. WebAuthn tells a relying party to keep
    /// the handle to 64 bytes or fewer, and CTAP2 only requires an authenticator to hold that many. Real relying parties send
    /// more (PayPal's passkey in Apple Passwords has one), so WSurf accepts up to this bound on import, on registration and
    /// on the way back out in an assertion or an export. A handle is stored and hashed length-prefixed, so no format depends on it.
    public static let userHandleLimit = 1_024
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

    public func validate() throws {
        guard algorithm == -7, backupEligible || !backupState, problem == nil else {
            throw CredentialVaultError.invalidData
        }
        try events?.validate()
    }
}

public nonisolated enum WebsitePasskeySource: String, Codable, Sendable, Equatable {
    case created
    case imported
}

extension UUID {
    public nonisolated func shortestUniquePrefix(in identifiers: [UUID]) -> String {
        let value = uuidString
        var length = 4
        while length < value.count,
              identifiers.contains(where: { $0 != self && $0.uuidString.prefix(length) == value.prefix(length) }) {
            length += 1
        }
        return String(value.prefix(length))
    }
}

public nonisolated enum TOTPAlgorithm: String, Codable, Sendable {
    case sha1
    case sha256
    case sha512
}

public nonisolated struct TOTPGenerator: Codable, Sendable, Equatable {
    public var secret: Data
    public var algorithm: TOTPAlgorithm
    public var period: UInt16
    public var digits: UInt16
    public var issuer: String?
    public var userName: String?

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
