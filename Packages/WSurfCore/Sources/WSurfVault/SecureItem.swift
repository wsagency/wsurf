// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The kinds of item a credential can hold besides a login, passkeys, a code and notes. The raw values are the Credential Exchange
/// case names and the persisted format.
public nonisolated enum SecureItemKind: String, Codable, Sendable, CaseIterable {
    case creditCard, address, personName, wifi, apiKey, sshKey, driversLicense, passport, identityDocument, customFields

    /// Revealing or copying a hidden field, and opening the editor of a credential holding one, needs a fresh device-owner
    /// authentication (Touch ID or the Mac password). The value is encrypted in the vault like every other one.
    var isSensitive: Bool {
        switch self {
        case .creditCard, .driversLicense, .passport, .identityDocument:
            true
        case .address, .personName, .wifi, .apiKey, .sshKey, .customFields:
            false
        }
    }

    /// A person's name or an identity document: what makes an entry without a sign-in an identity.
    public var isIdentity: Bool {
        switch self {
        case .personName, .driversLicense, .passport, .identityDocument:
            true
        case .creditCard, .address, .wifi, .apiKey, .sshKey, .customFields:
            false
        }
    }

    /// The Credential Exchange members of this kind, in the SDK's order. `customFields` has none: its fields are positional.
    public var members: [SecureItemMember] {
        typealias Member = SecureItemMember
        switch self {
        case .creditCard:
            return [
                Member("number", secret: true), Member("fullName"), Member("cardType"),
                Member("verificationNumber", .concealedString, secret: true), Member("pin", .concealedString, secret: true),
                Member("expiryDate", .yearMonth), Member("validFrom", .yearMonth),
            ]
        case .address:
            return [
                Member("streetAddress"), Member("postalCode"), Member("city"), Member("territory", .subdivisionCode),
                Member("country", .countryCode), Member("telephone"),
            ]
        case .personName:
            return ["title", "given", "givenInformal", "given2", "surnamePrefix", "surname", "surname2", "credentials", "generation"]
                .map { Member($0) }
        case .wifi:
            return [
                Member("ssid"), Member("networkSecurityType", .wifiNetworkSecurityType),
                Member("passphrase", .concealedString, secret: true), Member("hidden", .boolean),
            ]
        case .apiKey:
            return [
                Member("key", .concealedString, secret: true), Member("userName"), Member("keyType"), Member("url"),
                Member("validFrom", .date), Member("expiryDate", .date),
            ]
        case .sshKey:
            // keyType, privateKey and keyComment are plain values in the SDK, not editable fields: they keep no field description.
            return [
                Member("keyType", isPlain: true), Member("privateKey", secret: true, isPlain: true), Member("keyComment", isPlain: true),
                Member("creationDate", .date), Member("expiryDate", .date), Member("keyGenerationSource"),
            ]
        case .driversLicense:
            return [
                Member("fullName"), Member("birthDate", .date), Member("issueDate", .date), Member("expiryDate", .date),
                Member("issuingAuthority"), Member("territory", .subdivisionCode), Member("country", .countryCode),
                Member("licenseNumber", secret: true), Member("licenseClass"),
            ]
        case .passport:
            return [
                Member("issuingCountry", .countryCode), Member("passportType"), Member("passportNumber", secret: true),
                Member("nationalIdentificationNumber", secret: true), Member("nationality"), Member("fullName"),
                Member("birthDate", .date), Member("birthPlace"), Member("sex"), Member("issueDate", .date),
                Member("expiryDate", .date), Member("issuingAuthority"),
            ]
        case .identityDocument:
            return [
                Member("issuingCountry", .countryCode), Member("documentNumber", secret: true),
                Member("identificationNumber", secret: true), Member("nationality"), Member("fullName"), Member("birthDate", .date),
                Member("birthPlace"), Member("sex"), Member("issueDate", .date), Member("expiryDate", .date), Member("issuingAuthority"),
            ]
        case .customFields:
            return []
        }
    }

    public func member(_ name: String) -> SecureItemMember? {
        members.first { $0.name == name }
    }
}

/// One member of a kind: its Credential Exchange name, the field type a value typed in WSurf gets, and whether its value is hidden
/// whatever type the exporter gave it.
public nonisolated struct SecureItemMember: Sendable, Equatable {
    public let name: String
    public let type: CredentialEditableFieldType
    let isSecret: Bool
    /// Stored without a field description (`SecureItemField.field` is nil): an SDK plain value, not an editable field.
    public let isPlain: Bool

    init(_ name: String, _ type: CredentialEditableFieldType = .string, secret: Bool = false, isPlain: Bool = false) {
        self.name = name
        self.type = type
        isSecret = secret
        self.isPlain = isPlain
    }
}

/// One value of an item. `name` is the member it belongs to ("" for custom fields). `field` keeps how the exporter described it
/// (id, label, type) so a value round-trips unchanged; it is nil for a plain SDK value.
public nonisolated struct SecureItemField: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var field: CredentialEditableFieldMetadata?

    public init(name: String, value: String, field: CredentialEditableFieldMetadata? = nil) {
        self.name = name
        self.value = value
        self.field = field
    }
}

/// A payment card, an address, a Wi-Fi network, a key or another item, as the values of its members. Items are one encrypted part of
/// their credential, with their own history; they are never put in `exchangeMetadata`, a summary, a log or a Trash label.
public nonisolated struct SecureItem: Codable, Sendable, Equatable {
    public var kind: SecureItemKind
    /// Custom fields only: the exporter's id and title of the group.
    var id: Data?
    public var label: String?
    public var fields: [SecureItemField]

    public init(kind: SecureItemKind, id: Data? = nil, label: String? = nil, fields: [SecureItemField]) {
        self.kind = kind
        self.id = id
        self.label = label
        self.fields = fields
    }

    /// Most items one credential keeps, and most fields one item keeps.
    public static let itemLimit = 64
    public static let fieldLimit = 256

    /// Hidden until revealed: a field the exporter marked hidden, or one of a member that is always hidden (a card number, a key).
    public func isConcealed(_ field: SecureItemField) -> Bool {
        field.field?.fieldType == .concealedString || kind.member(field.name)?.isSecret == true
    }

    /// Showing or copying its hidden values, and opening the editor of a credential holding it, asks for Touch ID: a card, an
    /// identity document, or custom fields with a hidden value (an SSN, an OIB). A Wi-Fi password or an API key does not.
    public var isSensitive: Bool {
        kind.isSensitive || kind == .customFields && fields.contains(where: isConcealed)
    }

    /// The first value of `member`, or nil when the item has none.
    public func value(_ member: String) -> String? {
        fields.first { $0.name == member }?.value
    }

    func validate() throws {
        guard !fields.isEmpty || label != nil, fields.count <= Self.fieldLimit,
              (id?.count ?? 0) <= 1_024, (label?.utf8.count ?? 0) <= 2_048 else { throw CredentialVaultError.invalidData }
        if kind == .customFields {
            guard fields.allSatisfy({ $0.name.isEmpty }) else { throw CredentialVaultError.invalidData }
        } else {
            let names = fields.map(\.name)
            guard id == nil, label == nil, Set(names).count == names.count,
                  fields.allSatisfy({ field in kind.member(field.name).map { !$0.isPlain || field.field == nil } ?? false }) else {
                throw CredentialVaultError.invalidData
            }
        }
        for field in fields {
            guard !field.value.isEmpty, field.value.utf8.count <= CredentialVaultLimits.payloadBytes else {
                throw CredentialVaultError.invalidData
            }
            try field.field?.validate()
        }
        if kind == .sshKey, let key = value("privateKey") {
            guard let bytes = try? WebAuthnWire.base64URLDecode(key, maximum: CredentialVaultLimits.payloadBytes), !bytes.isEmpty else {
                throw CredentialVaultError.invalidData
            }
        }
    }
}

nonisolated extension Array where Element == SecureItem {
    /// Every item of `incoming` that this list does not already hold as the same bytes, appended in order: how an import merge and a
    /// credential merge unite items without losing or doubling one.
    public func uniting(_ incoming: [SecureItem]) throws -> [SecureItem] {
        var result = self
        var held = Set(try map { try CredentialContent.canonicalJSON($0) })
        for item in incoming {
            let bytes = try CredentialContent.canonicalJSON(item)
            if held.insert(bytes).inserted {
                result.append(item)
            }
        }
        return result
    }
}
