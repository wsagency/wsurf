// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import WSurfVault

extension VaultSync {
    func enrollmentAccount(_ engine: any SyncEngine, key: VaultKey, session: Int, expecting user: String?) async throws -> String {
        let actual = try await (engine as? any SyncAccountIdentity)?.currentAccountUser() ?? user
        guard let actual, !actual.isEmpty, self.engine === engine, token(key) == session, state.accountUser == user, accountAvailable != false else {
            throw VaultSyncFailure.unavailable
        }
        if actual != user, !acceptDiscoveryAccount(actual) {
            throw VaultSyncFailure.unavailable
        }
        return actual
    }

    func enableNow(_ key: VaultKey) async throws {
        guard let engine else { throw VaultSyncFailure.unavailable }
        guard accountAvailable != false else { throw VaultSyncFailure.signedOut }
        let mine = token(key)
        let user = try await enrollmentAccount(engine, key: key, session: mine, expecting: state.accountUser)
        guard let lease = host.currentLease(profileID: key.profileID, vaultID: key.vaultID) else { throw VaultSyncFailure.locked }
        guard let database = database(key.profileID, create: true) else { throw VaultSyncFailure.unavailable }
        if runningRow(key) != nil {
            try await fetchAllNow(key)
            readd(key)
            return
        }
        guard let syncKey = await host.syncKey(profileID: key.profileID, vaultID: key.vaultID) else { throw VaultSyncFailure.locked }
        let snapshot = try await host.snapshot(profileID: key.profileID, vaultID: key.vaultID)
        let read: SyncZoneRead?
        do {
            read = try await readZone(key, engine: engine, session: mine, user: user)
        } catch {
            // An account switch can interrupt the first opt-in before it has a database row.
            if self.engine === engine, token(key) == mine, state.accountUser != user {
                try database.write { try $0.save(VaultRow(vaultID: key.vaultID, enabled: false, status: .accountChanged)) }
                refresh(key)
            }
            throw error
        }
        guard snapshot.lease == lease, host.currentLease(profileID: key.profileID, vaultID: key.vaultID) == lease else { throw VaultSyncFailure.locked }
        let payload = try vaultPayload(key, snapshot: snapshot, syncKey: syncKey)
        var row = VaultRow(vaultID: key.vaultID, needsFetch: read != nil, approvedUser: user)
        row.lastHeadRevision = snapshot.revision
        if let read {
            try Self.verifyHeader(in: read, key: key, syncKey: syncKey)
            row.uploadedMark = payload.mark
        } else {
            row.pendingVault = payload.data
            row.pendingMark = payload.mark
        }
        try database.write { tx in
            try tx.clear(key.vaultID)
            try tx.save(row)
        }
        clearAssets(key)
        begin(key)
        unlocked.insert(key)
        if let read {
            takeZoneRead(read, key: key, database: database)
        } else {
            refresh(key)
            readd(key)
        }
        await drain(key)
        await produce(key)
    }

    /// A competing first header proves the zone already existed. Hold the local outbox until the full zone is authenticated and joined.
    func awaitFirstHeader(_ key: VaultKey, database: VaultSyncDatabase, row: VaultRow, server: SyncRecord) {
        guard !row.needsFetch else { return }
        var next = row
        next.needsFetch = true
        do {
            try database.write { tx in
                try tx.setSystemFields(server.systemFields, vault: key.vaultID, name: Self.vaultRecordName)
                try tx.save(next)
            }
        } catch {
            halted.insert(key)
            return
        }
        refresh(key)
        enqueue(key) { [weak self] in await self?.cycle(key, fetch: false) }
    }

    /// An unenrolled zone is excluded from the shared incremental cursor. Only a confirmed missing zone permits a create.
    private func readZone(_ key: VaultKey, engine: any SyncEngine, session: Int, user: String?) async throws -> SyncZoneRead? {
        _ = try await enrollmentAccount(engine, key: key, session: session, expecting: user)
        let read: SyncZoneRead?
        do {
            read = try await engine.fetchAll(zone: key.zone)
        } catch where (error as? CKError)?.code == .zoneNotFound || (error as? URLError)?.code == .fileDoesNotExist {
            read = nil
        }
        _ = try await enrollmentAccount(engine, key: key, session: session, expecting: user)
        return read
    }

    private static func verifyHeader(in read: SyncZoneRead, key: VaultKey, syncKey: VaultSyncKey) throws {
        guard let header = read.records.first(where: { $0.id == key.vaultRecord && $0.type == .vault && $0.schema == 1 }),
              let payload = VaultRecordPayload.decode(header.payload), payload.keyGeneration == VaultSyncCodec.generation else { throw VaultSyncFailure.unavailable }
        _ = try VaultSyncCodec.openVault(payload.sealed, wrappers: payload.wrappers, key: syncKey)
        _ = try VaultWrapperList.decode(payload.wrappers)
    }

    func fetchAllNow(_ key: VaultKey, force: Bool = false) async throws {
        guard let engine, let (database, row) = runningRow(key), row.needsFetch || (force && row.rereadOwed) else { return }
        let mine = token(key)
        let user = state.accountUser
        let joining = row.needsFetch && row.pendingVault != nil && row.uploadedMark == nil
        guard let read = try await readZone(key, engine: engine, session: mine, user: user) else {
            if joining {
                zoneRemoved(key.zone, reason: .deleted)
            }
            throw VaultSyncFailure.unavailable
        }
        if joining {
            guard let lease = host.currentLease(profileID: key.profileID, vaultID: key.vaultID),
                  let syncKey = await host.syncKey(profileID: key.profileID, vaultID: key.vaultID) else { throw VaultSyncFailure.locked }
            let snapshot = try await host.snapshot(profileID: key.profileID, vaultID: key.vaultID)
            _ = try await enrollmentAccount(engine, key: key, session: mine, expecting: user)
            guard snapshot.lease == lease, host.currentLease(profileID: key.profileID, vaultID: key.vaultID) == lease else { throw VaultSyncFailure.locked }
            try Self.verifyHeader(in: read, key: key, syncKey: syncKey)
            // Keep the existing cloud header and the local unlock methods. A later local edit is measured against this baseline.
            let wrappers = try VaultWrapperList.encode(snapshot.wrappers)
            let mark = VaultSyncCodec.vaultMark(name: snapshot.name, wrappers: wrappers, key: syncKey)
            try database.write { tx in
                guard var current = try tx.vault(key.vaultID) else { throw VaultSyncFailure.unavailable }
                current.uploadedMark = mark
                current.pendingVault = nil
                current.pendingMark = nil
                try tx.save(current)
            }
        }
        takeZoneRead(read, key: key, database: database)
        if joining {
            readd(key)
        }
    }

    private func takeZoneRead(_ read: SyncZoneRead, key: VaultKey, database: VaultSyncDatabase) {
        incomplete.remove(key)
        applyFetched(modified: read.records, deleted: [])
        // The count is of the records the last read skipped, not of every read added up.
        tallies[key, default: (0, 0)].unreadable += read.skipped - (skippedRecords[key] ?? 0)
        skippedRecords[key] = read.skipped
        // A read that could not keep every record is still owed. A read that skipped some owes one more, which holds nothing back.
        if !incomplete.contains(key) {
            try? database.write { tx in
                if var current = try tx.vault(key.vaultID) {
                    current.needsFetch = false
                    current.rereadOwed = read.skipped > 0
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
