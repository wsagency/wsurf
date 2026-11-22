// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import WSurfVault

extension VaultSync {
    func enrollmentAccount(_ engine: any SyncEngine, key: VaultKey, session: Int, expecting user: String?, explicit: Bool = false) async throws -> String {
        let actual = try await (engine as? any SyncAccountIdentity)?.currentAccountUser() ?? user
        guard permits(key), let actual, !actual.isEmpty, self.engine === engine, token(key) == session, state.accountUser == user, accountAvailable != false else {
            throw VaultSyncFailure.unavailable
        }
        if actual != user {
            let restored = acceptDiscoveryAccount(actual)
            guard user == nil, restored || explicit else { throw VaultSyncFailure.unavailable }
        }
        return actual
    }

    func enableNow(_ key: VaultKey, joiningFor expectedUser: String? = nil) async throws {
        guard permits(key), let engine else { throw VaultSyncFailure.unavailable }
        guard accountAvailable != false else { throw VaultSyncFailure.signedOut }
        let user = try await enrollmentAccount(engine, key: key, session: token(key), expecting: state.accountUser, explicit: expectedUser == nil)
        try await checkInstance?(key.profileID, user)
        guard permits(key), self.engine === engine, state.accountUser == user else { throw VaultSyncFailure.unavailable }
        // Verifying a first explicit choice may have quarantined an unowned row from the previous release.
        let mine = token(key)
        if let expectedUser, user != expectedUser {
            throw VaultSyncFailure.unavailable
        }
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
            if expectedUser == nil, self.engine === engine, token(key) == mine, state.accountUser != user {
                try database.write { try $0.save(VaultRow(vaultID: key.vaultID, enabled: false, status: .accountChanged)) }
                refresh(key)
            }
            throw error
        }
        guard snapshot.lease == lease, host.currentLease(profileID: key.profileID, vaultID: key.vaultID) == lease else { throw VaultSyncFailure.locked }
        // A retry joins the vault the owner saw. A disappearing zone must never become an invitation to upload.
        if let expectedUser, read == nil || catalogUser != expectedUser {
            throw VaultSyncFailure.unavailable
        }
        let wrappers = try VaultWrapperList.encode(snapshot.wrappers)
        let mark = VaultSyncCodec.vaultMark(name: snapshot.name, wrappers: wrappers, key: syncKey)
        var row = VaultRow(vaultID: key.vaultID, needsFetch: read != nil, approvedUser: user)
        row.instanceID = key.instanceID
        row.lastHeadRevision = snapshot.revision
        if let read {
            let server = try Self.header(in: read, key: key, syncKey: syncKey)
            let previous = try database.read { try $0.vault(key.vaultID) }
            row.uploadedMark = server.joinedMark(previous: previous, name: snapshot.name, wrappers: wrappers, mark: mark, key: syncKey)
            row.localWrappers = wrappers
        } else {
            guard var card = host.profileCard(profileID: key.profileID) else { throw VaultSyncFailure.unavailable }
            if let source = key.instanceID.flatMap({ instancePublicationSource?($0) }) {
                card.publicationSource = source
            } else if let recorded = recordedProfileCard(key.profileID, instance: key.instanceID) {
                card.publicationSource = recorded.publicationSource
            }
            row.pendingVault = try VaultSyncHeader.seal(name: snapshot.name, wrappers: wrappers, profile: card, key: syncKey)
            row.pendingMark = mark
            row.pendingLocalWrappers = wrappers
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

    private static func header(in read: SyncZoneRead, key: VaultKey, syncKey: VaultSyncKey) throws -> VaultSyncHeader {
        guard let header = read.records.first(where: { $0.id == key.vaultRecord && $0.type == .vault && $0.schema == 1 }) else { throw VaultSyncFailure.unavailable }
        return try VaultSyncHeader(header.payload, key: syncKey)
    }

    func fetchAllNow(_ key: VaultKey, force: Bool = false) async throws {
        guard let engine, let (database, row) = runningRow(key), row.needsFetch || (force && row.rereadOwed) else { return }
        let mine = token(key)
        let user = state.accountUser
        let joining = row.needsFetch && row.pendingVault != nil && row.uploadedMark == nil
        guard let read = try await readZone(key, engine: engine, session: mine, user: user) else {
            if row.needsFetch || row.uploadedMark != nil {
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
            _ = try Self.header(in: read, key: key, syncKey: syncKey)
            // Keep the existing cloud header and the local unlock methods. A later local edit is measured against this baseline.
            let wrappers = try VaultWrapperList.encode(snapshot.wrappers)
            let mark = VaultSyncCodec.vaultMark(name: snapshot.name, wrappers: wrappers, key: syncKey)
            try database.write { tx in
                guard var current = try tx.vault(key.vaultID) else { throw VaultSyncFailure.unavailable }
                current.acknowledgeHeader(mark: mark, local: wrappers)
                try tx.save(current)
            }
        }
        takeZoneRead(read, key: key, database: database)
        if row.needsFetch {
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
            let hasHeader = read.records.contains { $0.id == key.vaultRecord }
            try? database.write { tx in
                if var current = try tx.vault(key.vaultID) {
                    if !hasHeader, current.uploadedMark != nil {
                        current.serverVault = nil
                        current.pendingVault = nil
                        try tx.deleteSystemFields(key.vaultID, Self.vaultRecordName)
                    }
                    current.needsFetch = false
                    current.rereadOwed = read.skipped > 0
                    try tx.save(current)
                }
            }
        }
        incomplete.remove(key)
        refresh(key)
    }
}
