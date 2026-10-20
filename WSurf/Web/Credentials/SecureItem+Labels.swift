// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated extension SecureItemKind {
    /// What the kind is called on a row, in the editor and in a menu.
    var label: String {
        switch self {
        case .creditCard:
            String(localized: "Payment card")
        case .address:
            String(localized: "Address")
        case .personName:
            String(localized: "Name")
        case .wifi:
            String(localized: "Wi-Fi network")
        case .apiKey:
            String(localized: "API key")
        case .sshKey:
            String(localized: "SSH key")
        case .driversLicense:
            String(localized: "Driver’s license")
        case .passport:
            String(localized: "Passport")
        case .identityDocument:
            String(localized: "ID document")
        case .customFields:
            String(localized: "Custom fields")
        }
    }

    /// The kinds the editor's Add Item menu offers, in its order. An SSH key comes only from a transfer: its private key is not typed.
    static let addable: [Self] = [.creditCard, .address, .personName, .wifi, .apiKey, .driversLicense, .passport, .identityDocument, .customFields]

    /// What a member is called where the user reads it.
    static func memberLabel(_ name: String) -> String {
        memberLabels[name] ?? name
    }

    private static let memberLabels: [String: String] = [
        "number": String(localized: "Card number"),
        "fullName": String(localized: "Full name"),
        "cardType": String(localized: "Card type"),
        "verificationNumber": String(localized: "Security code"),
        "pin": String(localized: "PIN"),
        "expiryDate": String(localized: "Expires"),
        "validFrom": String(localized: "Valid from"),
        "streetAddress": String(localized: "Street"),
        "postalCode": String(localized: "Postal code"),
        "city": String(localized: "City"),
        "territory": String(localized: "State or region"),
        "country": String(localized: "Country"),
        "telephone": String(localized: "Phone"),
        "title": String(localized: "Title"),
        "given": String(localized: "First name"),
        "givenInformal": String(localized: "Nickname"),
        "given2": String(localized: "Middle name"),
        "surnamePrefix": String(localized: "Surname prefix"),
        "surname": String(localized: "Last name"),
        "surname2": String(localized: "Second last name"),
        "credentials": String(localized: "Credentials"),
        "generation": String(localized: "Suffix"),
        "ssid": String(localized: "Network name"),
        "networkSecurityType": String(localized: "Security"),
        "passphrase": String(localized: "Password"),
        "hidden": String(localized: "Hidden network"),
        "key": String(localized: "Key"),
        "userName": String(localized: "Username"),
        "keyType": String(localized: "Key type"),
        "url": String(localized: "Website"),
        "privateKey": String(localized: "Private key"),
        "keyComment": String(localized: "Comment"),
        "creationDate": String(localized: "Created"),
        "keyGenerationSource": String(localized: "Created by"),
        "birthDate": String(localized: "Date of birth"),
        "issueDate": String(localized: "Issued"),
        "issuingAuthority": String(localized: "Issued by"),
        "licenseNumber": String(localized: "License number"),
        "licenseClass": String(localized: "License class"),
        "issuingCountry": String(localized: "Issuing country"),
        "passportType": String(localized: "Passport type"),
        "passportNumber": String(localized: "Passport number"),
        "nationalIdentificationNumber": String(localized: "ID number"),
        "identificationNumber": String(localized: "ID number"),
        "nationality": String(localized: "Nationality"),
        "birthPlace": String(localized: "Place of birth"),
        "sex": String(localized: "Sex"),
        "documentNumber": String(localized: "Document number"),
    ]
}

nonisolated extension SecureItem {
    /// What a row and a fill suggestion call the item. A card shows its network and last four digits, and nothing else of the
    /// number; every other kind shows only its label, never a value.
    var title: String {
        if kind == .customFields, let label, !label.isEmpty {
            return label
        }
        guard kind == .creditCard, let number = value("number") else { return kind.label }
        let digits = number.filter(\.isNumber)
        guard digits.count >= 4 else { return kind.label }
        let network = (try? PaymentCard(number: digits))?.network ?? kind.label
        return "\(network) •••• \(digits.suffix(4))"
    }

    /// What one value is called: a custom field's own label, else the member's.
    func label(of field: SecureItemField) -> String {
        if kind == .customFields {
            return field.field?.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Field")
        }
        return SecureItemKind.memberLabel(field.name)
    }

    /// A new, empty item of `kind` as the editor adds it: one empty value per member a person can type, with the member's type.
    static func empty(_ kind: SecureItemKind) -> SecureItem {
        guard kind != .customFields else {
            return SecureItem(kind: .customFields, label: "", fields: [SecureItemField(name: "", value: "", field: .init(id: nil, label: "", fieldType: .string))])
        }
        let fields = kind.members.filter { !$0.isPlain }.map {
            SecureItemField(name: $0.name, value: "", field: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: $0.type))
        }
        return SecureItem(kind: kind, fields: fields)
    }
}

/// One value of a credential's items, by position: what a row's menu offers to copy. A name only, never the value.
nonisolated struct SecureFieldReference: Equatable, Hashable, Sendable {
    let item: Int
    let field: Int
    let label: String
}
