// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Undo (spec §11.3b): puts back the state an earlier action of the Credentials page changed, as one ordinary commit with the cause
/// `undo`. Nothing in history is rewritten; a value the undo supersedes becomes a revision like any other.
extension ProfileVaultStore {
    /// One transaction, so a crash or a refusal leaves everything as it was:
    /// - `writes` put accounts back as they were. Each is bound to the stamp the page read after the action, so an account that
    ///   changed since is `staleRevision`.
    /// - `returning` names what the action moved to the Trash. The newest matching entry comes back, with its complete history, under
    ///   the identity rules of `block(_:among:forUndo:)`. A part that comes back is taken out of the written account first, so it exists
    ///   once.
    /// - `removing` moves accounts the action added or restored back to the Trash, each bound to its stamp.
    /// Merging the pieces of `CredentialDiff.plan` is what makes undoing a merge return the absorbed items and the survivor together.
    func undo(
        vaultID: UUID, writes: [AccountWrite], returning: [RemovalScope], removing: [UUID: AccountStamp], using access: VaultAccess
    ) async throws -> VaultCommitReceipt {
        guard !writes.isEmpty || !returning.isEmpty || !removing.isEmpty else { throw CredentialStoreError.malformed }
        var written = Set<UUID>(minimumCapacity: writes.count)
        for write in writes {
            guard written.insert(write.accountID).inserted, write.replacement.id == write.accountID, removing[write.accountID] == nil else {
                throw CredentialStoreError.malformed
            }
        }
        // An account that comes back from the Trash is not also moved to it in the same write.
        for case .account(let id) in returning where removing[id] != nil {
            throw CredentialStoreError.malformed
        }
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: nil, cause: CredentialChangeCause.undo, isCommit: true)
        // The scratch is attached up front: the undo may move accounts to the Trash and back, and nothing is ever retried.
        return try await run(intent, ledgerOnDemand: false) { db, request, _ in
            let (transaction, snapshot) = try Self.begin(db, request)
            try transaction.verifyHistories()
            return try Self.undoing(transaction, snapshot: snapshot, writes: writes, returning: returning, removing: removing)
        }.receipt
    }

    nonisolated private static func undoing(
        _ transaction: CommitTransaction, snapshot: StoreSnapshot, writes: [AccountWrite], returning: [RemovalScope],
        removing: [UUID: AccountStamp]
    ) throws -> CommitOutcome {
        var entries: [StoredTrashEntry] = []
        for scope in returning {
            let entry = try transaction.newestTrashEntry(for: scope)
            guard !entries.contains(where: { $0.row.recordID == entry.row.recordID }) else { throw CredentialVaultError.invalidData }
            entries.append(entry)
        }
        let emptied = try writes.map { write -> AccountWrite in
            let parts = entries.filter { $0.body.scope == .credential && $0.body.ownerID == write.accountID }.map(\.body)
            guard !parts.isEmpty else { return write }
            let current = snapshot.accounts.first { $0.id == write.accountID }
            let replacement = try Self.emptying(write.replacement, of: parts, current: current)
            return AccountWrite(accountID: write.accountID, expected: write.expected, replacement: replacement)
        }
        var accounts = try Self.candidates(applying: emptied, removing: removing, to: snapshot)
        let wholeAccounts = entries.compactMap { $0.body.scope == .account ? $0.body.snapshot : nil }
        let plan = try CredentialDiff.plan(old: snapshot.accounts, new: accounts, returning: wholeAccounts)
        let writesSomething = plan.persistence != .noop && !(plan.touched.isEmpty && plan.removals.isEmpty)
        guard writesSomething || !entries.isEmpty else {
            return CommitOutcome(receipt: VaultCommitReceipt(revision: transaction.opened.head.revision), entry: nil, trashEntry: nil)
        }
        if writesSomething {
            try transaction.write(plan, proposed: accounts, cause: CredentialChangeCause.undo)
        }
        for entry in entries {
            if let block = try Self.block(entry.body, among: accounts, forUndo: true) {
                throw CredentialStoreError.undeleteBlocked(block)
            }
            let restored = try Self.restoring(entry.body, into: accounts)
            accounts = restored.accounts
            try transaction.restore(entry, account: restored.account, stampsModifiedAt: entry.body.scope == .credential)
        }
        try Self.validate(accounts, blockedOrigins: transaction.opened.head.blockedOrigins)
        return try transaction.finish()
    }

    /// `account` without the credentials `bodies` put back, so the slot is free when the Trash entry returns. A password that
    /// leaves keeps the username the vault holds now when it is the one that returns, so an unchanged username is not a change.
    nonisolated private static func emptying(
        _ account: CredentialAccount, of bodies: [TrashEntryBody], current: CredentialAccount?
    ) throws -> CredentialAccount {
        var result = account
        for body in bodies {
            guard let subject = body.subject, let value = body.credentialValue else { throw CredentialStoreError.malformed }
            switch subject {
            case .password:
                let login = try Self.decode(PasswordValue.self, from: value)
                result.password = nil
                result.basicAuthenticationMetadata = nil
                result.username = current?.username == login.username ? login.username : ""
            case .totp:
                result.totp = nil
            case .note:
                result.notes = nil
            case .passkey:
                let passkey = try Self.decode(WebsitePasskey.self, from: value)
                result.passkeys.removeAll { $0.id == passkey.id }
            case .account, .metadata:
                throw CredentialStoreError.malformed
            }
        }
        return result
    }
}

nonisolated extension CommitTransaction {
    /// The newest Trash entry that holds what `scope` removed: a whole account, or one password, code, notes or passkey of an
    /// owner. `invalidData` when there is none (it was purged or restored by hand), with nothing written. Runs after `verifyHistories`.
    func newestTrashEntry(for scope: RemovalScope) throws -> StoredTrashEntry {
        guard let trash else { throw integrity }
        let (ownerID, subject, passkeyID): (UUID, RecordSubject, UUID?) = switch scope {
        case .account(let id):
            (id, .account, nil)
        case .credential(let owner, let kind, let passkey):
            (owner, kind, passkey)
        }
        let candidates = try mapIntegrity(grant.ordinal) {
            try StoreTables.trashEntryIDs(db, vaultID: trash.side.vaultID, ownerID: ownerID, subject: subject)
        }
        for id in candidates {
            let entry = try trashEntry(id)
            if passkeyID == nil || entry.body.passkeyID == passkeyID {
                return entry
            }
        }
        throw CredentialVaultError.invalidData
    }
}
