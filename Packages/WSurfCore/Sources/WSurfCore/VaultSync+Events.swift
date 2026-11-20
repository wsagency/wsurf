// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import os
import WSurfVault

// What the engine tells `VaultSync` (spec: fetched, sent, zones deleted, account), and enabling, joining and leaving a vault. Events
// only write `Credentials.sync` and queue work; none awaits a drain, because the engine waits for each event.

extension VaultSync {
    // MARK: - Fetched

    func applyFetched(modified: [SyncRecord], deleted: [SyncRecordID]) {
        var byVault: [VaultKey: [SyncRecord]] = [:]
        for record in modified {
            guard let ids = SyncZone.vaultIDs(record.id.zone), !excluded.contains(ids.profileID) else { continue }
            byVault[VaultKey(ids), default: []].append(record)
        }
        var touched = Set<VaultKey>()
        for key in byVault.keys.sorted(by: { $0.zone < $1.zone }) {
            let records = byVault[key] ?? []
            for record in records where record.id == key.vaultRecord {
                if takeVaultRecord(record, key: key) {
                    touched.insert(key)
                }
            }
            if takeItems(records.filter { $0.type == .item }, key: key) {
                touched.insert(key)
            }
        }
        for id in deleted {
            guard let ids = SyncZone.vaultIDs(id.zone), !excluded.contains(ids.profileID) else { continue }
            if id.name == Self.vaultRecordName {
                zoneRemoved(id.zone, reason: .deleted)
            } else if let (database, _) = enabledRow(VaultKey(ids)) {
                try? database.write { try $0.deleteSystemFields(ids.vaultID, id.name) }
            }
        }
        for key in touched {
            refresh(key)
            if unlocked.contains(key) {
                enqueue(key) { [weak self] in
                    await self?.drain(key)
                    await self?.produce(key)
                }
            }
        }
    }

    /// The vault's `Vault` record: what the Macs that do not hold the vault list. A Mac that holds it keeps its own unlock passkeys.
    private func takeVaultRecord(_ record: SyncRecord, key: VaultKey, conflict: Bool = false) -> Bool {
        let payload = record.type == .vault && record.schema == 1 ? VaultRecordPayload.decode(record.payload) : nil
        state.remote[key.zone] = payload.map { RemoteVault(profileID: key.profileID, vaultID: key.vaultID, payload: $0) }
        guard let (database, row) = enabledRow(key) else { return false }
        if payload != nil, record.payload == row.pendingVault, row.pendingLocalWrappers != nil {
            confirmVaultRecord(record, key: key, fetched: true)
            return true
        }
        if row.uploadedMark == nil, row.pendingVault != nil {
            awaitFirstHeader(key, database: database, row: row, server: record)
            return false
        }
        var next = row
        next.serverVault = payload == nil ? nil : record.payload
        let changed = conflict || next.serverVault != row.serverVault || (row.pendingVault != nil && row.pendingLocalWrappers == nil)
        if changed {
            next.pendingVault = nil
        }
        if record.schema != 1 || (payload != nil && payload?.keyGeneration != VaultSyncCodec.generation) {
            next.status = .needsUpdate
        }
        do {
            try database.write { tx in
                if let fields = record.systemFields {
                    try tx.setSystemFields(fields, vault: key.vaultID, name: record.id.name)
                } else {
                    try tx.deleteSystemFields(key.vaultID, record.id.name)
                }
                try tx.save(next)
            }
        } catch {
            halted.insert(key)
            return false
        }
        refresh(key)
        return changed
    }

    /// Stores each record's change tag and queues its envelope when it is newer than what this Mac agreed on. A record in a format
    /// only a newer WSurf reads is parked, as it came. Returns whether anything was queued or parked.
    private func takeItems(_ records: [SyncRecord], key: VaultKey) -> Bool {
        guard !records.isEmpty, let (database, row) = enabledRow(key), row.uploadedMark != nil || row.pendingVault == nil else { return false }
        var queuedAny = false
        do {
            try database.write { tx in
                // One lookup per record, so a read of a whole zone is O(records), not O(records x events).
                for record in records {
                    guard let account = Self.accountID(record.id.name) else { continue }
                    try tx.setSystemFields(record.systemFields, vault: key.vaultID, name: record.id.name)
                    let version: UInt64
                    do {
                        version = try VaultSyncCodec.version(of: record.payload)
                    } catch VaultSyncError.unsupportedFormat {
                        // This one entry waits for an update; the vault goes on.
                        try tx.save(InboxRow(accountID: account, version: 0, envelope: record.payload), vault: key.vaultID)
                        queuedAny = true
                        continue
                    } catch {
                        continue
                    }
                    var waiting = try tx.inboxVersion(key.vaultID, account)
                    if waiting == 0 {
                        // A record this build reads replaces the one it could not.
                        try tx.deleteInbox(key.vaultID, account, upTo: 0)
                        waiting = nil
                    }
                    guard version > (try tx.baseVersion(key.vaultID, account) ?? 0), version > (waiting ?? 0),
                          version > (try tx.conflictVersion(key.vaultID, account) ?? 0)
                    else { continue }
                    try tx.save(InboxRow(accountID: account, version: version, envelope: record.payload), vault: key.vaultID)
                    queuedAny = true
                }
            }
        } catch {
            // The engine moves on whatever happens here, so records that could not be kept are read again from the zone.
            SyncLog.logger.error("sync: fetched vault records could not be kept; the zone is read again")
            incomplete.insert(key)
            try? database.write { tx in
                if var current = try tx.vault(key.vaultID) {
                    current.needsFetch = true
                    try tx.save(current)
                }
            }
        }
        return queuedAny
    }

    // MARK: - Sent

    func applySent(saved: [SyncRecord], deleted: [SyncRecordID], failed: [SyncFailedSave]) {
        var produce = Set<VaultKey>()
        var drain = Set<VaultKey>()
        var items: [VaultKey: [SyncRecord]] = [:]
        for record in saved {
            guard let ids = SyncZone.vaultIDs(record.id.zone), !excluded.contains(ids.profileID) else { continue }
            let key = VaultKey(ids)
            switch record.type {
            case .vault where record.id.name == Self.vaultRecordName:
                confirmVaultRecord(record, key: key)
                produce.insert(key)
            case .item:
                items[key, default: []].append(record)
            default:
                break
            }
        }
        // One transaction and one refresh per vault for everything a `.sent` confirms, not one per record: a first upload of a large
        // vault is confirmed in many hundreds of records at a time.
        for key in items.keys.sorted(by: { $0.zone < $1.zone }) {
            let confirmed = confirmItems(items[key] ?? [], key: key)
            if confirmed.held {
                produce.insert(key)
            }
            if confirmed.reread {
                rereadAfterUnconfirmedSave(key)
            }
        }
        for failure in failed {
            guard let ids = SyncZone.vaultIDs(failure.id.zone), !excluded.contains(ids.profileID) else { continue }
            let key = VaultKey(ids)
            if retry(failure, key: key) {
                drain.insert(key)
            }
        }
        for key in drain.union(produce) {
            refresh(key)
            guard unlocked.contains(key) else { continue }
            let reads = drain.contains(key)
            enqueue(key) { [weak self] in
                if reads {
                    await self?.drain(key)
                }
                await self?.produce(key)
            }
        }
    }

    private func confirmVaultRecord(_ record: SyncRecord, key: VaultKey, fetched: Bool = false) {
        guard let (database, row) = enabledRow(key), fetched || !row.needsFetch else { return }
        guard record.payload == row.pendingVault, row.uploadedMark == nil || row.pendingLocalWrappers != nil else {
            // A rename can overtake a save. Only the current account's zone can confirm its change tag.
            if record.systemFields != (try? database.read { try $0.systemFields(key.vaultID, record.id.name) }) {
                rereadAfterUnconfirmedSave(key)
            }
            return
        }
        var next = row
        zoneRetries[key] = nil
        next.serverVault = record.payload
        next.acknowledgeHeader(mark: row.pendingMark, local: row.pendingLocalWrappers ?? VaultRecordPayload.decode(record.payload)?.wrappers)
        if next.status == .iCloudFull {
            next.status = .active
        }
        try? database.write { tx in
            try tx.setSystemFields(record.systemFields, vault: key.vaultID, name: record.id.name)
            try tx.save(next)
        }
        refresh(key)
        if row.uploadedMark == nil {
            readd(key)
        }
    }

    /// A matching receipt can release a queued edit. An unexpected newer receipt needs verification in the current account.
    private struct Confirmed {
        var held = false
        var reread = false
    }

    private func confirmItems(_ records: [SyncRecord], key: VaultKey) -> Confirmed {
        guard let (database, row) = enabledRow(key), row.uploadedMark != nil else { return Confirmed() }
        var result = Confirmed()
        var promoted: [(outgoing: OutboxRow, account: UUID)] = []
        var next = row
        do {
            try database.write { tx in
                for record in records {
                    guard let account = Self.accountID(record.id.name) else { continue }
                    if let outgoing = try tx.outbox(key.vaultID, account), outgoing.remainingAssets.isEmpty, outgoing.envelope == record.payload,
                       outgoing.envelope.first != VaultSyncCodec.assetFormat || handedOut[key]?.contains(account) == true {
                        try tx.setSystemFields(record.systemFields, vault: key.vaultID, name: record.id.name)
                        try tx.save(BaseRow(accountID: account, version: outgoing.version, parts: outgoing.parts), vault: key.vaultID)
                        try tx.deleteOutbox(key.vaultID, account)
                        result.held = result.held || row.dirty
                        promoted.append((outgoing, account))
                    } else if let version = try? VaultSyncCodec.version(of: record.payload),
                              version > (try tx.baseVersion(key.vaultID, account) ?? 0) {
                        // A different payload can be another Mac's change or a delayed reply for a previous Apple Account.
                        result.reread = true
                    }
                }
                if !promoted.isEmpty, next.status == .iCloudFull {
                    next.status = .active
                    try tx.save(next)
                }
            }
        } catch {
            return Confirmed()
        }
        for (outgoing, account) in promoted {
            handedOut[key]?.remove(account)
            queued[key]?.remove(account)
            promote(outgoing, key: key, account: account)
        }
        refresh(key)
        return result
    }

    private func rereadAfterUnconfirmedSave(_ key: VaultKey) {
        guard let (database, row) = enabledRow(key) else { return }
        var next = row
        next.rereadOwed = true
        try? database.write { try $0.save(next) }
        rereadTried.remove(key)
        rereadIfOwed(key)
    }

    /// The cleartext base follows the database: the parts this run sealed for the row, or nothing, which reloads from the database.
    private func promote(_ outgoing: OutboxRow, key: VaultKey, account: UUID) {
        if outgoing.envelope.first == VaultSyncCodec.assetFormat {
            clearAssets(key, account: account)
        }
        if let pending = pendingBases[key]?[account], pending.version == outgoing.version, baseCache[key] != nil {
            baseCache[key]?[account] = pending
        } else {
            baseCache[key] = nil
        }
        pendingBases[key]?[account] = nil
    }

    /// What a failed save asks for. True when a newer record from the server waits to be taken in.
    private func retry(_ failure: SyncFailedSave, key: VaultKey) -> Bool {
        guard let (database, row) = enabledRow(key), !row.needsFetch else { return false }
        let isVaultRecord = failure.id.name == Self.vaultRecordName
        let account = Self.accountID(failure.id.name)
        guard let attempted = failure.attempted, attempted.id == failure.id else { return false }
        if let account {
            guard row.uploadedMark != nil, let current = try? database.read({ try $0.outbox(key.vaultID, account) }), current.envelope == attempted.payload else { return false }
            handedOut[key]?.remove(account)
            queued[key]?.remove(account)
        } else if !isVaultRecord || row.pendingVault != attempted.payload {
            return false
        }
        switch failure.failure {
        case .serverRecordChanged(let server):
            return takeConflict(server, key: key, id: failure.id, database: database, account: account)
        case .zoneNotFound:
            zoneMissing(failure.id, key: key, database: database, row: row)
            return false
        case .unknownItem:
            if isVaultRecord, row.uploadedMark != nil {
                zoneRemoved(key.zone, reason: .deleted)
                return false
            }
            try? database.write { try $0.deleteSystemFields(key.vaultID, failure.id.name) }
            engine?.add([.saveRecord(failure.id)])
            return false
        case .quotaExceeded:
            markICloudFull(key, database: database, row: row)
            return false
        case .other:
            SyncLog.logger.error("sync: a vault record save failed; the next heartbeat tries again")
            return false
        }
    }

    private func takeConflict(_ server: SyncRecord, key: VaultKey, id: SyncRecordID, database: VaultSyncDatabase, account: UUID?) -> Bool {
        guard server.id == id else { return false }
        if id == key.vaultRecord {
            return takeVaultRecord(server, key: key, conflict: true)
        }
        // Whether the server holds a version this Mac has not agreed on: it is merged, and this Mac's row never goes up over it.
        // A record this build cannot read is parked and waits the same way.
        var ahead = false
        var parked = false
        try? database.write { tx in
            try tx.setSystemFields(server.systemFields, vault: key.vaultID, name: id.name)
            guard let account else { return }
            let version: UInt64
            do {
                version = try VaultSyncCodec.version(of: server.payload)
            } catch VaultSyncError.unsupportedFormat {
                try tx.save(InboxRow(accountID: account, version: 0, envelope: server.payload), vault: key.vaultID)
                parked = true
                return
            } catch {
                return
            }
            guard version > (try tx.base(key.vaultID, account)?.version ?? 0) else { return }
            ahead = true
            if version > (try tx.inboxVersion(key.vaultID, account) ?? 0) {
                try tx.save(InboxRow(accountID: account, version: version, envelope: server.payload), vault: key.vaultID)
            }
        }
        if parked {
            refresh(key)
            return false
        }
        if ahead {
            return true
        }
        // The server holds nothing newer than the base: the engine dropped the save, so send this Mac's row again on its tag.
        if let account, (try? database.read { try $0.outbox(key.vaultID, account) }) != nil {
            engine?.add([.saveRecord(id)])
        }
        return false
    }

    /// A save found its zone missing. For a zone this Mac made whose `Vault` record never landed, the zone was lost on the way up (the
    /// engine only logs a failed zone save, as `readd` assumes after a lost queue): ask for it again with the save. Any other missing
    /// zone was removed.
    ///
    /// "Never landed" is no uploaded mark, the record still waiting, and no server fields stored for it: fields exist only once the
    /// record was seen on the server (a rename that overtook the first save, or another Mac that enabled the vault at the same moment),
    /// and then a missing zone is another Mac's removal, which this Mac never undoes.
    ///
    /// Entries and file chunks wait for the first header, including while the heartbeat retries a lost zone creation.
    private func zoneMissing(_ id: SyncRecordID, key: VaultKey, database: VaultSyncDatabase, row: VaultRow) {
        guard firstUploadPending(key, database: database, row: row) else {
            zoneRemoved(id.zone, reason: .deleted)
            return
        }
        guard id == key.vaultRecord, zoneRetries[key, default: 0] < Self.zoneRetryLimit else { return }
        zoneRetries[key, default: 0] += 1
        engine?.add([.saveZone(id.zone), .saveRecord(id)])
    }

    // MARK: - Zones and the account

    /// The zone is gone, whatever the reason. This Mac keeps its copy, stops, and never re-creates it.
    func zoneRemoved(_ zone: String, reason: SyncZoneDeletionReason) {
        guard let ids = SyncZone.vaultIDs(zone), !excluded.contains(ids.profileID) else { return }
        let key = VaultKey(ids)
        state.remote[zone] = nil
        guard let (database, row) = enabledRow(key) else {
            // A removal this Mac asked for that failed is done now that the zone is gone.
            if let database = database(ids.profileID), var left = (try? database.read { try $0.vault(ids.vaultID) }) ?? nil,
               !left.enabled, left.status == .removalFailed, let user = state.accountUser, left.approvedUser == user {
                left.status = .removedDeleted
                try? database.write { try $0.save(left) }
                refresh(key)
            }
            return
        }
        leave(key, database: database, row: row, status: .removed(reason))
    }

    /// The engine could not delete a zone. For a vault this Mac removed from iCloud, the status says it is still there.
    func zoneDeleteFailed(_ zone: String) {
        guard let ids = SyncZone.vaultIDs(zone), !excluded.contains(ids.profileID), let database = database(ids.profileID) else { return }
        let key = VaultKey(ids)
        guard var row = (try? database.read { try $0.vault(key.vaultID) }) ?? nil, !row.enabled, row.status == .removedDeleted,
              let user = state.accountUser, row.approvedUser == user else { return }
        row.status = .removalFailed
        try? database.write { try $0.save(row) }
        refresh(key)
    }

    /// The account's iCloud storage is full: the vault says so until a save goes through (`confirmVaultRecord`, `confirmItems`).
    private func markICloudFull(_ key: VaultKey, database: VaultSyncDatabase, row: VaultRow) {
        guard row.status == .active else { return }
        var next = row
        next.status = .iCloudFull
        try? database.write { try $0.save(next) }
        refresh(key)
    }

    /// The engine could not create the vault's zone because iCloud is full. The records then only find their zone missing, so without
    /// this the vault would wait on "Sending changes to iCloud…" with nothing for the person to act on.
    func zoneSaveOverQuota(_ zone: String) {
        guard let ids = SyncZone.vaultIDs(zone), !excluded.contains(ids.profileID) else { return }
        let key = VaultKey(ids)
        guard let (database, row) = enabledRow(key) else { return }
        markICloudFull(key, database: database, row: row)
    }

    /// Ends this Mac's syncing of the vault with `status` as the reason, and drops everything it kept for it.
    func leave(_ key: VaultKey, database: VaultSyncDatabase, row: VaultRow, status: VaultSyncStatus.Stored) {
        var next = VaultRow(vaultID: key.vaultID, enabled: false, status: status)
        if status == .removedDeleted {
            next.approvedUser = row.approvedUser
        }
        next.lastHeadRevision = row.lastHeadRevision
        forget(key)
        do {
            try database.write { tx in
                try tx.clear(key.vaultID)
                try tx.save(next)
            }
        } catch {
            halted.insert(key)
        }
        clearAssets(key)
        if !halted.contains(key) {
            refresh(key)
        }
    }

    func applyAccount(_ change: SyncAccountChange) {
        switch change {
        case .signOut:
            catalogUser = nil
            accountAvailable = false
            checkedAtAttach = []
            state.remote = [:]
            for key in summaries.keys {
                sessions[key, default: 0] += 1
                try? database(key.profileID)?.write { tx in
                    for name in (try? Self.recordNames(tx, key.vaultID)) ?? [] {
                        try tx.deleteSystemFields(key.vaultID, name)
                    }
                }
            }
        case .signIn(let user) where (state.accountUser == nil || state.accountUser == user) && canRestoreAccount(user):
            state.accountUser = user
            accountAvailable = true
        case .signIn(let user), .switchAccounts(let user):
            // Another Apple Account: nothing of the old one is kept, and nothing goes up until the person turns sync on again.
            catalogUser = nil
            state.accountUser = user
            accountAvailable = true
            state.remote = [:]
            for profileID in Set(host.profileIDs()).union(databases.keys) {
                guard let database = database(profileID), let rows = try? database.read({ try $0.vaults() }) else { continue }
                for row in rows {
                    let key = VaultKey(profileID: profileID, vaultID: row.vaultID)
                    if row.pendingAdoptionUser != nil || row.approvedUser == user {
                        // Invalidate work from the old session. Per-vault consent still belongs to its recorded owner.
                        forget(key)
                        checkedAtAttach.remove(key)
                    } else {
                        leave(key, database: database, row: row, status: .accountChanged)
                    }
                }
            }
        }
        refreshAll()
        if accountAvailable == true {
            resumeEnrolledVaults()
        }
    }

    private static func recordNames(_ tx: VaultSyncDatabase.Transaction, _ vault: UUID) throws -> [String] {
        try String.fetchAll(tx.db, sql: "SELECT name FROM record WHERE vaultID = ?", arguments: [vault.sqlText])
    }

    /// Deletes the vault's zone in iCloud, drops its rows and says why.
    func deleteZone(_ key: VaultKey) {
        guard let (database, row) = enabledRow(key) else { return }
        engine?.add([.deleteZone(key.zone)])
        leave(key, database: database, row: row, status: .removed(.deleted))
        state.remote[key.zone] = nil
        persist(state)
    }
}
