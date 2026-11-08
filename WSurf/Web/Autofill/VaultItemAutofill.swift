// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// The cards and addresses of the credentials vault, as the page receives them, and as a save offer or the move from the old Keychain
/// lists writes them. The rules that read a card or a contact are the vault's (`AutofillCardValues`, `AutofillContactValues`), so the
/// fill panel's rows, which the vault builds (`ProfileVaultStore.autofillItems`), and everything here read an item the same way. Pure:
/// the caller reads the vault under its own lease and checks it again before anything reaches the page or the vault.
nonisolated enum VaultItemAutofill {
    /// The stable ids of a contact's email and organization, which an entry keeps as custom fields.
    static let emailFieldID = AutofillContactValues.emailFieldID
    static let organizationFieldID = AutofillContactValues.organizationFieldID

    /// One row the panel can show: the credential and item it comes from, and what fills. `value` stays in Swift until delivery.
    struct Offer<Value: Sendable>: Sendable {
        let accountID: UUID
        let item: Int
        let value: Value
    }

    /// Every card that can fill a form, in vault order: a number that passes the card check and an expiry not in the past. The
    /// whole-entry form of the vault's card rows, which the fill panel lists.
    static func cards(in accounts: [CredentialAccount], now: Date = .now) -> [Offer<PaymentCard>] {
        accounts.flatMap { account -> [Offer<PaymentCard>] in
            (account.secureItems ?? []).enumerated().compactMap { index, item -> Offer<PaymentCard>? in
                guard let card = paymentCard(item), !card.isExpired(on: now) else { return nil }
                return Offer(accountID: account.id, item: index, value: card)
            }
        }
    }

    /// One contact per credential that holds an address, a name, or a contact's email or organization: its first of each, combined.
    /// The whole-entry form of the vault's contact rows.
    static func contacts(in accounts: [CredentialAccount]) -> [Offer<AutofillContact>] {
        accounts.compactMap { account -> Offer<AutofillContact>? in
            guard let index = account.secureItems?.firstIndex(where: AutofillContactValues.isContactItem), let contact = contact(of: account)
            else { return nil }
            return Offer(accountID: account.id, item: index, value: contact)
        }
    }

    /// The card an item fills with, or `nil` when it is not a card or its number fails the card check. A security code or an expiry
    /// that does not read is left out rather than refusing the card (`AutofillCardValues`).
    static func paymentCard(_ item: SecureItem) -> PaymentCard? {
        AutofillCardValues(item).flatMap(paymentCard)
    }

    /// A card the vault read for a pick, as the page receives it.
    static func paymentCard(_ card: AutofillCardValues) -> PaymentCard? {
        try? PaymentCard(number: card.number, cardholder: card.cardholder, month: card.month, year: card.year, securityCode: card.securityCode)
    }

    /// The first address, the first name and the contact email and organization of `account` as one contact, or `nil` when it has none
    /// of them or the result is not valid (`AutofillContactValues`).
    static func contact(of account: CredentialAccount) -> AutofillContact? {
        AutofillContactValues(of: account).map(AutofillContact.init)
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

    /// "YYYY-MM" (the Credential Exchange year-month) as numbers; either is nil when it does not read (`PaymentCardRules`).
    static func yearMonth(_ text: String?) -> (year: Int?, month: Int?) {
        PaymentCardRules.yearMonth(text)
    }
}
