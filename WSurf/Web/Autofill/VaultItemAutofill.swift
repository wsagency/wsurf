// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The cards and addresses of the credentials vault, as the fill panel offers them and the page receives them, and as a save offer or
/// the move from the old Keychain lists writes them. Pure: the caller reads the vault under its own lease and checks it again before
/// anything reaches the page or the vault.
nonisolated enum VaultItemAutofill {
    /// The stable ids of a contact's email and organization, which an entry keeps as custom fields.
    static let emailFieldID = Data("email".utf8)
    static let organizationFieldID = Data("organization".utf8)

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

    /// One contact per credential that holds an address, a name, or a contact's email or organization: its first of each, combined.
    static func contacts(in accounts: [CredentialAccount]) -> [Offer<AutofillContact>] {
        accounts.compactMap { account -> Offer<AutofillContact>? in
            guard let index = account.secureItems?.firstIndex(where: isContactItem), let contact = contact(of: account) else { return nil }
            return Offer(accountID: account.id, item: index, value: contact)
        }
    }

    private static func isContactItem(_ item: SecureItem) -> Bool {
        item.kind == .address || item.kind == .personName
            || item.kind == .customFields && item.fields.contains { $0.field?.id == emailFieldID || $0.field?.id == organizationFieldID }
    }

    /// The card an item fills with, or `nil` when it is not a card or its number fails the card check. A security code or an expiry
    /// that does not read is left out rather than refusing the card.
    static func paymentCard(_ item: SecureItem) -> PaymentCard? {
        guard item.kind == .creditCard, let number = item.value("number") else { return nil }
        var (year, month) = yearMonth(item.value("expiryDate"))
        if !(month.map { (1...12).contains($0) } ?? true) || !(year.map { (2000...2199).contains($0) } ?? true) {
            (year, month) = (nil, nil)
        }
        let code = item.value("verificationNumber")
        let holder = item.value("fullName") ?? ""
        let digits = number.filter(\.isNumber)
        return (try? PaymentCard(number: digits, cardholder: holder, month: month, year: year, securityCode: code))
            ?? (try? PaymentCard(number: digits, cardholder: holder, month: month, year: year))
    }

    /// The first address, the first name and the contact email and organization of `account` as one contact, or `nil` when it has none
    /// of them or the result is not valid.
    static func contact(of account: CredentialAccount) -> AutofillContact? {
        let items = account.secureItems ?? []
        let address = items.first { $0.kind == .address }
        let name = items.first { $0.kind == .personName }
        let custom = items.filter { $0.kind == .customFields }.flatMap(\.fields)
        let email = custom.first { $0.field?.id == emailFieldID }?.value ?? ""
        let organization = custom.first { $0.field?.id == organizationFieldID }?.value ?? ""
        guard address != nil || name != nil || !email.isEmpty || !organization.isEmpty else { return nil }
        func joined(_ item: SecureItem?, _ members: [String]) -> String {
            members.compactMap { item?.value($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        var contact = AutofillContact()
        contact.label = account.displayName ?? ""
        contact.email = email
        contact.organization = organization
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

    // MARK: Into the vault

    /// A new entry that holds `card` as one card item: number, name on card, expiry ("YYYY-MM") and security code. An expiry with only a
    /// month or only a year is left out.
    static func account(for card: PaymentCard) -> CredentialAccount {
        entry([cardItem(card)], name: nil)
    }

    /// A new entry that holds `contact`: its name as a name item, its address and phone as an address item, and its email and
    /// organization as custom fields with stable ids. Its label is the entry's name.
    static func account(for contact: AutofillContact) -> CredentialAccount {
        let custom = [
            (emailFieldID, String(localized: "Email"), CredentialEditableFieldType.email, contact.email),
            (organizationFieldID, String(localized: "Organization"), CredentialEditableFieldType.string, contact.organization),
        ].filter { !$0.3.isEmpty }.map { id, label, type, value in
            SecureItemField(name: "", value: value, field: CredentialEditableFieldMetadata(id: id, label: label, fieldType: type))
        }
        let items = [
            item(.personName, ["given": contact.givenName, "surname": contact.familyName]),
            item(.address, [
                "streetAddress": contact.street, "postalCode": contact.postalCode, "city": contact.city, "territory": contact.region,
                "country": contact.countryCode, "telephone": contact.phone,
            ]),
            custom.isEmpty ? nil : SecureItem(kind: .customFields, fields: custom),
        ].compactMap { $0 }
        return entry(items, name: contact.label.isEmpty ? nil : contact.label)
    }

    /// The same card for filling: number, name, expiry and security code. A lone month or year counts as no expiry, as it is stored.
    static func sameCard(_ lhs: PaymentCard, _ rhs: PaymentCard) -> Bool {
        func expiry(_ card: PaymentCard) -> [Int]? {
            card.month.flatMap { month in card.year.map { [$0, month] } }
        }
        return lhs.number == rhs.number && lhs.cardholder == rhs.cardholder && expiry(lhs) == expiry(rhs) && lhs.securityCode == rhs.securityCode
    }

    /// What saving `candidate` (a card or a contact from a form) would do to `accounts`: nothing when an entry already holds it, an
    /// update of the entry that holds a card with its number, and a new entry otherwise. A card compares as the save index did (number,
    /// name and expiry), a contact by all its values.
    static func savePlan(_ candidate: AutofillSaveCandidate, in accounts: [CredentialAccount]) -> CredentialSavePlan {
        switch candidate {
        case .password:
            return .ambiguous
        case .card(let card):
            for account in accounts {
                for item in account.secureItems ?? [] {
                    guard let held = paymentCard(item), held.number == card.number else { continue }
                    return AutofillSaveCandidate.card(held).values == candidate.values ? .unchanged : .update(account.id)
                }
            }
            return .create
        case .contact:
            return accounts.contains { contact(of: $0).map { AutofillSaveCandidate.contact($0).values } == candidate.values } ? .unchanged : .create
        }
    }

    /// The one write that saves `candidate` into `snapshot`'s vault, or `nil` when the vault already holds it. An update changes only
    /// the card item with that number, keeping its other values (and its security code when `keepingCode` and the form had none).
    static func saveWrite(_ candidate: AutofillSaveCandidate, into snapshot: StoreSnapshot, keepingCode: Bool) throws -> AccountWrite? {
        switch savePlan(candidate, in: snapshot.accounts) {
        case .unchanged:
            return nil
        case .ambiguous:
            throw CredentialVaultError.invalidData
        case .create:
            guard snapshot.accounts.count < CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }
            let account: CredentialAccount
            switch candidate {
            case .card(let card):
                account = Self.account(for: card)
            case .contact(let contact):
                account = Self.account(for: contact)
            case .password:
                throw CredentialVaultError.invalidData
            }
            return AccountWrite(accountID: account.id, expected: .absent, replacement: account)
        case .update(let id):
            guard case .card(let card) = candidate, var account = snapshot.accounts.first(where: { $0.id == id }),
                  let stamp = snapshot.stamps[id], var items = account.secureItems,
                  let index = items.firstIndex(where: { paymentCard($0)?.number == card.number }) else { throw CredentialVaultError.staleRevision }
            let fresh = cardItem(card)
            for name in ["number", "fullName", "expiryDate", "verificationNumber"] {
                let value = fresh.fields.first { $0.name == name }
                if name == "verificationNumber", value == nil, keepingCode {
                    continue
                }
                if let held = items[index].fields.firstIndex(where: { $0.name == name }) {
                    if let value {
                        items[index].fields[held].value = value.value
                    } else {
                        items[index].fields.remove(at: held)
                    }
                } else if let value {
                    items[index].fields.append(value)
                }
            }
            account.secureItems = items
            return AccountWrite(accountID: id, expected: .stamp(stamp), replacement: account)
        }
    }

    private static func cardItem(_ card: PaymentCard) -> SecureItem {
        let expiry = card.month.flatMap { month in card.year.map { String(format: "%04d-%02d", $0, month) } }
        // A card always has a number, so the item is never empty.
        return item(.creditCard, [
            "number": card.number, "fullName": card.cardholder, "expiryDate": expiry ?? "", "verificationNumber": card.securityCode ?? "",
        ]) ?? SecureItem(kind: .creditCard, fields: [])
    }

    /// An item of `kind` as the editor makes it, holding the non-empty `values` by member name.
    private static func item(_ kind: SecureItemKind, _ values: [String: String]) -> SecureItem? {
        var item = SecureItem.empty(kind)
        item.fields = item.fields.compactMap { field in
            guard let value = values[field.name], !value.isEmpty else { return nil }
            var filled = field
            filled.value = value
            return filled
        }
        return item.fields.isEmpty ? nil : item
    }

    private static func entry(_ items: [SecureItem], name: String?) -> CredentialAccount {
        var account = CredentialAccount(
            id: UUID(), username: "", displayName: name, origins: [], loginURLs: [], password: nil, passkeys: [], totp: nil,
            exchangeAccountID: nil, exchangeItemID: nil
        )
        account.secureItems = items.isEmpty ? nil : items
        return account
    }

    /// "YYYY-MM" (the Credential Exchange year-month) as numbers; either is nil when it does not read.
    static func yearMonth(_ text: String?) -> (year: Int?, month: Int?) {
        let parts = (text ?? "").split(separator: "-")
        guard parts.count >= 2 else { return (nil, nil) }
        return (Int(parts[0]), Int(parts[1]))
    }
}
