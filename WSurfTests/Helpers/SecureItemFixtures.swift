// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import WSurf

/// Synthetic items only. The card number is a published test number (it passes the Luhn check); nothing here is real.
nonisolated enum SecureItemFixtures {
    static let cardNumber = "4242424242424242"
    static let cardCode = "737"
    static let wifiPassphrase = "synthetic-wifi-passphrase-1"

    static func field(_ name: String, _ value: String, type: CredentialEditableFieldType? = nil) -> SecureItemField {
        SecureItemField(name: name, value: value, field: type.map { CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: $0) })
    }

    static func card(number: String = cardNumber, code: String = cardCode, name: String = "Ada Lovelace") -> SecureItem {
        SecureItem(kind: .creditCard, fields: [
            field("number", number, type: .string),
            field("fullName", name, type: .string),
            field("verificationNumber", code, type: .concealedString),
            field("expiryDate", "2031-07", type: .yearMonth),
        ])
    }

    static func address(street: String = "1 Synthetic Way", city: String = "Testville") -> SecureItem {
        SecureItem(kind: .address, fields: [
            field("streetAddress", street, type: .string),
            field("city", city, type: .string),
            field("postalCode", "10000", type: .string),
            field("country", "HR", type: .countryCode),
            field("telephone", "+385 1 000 0000", type: .string),
        ])
    }

    static func name(given: String = "Ada", surname: String = "Lovelace") -> SecureItem {
        SecureItem(kind: .personName, fields: [field("given", given, type: .string), field("surname", surname, type: .string)])
    }

    static func wifi(ssid: String = "Synthetic-Net", passphrase: String = wifiPassphrase) -> SecureItem {
        SecureItem(kind: .wifi, fields: [
            field("ssid", ssid, type: .string),
            field("networkSecurityType", "WPA3-Personal", type: .wifiNetworkSecurityType),
            field("passphrase", passphrase, type: .concealedString),
            field("hidden", "false", type: .boolean),
        ])
    }

    static func custom(label: String = "Locker", values: [(label: String, value: String, hidden: Bool)] = [("Code", "4711", true)]) -> SecureItem {
        SecureItem(kind: .customFields, id: Data([0xC0, 0x01]), label: label, fields: values.map { value in
            SecureItemField(
                name: "", value: value.value,
                field: CredentialEditableFieldMetadata(id: nil, label: value.label, fieldType: value.hidden ? .concealedString : .string)
            )
        })
    }

    /// A credential that holds only `items`: no login, website, passkey, code or note.
    static func account(_ items: [SecureItem], id: UUID = UUID(), name: String? = "Synthetic item") -> CredentialAccount {
        var account = CredentialAccount(
            id: id, username: "", displayName: name, origins: [], loginURLs: [],
            password: nil, passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        account.secureItems = items
        return account
    }
}
