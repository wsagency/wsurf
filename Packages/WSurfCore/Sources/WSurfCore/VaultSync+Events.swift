// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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
            for record in records where record.type == .vault && record.id.name == Self.vaultRecordName {
                takeVaultRecord(record, key: key)
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
    private func takeVaultRecord(_ record: SyncRecord, key: VaultKey) {
        guard let payload = VaultRecordPayload.decode(record.payload) else { return }
        state.remote[key.zone] = RemoteVault(profileID: key.profileID, vaultID: key.vaultID, payload: payload)
        guard let (database, row) = enabledRow(key) else { return }
        var next = row
        if payload.keyGeneration != VaultSyncCodec.generation {
            next.status = .needsUpdate
        }
        try? database.write { tx in
            try tx.setSystemFields(record.systemFields, vault: key.vaultID, name: record.id.name)
            try tx.save(next)
        }
        refresh(key)
    }

    /// Stores each record's change tag and queues its envelope when it is newer than what this Mac agreed on. A record in a format
    /// only a newer WSurf reads is parked, as it came. Returns whether anything was queued or parked.
    private func takeItems(_ records: [SyncRecord], key: VaultKey) -> Bool {
        guard !records.isEmpty, let (database, _) = enabledRow(key) else { return false }
        var queuedAny = false
        do {
            try database.write { tx in
                let bases = try tx.baseVersions(key.vaultID)
                var waiting = try tx.inboxVersions(key.vaultID)
                let reviewed = try tx.conflictVersions(key.vaultID)
                for record in records {
                    guard let account = Self.accountID(record.id.name) else { continue }
                    try tx.setSystemFields(record.systemFields, vault: key.vaultID, name: record.id.name)
                    let version: UInt64
                    do {
                        version = try VaultSyncCodec.version(of: record.payload)
                    } catch VaultSyncError.unsupportedFormat {
                        // This one entry waits for an update; the vault goes on.
                        try tx.save(InboxRow(accountID: account, version: 0, envelope: record.payload), vault: key.vaultID)
                        waiting[account] = 0
                        queuedAny = true
                        continue
                    } catch {
                        continue
                    }
                    if waiting[account] == 0 {
                        // A record this build reads replaces the one it could not.
                        try tx.deleteInbox(key.vaultID, account, upTo: 0)
                        waiting[account] = nil
                    }
                    guard version > (bases[account] ?? 0), version > (waiting[account] ?? 0), version > (reviewed[account] ?? 0) else { continue }
                    try tx.save(InboxRow(accountID: account, version: version, envelope: record.payload), vault: key.vaultID)
                    waiting[account] = version
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
        for record in saved {
            guard let ids = SyncZone.vaultIDs(record.id.zone), !excluded.contains(ids.profileID) else { continue }
            let key = VaultKey(ids)
            switch record.type {
            case .vault where record.id.name == Self.vaultRecordName:
                confirmVaultRecord(record, key: key)
                produce.insert(key)
            case .item:
                switch confirmItem(record, key: key) {
                case .confirmed(let held):
                    if held {
                        produce.insert(key)
                    }
                case .other:
                    drain.insert(key)
                case .ignored:
                    break
                }
            default:
                break
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

    private func confirmVaultRecord(_ record: SyncRecord, key: VaultKey) {
        guard let (database, row) = enabledRow(key) else { return }
        var next = row
        if record.payload == row.pendingVault {
            next.uploadedMark = row.pendingMark
            next.pendingVault = nil
            next.pendingMark = nil
        }
        if next.status == .iCloudFull {
            next.status = .active
        }
        try? database.write { tx in
            try tx.setSystemFields(record.systemFields, vault: key.vaultID, name: record.id.name)
            try tx.save(next)
        }
        refresh(key)
    }

    private enum Confirmation {
        /// The server holds this Mac's row: its parts are the base now. `held` says a change waited for it.
        case confirmed(held: Bool)
        /// The server holds something this Mac did not seal for that version: it is read as incoming.
        case other
        case ignored
    }

    private func confirmItem(_ record: SyncRecord, key: VaultKey) -> Confirmation {
        guard let account = Self.accountID(record.id.name), let (database, row) = enabledRow(key) else { return .ignored }
        handedOut[key]?.remove(account)
        queued[key]?.remove(account)
        var result = Confirmation.ignored
        var next = row
        if next.status == .iCloudFull {
            next.status = .active
        }
        try? database.write { tx in
            try tx.setSystemFields(record.systemFields, vault: key.vaultID, name: record.id.name)
            if let outgoing = try tx.outbox(key.vaultID, account), outgoing.envelope == record.payload {
                try tx.save(BaseRow(accountID: account, version: outgoing.version, parts: outgoing.parts), vault: key.vaultID)
                try tx.deleteOutbox(key.vaultID, account)
                result = .confirmed(held: row.dirty)
                promote(outgoing, key: key, account: account)
            } else if let version = try? VaultSyncCodec.version(of: record.payload),
                      version > (try tx.base(key.vaultID, account)?.version ?? 0) {
                // Not the bytes this Mac handed out (a row resealed since, or another Mac's record at that version): read it as
                // incoming, so the base is never set to parts the server does not hold.
                try tx.save(InboxRow(accountID: account, version: version, envelope: record.payload), vault: key.vaultID)
                result = .other
            }
            try tx.save(next)
        }
        refresh(key)
        return result
    }

    /// The cleartext base follows the database: the parts this run sealed for the row, or nothing, which reloads from the database.
    private func promote(_ outgoing: OutboxRow, key: VaultKey, account: UUID) {
        if let pending = pendingBases[key]?[account], pending.version == outgoing.version, baseCache[key] != nil {
            baseCache[key]?[account] = pending
        } else {
            baseCache[key] = nil
        }
        pendingBases[key]?[account] = nil
    }

    /// What a failed save asks for. True when a newer record from the server waits to be taken in.
    private func retry(_ failure: SyncFailedSave, key: VaultKey) -> Bool {
        guard let (database, row) = enabledRow(key) else { return false }
        let isVaultRecord = failure.id.name == Self.vaultRecordName
        let account = Self.accountID(failure.id.name)
        guard isVaultRecord || account != nil else { return false }
        if let account {
            handedOut[key]?.remove(account)
            queued[key]?.remove(account)
        }
        switch failure.failure {
        case .serverRecordChanged(let server):
            // Whether the server holds a version this Mac has not agreed on: it is merged, and this Mac's row never goes up over it.
            // A record this build cannot read is parked and waits the same way.
            var ahead = false
            var parked = false
            try? database.write { tx in
                try tx.setSystemFields(server.systemFields, vault: key.vaultID, name: failure.id.name)
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
                if version > (try tx.inboxVersions(key.vaultID)[account] ?? 0) {
                    try tx.save(InboxRow(accountID: account, version: version, envelope: server.payload), vault: key.vaultID)
                }
            }
            if parked {
                refresh(key)
                return false
            }
            if isVaultRecord {
                // This Mac's list wins on the server's tag: every list in it was sealed by a holder of the vault's key.
                engine?.add([.saveRecord(failure.id)])
                return false
            }
            if ahead {
                return true
            }
            // The server holds nothing newer than the base: the engine dropped the save, so send this Mac's row again on its tag.
            if let account, (try? database.read { try $0.outbox(key.vaultID, account) }) != nil {
                engine?.add([.saveRecord(failure.id)])
            }
            return false
        case .zoneNotFound:
            zoneRemoved(failure.id.zone, reason: .deleted)
            return false
        case .unknownItem:
            try? database.write { try $0.deleteSystemFields(key.vaultID, failure.id.name) }
            engine?.add([.saveRecord(failure.id)])
            return false
        case .quotaExceeded:
            if row.status == .active {
                var next = row
                next.status = .iCloudFull
                try? database.write { try $0.save(next) }
                refresh(key)
            }
            return false
        case .other:
            SyncLog.logger.error("sync: a vault record save failed; the next heartbeat tries again")
            return false
        }
    }

    // MARK: - Zones and the account

    /// The zone is gone, whatever the reason. This Mac keeps its copy, stops, and never re-creates it.
    func zoneRemoved(_ zone: String, reason: SyncZoneDeletionReason) {
        guard let ids = SyncZone.vaultIDs(zone), !excluded.contains(ids.profileID) else { return }
        let key = VaultKey(ids)
        state.remote[zone] = nil
        guard let (database, row) = enabledRow(key) else { return }
        leave(key, database: database, row: row, status: .removed(reason))
    }

    /// The engine could not delete a zone. For a vault this Mac removed from iCloud, the status says it is still there.
    func zoneDeleteFailed(_ zone: String) {
        guard let ids = SyncZone.vaultIDs(zone), !excluded.contains(ids.profileID), let database = database(ids.profileID) else { return }
        let key = VaultKey(ids)
        guard var row = (try? database.read { try $0.vault(key.vaultID) }) ?? nil, !row.enabled, row.status == .removedDeleted else { return }
        row.status = .removalFailed
        try? database.write { try $0.save(row) }
        refresh(key)
    }

    /// Ends this Mac's syncing of the vault with `status` as the reason, and drops everything it kept for it.
    func leave(_ key: VaultKey, database: VaultSyncDatabase, row: VaultRow, status: VaultSyncStatus.Stored) {
        var next = VaultRow(vaultID: key.vaultID, enabled: false, status: status)
        next.lastHeadRevision = row.lastHeadRevision
        do {
            try database.write { tx in
                try tx.clear(key.vaultID)
                try tx.save(next)
            }
        } catch {
            halted.insert(key)
        }
        forget(key)
        if !halted.contains(key) {
            refresh(key)
        }
    }

    func applyAccount(_ change: SyncAccountChange) {
        switch change {
        case .signOut:
            accountAvailable = false
            state.remote = [:]
            for key in summaries.keys {
                try? database(key.profileID)?.write { tx in
                    for name in (try? Self.recordNames(tx, key.vaultID)) ?? [] {
                        try tx.deleteSystemFields(key.vaultID, name)
                    }
                }
            }
        case .signIn(let user) where state.accountUser == user || (state.accountUser == nil && enabledKeys.isEmpty):
            state.accountUser = user
            accountAvailable = true
            for key in enabledKeys {
                readd(key)
            }
        case .signIn(let user), .switchAccounts(let user):
            // Another Apple Account: nothing of the old one is kept, and nothing goes up until the person turns sync on again.
            state.accountUser = user
            accountAvailable = true
            state.remote = [:]
            for profileID in Set(host.profileIDs()).union(databases.keys) {
                guard let database = database(profileID), let rows = try? database.read({ try $0.vaults() }) else { continue }
                for row in rows {
                    leave(VaultKey(profileID: profileID, vaultID: row.vaultID), database: database, row: row, status: .accountChanged)
                }
            }
        }
        refreshAll()
    }

    private static func recordNames(_ tx: VaultSyncDatabase.Transaction, _ vault: UUID) throws -> [String] {
        try String.fetchAll(tx.db, sql: "SELECT name FROM record WHERE vaultID = ?", arguments: [vault.sqlText])
    }

    /// Deletes the vault's zone in iCloud, drops its rows and says why.
    func deleteZone(_ key: VaultKey) {
        guard let (database, row) = enabledRow(key) else { return }
        engine?.add([.deleteZone(key.zone)])
        leave(key, database: database, row: row, status: .removed(.deleted))
    }

    // MARK: - Enable and join

    func enableNow(_ key: VaultKey) async throws {
        guard let engine else { throw VaultSyncFailure.unavailable }
        guard accountAvailable != false else { throw VaultSyncFailure.signedOut }
        guard await host.syncKey(profileID: key.profileID, vaultID: key.vaultID) != nil else { throw VaultSyncFailure.locked }
        guard let database = database(key.profileID, create: true) else { throw VaultSyncFailure.unavailable }
        // The zone either exists (another Mac made it) or does not; a fetch that cannot run stops here and changes nothing.
        try await engine.fetchNow()
        guard let syncKey = await host.syncKey(profileID: key.profileID, vaultID: key.vaultID) else { throw VaultSyncFailure.locked }
        let snapshot = try await host.snapshot(profileID: key.profileID, vaultID: key.vaultID)
        begin(key)
        unlocked.insert(key)
        var row = VaultRow(vaultID: key.vaultID)
        row.lastHeadRevision = snapshot.revision
        if state.remote[key.zone] == nil {
            let payload = try vaultPayload(key, snapshot: snapshot, syncKey: syncKey)
            row.pendingVault = payload.data
            row.pendingMark = payload.mark
            try database.write { tx in
                try tx.clear(key.vaultID)
                try tx.save(row)
            }
            engine.add([.saveZone(key.zone), .saveRecord(key.vaultRecord)])
        } else {
            row.needsFetch = true
            try database.write { tx in
                try tx.clear(key.vaultID)
                try tx.save(row)
            }
            do {
                try await fetchAllNow(key)
            } catch {
                try? database.write { try $0.remove(key.vaultID) }
                forget(key)
                summaries[key] = nil
                throw error
            }
        }
        refresh(key)
        await drain(key)
        await produce(key)
    }

    /// Reads the whole zone into the inbox: what a Mac that joins or adds a vault missed before it was one of its writers.
    func fetchAllNow(_ key: VaultKey) async throws {
        guard let engine, let (database, row) = runningRow(key), row.needsFetch else { return }
        let mine = token(key)
        let read = try await engine.fetchAll(zone: key.zone)
        guard mine == token(key) else { return }
        incomplete.remove(key)
        applyFetched(modified: read.records, deleted: [])
        if read.skipped > 0 {
            tallies[key, default: (0, 0)].unreadable += read.skipped
        }
        // A read that could not keep every record is still owed.
        if !incomplete.contains(key) {
            try? database.write { tx in
                if var current = try tx.vault(key.vaultID) {
                    current.needsFetch = false
                    try tx.save(current)
                }
            }
        }
        incomplete.remove(key)
        refresh(key)
    }

    /// The `Vault` record's payload for the vault as it is now, with the mark it stands for.
    func vaultPayload(_ key: VaultKey, snapshot: VaultSyncSnapshot, syncKey: VaultSyncKey) throws -> (data: Data, mark: Data) {
        guard let card = host.profileCard(profileID: key.profileID) else { throw VaultSyncFailure.unavailable }
        let wrappers = try VaultWrapperList.encode(snapshot.wrappers)
        let sealed = try VaultSyncCodec.sealVault(name: snapshot.name, wrappers: wrappers, key: syncKey)
        let payload = VaultRecordPayload(keyGeneration: VaultSyncCodec.generation, profile: card, wrappers: wrappers, sealed: sealed)
        return (try payload.encoded(), VaultSyncCodec.vaultMark(name: snapshot.name, wrappers: wrappers, key: syncKey))
    }
}
