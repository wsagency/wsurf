// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The networks a card number names by its prefix. The app keeps their names; a prefix none of them claims is a plain payment card.
public nonisolated enum CardNetwork: String, Sendable, CaseIterable {
    case visa, americanExpress, mastercard, discover, jcb, unionPay

    /// The network `number` (digits only) names, or nil for a prefix the rules do not know.
    public init?(number: String) {
        if number.hasPrefix("4") {
            self = .visa
        } else if number.hasPrefix("34") || number.hasPrefix("37") {
            self = .americanExpress
        } else if let prefix = Int(number.prefix(2)), (51...55).contains(prefix) {
            self = .mastercard
        } else if let prefix = Int(number.prefix(4)), (2221...2720).contains(prefix) {
            self = .mastercard
        } else if number.hasPrefix("6011") || number.hasPrefix("65") {
            self = .discover
        } else if number.hasPrefix("35") {
            self = .jcb
        } else if number.hasPrefix("62") {
            self = .unionPay
        } else {
            return nil
        }
    }
}

/// The rules a payment card is read by, wherever it is filled from or saved to: the card check, the stored expiry and its end.
public nonisolated enum PaymentCardRules {
    /// 13 to 19 ASCII digits, not all zero, that pass the Luhn check. A UnionPay number (62…) is accepted without the check.
    public static func isValidNumber(_ number: String) -> Bool {
        let digits = Array(number.utf8)
        guard (13...19).contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }),
              digits.contains(where: { $0 != 48 }) else { return false }
        if number.hasPrefix("62") {
            return true
        }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            let digit = Int(item.element - 48) * (item.offset.isMultiple(of: 2) ? 1 : 2)
            return total + (digit > 9 ? digit - 9 : digit)
        }
        return sum.isMultiple(of: 10)
    }

    /// 3 or 4 ASCII digits: a security code a card keeps.
    public static func isValidSecurityCode(_ code: String) -> Bool {
        (3...4).contains(code.utf8.count) && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// "YYYY-MM" (the Credential Exchange year-month) as numbers; either is nil when it does not read.
    public static func yearMonth(_ text: String?) -> (year: Int?, month: Int?) {
        let parts = (text ?? "").split(separator: "-")
        guard parts.count >= 2 else { return (nil, nil) }
        return (Int(parts[0]), Int(parts[1]))
    }

    /// Whether a card that ends in `month` of `year` has ended by `date` (in the Gregorian calendar). A card without both never has.
    public static func isExpired(month: Int?, year: Int?, on date: Date) -> Bool {
        guard let month, let year else { return false }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        guard let currentYear = parts.year, let currentMonth = parts.month else { return false }
        return year < currentYear || (year == currentYear && month < currentMonth)
    }
}

/// One card item as it fills a form: a number that passes the card check, the name on the card, the expiry and the security code. It
/// reaches the app only for the card a person picked (`ProfileVaultStore.autofillItems`), or on the save path, which compares whole
/// entries. It prints and mirrors without its values.
public nonisolated struct AutofillCardValues: Equatable, Sendable {
    public let number: String
    public let cardholder: String
    public let month: Int?
    public let year: Int?
    public let securityCode: String?

    /// The card `item` fills with, or nil when it is not a card or its number fails the card check. An expiry outside 1-12 or
    /// 2000-2199 is left out whole, and a security code that is not 3 or 4 digits is left out, rather than refusing the card.
    public init?(_ item: SecureItem) {
        guard item.kind == .creditCard, let stored = item.value("number") else { return nil }
        let number = stored.filter(\.isNumber)
        guard PaymentCardRules.isValidNumber(number) else { return nil }
        var (year, month) = PaymentCardRules.yearMonth(item.value("expiryDate"))
        if !(month.map { (1...12).contains($0) } ?? true) || !(year.map { (2000...2199).contains($0) } ?? true) {
            (year, month) = (nil, nil)
        }
        let code = item.value("verificationNumber")?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.number = number
        cardholder = String((item.value("fullName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.month = month
        self.year = year
        securityCode = code.flatMap { !$0.isEmpty && PaymentCardRules.isValidSecurityCode($0) ? $0 : nil }
    }

    public var network: CardNetwork? {
        CardNetwork(number: number)
    }

    public var lastFour: String {
        String(number.suffix(4))
    }

    public func isExpired(on date: Date) -> Bool {
        PaymentCardRules.isExpired(month: month, year: year, on: date)
    }
}

/// A contact as it fills a form: an entry's first name item, first address item, and the email and organization it keeps as custom
/// fields with stable ids, with the entry's name as its label. It reaches the app only for the contact a person picked, or on the
/// save path. It prints and mirrors without its values.
public nonisolated struct AutofillContactValues: Equatable, Sendable {
    /// The stable ids of a contact's email and organization, which an entry keeps as custom fields.
    public static let emailFieldID = Data("email".utf8)
    public static let organizationFieldID = Data("organization".utf8)

    public let label: String
    public let givenName: String
    public let familyName: String
    public let organization: String
    public let email: String
    public let phone: String
    public let street: String
    public let city: String
    public let region: String
    public let postalCode: String
    public let countryCode: String

    /// The contact `account` holds, or nil when it holds no address, name, email or organization, or the result is not a valid
    /// contact. A country that is not an ISO region code (an exporter may send a name) is left out rather than refusing the contact.
    public init?(of account: CredentialAccount) {
        let items = account.secureItems ?? []
        let address = items.first { $0.kind == .address }
        let name = items.first { $0.kind == .personName }
        let custom = items.filter { $0.kind == .customFields }.flatMap(\.fields)
        let email = custom.first { $0.field?.id == Self.emailFieldID }?.value ?? ""
        let organization = custom.first { $0.field?.id == Self.organizationFieldID }?.value ?? ""
        guard address != nil || name != nil || !email.isEmpty || !organization.isEmpty else { return nil }
        func joined(_ item: SecureItem?, _ members: [String]) -> String {
            members.compactMap { item?.value($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let country = (address?.value("country") ?? "").uppercased()
        self.init(
            label: account.displayName ?? "",
            givenName: joined(name, ["given", "given2"]),
            familyName: joined(name, ["surnamePrefix", "surname", "surname2"]),
            organization: organization,
            email: email,
            phone: address?.value("telephone") ?? "",
            street: address?.value("streetAddress") ?? "",
            city: address?.value("city") ?? "",
            region: address?.value("territory") ?? "",
            postalCode: address?.value("postalCode") ?? "",
            countryCode: Self.isRegion(country) ? country : ""
        )
        guard isValid else { return nil }
    }

    /// The values as given; `isValid` says whether they make a contact that fills.
    public init(
        label: String, givenName: String, familyName: String, organization: String, email: String, phone: String, street: String,
        city: String, region: String, postalCode: String, countryCode: String
    ) {
        self.label = label
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.email = email
        self.phone = phone
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.countryCode = countryCode
    }

    /// An item a contact is made from: an address, a name, or custom fields that hold its email or organization.
    static func isContactItem(_ item: SecureItem) -> Bool {
        item.kind == .address || item.kind == .personName
            || item.kind == .customFields && item.fields.contains { $0.field?.id == emailFieldID || $0.field?.id == organizationFieldID }
    }

    private static func isRegion(_ code: String) -> Bool {
        Locale.Region.isoRegions.contains { $0.identifier == code }
    }

    public var name: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// No value longer than 500 characters, a value besides the label, and a country that is empty or an ISO region code.
    public var isValid: Bool {
        let values = [label, givenName, familyName, organization, email, phone, street, city, region, postalCode, countryCode]
        return values.allSatisfy { $0.count <= 500 }
            && values.dropFirst().contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (countryCode.isEmpty || Self.isRegion(countryCode))
    }

    /// What a row calls the contact: its label, name, email, street, organization or phone, the first that is not empty. Nil when
    /// all are, and the app calls it a contact.
    public var title: String? {
        [label, name, email, street, organization, phone].first { !$0.isEmpty }
    }

    /// A row's second line: the email and the street on one line.
    public var detail: String {
        [email, street.replacingOccurrences(of: "\n", with: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A card's or contact's values never print, in a log line, a failed assertion or a dump.
nonisolated extension AutofillCardValues: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AutofillCardValues"
    }

    public var debugDescription: String {
        "AutofillCardValues"
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }
}

nonisolated extension AutofillContactValues: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AutofillContactValues"
    }

    public var debugDescription: String {
        "AutofillContactValues"
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }
}
