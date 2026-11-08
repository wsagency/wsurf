// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Contacts
import Foundation
import WSurfVault

nonisolated struct AutofillContact: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var label = ""
    var givenName = ""
    var familyName = ""
    var organization = ""
    var email = ""
    var phone = ""
    var street = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var countryCode = ""

    var name: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The vault's rule (`AutofillContactValues.title`), so a contact the vault lists as a row is named as this one is.
    var title: String {
        AutofillContactValues(self).title ?? String(localized: "Contact")
    }

    var detail: String {
        [name, email, phone, street, city, region, postalCode, countryCode]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The vault's rule (`AutofillContactValues.isValid`): no value over 500 characters, a value besides the label, and an ISO
    /// country or none.
    var isValid: Bool {
        AutofillContactValues(self).isValid
    }

    var fields: [String: String] {
        let lines = street.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return [
            "name": name, "given-name": givenName, "family-name": familyName,
            "organization": organization, "email": email, "tel": phone,
            "street-address": street, "address-line1": lines.first ?? "",
            "address-line2": lines.dropFirst().first ?? "", "address-line3": lines.dropFirst(2).joined(separator: ", "),
            "address-level2": city, "address-level1": region, "postal-code": postalCode,
            "country": countryCode, "country-name": Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode,
        ]
    }

    init() {}

    /// A contact the vault read for a pick (`AutofillContactValues`), with a fresh id.
    init(_ values: AutofillContactValues) {
        label = values.label
        givenName = values.givenName
        familyName = values.familyName
        organization = values.organization
        email = values.email
        phone = values.phone
        street = values.street
        city = values.city
        region = values.region
        postalCode = values.postalCode
        countryCode = values.countryCode
    }

    init(contact: CNContact) {
        if contact.isKeyAvailable(CNContactGivenNameKey) {
            givenName = contact.givenName
        }
        if contact.isKeyAvailable(CNContactFamilyNameKey) {
            familyName = contact.familyName
        }
        if contact.isKeyAvailable(CNContactOrganizationNameKey) {
            organization = contact.organizationName
        }
        if contact.isKeyAvailable(CNContactEmailAddressesKey) {
            email = contact.emailAddresses.first?.value as String? ?? ""
        }
        if contact.isKeyAvailable(CNContactPhoneNumbersKey) {
            phone = contact.phoneNumbers.first?.value.stringValue ?? ""
        }
        if contact.isKeyAvailable(CNContactPostalAddressesKey), let address = contact.postalAddresses.first?.value {
            apply(address)
        }
    }

    mutating func apply(_ address: CNPostalAddress) {
        street = address.street
        city = address.city
        region = address.state
        postalCode = address.postalCode
        countryCode = address.isoCountryCode.uppercased()
    }
}

nonisolated extension AutofillContactValues {
    /// `contact`'s values, for the vault's rules (title, row detail, validity).
    init(_ contact: AutofillContact) {
        self.init(
            label: contact.label, givenName: contact.givenName, familyName: contact.familyName, organization: contact.organization,
            email: contact.email, phone: contact.phone, street: contact.street, city: contact.city, region: contact.region,
            postalCode: contact.postalCode, countryCode: contact.countryCode
        )
    }
}
