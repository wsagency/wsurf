// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

/// The authenticated state of one vault inside a write transaction: the registry as it is now, this vault's and its Trash's registry
/// entries (both still the ones the session verified), the stored vault row, the opened head and the wrapper list.
nonisolated struct OpenedVault {
    let catalog: RegistryCatalog
    let entry: RegistryEntry
    let trashEntry: RegistryEntry
    let row: StoreTables.VaultRow
    let head: VaultHead
    let wrappers: [CredentialKeyWrapper]
}

/// What the caller asked for, independent of the store's state.
nonisolated struct CommitIntent {
    let vaultID: UUID
    let access: VaultAccess
    /// `nil` skips the compare-and-set (purge has no revision argument; it still opens against the entries the session verified).
    let expectedRevision: UInt64?
    let cause: String?
    /// `commit` validates the proposed accounts and enforces the live caps; `delete` never does, so a delete always works.
    let isCommit: Bool
}

nonisolated struct CommitRequest {
    let grant: VaultGrant
    let intent: CommitIntent
    let now: @Sendable () -> ContinuousClock.Instant
    let wall: Date
}

/// The accounts a write would leave live, and (for a delete) the removal the plan has to contain.
nonisolated struct Proposal {
    let accounts: [CredentialAccount]
    let requires: RemovalScope?
    /// The account an explicit earlier-revision restore applies to: its changes are revisions, never removals (see `CredentialDiff.plan`).
    var restoring: UUID?
}

/// `entry == nil` means nothing was written (a true no-op).
nonisolated struct CommitOutcome {
    let receipt: VaultCommitReceipt
    let entry: RegistryEntry?
    let trashEntry: RegistryEntry?
}

/// A plan with a removal reached `transact` on a connection without the verification scratch. Thrown before anything is written, so
/// the transaction rolls back untouched and `perform` runs it again with the scratch attached.
private nonisolated struct LedgerRequired: Error {}

/// Spec §7 atomic commit: one `BEGIN IMMEDIATE` transaction per logical operation on the pool's writer (inside the operation lock,
/// spec §15): CAS this vault's head revision, re-read and authenticate the registry, write rows, append journal rows, seal both
/// heads, rewrite the registry. `CommitTransaction.write` is the one internal write contract (`commit`, `delete`, and later the
/// per-account and restore paths all route through it).
extension ProfileVaultStore {
    func commit(
        vaultID: UUID, _ accounts: [CredentialAccount], expectedRevision: UInt64, cause: String?, using access: VaultAccess
    ) async throws -> VaultCommitReceipt {
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: expectedRevision, cause: cause, isCommit: true)
        return try await perform(intent) { _ in Proposal(accounts: accounts, requires: nil) }
    }

    func delete(vaultID: UUID, scope: RemovalScope, expectedRevision: UInt64, using access: VaultAccess) async throws -> VaultCommitReceipt {
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: expectedRevision, cause: nil, isCommit: false)
        return try await perform(intent) { old in try Self.removing(scope, from: old) }
    }

    private func perform(_ intent: CommitIntent, derive: ([CredentialAccount]) throws -> Proposal) async throws -> VaultCommitReceipt {
        try await run(intent, ledgerOnDemand: intent.isCommit) { db, request, ledgerAttached in
            try Self.transact(db, request, derive: derive, ledgerAttached: ledgerAttached)
        }.receipt
    }

    /// The one write runner: authorize, take the operation lock, run `step` in one `BEGIN IMMEDIATE` transaction on the pool's writer,
    /// publish the new registry entries to the grant. A removal needs the verification scratch attached to the connection before
    /// `BEGIN IMMEDIATE` (a transaction cannot attach), so `ledgerOnDemand == false` always starts with it; `true` learns it from the
    /// plan, which writes nothing before that, and runs again with the scratch attached. A scratch cleanup failure never changes the
    /// outcome (the next EXCLUSIVE unlock finds and reports the file); `scratchNeedsExclusive` already keeps a live scratch away from
    /// other processes' cleanup. `checkpoint` is the best-effort `wal_checkpoint(TRUNCATE)` of a purge.
    func run(
        _ intent: CommitIntent, ledgerOnDemand: Bool, checkpoint: Bool = false,
        _ step: (Database, CommitRequest, Bool) throws -> CommitOutcome
    ) async throws -> CommitOutcome {
        _ = try authorizedGrant(intent.vaultID, intent.access)
        let clock = now
        let wallClock = wall
        let outcome = try await withOperation { pool -> CommitOutcome in
            let grant = try authorizedGrant(intent.vaultID, intent.access)  // re-checked after the lock wait
            let request = CommitRequest(grant: grant, intent: intent, now: clock, wall: wallClock())
            func write(_ db: Database, ledgerAttached: Bool) throws -> CommitOutcome? {
                var committed: CommitOutcome?
                try db.inTransaction(.immediate) {
                    let outcome = try step(db, request, ledgerAttached)
                    committed = outcome
                    return outcome.entry == nil ? .rollback : .commit
                }
                return committed
            }
            func withLedger() throws -> CommitOutcome? {
                try VerificationScratch.attached(on: pool, supportDirectory: directory, cleanupFailed: { _ in }) {
                    try write($0, ledgerAttached: true)
                }
            }
            var committed: CommitOutcome?
            if ledgerOnDemand {
                do {
                    committed = try pool.writeWithoutTransaction { try write($0, ledgerAttached: false) }
                } catch is LedgerRequired {
                    committed = try withLedger()
                }
            } else {
                committed = try withLedger()
            }
            guard let committed else { throw CredentialStoreError.integrityFailure(vaultOrdinal: grant.ordinal) }
            if checkpoint, committed.entry != nil {
                try? pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            }
            return committed
        }
        if let entry = outcome.entry, grants[intent.vaultID]?.access === intent.access {
            grants[intent.vaultID]?.entry = entry
            if let trashEntry = outcome.trashEntry {
                grants[intent.vaultID]?.trashEntry = trashEntry
            }
        }
        return outcome
    }

    /// Everything inside the write transaction, in the order of §7: authenticate, CAS, read the live rows, plan, (a removal) verify the
    /// source history against its journal, write, seal. `ledgerAttached` says the verification scratch is attached to `db`; a plan
    /// with a removal and no scratch throws `LedgerRequired` before anything is written.
    nonisolated static func transact(
        _ db: Database, _ request: CommitRequest, derive: ([CredentialAccount]) throws -> Proposal, ledgerAttached: Bool
    ) throws -> CommitOutcome {
        let (transaction, snapshot) = try begin(db, request)
        return try apply(try derive(snapshot.accounts), snapshot: snapshot, transaction, request, ledgerAttached: ledgerAttached)
    }

    /// Authenticate, CAS, read the live rows. Nothing is written.
    nonisolated static func begin(_ db: Database, _ request: CommitRequest) throws -> (CommitTransaction, StoreSnapshot) {
        let intent = request.intent
        let opened = try openVault(db, grant: request.grant, vaultID: intent.vaultID, access: intent.access, now: request.now)
        if let expected = intent.expectedRevision, expected != opened.head.revision {
            throw CredentialVaultError.staleRevision
        }
        guard opened.head.revision < UInt64(Int64.max), opened.catalog.revision < UInt64(Int64.max) else { throw CredentialVaultError.invalidData }
        let snapshot = try readSnapshot(db, grant: request.grant, vaultID: intent.vaultID)
        return (CommitTransaction(db, request: request, opened: opened, snapshot: snapshot), snapshot)
    }

    /// Plan, (a removal) verify both histories, write, seal. A caller that already ran `verifyHistories` is not charged twice.
    nonisolated static func apply(
        _ proposal: Proposal, snapshot: StoreSnapshot, _ transaction: CommitTransaction, _ request: CommitRequest, ledgerAttached: Bool
    ) throws -> CommitOutcome {
        let intent = request.intent
        if intent.isCommit {
            try validate(proposal.accounts, blockedOrigins: transaction.opened.head.blockedOrigins)
        }
        // §11.1: the plan is classified on the complete payload bytes, never on `==`.
        let plan = try CredentialDiff.plan(old: snapshot.accounts, new: proposal.accounts, restoring: proposal.restoring)
        if let required = proposal.requires {
            guard plan.removals.contains(required) else { throw CredentialVaultError.invalidData }
        }
        guard plan.persistence != .noop, !plan.touched.isEmpty || !plan.removals.isEmpty else {
            return CommitOutcome(receipt: VaultCommitReceipt(revision: transaction.opened.head.revision), entry: nil, trashEntry: nil)
        }
        if !plan.removals.isEmpty, transaction.trash == nil {
            // Once, before this transaction's first write: the rows a MOVE selects and journals on either side must be the ones the
            // authenticated heads' journals replay to. Errors map as everywhere else: a full disk or a busy database stays operational,
            // a decode, crypto or ledger mismatch is an integrity failure.
            guard ledgerAttached else { throw LedgerRequired() }
            try transaction.verifyHistories()
        }
        try transaction.write(plan, proposed: proposal.accounts, cause: intent.cause)
        return try transaction.finish()
    }

    /// The v1 payload rules at the boundary: distinct ids, `CredentialAccount.validate()`, the live byte budget (blocked origins
    /// included). A live limit names itself.
    nonisolated static func validate(_ accounts: [CredentialAccount], blockedOrigins: [String]) throws {
        do {
            try CredentialVaultCrypto.validate(CredentialVaultPayload(revision: 0, accounts: accounts, blockedPasswordOrigins: Set(blockedOrigins)))
        } catch CredentialVaultError.oversized {
            throw CredentialStoreError.limit(accounts.count > CredentialVaultLimits.accounts ? .accounts : .payloadBytes)
        }
    }

    /// The accounts a delete leaves live. A credential whose removal leaves nothing valid (`A:43`) takes the whole-account path.
    nonisolated static func removing(_ scope: RemovalScope, from old: [CredentialAccount]) throws -> Proposal {
        switch scope {
        case .account(let id):
            guard old.contains(where: { $0.id == id }) else { throw CredentialVaultError.invalidData }
            return Proposal(accounts: old.filter { $0.id != id }, requires: .account(id))
        case .credential(let ownerID, let subject, let passkeyID):
            guard let index = old.firstIndex(where: { $0.id == ownerID }) else { throw CredentialVaultError.invalidData }
            var account = old[index]
            var required = RemovalScope.credential(ownerID: ownerID, subject: subject, passkeyID: nil)
            switch subject {
            case .password:
                guard account.password != nil else { throw CredentialVaultError.invalidData }
                account.username = ""
                account.password = nil
                account.basicAuthenticationMetadata = nil
            case .totp:
                guard account.totp != nil else { throw CredentialVaultError.invalidData }
                account.totp = nil
            case .note:
                guard account.notes != nil else { throw CredentialVaultError.invalidData }
                account.notes = nil
            case .passkey:
                guard let passkeyID, account.passkeys.contains(where: { $0.id == passkeyID }) else { throw CredentialVaultError.invalidData }
                account.passkeys.removeAll { $0.id == passkeyID }
                required = .credential(ownerID: ownerID, subject: .passkey, passkeyID: passkeyID)
            case .account, .metadata:
                throw CredentialVaultError.invalidData
            }
            if account.username.isEmpty, account.password == nil, account.passkeys.isEmpty, account.totp == nil, account.notes == nil {
                return Proposal(accounts: old.filter { $0.id != ownerID }, requires: .account(ownerID))
            }
            var accounts = old
            accounts[index] = account
            return Proposal(accounts: accounts, requires: required)
        }
    }

    // MARK: Shared preamble

    /// Authenticates the registry, checks it still holds the entries this session verified for the vault and its Trash (else
    /// `staleRevision`), checks the stored vault row and head against this vault's entry, and opens the head and wrapper list.
    nonisolated static func openVault(
        _ db: Database, grant: VaultGrant, vaultID: UUID, access: VaultAccess, now: @Sendable () -> ContinuousClock.Instant
    ) throws -> OpenedVault {
        try access.checkAuthorization(at: now())
        let ordinal = grant.ordinal
        let integrity = CredentialStoreError.integrityFailure(vaultOrdinal: ordinal)

        // The registry as it is now: authenticated, and still the entries this session verified.
        let catalog = try mapIntegrity(nil) { () throws -> RegistryCatalog in
            guard let stored = try StoreTables.registry(db), StoreSeal.verifyRegistryMAC(rk: grant.registryKey, catalog: stored.catalog, mac: stored.mac) else {
                throw CredentialStoreError.malformed
            }
            let catalog = try RegistryCatalog.decode(stored.catalog)
            guard catalog.ids == grant.ids, catalog.revision == stored.revision else { throw CredentialStoreError.malformed }
            return catalog
        }
        guard let entry = catalog.vaults.first(where: { $0.vaultID == vaultID }),
            let trashEntry = catalog.vaults.first(where: { $0.vaultID == grant.trashID })
        else { throw integrity }
        guard entry == grant.entry, trashEntry == grant.trashEntry else { throw CredentialVaultError.staleRevision }

        // The stored vault and head are what that entry says; then the head opens under the session's key.
        let row = try activeRow(vaultID, in: db)
        guard let storedHead = try mapIntegrity(ordinal, { try StoreTables.head(db, vaultID: vaultID) }),
            StoreSeal.digestOrZero(row.wrappers) == entry.wrappersDigest, StoreSeal.digestOrZero(row.keyWrap) == entry.keyWrapDigest,
            storedHead.revision == entry.headRevision, StoreSeal.digest(storedHead.sealed) == entry.headDigest
        else { throw integrity }
        let (head, wrappers) = try mapIntegrity(ordinal) { () throws -> (VaultHead, [CredentialKeyWrapper]) in
            let head = try StoreSeal.openHead(
                storedHead.sealed, key: grant.dek, ids: grant.ids, vaultID: vaultID, revision: storedHead.revision,
                wrappersDigest: entry.wrappersDigest, keyWrapDigest: entry.keyWrapDigest
            )
            return (head, try VaultWrapperList.decode(row.wrappers))
        }
        return OpenedVault(catalog: catalog, entry: entry, trashEntry: trashEntry, row: row, head: head, wrappers: wrappers)
    }

    /// Rewrites the registry row with `entries` replacing the catalog's entries of the same vault ids; revision + 1, MAC under RK.
    nonisolated static func storeRegistry(_ db: Database, grant: VaultGrant, catalog: RegistryCatalog, replacing entries: [RegistryEntry]) throws {
        var next = catalog
        next.revision += 1
        next.vaults = catalog.vaults.map { old in entries.first { $0.vaultID == old.vaultID } ?? old }
        let encoded = next.encode()
        try StoreTables.putRegistry(
            db, revision: next.revision, catalog: encoded, mac: StoreSeal.registryMAC(rk: grant.registryKey, catalog: encoded)
        )
    }
}

/// The linked Trash as a MOVE needs it: its opened head and its journal and counters.
nonisolated struct TrashState {
    var head: VaultHead
    var side: WriteSide
}

/// One transaction's mutable state: the live rows, this vault's journal and counters, and (once a MOVE needs it) the Trash side.
/// A class on purpose: `write`, the MOVE and `finish` mutate disjoint parts of it and nothing else holds a reference.
nonisolated final class CommitTransaction {
    let db: Database
    let grant: VaultGrant
    let opened: OpenedVault
    let wall: Date
    var source: WriteSide
    var trash: TrashState?
    var live: [UUID: LiveEntry] = [:]
    /// The accounts as stored when the transaction began (a MOVE copies the removed value from here).
    let previous: [UUID: CredentialAccount]

    var ids: StoreIDs {
        grant.ids
    }

    var integrity: CredentialStoreError {
        .integrityFailure(vaultOrdinal: grant.ordinal)
    }

    init(_ db: Database, request: CommitRequest, opened: OpenedVault, snapshot: StoreSnapshot) {
        self.db = db
        self.grant = request.grant
        self.opened = opened
        self.wall = request.wall
        self.trash = nil
        self.source = WriteSide(
            vaultID: opened.head.vaultID, key: request.grant.dek, journalSeq: opened.head.journalSeq, chainTip: opened.head.chainTip,
            counts: opened.head.historyCounts
        )
        var previous: [UUID: CredentialAccount] = [:]
        for account in snapshot.accounts {
            previous[account.id] = account
            if let stamp = snapshot.stamps[account.id] {
                live[account.id] = LiveEntry(recordID: account.id, version: stamp.version, digest: stamp.digest)
            }
        }
        self.previous = previous
    }

    /// §7/§11 write of one plan: the touched live rows, a revision row per superseded value, one MOVE per removal. No heads and no
    /// registry yet (`finish`). `proposed` carries the new content of every touched account.
    func write(_ plan: CredentialChangePlan, proposed: [CredentialAccount], cause: String?) throws {
        for account in proposed where plan.touched.contains(account.id) {
            try putLive(account, stampsModifiedAt: plan.setsModifiedAt.contains(account.id))
        }
        try writeRevisions(plan.revisions, cause: cause)
        for scope in plan.removals {
            try move(scope)
        }
    }

    func putLive(_ proposed: CredentialAccount, stampsModifiedAt: Bool) throws {
        var account = proposed
        if stampsModifiedAt {
            account.modifiedAt = wall
        }
        let plaintext = try CredentialContent.canonicalJSON(account)
        let version = (live[account.id]?.version ?? 0) + 1
        let aad = RowAAD(
            ids: ids, vaultID: source.vaultID, recordID: account.id, kind: .account, ownerID: account.id, subject: .account, version: version
        )
        let sealed = try StoreSeal.sealRow(plaintext, key: source.key, aad: aad)
        try StoreTables.putRecord(db, StoreTables.RecordRow(aad, sealed: sealed))
        live[account.id] = LiveEntry(recordID: account.id, version: version, digest: StoreSeal.digest(sealed))
    }

    private func writeRevisions(_ drafts: [RevisionDraft], cause: String?) throws {
        var group = JournalGroup(transfer: nil)
        for draft in drafts {
            try Task.checkCancellation()
            let plaintext = try CredentialContent.canonicalJSON(RevisionBody(recordedAt: wall, cause: cause, value: draft.superseded))
            let aad = RowAAD(
                ids: ids, vaultID: source.vaultID, recordID: UUID(), kind: .revision, ownerID: draft.ownerID, subject: draft.subject, version: 1
            )
            let op = try insertHistory(plaintext, aad: aad, key: source.key)
            source.counts.revision += 1
            try group.add(op, to: &source, db: db, ids: ids)
        }
        try group.finish(&source, db: db, ids: ids)
    }

    /// Seals and stores one new history row (never a moved one: a MOVE keeps whatever size the row has); returns its `add` op.
    func insertHistory(_ plaintext: Data, aad: RowAAD, key: SymmetricKey) throws -> JournalOp {
        guard plaintext.count <= StoreFormat.historyRowBytes else { throw CredentialStoreError.limit(.historyRow) }
        return try putSealed(plaintext, aad: aad, key: key)
    }

    func putSealed(_ plaintext: Data, aad: RowAAD, key: SymmetricKey) throws -> JournalOp {
        let sealed = try StoreSeal.sealRow(plaintext, key: key, aad: aad)
        try StoreTables.putRecord(db, StoreTables.RecordRow(aad, sealed: sealed))
        return JournalOp(aad, op: .add, rowDigest: StoreSeal.digest(sealed))
    }

    /// Seals both heads (revision + 1, the live catalog, journal tip and history counts) and rewrites the registry.
    func finish() throws -> CommitOutcome {
        try Task.checkCancellation()  // last poll before the heads and registry are sealed: a cancel during the final row still rolls back
        // A head seals counts it carried forward or adjusted, never the table. A history row deleted or reparented after unlock is
        // invisible to every scan of its vault, so the stored rows must still add up to the counts about to be sealed: else the
        // write would commit a store whose next unlock fails. COUNT(*) only; no row is opened.
        try reconcileHistory(source)
        if let trash {
            try reconcileHistory(trash.side)
        }
        var next = opened.head
        next.revision += 1
        next.liveCatalog = live.values.sorted { $0.recordID.uuidString < $1.recordID.uuidString }
        next.journalSeq = source.journalSeq
        next.chainTip = source.chainTip
        next.historyCounts = source.counts
        let sealed = try StoreSeal.sealHead(
            next, key: grant.dek, wrappersDigest: opened.entry.wrappersDigest, keyWrapDigest: opened.entry.keyWrapDigest
        )
        try StoreTables.putHead(db, vaultID: next.vaultID, revision: next.revision, sealed: sealed)
        var entry = opened.entry
        entry.headRevision = next.revision
        entry.headDigest = StoreSeal.digest(sealed)

        var entries = [entry]
        var trashEntry: RegistryEntry?
        if let trash {
            var head = trash.head
            head.revision += 1
            head.journalSeq = trash.side.journalSeq
            head.chainTip = trash.side.chainTip
            head.historyCounts = trash.side.counts
            let sealedTrash = try StoreSeal.sealHead(
                head, key: trash.side.key, wrappersDigest: opened.trashEntry.wrappersDigest, keyWrapDigest: opened.trashEntry.keyWrapDigest
            )
            try StoreTables.putHead(db, vaultID: head.vaultID, revision: head.revision, sealed: sealedTrash)
            var moved = opened.trashEntry
            moved.headRevision = head.revision
            moved.headDigest = StoreSeal.digest(sealedTrash)
            trashEntry = moved
            entries.append(moved)
        }
        try ProfileVaultStore.storeRegistry(db, grant: grant, catalog: opened.catalog, replacing: entries)
        return CommitOutcome(receipt: VaultCommitReceipt(revision: next.revision), entry: entry, trashEntry: trashEntry)
    }

    private func reconcileHistory(_ side: WriteSide) throws {
        guard try side.counts.matchesRows(db, vaultID: side.vaultID, ordinal: grant.ordinal) else { throw integrity }
    }
}

nonisolated extension StoreTables.RecordRow {
    /// The row a sealed value is stored as: every plaintext column is the AAD field it was sealed under.
    init(_ aad: RowAAD, sealed: Data) {
        self.init(
            vaultID: aad.vaultID, recordID: aad.recordID, kind: aad.kind, ownerID: aad.ownerID, subject: aad.subject, version: aad.version,
            sealed: sealed
        )
    }
}
