// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The cards and addresses of the credentials vault, as the fill panel offers them and the page receives them. Pure: the caller reads
/// the vault under its own lease and checks it again before anything reaches the page.
nonisolated enum VaultItemAutofill {
    /// One row the panel can show: the credential and item it comes from, and what fills. `value` stays in Swift until delivery.
    struct Offer<Value: Sendable>: Sendable {
        let accountID: UUID
        let item: Int
        let value: Value
    }

    /// Every card that can fill a form, in vault order: a number that passes the card check and an expiry not in the past.
    static func cards(in accounts: [CredentialAccount], now: Date = .now) -> [Offer<PaymentCard>] {
        accounts.flatMap { account -> [Offer<PaymentCard>] in
            (account.secureItems ?? []).enumerated().compactMap { index, item -> Offer<PaymentCard>? in
                guard let card = paymentCard(item), !card.isExpired(on: now) else { return nil }
                return Offer(accountID: account.id, item: index, value: card)
            }
        }
    }

    /// One contact per credential that holds an address or a name: its first of each, combined.
    static func contacts(in accounts: [CredentialAccount]) -> [Offer<AutofillContact>] {
        accounts.compactMap { account -> Offer<AutofillContact>? in
            guard let index = account.secureItems?.firstIndex(where: { $0.kind == .address || $0.kind == .personName }),
                  let contact = contact(of: account) else { return nil }
            return Offer(accountID: account.id, item: index, value: contact)
        }
    }

    /// The card an item fills with, or `nil` when it is not a card or its number fails the card check. A security code or an expiry
    /// that does not read is left out rather than refusing the card.
    static func paymentCard(_ item: SecureItem) -> PaymentCard? {
        guard item.kind == .creditCard, let number = item.value("number") else { return nil }
        let (year, month) = yearMonth(item.value("expiryDate"))
        let code = item.value("verificationNumber")
        let holder = item.value("fullName") ?? ""
        let digits = number.filter(\.isNumber)
        return (try? PaymentCard(number: digits, cardholder: holder, month: month, year: year, securityCode: code))
            ?? (try? PaymentCard(number: digits, cardholder: holder, month: month, year: year))
            ?? (try? PaymentCard(number: digits, cardholder: holder))
    }

    /// The first address and the first name of `account` as one contact, or `nil` when it has neither or the result is not valid.
    static func contact(of account: CredentialAccount) -> AutofillContact? {
        let items = account.secureItems ?? []
        let address = items.first { $0.kind == .address }
        let name = items.first { $0.kind == .personName }
        guard address != nil || name != nil else { return nil }
        func joined(_ item: SecureItem?, _ members: [String]) -> String {
            members.compactMap { item?.value($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        var contact = AutofillContact()
        contact.label = account.displayName ?? ""
        contact.givenName = joined(name, ["given", "given2"])
        contact.familyName = joined(name, ["surnamePrefix", "surname", "surname2"])
        contact.street = address?.value("streetAddress") ?? ""
        contact.city = address?.value("city") ?? ""
        contact.region = address?.value("territory") ?? ""
        contact.postalCode = address?.value("postalCode") ?? ""
        contact.phone = address?.value("telephone") ?? ""
        // A country that is not an ISO region code (the exporter may send a name) is left out rather than invalidating the contact.
        let country = (address?.value("country") ?? "").uppercased()
        contact.countryCode = Locale.Region.isoRegions.contains { $0.identifier == country } ? country : ""
        return contact.isValid ? contact : nil
    }

    /// "YYYY-MM" (the Credential Exchange year-month) as numbers; either is nil when it does not read.
    static func yearMonth(_ text: String?) -> (year: Int?, month: Int?) {
        let parts = (text ?? "").split(separator: "-")
        guard parts.count >= 2 else { return (nil, nil) }
        return (Int(parts[0]), Int(parts[1]))
    }
}
