// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os
import WSurfVault

// Drain (what arrived is merged into the vault through its own commit), produce (what changed here is sealed for the engine) and
// resolve (the person's answer to a review row). All three run on the vault's serial chain and only while it is unlocked, under the
// lease the snapshot was read with. None prompts, and none extends or shortens a lease.

/// What one pass decided: the commit to make, and the rows to change once it is made.
nonisolated struct SyncPass {
    var writes: [AccountWrite] = []
    /// The account of each write, in order (`AccountWrite` does not show it).
    var writeIDs: [UUID] = []
    var removing: [UUID: AccountStamp] = [:]
    /// The base to record per account once its decision is applied.
    var bases: [UUID: SyncBase] = [:]
    var conflicts: [UUID: ConflictRow] = [:]
    /// Accounts decided: their outbox rows are dropped, and a review row they had is replaced or removed.
    var decided: Set<UUID> = []
    /// Inbox rows taken in, deleted by version so a newer row that arrived meanwhile stays.
    var processed: [InboxRow] = []
    /// Review rows answered.
    var answered: Set<UUID> = []
    var envelopes: [UUID: (version: UInt64, envelope: Data)] = [:]
    var unreadable = 0
    /// Accounts whose record came back as the very row this Mac sealed: the send is done, whether or not its `.sent` arrived.
    var own: Set<UUID> = []

    /// The vault cannot take this entry on this Mac: it waits as information, and its base stays.
    mutating func refuse(_ id: UUID) {
        bases[id] = nil
        guard let incoming = envelopes[id] else { return }
        conflicts[id] = ConflictRow(accountID: id, version: incoming.version, kind: .refused, envelope: incoming.envelope)
    }
}

/// How a commit ended.
nonisolated enum SyncCommitOutcome {
    case done(UInt64?)
    /// A stamp no longer holds: read the vault again.
    case stale
    /// The lease ended, or something that a retry would not change.
    case stop
}

extension VaultSync {
    // MARK: - Drain

    func drain(_ key: VaultKey) async {
        var staleRetries = 0
        while true {
            let mine = token(key)
            guard let (database, _) = runningRow(key),
                  let batch = try? database.read({ try $0.inbox(key.vaultID, limit: Self.drainBatch) }), !batch.isEmpty
            else { return }
            guard let syncKey = await host.syncKey(profileID: key.profileID, vaultID: key.vaultID) else {
                locked(key)
                return
            }
            guard let snapshot = await snapshot(key) else { return }
            guard stillOpen(key, mine), let (_, row) = runningRow(key), notRolledBack(key, snapshot, row, database) else { return }
            var pass = SyncPass()
            decide(batch, key: key, snapshot: snapshot, syncKey: syncKey, database: database, into: &pass)
            pass.processed = batch
            switch await commit(&pass, key: key, snapshot: snapshot) {
            case .done(let revision):
                guard mine == token(key), record(pass, key: key, database: database, syncKey: syncKey, revision: max(revision ?? 0, snapshot.revision)) else {
                    return
                }
                staleRetries = 0
            case .stale:
                staleRetries += 1
                guard staleRetries < 3 else { return }
            case .stop:
                return
            }
            await Task.yield()
        }
    }

    /// One decision per inbox row (§4.4), from the vault as `snapshot` shows it.
    private func decide(
        _ batch: [InboxRow], key: VaultKey, snapshot: VaultSyncSnapshot, syncKey: VaultSyncKey, database: VaultSyncDatabase,
        into pass: inout SyncPass
    ) {
        let index = SyncLocalIndex(accounts: snapshot.accounts, removed: snapshot.removed)
        var local: [UUID: CredentialAccount] = [:]
        for account in snapshot.accounts {
            local[account.id] = account
        }
        let rows = (try? database.read { tx in
            try batch.map { (try tx.base(key.vaultID, $0.accountID), try tx.outbox(key.vaultID, $0.accountID)) }
        }) ?? []
        for (position, inbound) in batch.enumerated() {
            let id = inbound.accountID
            pass.envelopes[id] = (inbound.version, inbound.envelope)
            let item: SyncItem
            do {
                item = try VaultSyncCodec.openItem(inbound.envelope, accountID: id, key: syncKey)
            } catch {
                pass.unreadable += 1
                continue
            }
            let (baseRow, outgoing) = position < rows.count ? rows[position] : (nil, nil)
            let base = openBase(baseRow, account: id, key: syncKey)
            if let outgoing, outgoing.version == item.version,
               let own = try? VaultSyncCodec.openParts(outgoing.parts, accountID: id, version: outgoing.version, key: syncKey),
               (try? item.parts()) == own {
                // This Mac's own record, fetched back before its `.sent`: the base is what it sealed, and nothing else changes.
                pass.bases[id] = SyncBase(version: item.version, parts: own)
                pass.decided.insert(id)
                pass.own.insert(id)
                continue
            }
            let decision: SyncDecision
            do {
                decision = try CredentialSyncMerge.decide(item, local: local[id], base: base, index: index)
            } catch {
                pass.conflicts[id] = ConflictRow(accountID: id, version: inbound.version, kind: .refused, envelope: inbound.envelope)
                pass.decided.insert(id)
                continue
            }
            apply(decision, id: id, version: inbound.version, envelope: inbound.envelope, snapshot: snapshot, into: &pass)
        }
    }

    /// Turns a decision into rows and writes. A write or removal needs the stamp it was decided against.
    private func apply(
        _ decision: SyncDecision, id: UUID, version: UInt64, envelope: Data, snapshot: VaultSyncSnapshot, into pass: inout SyncPass
    ) {
        switch decision {
        case .ignore:
            break
        case .keep(let base):
            pass.bases[id] = base
            pass.decided.insert(id)
        case .write(let account, let base):
            pass.decided.insert(id)
            if snapshot.accounts.contains(where: { $0.id == id }) {
                guard let stamp = snapshot.stamps[id] else {
                    pass.conflicts[id] = ConflictRow(accountID: id, version: version, kind: .refused, envelope: envelope)
                    return
                }
                pass.writes.append(AccountWrite(accountID: id, expected: .stamp(stamp), replacement: account))
            } else {
                pass.writes.append(AccountWrite(accountID: id, expected: .absent, replacement: account))
            }
            pass.writeIDs.append(id)
            pass.bases[id] = base
        case .moveToTrash(let base):
            pass.decided.insert(id)
            guard let stamp = snapshot.stamps[id] else {
                pass.conflicts[id] = ConflictRow(accountID: id, version: version, kind: .refused, envelope: envelope)
                return
            }
            pass.removing[id] = stamp
            pass.bases[id] = base
        case .review(let kind, _):
            pass.conflicts[id] = ConflictRow(accountID: id, version: version, kind: kind, envelope: envelope)
            pass.decided.insert(id)
        }
    }

    /// One commit for the pass. A write the vault refuses for its own rules is tried alone and, if it still fails, becomes an
    /// information row; a lease that ended or any other failure stops the pass with nothing recorded as applied.
    private func commit(_ pass: inout SyncPass, key: VaultKey, snapshot: VaultSyncSnapshot) async -> SyncCommitOutcome {
        guard !pass.writes.isEmpty || !pass.removing.isEmpty else { return .done(nil) }
        do {
            return .done(try await host.commit(
                profileID: key.profileID, vaultID: key.vaultID, lease: snapshot.lease, writes: pass.writes, removing: pass.removing
            ))
        } catch {
            switch Self.classify(error) {
            case .stale:
                return .stale
            case .stop:
                return .stop
            case .data:
                break
            }
        }
        var revision: UInt64?
        for (write, id) in zip(pass.writes, pass.writeIDs) {
            do {
                revision = try await host.commit(
                    profileID: key.profileID, vaultID: key.vaultID, lease: snapshot.lease, writes: [write], removing: [:]
                )
            } catch {
                switch Self.classify(error) {
                case .stale:
                    return .stale
                case .stop:
                    return .stop
                case .data:
                    pass.refuse(id)
                }
            }
        }
        for (id, stamp) in pass.removing.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            do {
                revision = try await host.commit(
                    profileID: key.profileID, vaultID: key.vaultID, lease: snapshot.lease, writes: [], removing: [id: stamp]
                )
            } catch {
                switch Self.classify(error) {
                case .stale:
                    return .stale
                case .stop:
                    return .stop
                case .data:
                    pass.refuse(id)
                }
            }
        }
        return .done(revision)
    }

    private enum CommitFailure {
        case stale, stop, data
    }

    private static func classify(_ error: any Error) -> CommitFailure {
        if let error = error as? CredentialVaultError {
            switch error {
            case .staleRevision:
                return .stale
            case .duplicateIdentifier, .invalidData, .oversized:
                return .data
            default:
                return .stop
            }
        }
        if let error = error as? CredentialStoreError {
            switch error {
            case .limit, .malformed:
                return .data
            default:
                return .stop
            }
        }
        return .stop
    }

    /// Records a pass that was committed: the bases, the rows taken in, the review rows. One transaction.
    @discardableResult
    private func record(_ pass: SyncPass, key: VaultKey, database: VaultSyncDatabase, syncKey: VaultSyncKey, revision: UInt64) -> Bool {
        do {
            try database.write { tx in
                guard var current = try tx.vault(key.vaultID), current.enabled else { return }
                for (id, base) in pass.bases.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                    let sealed = try VaultSyncCodec.sealParts(base.parts, accountID: id, version: base.version, key: syncKey)
                    try tx.save(BaseRow(accountID: id, version: base.version, parts: sealed), vault: key.vaultID)
                }
                for inbound in pass.processed {
                    try tx.deleteInbox(key.vaultID, inbound.accountID, upTo: inbound.version)
                }
                for id in pass.decided {
                    try tx.deleteOutbox(key.vaultID, id)
                    if pass.conflicts[id] == nil {
                        try tx.deleteConflict(key.vaultID, id)
                    }
                }
                for id in pass.answered where pass.conflicts[id] == nil {
                    try tx.deleteConflict(key.vaultID, id)
                }
                for id in pass.conflicts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                    if let conflict = pass.conflicts[id] {
                        try tx.save(conflict, vault: key.vaultID)
                    }
                }
                current.lastHeadRevision = max(current.lastHeadRevision, revision)
                try tx.save(current)
            }
        } catch {
            // The vault already holds the result; the rows are decided again, which finds nothing left to change.
            SyncLog.logger.error("sync: a vault sync pass could not be recorded")
            return false
        }
        if baseCache[key] != nil {
            for (id, base) in pass.bases {
                baseCache[key]?[id] = base
            }
        }
        for id in pass.decided {
            pendingBases[key]?[id] = nil
            queued[key]?.remove(id)
        }
        handedOut[key]?.subtract(pass.own)
        if pass.unreadable > 0 {
            tallies[key, default: (0, 0)].unreadable += pass.unreadable
        }
        refresh(key)
        return true
    }

    // MARK: - Produce

    func produce(_ key: VaultKey) async {
        let mine = token(key)
        guard let (database, _) = runningRow(key), !needsFetch(key) else { return }
        guard let syncKey = await host.syncKey(profileID: key.profileID, vaultID: key.vaultID), stillOpen(key, mine) else { return }
        guard let snapshot = await snapshot(key) else { return }
        guard stillOpen(key, mine), let (_, row) = runningRow(key), notRolledBack(key, snapshot, row, database) else { return }
        let inputs = produceState(key, database: database, syncKey: syncKey)
        var work = ProduceWork()
        var sums = sumCache[key] ?? [:]
        var notSyncable = 0
        let live = Set(snapshot.accounts.map(\.id))

        var start = 0
        while start < snapshot.accounts.count {
            let chunk = snapshot.accounts[start..<min(start + Self.produceBatch, snapshot.accounts.count)]
            start += Self.produceBatch
            for account in chunk where !inputs.reviewed.contains(account.id) && !inputs.parked.contains(account.id) {
                let stamp = snapshot.stamps[account.id]
                var syncable: SyncableAccount?
                let sum: Data?
                if let stamp, let cached = sums[account.id], cached.stamp == stamp {
                    sum = cached.sum
                } else {
                    syncable = VaultSyncCodec.syncable(account)
                    sum = syncable?.parts.sum
                    if let stamp {
                        sums[account.id] = StampedSum(stamp: stamp, sum: sum)
                    }
                }
                guard let sum else {
                    notSyncable += 1
                    continue
                }
                if let base = inputs.bases[account.id], !base.parts.removed, base.parts.sum == sum {
                    if inputs.outgoing.contains(account.id) {
                        work.dropped.append(account.id)
                    }
                    continue
                }
                guard !(handedOut[key]?.contains(account.id) ?? false) else {
                    work.held = true
                    continue
                }
                let version = (inputs.versions[account.id] ?? 0) + 1
                if let pending = pendingBases[key]?[account.id], pending.version == version, pending.parts.sum == sum,
                   inputs.outgoing.contains(account.id) {
                    continue
                }
                guard let entry = syncable ?? VaultSyncCodec.syncable(account),
                      let sealed = Self.seal(entry, version: version, key: syncKey)
                else {
                    notSyncable += 1
                    continue
                }
                work.rows.append(sealed.row)
                work.bases[account.id] = SyncBase(version: version, parts: entry.parts)
            }
            flush(&work, key: key, database: database)
            await Task.yield()
            guard stillOpen(key, mine), runningRow(key) != nil else { return }
        }

        // Entries that were synced and are gone from the vault: a removed state at the next version. A pass that would send a large
        // part of the vault's entries as removed sends none of them until the owner agrees.
        let gone = inputs.bases.sorted { $0.key.uuidString < $1.key.uuidString }.filter { id, base in
            !base.parts.removed && !live.contains(id) && !inputs.reviewed.contains(id) && !inputs.parked.contains(id)
        }
        let released = releasing.remove(key) != nil
        let sending = gone.filter { id, _ in !(inputs.outgoing.contains(id) && pendingBases[key]?[id]?.parts.removed == true) }
        let limit = max(Self.removalFloor, inputs.bases.values.filter { !$0.parts.removed }.count / 4)
        let holds = sending.count > limit && !released
        holding[key] = holds ? sending.count : nil
        for (id, base) in gone where !holds {
            guard !(handedOut[key]?.contains(id) ?? false) else {
                work.held = true
                continue
            }
            let version = base.version + 1
            if let pending = pendingBases[key]?[id], pending.version == version, pending.parts.removed, inputs.outgoing.contains(id) {
                continue
            }
            let item = SyncItem(accountID: id, version: version, account: nil)
            guard let envelope = try? VaultSyncCodec.sealItem(item, key: syncKey),
                  let parts = try? VaultSyncCodec.sealParts(.removedParts, accountID: id, version: version, key: syncKey)
            else { continue }
            work.rows.append(OutboxRow(accountID: id, version: version, envelope: envelope, parts: parts))
            work.bases[id] = SyncBase(version: version, parts: .removedParts)
        }
        sumCache[key] = sums
        tallies[key, default: (0, 0)].notSyncable = notSyncable
        let addVaultRecord = settleVaultRecord(key, snapshot: snapshot, syncKey: syncKey, database: database)
        flush(&work, key: key, database: database)
        if addVaultRecord {
            engine?.add([.saveRecord(key.vaultRecord)])
        }
        refresh(key)
    }

    private nonisolated struct ProduceWork {
        var rows: [OutboxRow] = []
        var bases: [UUID: SyncBase] = [:]
        var dropped: [UUID] = []
        var held = false
    }

    private nonisolated struct ProduceState {
        var bases: [UUID: SyncBase]
        var versions: [UUID: UInt64]
        var outgoing: Set<UUID>
        var reviewed: Set<UUID>
        /// Accounts whose record a newer WSurf wrote: nothing is sealed for them until this build reads it.
        var parked: Set<UUID>
    }

    private nonisolated struct ProduceRows {
        var versions: [UUID: UInt64]
        var outgoing: Set<UUID>
        var reviewed: Set<UUID>
        var parked: Set<UUID>
    }

    private func produceState(_ key: VaultKey, database: VaultSyncDatabase, syncKey: VaultSyncKey) -> ProduceState {
        let loaded = try? database.read { tx in
            ProduceRows(
                versions: try tx.baseVersions(key.vaultID), outgoing: Set(try tx.outbox(key.vaultID).map(\.accountID)),
                reviewed: Set(try tx.conflicts(key.vaultID).map(\.accountID)), parked: try tx.parkedAccounts(key.vaultID)
            )
        }
        return ProduceState(
            bases: openedBases(key, database: database, syncKey: syncKey), versions: loaded?.versions ?? [:],
            outgoing: loaded?.outgoing ?? [], reviewed: loaded?.reviewed ?? [], parked: loaded?.parked ?? []
        )
    }

    private static func seal(_ entry: SyncableAccount, version: UInt64, key: VaultSyncKey) -> (row: OutboxRow, parts: SyncParts)? {
        let id = entry.account.id
        guard let envelope = try? VaultSyncCodec.sealItem(SyncItem(accountID: id, version: version, account: entry.account), key: key),
              let parts = try? VaultSyncCodec.sealParts(entry.parts, accountID: id, version: version, key: key)
        else { return nil }
        return (OutboxRow(accountID: id, version: version, envelope: envelope, parts: parts), entry.parts)
    }

    /// Writes the sealed rows and tells the engine, with no await between the last check and the write. A row is written only if
    /// its version is still the next one after the base (an event may have confirmed the account while this pass yielded) and the
    /// engine has not asked for the row before: otherwise the pass runs again after the `.sent`.
    private func flush(_ work: inout ProduceWork, key: VaultKey, database: VaultSyncDatabase) {
        let handed = handedOut[key] ?? []
        var written: [OutboxRow] = []
        var held = work.held
        var dropped = work.dropped.filter { !handed.contains($0) }
        do {
            try database.write { tx in
                guard var current = try tx.vault(key.vaultID), current.enabled else { return }
                for row in work.rows {
                    let next = (try tx.base(key.vaultID, row.accountID)?.version ?? 0) + 1
                    if handed.contains(row.accountID) || row.version != next {
                        held = true
                        continue
                    }
                    try tx.save(row, vault: key.vaultID)
                    written.append(row)
                }
                for id in dropped {
                    try tx.deleteOutbox(key.vaultID, id)
                }
                current.dirty = held
                try tx.save(current)
            }
        } catch {
            SyncLog.logger.error("sync: sealed vault rows could not be written")
            written = []
            dropped = []
        }
        for row in written {
            if let base = work.bases[row.accountID] {
                pendingBases[key, default: [:]][row.accountID] = base
            }
            queued[key, default: []].insert(row.accountID)
        }
        for id in dropped {
            pendingBases[key]?[id] = nil
            queued[key]?.remove(id)
        }
        if !written.isEmpty {
            engine?.add(written.map { .saveRecord(key.itemRecord($0.accountID)) })
        }
        work = ProduceWork(held: held)
    }

    /// Compares the vault's name and wrapper list with what was last uploaded (§5.6 step 4). True when a new `Vault` record waits.
    private func settleVaultRecord(_ key: VaultKey, snapshot: VaultSyncSnapshot, syncKey: VaultSyncKey, database: VaultSyncDatabase) -> Bool {
        guard let encoded = try? VaultWrapperList.encode(snapshot.wrappers) else { return false }
        let mark = VaultSyncCodec.vaultMark(name: snapshot.name, wrappers: encoded, key: syncKey)
        var addRecord = false
        let payload = try? vaultPayload(key, snapshot: snapshot, syncKey: syncKey)
        do {
            try database.write { tx in
                guard var current = try tx.vault(key.vaultID), current.enabled else { return }
                let before = current
                if current.uploadedMark == nil, current.pendingMark == nil {
                    // Just added or rejoined: the record already says what this Mac holds, so nothing goes up.
                    current.uploadedMark = mark
                } else if current.uploadedMark == mark {
                    current.pendingVault = nil
                    current.pendingMark = nil
                } else if current.pendingMark != mark, let payload {
                    current.pendingVault = payload.data
                    current.pendingMark = payload.mark
                    addRecord = true
                }
                current.lastHeadRevision = max(current.lastHeadRevision, snapshot.revision)
                if current != before {
                    try tx.save(current)
                }
            }
        } catch {
            return false
        }
        return addRecord
    }

    // MARK: - Resolve and conflicts

    /// Answers review rows: keep this Mac's version or take iCloud's. The version not kept stays recoverable in History or Trash.
    public func resolve(profileID: UUID, vaultID: UUID, accountIDs: [UUID], keepLocal: Bool) async throws {
        let key = try checkedKey(profileID, vaultID)
        try await serial(key) { [self] in
            try await resolveNow(key, accountIDs: Set(accountIDs), keepLocal: keepLocal)
        }
    }

    private func resolveNow(_ key: VaultKey, accountIDs: Set<UUID>, keepLocal: Bool) async throws {
        var staleRetries = 0
        while true {
            let mine = token(key)
            guard let (database, _) = runningRow(key) else { throw VaultSyncFailure.unavailable }
            guard let syncKey = await host.syncKey(profileID: key.profileID, vaultID: key.vaultID) else { throw VaultSyncFailure.locked }
            guard let snapshot = await snapshot(key) else { throw VaultSyncFailure.locked }
            guard mine == token(key), let (_, row) = runningRow(key), notRolledBack(key, snapshot, row, database) else {
                throw VaultSyncFailure.unavailable
            }
            let rows = ((try? database.read { try $0.conflicts(key.vaultID) }) ?? []).filter { accountIDs.contains($0.accountID) }
            var pass = SyncPass()
            let index = SyncLocalIndex(accounts: snapshot.accounts, removed: snapshot.removed)
            for conflict in rows {
                let id = conflict.accountID
                pass.answered.insert(id)
                pass.envelopes[id] = (conflict.version, conflict.envelope)
                guard let item = try? VaultSyncCodec.openItem(conflict.envelope, accountID: id, key: syncKey) else {
                    pass.unreadable += 1
                    continue
                }
                let base = openBase((try? database.read { try $0.base(key.vaultID, id) }) ?? nil, account: id, key: syncKey)
                let local = snapshot.accounts.first { $0.id == id }
                let decision = try CredentialSyncMerge.resolve(
                    item, kind: conflict.kind, local: local, base: base, keepLocal: keepLocal, index: index
                )
                if case .review = decision {
                    pass.answered.remove(id)
                    continue
                }
                apply(decision, id: id, version: conflict.version, envelope: conflict.envelope, snapshot: snapshot, into: &pass)
            }
            switch await commit(&pass, key: key, snapshot: snapshot) {
            case .done(let revision):
                record(pass, key: key, database: database, syncKey: syncKey, revision: max(revision ?? 0, snapshot.revision))
                await produce(key)
                return
            case .stale:
                staleRetries += 1
                guard staleRetries < 3 else { throw CredentialVaultError.staleRevision }
            case .stop:
                throw VaultSyncFailure.locked
            }
        }
    }

    /// The review rows with both versions opened, for the sheet. The vault must be unlocked.
    public func conflicts(profileID: UUID, vaultID: UUID) async throws -> [VaultSyncConflict] {
        let key = try checkedKey(profileID, vaultID)
        guard let (database, _) = runningRow(key) else { return [] }
        guard let syncKey = await host.syncKey(profileID: profileID, vaultID: vaultID) else { throw VaultSyncFailure.locked }
        guard let snapshot = await snapshot(key) else { throw VaultSyncFailure.locked }
        let rows = (try? database.read { try $0.conflicts(vaultID) }) ?? []
        let index = SyncLocalIndex(accounts: snapshot.accounts, removed: snapshot.removed)
        var result: [VaultSyncConflict] = []
        for conflict in rows {
            guard let item = try? VaultSyncCodec.openItem(conflict.envelope, accountID: conflict.accountID, key: syncKey) else { continue }
            let local = snapshot.accounts.first { $0.id == conflict.accountID }
            let base = openBase((try? database.read { try $0.base(vaultID, conflict.accountID) }) ?? nil, account: conflict.accountID, key: syncKey)
            var parts: [SyncPart] = []
            if case .review(_, let found)? = try? CredentialSyncMerge.decide(item, local: local, base: base, index: index) {
                parts = found
            }
            result.append(VaultSyncConflict(id: conflict.accountID, kind: conflict.kind, parts: parts, local: local, incoming: item.account))
        }
        return result
    }

    // MARK: - Shared reads

    /// The vault as the host shows it now. A vault that cannot be read is locked, as far as sync is concerned.
    func snapshot(_ key: VaultKey) async -> VaultSyncSnapshot? {
        do {
            return try await host.snapshot(profileID: key.profileID, vaultID: key.vaultID)
        } catch {
            locked(key)
            return nil
        }
    }

    /// Whether a step that waited for the host may go on: it is still the vault’s enablement the step started with, and the vault is
    /// still unlocked. A vault locked meanwhile drops what was kept for it, so a step never seals or opens with a key that is gone.
    func stillOpen(_ key: VaultKey, _ session: Int) -> Bool {
        guard session == token(key) else { return false }
        guard unlocked.contains(key) else {
            locked(key)
            return false
        }
        return true
    }

    func locked(_ key: VaultKey) {
        unlocked.remove(key)
        baseCache[key] = nil
        pendingBases[key] = nil
        sumCache[key] = nil
        refresh(key)
    }

    /// False, and sync stops, when the store is older than the last state this Mac synced from it (a restored backup).
    func notRolledBack(_ key: VaultKey, _ snapshot: VaultSyncSnapshot, _ row: VaultRow, _ database: VaultSyncDatabase) -> Bool {
        guard snapshot.revision < row.lastHeadRevision else { return true }
        var next = row
        next.status = .rolledBack
        try? database.write { try $0.save(next) }
        refresh(key)
        return false
    }

    func openBase(_ row: BaseRow?, account: UUID, key: VaultSyncKey) -> SyncBase? {
        guard let row, let parts = try? VaultSyncCodec.openParts(row.parts, accountID: account, version: row.version, key: key) else {
            return nil
        }
        return SyncBase(version: row.version, parts: parts)
    }

    /// Every base of the vault, opened once per unlock. A row that does not open is left out; its version still counts (`versions`).
    func openedBases(_ key: VaultKey, database: VaultSyncDatabase, syncKey: VaultSyncKey) -> [UUID: SyncBase] {
        if let cached = baseCache[key] {
            return cached
        }
        var opened: [UUID: SyncBase] = [:]
        for row in (try? database.read { try $0.bases(key.vaultID) }) ?? [] {
            opened[row.accountID] = openBase(row, account: row.accountID, key: syncKey)
        }
        baseCache[key] = opened
        return opened
    }
}
