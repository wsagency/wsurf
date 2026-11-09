// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// What autofill reads, without the whole vault leaving the store. Each method runs the verified read (`snapshot(vaultID:using:)`:
/// the operation lock, the head, every row's digest and AAD, the row count, and the decoded cache) on this actor, projects what its
/// caller needs, and checks once more, right before it returns, that `access` still holds its grant: a lock whose revocation lands
/// during the read or the projection returns nothing. A list gets candidates or rows; a pick, named by a credential (and an item) and
/// the revision its list was read at, gets that one value. The storage format, the read, the decoded cache, writes and sync are
/// unchanged.
extension ProfileVaultStore {
    /// The credentials of an unlocked vault as a list may show them (`AutofillCandidate`): no secret value.
    public func autofillCandidates(vaultID: UUID, using access: VaultAccess) async throws -> AutofillCandidates {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        let candidates = AutofillCandidates(
            vaultID: vaultID, revision: snapshot.revision, candidates: snapshot.accounts.map(AutofillCandidate.init)
        )
        _ = try authorizedGrant(vaultID, access)
        return candidates
    }

    /// The picked credential's candidate and `field`'s secret only: its password, or the source of its code. A credential that is no
    /// longer there, or any write since `expectedRevision` (the revision its list was read at), is `staleRevision`.
    public func autofillLogin(
        vaultID: UUID, accountID: UUID, field: AutofillLoginField, expectedRevision: UInt64, using access: VaultAccess
    ) async throws -> AutofillLogin {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        guard snapshot.revision == expectedRevision, let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
            throw CredentialVaultError.staleRevision
        }
        let login = AutofillLogin(account, field: field)
        _ = try authorizedGrant(vaultID, access)
        return login
    }

    /// The cards or contacts of an unlocked vault as rows (`AutofillItemRows`): a card's network, last four digits, name and expiry,
    /// a contact's title and detail, and no other value or kind of item. The type holds rows only, so no value can reach a list.
    public func autofillItems(vaultID: UUID, kind: AutofillItemKind, using access: VaultAccess) async throws -> AutofillItemRows {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        let now = wall()
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
        let rows = AutofillItemRows(vaultID: vaultID, revision: snapshot.revision, cards: cards, contacts: contacts)
        _ = try authorizedGrant(vaultID, access)
        return rows
    }

    /// One row a list showed, named by its credential and item and the revision its list was read at, with that row's values
    /// (`AutofillItemPick`): the one card or the contact, and nothing else. A row that is no longer there (a card that has expired
    /// since included), or any write since `expectedRevision`, is `staleRevision`.
    public func autofillItems(
        vaultID: UUID, kind: AutofillItemKind, accountID: UUID, item: Int, expectedRevision: UInt64, using access: VaultAccess
    ) async throws -> AutofillItemPick {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        let now = wall()
        guard snapshot.revision == expectedRevision, let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
            throw CredentialVaultError.staleRevision
        }
        let picked: AutofillItemPick
        switch kind {
        case .cards:
            guard let card = Self.cardRows(of: account, now: now).first(where: { $0.row.item == item }) else {
                throw CredentialVaultError.staleRevision
            }
            picked = .card(card.row, card.values)
        case .contacts:
            guard let contact = Self.contactRow(of: account), contact.row.item == item else { throw CredentialVaultError.staleRevision }
            picked = .contact(contact.row, contact.values)
        }
        _ = try authorizedGrant(vaultID, access)
        return picked
    }

    /// Every card of `account` that can fill at `now`: a number that passes the card check, not expired. Internal, not private, so
    /// the projection's performance case times this code and not a copy of it.
    nonisolated static func cardRows(of account: CredentialAccount, now: Date) -> [(row: AutofillCardRow, values: AutofillCardValues)] {
        (account.secureItems ?? []).enumerated().compactMap { index, item in
            guard let card = AutofillCardValues(item), !card.isExpired(on: now) else { return nil }
            return (AutofillCardRow(accountID: account.id, item: index, card), card)
        }
    }

    /// The contact `account` holds, if any, at the position of its first contact item. Internal for the same reason.
    nonisolated static func contactRow(of account: CredentialAccount) -> (row: AutofillContactRow, values: AutofillContactValues)? {
        guard let index = account.secureItems?.firstIndex(where: AutofillContactValues.isContactItem),
              let contact = AutofillContactValues(of: account) else { return nil }
        return (AutofillContactRow(accountID: account.id, item: index, contact), contact)
    }
}
