// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// What a write requires of one account when the transaction opens: the stamp it was bound to, or that the id is not live.
public nonisolated enum AccountExpectation: Equatable, Sendable {
    case stamp(AccountStamp)
    case absent
}

/// One touched account of a per-account write. `replacement.id == accountID`.
public nonisolated struct AccountWrite: Sendable {
    let accountID: UUID
    let expected: AccountExpectation
    let replacement: CredentialAccount

    public init(accountID: UUID, expected: AccountExpectation, replacement: CredentialAccount) {
        self.accountID = accountID
        self.expected = expected
        self.replacement = replacement
    }
}

extension ProfileVaultStore {
    /// Writes only the touched accounts in one transaction. Each write's stamp (or absence) is checked against the live rows
    /// inside the transaction. A cross-vault review additionally binds the whole destination revision and the source lease because
    /// a newly added entry can change which source entry is a duplicate. The complete candidate payload (current live accounts with
    /// the touched ids replaced or added, plus the current head's blocked origins) is validated before any write, and an exchange
    /// item identity (`exchangeAccountID` + `exchangeItemID`, as the codec derives it) that two accounts would share is
    /// `duplicateIdentifier`. Untouched rows and the head's policy are never rewritten; an all-unchanged write changes nothing.
    ///
    /// `removing` names live accounts to move to Trash in the same transaction, each bound to the stamp the caller read: the whole
    /// account goes with its earlier versions, as an ordinary delete does, and a stamp that no longer holds is `staleRevision` with
    /// nothing written. An account is either written or removed, never both.
    public func commitAccounts(
        vaultID: UUID, _ writes: [AccountWrite], removing: [UUID: AccountStamp] = [:], cause: String?, using access: VaultAccess,
        expectedRevision: UInt64? = nil, validateMerge: (@Sendable (ContinuousClock.Instant) throws -> Void)? = nil
    ) async throws -> VaultCommitReceipt {
        guard !writes.isEmpty || !removing.isEmpty else { throw CredentialStoreError.malformed }
        var ids = Set<UUID>(minimumCapacity: writes.count)
        for write in writes {
            guard ids.insert(write.accountID).inserted, write.replacement.id == write.accountID, removing[write.accountID] == nil else {
                throw CredentialStoreError.malformed
            }
        }
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: expectedRevision, cause: cause, isCommit: true)
        // The scratch is attached up front (`ledgerOnDemand: false`): a removal inside a write verifies in this one transaction and
        // nothing is ever retried.
        return try await run(intent, ledgerOnDemand: false) { db, request, ledgerAttached in
            let (transaction, snapshot) = try Self.begin(db, request)
            let accounts = try Self.candidates(applying: writes, removing: removing, to: snapshot)
            // Every account but the written ones is the snapshot's own value (`candidates`); a removed one is absent from `accounts`.
            let result = try Self.apply(
                Proposal(accounts: accounts, requires: nil, changing: ids), snapshot: snapshot, transaction, request, ledgerAttached: ledgerAttached
            )
            // A source edit, lock or withdrawal while this writer waited must still roll the entire merge back.
            if let validateMerge {
                let instant = request.now()
                try validateMerge(instant)
                try access.checkAuthorization(at: instant)
                try Task.checkCancellation()
            }
            return result
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
