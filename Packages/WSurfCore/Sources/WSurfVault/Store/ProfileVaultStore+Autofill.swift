// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// What autofill reads, without the whole vault leaving the store. Each method runs the verified read (`snapshot(vaultID:using:)`:
/// the operation lock, the head, every row's digest and AAD, the row count, and the decoded cache) on this actor, checks once more that
/// `access` still holds its grant, and returns only what its caller needs. A list gets candidates or rows; a pick, named by a
/// credential (and an item) and the revision its list was read at, gets that one value. The storage format, the read, the decoded
/// cache, writes and sync are unchanged.
extension ProfileVaultStore {
    /// The credentials of an unlocked vault as a list may show them (`AutofillCandidate`): no secret value.
    public func autofillCandidates(vaultID: UUID, using access: VaultAccess) async throws -> AutofillCandidates {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        _ = try authorizedGrant(vaultID, access)
        return AutofillCandidates(vaultID: vaultID, revision: snapshot.revision, candidates: snapshot.accounts.map(AutofillCandidate.init))
    }

    /// The picked credential's candidate and `field`'s secret only: its password, or the source of its code. A credential that is no
    /// longer there, or any write since `expectedRevision` (the revision its list was read at), is `staleRevision`.
    public func autofillLogin(
        vaultID: UUID, accountID: UUID, field: AutofillLoginField, expectedRevision: UInt64, using access: VaultAccess
    ) async throws -> AutofillLogin {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        _ = try authorizedGrant(vaultID, access)
        guard snapshot.revision == expectedRevision, let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
            throw CredentialVaultError.staleRevision
        }
        return AutofillLogin(account, field: field)
    }

    /// The cards or contacts of an unlocked vault as rows (`AutofillItems`): a card's network, last four digits, name and expiry, a
    /// contact's title and detail, and no other value or kind of item. A pick names a row, by its credential and item, and the
    /// revision its list was read at: the result then holds that row and its values (`picked`), the one card or the contact, and
    /// nothing else. A pick of a row that is no longer there, or any write since `expectedRevision`, is `staleRevision`; a pick
    /// without an item or a revision is `invalidData`.
    public func autofillItems(
        vaultID: UUID, kind: AutofillItemKind, accountID: UUID? = nil, item: Int? = nil, expectedRevision: UInt64? = nil,
        using access: VaultAccess
    ) async throws -> AutofillItems {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        _ = try authorizedGrant(vaultID, access)
        let now = wall()
        guard let accountID else {
            var cards: [AutofillCardRow] = []
            var contacts: [AutofillContactRow] = []
            for account in snapshot.accounts {
                switch kind {
                case .cards:
                    cards += Self.cardRows(of: account, now: now).map(\.row)
                case .contacts:
                    if let contact = Self.contactRow(of: account) {
                        contacts.append(contact.row)
                    }
                }
            }
            return AutofillItems(vaultID: vaultID, revision: snapshot.revision, cards: cards, contacts: contacts, picked: nil)
        }
        guard let item, let expectedRevision else { throw CredentialVaultError.invalidData }
        guard snapshot.revision == expectedRevision, let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
            throw CredentialVaultError.staleRevision
        }
        switch kind {
        case .cards:
            guard let card = Self.cardRows(of: account, now: now).first(where: { $0.row.item == item }) else {
                throw CredentialVaultError.staleRevision
            }
            return AutofillItems(vaultID: vaultID, revision: snapshot.revision, cards: [card.row], contacts: [], picked: .card(card.values))
        case .contacts:
            guard let contact = Self.contactRow(of: account), contact.row.item == item else { throw CredentialVaultError.staleRevision }
            return AutofillItems(
                vaultID: vaultID, revision: snapshot.revision, cards: [], contacts: [contact.row], picked: .contact(contact.values)
            )
        }
    }

    /// Every card of `account` that can fill at `now`: a number that passes the card check, not expired.
    private nonisolated static func cardRows(of account: CredentialAccount, now: Date) -> [(row: AutofillCardRow, values: AutofillCardValues)] {
        (account.secureItems ?? []).enumerated().compactMap { index, item in
            guard let card = AutofillCardValues(item), !card.isExpired(on: now) else { return nil }
            return (AutofillCardRow(accountID: account.id, item: index, card), card)
        }
    }

    /// The contact `account` holds, if any, at the position of its first contact item.
    private nonisolated static func contactRow(of account: CredentialAccount) -> (row: AutofillContactRow, values: AutofillContactValues)? {
        guard let index = account.secureItems?.firstIndex(where: AutofillContactValues.isContactItem),
              let contact = AutofillContactValues(of: account) else { return nil }
        return (AutofillContactRow(accountID: account.id, item: index, contact), contact)
    }
}
