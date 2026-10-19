// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a write requires of one account when the transaction opens: the stamp it was bound to, or that the id is not live.
nonisolated enum AccountExpectation: Equatable, Sendable {
    case stamp(AccountStamp)
    case absent
}

/// One touched account of a per-account write. `replacement.id == accountID`.
nonisolated struct AccountWrite: Sendable {
    let accountID: UUID
    let expected: AccountExpectation
    let replacement: CredentialAccount
}

extension ProfileVaultStore {
    /// Spec §13.5: writes only the touched accounts, in one `BEGIN IMMEDIATE` transaction and one attempt, with no caller-supplied
    /// vault revision. Each write's stamp (or absence) is checked against the live rows inside the transaction (`staleRevision`,
    /// nothing written); an unrelated concurrent write therefore survives. The complete candidate payload (current live accounts with
    /// the touched ids replaced or added, plus the current head's blocked origins) is validated before any write, and an exchange
    /// item identity (`exchangeAccountID` + `exchangeItemID`, as the codec derives it) that two accounts would share is
    /// `duplicateIdentifier`. Untouched rows and the head's policy are never rewritten; an all-unchanged write changes nothing.
    ///
    /// `removing` names live accounts to move to Trash in the same transaction, each bound to the stamp the caller read: the whole
    /// account goes with its earlier versions, as an ordinary delete does, and a stamp that no longer holds is `staleRevision` with
    /// nothing written. An account is either written or removed, never both.
    func commitAccounts(
        vaultID: UUID, _ writes: [AccountWrite], removing: [UUID: AccountStamp] = [:], cause: String?, using access: VaultAccess
    ) async throws -> VaultCommitReceipt {
        guard !writes.isEmpty || !removing.isEmpty else { throw CredentialStoreError.malformed }
        var ids = Set<UUID>(minimumCapacity: writes.count)
        for write in writes {
            guard ids.insert(write.accountID).inserted, write.replacement.id == write.accountID, removing[write.accountID] == nil else {
                throw CredentialStoreError.malformed
            }
        }
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: nil, cause: cause, isCommit: true)
        // The scratch is attached up front (`ledgerOnDemand: false`): a removal inside a write verifies in this one transaction and
        // nothing is ever retried.
        return try await run(intent, ledgerOnDemand: false) { db, request, ledgerAttached in
            let (transaction, snapshot) = try Self.begin(db, request)
            let accounts = try Self.candidates(applying: writes, removing: removing, to: snapshot)
            return try Self.apply(
                Proposal(accounts: accounts, requires: nil), snapshot: snapshot, transaction, request, ledgerAttached: ledgerAttached
            )
        }.receipt
    }

    /// The accounts the write would leave live. Throws `staleRevision` for any write or removal whose expectation no longer holds
    /// and `duplicateIdentifier` for two accounts with one exchange item identity. A removed account is left out of the result,
    /// which `CredentialDiff` turns into a move of the whole account to Trash.
    nonisolated static func candidates(
        applying writes: [AccountWrite], removing: [UUID: AccountStamp] = [:], to snapshot: StoreSnapshot
    ) throws -> [CredentialAccount] {
        for (id, stamp) in removing {
            guard snapshot.stamps[id] == stamp else { throw CredentialVaultError.staleRevision }
        }
        var replacements: [UUID: CredentialAccount] = [:]
        replacements.reserveCapacity(writes.count)
        for write in writes {
            let current = snapshot.stamps[write.accountID]
            switch write.expected {
            case .stamp(let stamp):
                guard current == stamp else { throw CredentialVaultError.staleRevision }
            case .absent:
                guard current == nil else { throw CredentialVaultError.staleRevision }
            }
            replacements[write.accountID] = write.replacement
        }
        var accounts: [CredentialAccount] = []
        accounts.reserveCapacity(snapshot.accounts.count + writes.count)
        var identities = Set<CredentialExchangeCodec.ExternalItemID>(minimumCapacity: snapshot.accounts.count + writes.count)
        for account in snapshot.accounts where removing[account.id] == nil {
            accounts.append(replacements[account.id] ?? account)
        }
        for write in writes where write.expected == .absent {
            accounts.append(write.replacement)
        }
        for account in accounts {
            guard identities.insert(try CredentialExchangeCodec.externalItemID(for: account)).inserted else {
                throw CredentialVaultError.duplicateIdentifier
            }
        }
        return accounts
    }
}
