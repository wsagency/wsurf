// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import os
import WSurfVault

/// A vault of one profile: the key of everything `VaultSync` keeps per vault.
nonisolated struct VaultKey: Hashable, Sendable {
    let profileID: UUID
    let vaultID: UUID

    init(profileID: UUID, vaultID: UUID) {
        self.profileID = profileID
        self.vaultID = vaultID
    }

    init(_ ids: (profileID: UUID, vaultID: UUID)) {
        self.init(profileID: ids.profileID, vaultID: ids.vaultID)
    }

    var zone: String {
        SyncZone.vault(profileID: profileID, vaultID: vaultID)
    }

    /// The record that holds the vault's wrapper list and name: one per zone.
    var vaultRecord: SyncRecordID {
        SyncRecordID(zone: zone, name: VaultSync.vaultRecordName)
    }

    func itemRecord(_ accountID: UUID) -> SyncRecordID {
        SyncRecordID(zone: zone, name: accountID.uuidString)
    }
}

/// What the status of one vault is derived from; observed, so a view that shows a status updates.
nonisolated struct VaultSyncSummary: Equatable {
    var enabled: Bool
    var stored: VaultSyncStatus.Stored
    var outbox: Int
    var inbox: Int
    var review: Int
    var hasPendingVault: Bool
    var isHeldBack: Bool
    var isReading: Bool
    var isUnlocked: Bool
    var notSyncable = 0
    var unreadable = 0
    var parked = 0
    var holding = 0
}

/// Sync of sealed vaults through the one engine (spec amendment 2026-10-22). Per vault, opt-in: this Mac seals each entry under the
/// vault's sync key and sends it as an `Item` record in the vault's zone, and opens, merges and applies what the other Macs sent,
/// through the vault's own commit. It works only while the vault is unlocked, and never prompts, unlocks or touches a lease; what
/// arrives while it is locked waits sealed in `Credentials.sync`. Nothing here reads a store row, a file or a setting.
///
/// Every step of one vault runs on that vault's serial chain, so a drain, a produce and a resolve never interleave; an event only
/// writes the database and queues work.
@Observable
public final class VaultSync: SyncEngineDelegate {
    /// The name of the one `Vault` record in a zone.
    public nonisolated static let vaultRecordName = "vault"
    static let drainBatch = 200
    static let produceBatch = 500
    /// A pass that would send more removed states than this, or a quarter of the vault's synced entries if that is more, waits for
    /// the owner.
    static let removalFloor = 20

    public internal(set) var state: VaultSyncAppState
    /// Nil until the engine has answered.
    public internal(set) var accountAvailable: Bool?
    var summaries: [VaultKey: VaultSyncSummary] = [:]

    @ObservationIgnored let host: any VaultSyncHost
    @ObservationIgnored let excluded: Set<UUID>
    @ObservationIgnored let debounce: Duration
    @ObservationIgnored let clock: any Clock<Duration>
    @ObservationIgnored let persist: (VaultSyncAppState) -> Void
    @ObservationIgnored var engine: (any SyncEngine)?
    @ObservationIgnored var databases: [UUID: VaultSyncDatabase] = [:]
    /// Profiles being erased: their folder is about to go, so their database is never opened again.
    @ObservationIgnored var erased: Set<UUID> = []
    @ObservationIgnored var chains: [VaultKey: Task<Void, Never>] = [:]
    @ObservationIgnored var debounced: [VaultKey: Task<Void, Never>] = [:]
    @ObservationIgnored var generation = 0
    /// Bumped whenever a vault is enabled, disabled or removed, so a step that waited for the host does not write for a vault that
    /// is no longer the one it started with.
    @ObservationIgnored var sessions: [VaultKey: Int] = [:]
    @ObservationIgnored var unlocked: Set<VaultKey> = []
    /// Vaults this run stopped syncing because a write of that decision failed, so nothing re-creates what the server removed.
    @ObservationIgnored var halted: Set<VaultKey> = []
    /// Vaults whose last fetched records were not all kept: a full read of the zone is still owed.
    @ObservationIgnored var incomplete: Set<VaultKey> = []
    /// Item records the engine asked for and has not answered: they are never resealed (spec: next version after the `.sent`).
    @ObservationIgnored var handedOut: [VaultKey: Set<UUID>] = [:]
    /// Cleartext sync bases and the parts of rows in the outbox; memory only, while the vault is unlocked.
    @ObservationIgnored var baseCache: [VaultKey: [UUID: SyncBase]] = [:]
    @ObservationIgnored var pendingBases: [VaultKey: [UUID: SyncBase]] = [:]
    /// Account id to the stamp a sum was computed for, and the sum (nil: the entry is not syncable).
    @ObservationIgnored var sumCache: [VaultKey: [UUID: StampedSum]] = [:]
    @ObservationIgnored var queued: [VaultKey: Set<UUID>] = [:]
    /// Vaults whose last pass held back this many removed states, and the vaults whose owner agreed to send them in the next pass.
    @ObservationIgnored var holding: [VaultKey: Int] = [:]
    @ObservationIgnored var releasing: Set<VaultKey> = []
    /// Checks that wait for the host and are not steps of a vault's chain; `settle` waits for them too.
    @ObservationIgnored var housekeeping: [Task<Void, Never>] = []
    @ObservationIgnored var tallies: [VaultKey: (notSyncable: Int, unreadable: Int)] = [:]

    nonisolated struct StampedSum {
        var stamp: AccountStamp
        var sum: Data?
    }

    public init(
        host: any VaultSyncHost,
        state: VaultSyncAppState,
        persist: @escaping (VaultSyncAppState) -> Void,
        excludedProfiles: Set<UUID>,
        debounce: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.host = host
        self.state = state
        self.persist = persist
        excluded = excludedProfiles
        self.debounce = debounce
        self.clock = clock
    }

    // MARK: - Engine

    /// Hands the engine everything this Mac still has to send: the sealed rows of every vault it syncs, and their `Vault` records.
    public func attach(_ engine: any SyncEngine) {
        self.engine = engine
        loadDatabases()
        for key in enabledKeys {
            retryAfterUpdate(key)
            oweReadOfParked(key)
            if needsFetch(key) {
                enqueue(key) { [weak self] in
                    try? await self?.fetchAllNow(key)
                }
            }
        }
        // What waits to go up is handed to the engine once rows of vaults that are gone are dropped.
        housekeeping.append(Task { [weak self] in
            await self?.pruneVanished()
            for key in self?.enabledKeys ?? [] {
                self?.readd(key)
            }
        })
        Task { [weak self] in
            let available = await engine.accountIsAvailable()
            self?.accountAvailable = available
        }
    }

    /// A vault that waited for a newer WSurf tries again at launch: this build may be the newer one. The next record that is still
    /// too new puts the notice back.
    private func retryAfterUpdate(_ key: VaultKey) {
        guard let (database, row) = enabledRow(key), row.status == .needsUpdate,
              (state.remote[key.zone]?.payload.keyGeneration ?? VaultSyncCodec.generation) == VaultSyncCodec.generation
        else { return }
        var next = row
        next.status = .active
        try? database.write { try $0.save(next) }
        refresh(key)
        enqueue(key) { [weak self] in
            await self?.cycle(key, fetch: false)
        }
    }

    /// Drops the rows of every vault the profile no longer lists, for every profile with a sync database.
    private func pruneVanished() async {
        for profileID in host.profileIDs() {
            await prune(profileID)
        }
    }

    /// A vault deleted while sync did not run left its rows, and a later pass would send them. The host’s list is trusted only when it
    /// has a vault in it: a profile always has one. Nothing in iCloud changes.
    func prune(_ profileID: UUID) async {
        guard let database = database(profileID), let listed = await host.vaultIDs(profileID: profileID), !listed.isEmpty else { return }
        for row in (try? database.read { try $0.vaults() }) ?? [] where !listed.contains(row.vaultID) {
            let key = VaultKey(profileID: profileID, vaultID: row.vaultID)
            try? database.write { try $0.remove(row.vaultID) }
            forget(key)
            summaries[key] = nil
        }
    }

    /// A record parked for a newer WSurf is read from the zone again at launch: this build may be the one that can read it.
    private func oweReadOfParked(_ key: VaultKey) {
        guard (summaries[key]?.parked ?? 0) > 0, let (database, row) = enabledRow(key), !row.needsFetch else { return }
        var next = row
        next.needsFetch = true
        try? database.write { try $0.save(next) }
        refresh(key)
    }

    /// Settles every step queued so far. A test waits on it; the app never needs to.
    public func settle() async {
        var seen: Int
        repeat {
            seen = generation
            let checks = housekeeping
            housekeeping = []
            for task in checks {
                await task.value
            }
            for task in Array(chains.values) {
                await task.value
            }
        } while seen != generation
    }

    // MARK: - What the interface shows

    public func status(profileID: UUID, vaultID: UUID) -> VaultSyncStatus {
        guard let summary = summaries[VaultKey(profileID: profileID, vaultID: vaultID)] else { return .off }
        guard summary.enabled else {
            switch summary.stored {
            case .removedDeleted:
                return .removed(.deleted)
            case .removedPurged:
                return .removed(.purged)
            case .removedEncryptedDataReset:
                return .removed(.encryptedDataReset)
            case .removalFailed:
                return .removalFailed
            case .accountChanged:
                return .accountChanged
            case .active, .iCloudFull, .needsUpdate, .rolledBack:
                return .off
            }
        }
        if summary.stored == .needsUpdate {
            return .needsUpdate
        }
        if summary.stored == .rolledBack {
            return .rolledBack
        }
        if accountAvailable == false {
            return .signedOut
        }
        if summary.stored == .iCloudFull {
            return .iCloudFull
        }
        if summary.review > 0 {
            return .needsReview(summary.review)
        }
        if summary.holding > 0 {
            return .holdingRemovals(summary.holding)
        }
        if !summary.isUnlocked, summary.inbox > 0 {
            return .waitingForUnlock(summary.inbox)
        }
        // Rows that arrived and are not applied yet count as work too, once the vault is unlocked.
        let waiting = summary.outbox + summary.inbox + (summary.hasPendingVault ? 1 : 0)
        if waiting > 0 || summary.isHeldBack || summary.isReading {
            return .sending(max(waiting, 1))
        }
        return .synced
    }

    /// Whether this Mac syncs the vault now (whatever its status), for the copy that warns before a deletion.
    public func isSyncing(profileID: UUID, vaultID: UUID) -> Bool {
        summaries[VaultKey(profileID: profileID, vaultID: vaultID)]?.enabled == true
    }

    public func hasSyncedVaults(profileID: UUID) -> Bool {
        summaries.contains { $0.key.profileID == profileID && $0.value.enabled }
    }

    /// Entries that stay on this Mac (too large, or only files), changes that could not be read this run, and entries a newer
    /// WSurf wrote that wait for an update.
    public func tally(profileID: UUID, vaultID: UUID) -> VaultSyncTally {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        return VaultSyncTally(
            notSyncable: summaries[key]?.notSyncable ?? 0, unreadable: summaries[key]?.unreadable ?? 0, newer: summaries[key]?.parked ?? 0
        )
    }

    /// The vaults other Macs synced for this profile; the interface leaves out the ones this Mac already holds.
    public func remoteVaults(profileID: UUID) -> [RemoteVault] {
        guard !excluded.contains(profileID) else { return [] }
        return state.remote.values.filter { $0.profileID == profileID }.sorted { $0.vaultID.uuidString < $1.vaultID.uuidString }
    }

    /// Profiles that have synced vaults and are not on this Mac.
    public func remoteProfiles() -> [(id: UUID, card: VaultProfileCard)] {
        let here = Set(host.profileIDs())
        var cards: [UUID: VaultProfileCard] = [:]
        for remote in state.remote.values.sorted(by: { $0.vaultID.uuidString < $1.vaultID.uuidString })
        where !here.contains(remote.profileID) && !excluded.contains(remote.profileID) {
            cards[remote.profileID] = cards[remote.profileID] ?? remote.payload.profile
        }
        return cards.map { (id: $0.key, card: $0.value) }.sorted { ($0.card.name, $0.id.uuidString) < ($1.card.name, $1.id.uuidString) }
    }

    // MARK: - Actions

    /// Turns sync on for an unlocked vault: creates its zone, or joins the zone another Mac made. The caller asks first when the vault
    /// was removed from iCloud or the account changed.
    public func enable(profileID: UUID, vaultID: UUID) async throws {
        let key = try checkedKey(profileID, vaultID)
        try await serial(key) { [self] in
            try await enableNow(key)
        }
    }

    /// This Mac stops syncing the vault. Its rows go; iCloud and the other Macs are untouched.
    public func disable(profileID: UUID, vaultID: UUID) {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        guard !excluded.contains(profileID) else { return }
        if let database = database(profileID) {
            try? database.write { try $0.remove(vaultID) }
        }
        forget(key)
        summaries[key] = nil
    }

    /// Deletes the vault's zone in iCloud. Every Mac keeps its copy.
    public func removeFromICloud(profileID: UUID, vaultID: UUID) {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        guard !excluded.contains(profileID) else { return }
        if retryRemoval(key) {
            return
        }
        deleteZone(key)
        state.remote[key.zone] = nil
        persist(state)
    }

    /// A removal that failed is asked for again, from the status that said so.
    private func retryRemoval(_ key: VaultKey) -> Bool {
        guard let database = database(key.profileID), var row = (try? database.read { try $0.vault(key.vaultID) }) ?? nil,
              !row.enabled, row.status == .removalFailed
        else { return false }
        row.status = .removedDeleted
        try? database.write { try $0.save(row) }
        engine?.add([.deleteZone(key.zone)])
        refresh(key)
        return true
    }

    /// The app added the vault from a `Vault` record: it syncs here now. It stays locked, so nothing is applied until the first unlock.
    public func adopted(profileID: UUID, vaultID: UUID) async {
        guard let key = try? checkedKey(profileID, vaultID) else { return }
        try? await serial(key) { [self] in
            guard let database = database(profileID, create: true) else { return }
            begin(key)
            try? database.write { tx in
                try tx.clear(vaultID)
                try tx.save(VaultRow(vaultID: vaultID, needsFetch: true))
            }
            refresh(key)
            try? await fetchAllNow(key)
        }
    }

    // MARK: - Hooks (each cheap when the vault is not synced here)

    /// A write reached the vault: produce after a quiet moment.
    public func noteWrite(profileID: UUID, vaultID: UUID) {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        guard summaries[key]?.enabled == true else { return }
        debounced[key]?.cancel()
        debounced[key] = Task { [weak self, clock, debounce] in
            do {
                try await clock.sleep(for: debounce)
            } catch {
                return
            }
            guard let self else { return }
            debounced[key] = nil
            enqueue(key) { [weak self] in
                await self?.produce(key)
            }
        }
    }

    public func vaultUnlocked(profileID: UUID, vaultID: UUID) {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        guard summaries[key]?.enabled == true else { return }
        unlocked.insert(key)
        refresh(key)
        housekeeping.append(Task { [weak self] in
            await self?.prune(profileID)
        })
        enqueue(key) { [weak self] in
            await self?.cycle(key, fetch: true)
        }
    }

    /// Drops what was kept in memory for the vault: the bases and sums are cleartext hashes and live only while it is unlocked.
    public func vaultLocked(profileID: UUID, vaultID: UUID) {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        unlocked.remove(key)
        baseCache[key] = nil
        pendingBases[key] = nil
        sumCache[key] = nil
        refresh(key)
    }

    /// The store removed the vault: its zone goes if this Mac synced it, and its rows go either way.
    public func vaultDeleted(profileID: UUID, vaultID: UUID) {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        guard !excluded.contains(profileID) else { return }
        if summaries[key]?.enabled == true {
            engine?.add([.deleteZone(key.zone)])
        }
        state.remote[key.zone] = nil
        persist(state)
        if let database = database(profileID) {
            try? database.write { try $0.remove(vaultID) }
        }
        forget(key)
        summaries[key] = nil
    }

    /// The profile is being erased: the zone of every vault this Mac synced goes, and its database closes.
    public func profileErased(_ profileID: UUID) {
        guard !excluded.contains(profileID) else { return }
        for key in summaries.keys where key.profileID == profileID {
            if summaries[key]?.enabled == true {
                engine?.add([.deleteZone(key.zone)])
            }
            state.remote[key.zone] = nil
            forget(key)
            summaries[key] = nil
        }
        persist(state)
        erased.insert(profileID)
        databases[profileID] = nil
    }

    /// The owner confirmed the deletions held back: the next pass sends them, and only that pass.
    public func releaseRemovals(profileID: UUID, vaultID: UUID) {
        let key = VaultKey(profileID: profileID, vaultID: vaultID)
        guard summaries[key]?.enabled == true, (holding[key] ?? 0) > 0 else { return }
        releasing.insert(key)
        enqueue(key) { [weak self] in
            await self?.produce(key)
        }
    }

    /// The heartbeat: re-add what is still waiting to go up, finish a read that did not, and fetch (once, for every vault).
    public func beat() {
        guard engine != nil else { return }
        let keys = enabledKeys
        for (position, key) in keys.enumerated() {
            readd(key)
            enqueue(key) { [weak self] in
                await self?.cycle(key, fetch: position == 0)
            }
        }
        if keys.isEmpty {
            Task { [weak self] in
                try? await self?.engine?.fetchNow()
            }
        }
    }

    // MARK: - SyncEngineDelegate

    public func record(for id: SyncRecordID) -> SyncRecord? {
        guard let ids = SyncZone.vaultIDs(id.zone), !excluded.contains(ids.profileID) else { return nil }
        let key = VaultKey(ids)
        guard let (database, row) = runningRow(key) else { return nil }
        let fields = (try? database.read { try $0.systemFields(key.vaultID, id.name) }) ?? nil
        if id.name == Self.vaultRecordName {
            guard let payload = row.pendingVault else { return nil }
            return SyncRecord(id: id, type: .vault, schema: 1, payload: payload, systemFields: fields)
        }
        guard let account = Self.accountID(id.name),
              let outgoing = (try? database.read { try $0.outbox(key.vaultID, account) }) ?? nil
        else { return nil }
        // A record from another Mac that is fetched and not yet merged is as new as this row or newer, and one parked for a newer WSurf
        // is of a version nobody here can tell: sending over either would overwrite it. The row waits; the merge decides.
        if let waiting = (try? database.read { try $0.inboxVersion(key.vaultID, account) }) ?? nil,
           waiting == 0 || waiting >= outgoing.version {
            return nil
        }
        handedOut[key, default: []].insert(account)
        return SyncRecord(id: id, type: .item, schema: 1, payload: outgoing.envelope, systemFields: fields)
    }

    public func handle(_ event: SyncEvent) async {
        switch event {
        case .state:
            return
        case .account(let change):
            applyAccount(change)
        case .zonesDeleted(let zones):
            for zone in zones.keys.sorted() {
                if let reason = zones[zone] {
                    zoneRemoved(zone, reason: reason)
                }
            }
        case .fetched(let modified, let deleted):
            applyFetched(modified: modified, deleted: deleted)
        case .sent(let saved, let deleted, let failed):
            applySent(saved: saved, deleted: deleted, failed: failed)
        case .zoneDeletesFailed(let zones):
            for zone in zones.sorted() {
                zoneDeleteFailed(zone)
            }
        }
        persist(state)
    }

    // MARK: - Helpers shared by the steps

    static func accountID(_ name: String) -> UUID? {
        UUID(uuidString: name).flatMap { $0.uuidString == name ? $0 : nil }
    }

    func checkedKey(_ profileID: UUID, _ vaultID: UUID) throws -> VaultKey {
        guard !excluded.contains(profileID) else { throw VaultSyncFailure.unavailable }
        return VaultKey(profileID: profileID, vaultID: vaultID)
    }

    /// The profile's database. It is created only when `create` is set; a database that cannot be opened is no database.
    func database(_ profileID: UUID, create: Bool = false) -> VaultSyncDatabase? {
        guard !excluded.contains(profileID), !erased.contains(profileID) else { return nil }
        if let existing = databases[profileID] {
            return existing
        }
        guard let directory = host.syncDirectory(profileID: profileID) else { return nil }
        do {
            guard let opened = try VaultSyncDatabase.open(directory: directory, create: create) else { return nil }
            databases[profileID] = opened
            return opened
        } catch {
            SyncLog.logger.error("sync: a vault sync database could not be opened")
            return nil
        }
    }

    func loadDatabases() {
        for profileID in host.profileIDs() {
            guard let database = database(profileID), let rows = try? database.read({ try $0.vaults() }) else { continue }
            for row in rows {
                refresh(VaultKey(profileID: profileID, vaultID: row.vaultID))
            }
        }
    }

    var enabledKeys: [VaultKey] {
        summaries.filter { $0.value.enabled }.keys.sorted { ($0.profileID.uuidString, $0.vaultID.uuidString) < ($1.profileID.uuidString, $1.vaultID.uuidString) }
    }

    func needsFetch(_ key: VaultKey) -> Bool {
        guard let database = database(key.profileID), let row = try? database.read({ try $0.vault(key.vaultID) }) else { return false }
        return row.enabled && row.needsFetch
    }

    /// The vault's row while this Mac syncs it, whatever its status.
    func enabledRow(_ key: VaultKey) -> (VaultSyncDatabase, VaultRow)? {
        guard !halted.contains(key), let database = database(key.profileID),
              let row = (try? database.read { try $0.vault(key.vaultID) }) ?? nil, row.enabled
        else { return nil }
        return (database, row)
    }

    /// The vault's row while this Mac syncs it and nothing stops it: not for a newer WSurf's records or a restored store.
    func runningRow(_ key: VaultKey) -> (VaultSyncDatabase, VaultRow)? {
        guard let (database, row) = enabledRow(key), row.status == .active || row.status == .iCloudFull else { return nil }
        return (database, row)
    }

    func token(_ key: VaultKey) -> Int {
        sessions[key] ?? 0
    }

    /// A new enablement of the vault: steps still running for the old one stop before they write.
    @discardableResult
    func begin(_ key: VaultKey) -> Int {
        sessions[key, default: 0] += 1
        halted.remove(key)
        return sessions[key] ?? 0
    }

    /// Everything in memory for the vault goes, and steps still running for it stop before they write.
    func forget(_ key: VaultKey) {
        sessions[key, default: 0] += 1
        debounced[key]?.cancel()
        debounced[key] = nil
        unlocked.remove(key)
        halted.remove(key)
        handedOut[key] = nil
        baseCache[key] = nil
        pendingBases[key] = nil
        sumCache[key] = nil
        queued[key] = nil
        tallies[key] = nil
        holding[key] = nil
        releasing.remove(key)
    }

    func refreshAll() {
        for key in Array(summaries.keys) {
            refresh(key)
        }
    }

    /// Rebuilds the vault's observed summary from its rows.
    func refresh(_ key: VaultKey) {
        guard let database = database(key.profileID), let loaded = try? database.read({ try $0.summary(key.vaultID) }) else {
            summaries[key] = nil
            return
        }
        let (row, counts) = loaded
        let tally = tallies[key] ?? (0, 0)
        let next = VaultSyncSummary(
            enabled: row.enabled, stored: row.status, outbox: counts.outbox, inbox: counts.inbox, review: counts.review,
            hasPendingVault: row.pendingVault != nil, isHeldBack: row.dirty, isReading: row.needsFetch,
            isUnlocked: unlocked.contains(key), notSyncable: tally.notSyncable, unreadable: tally.unreadable, parked: counts.parked,
            holding: holding[key] ?? 0
        )
        if summaries[key] != next {
            summaries[key] = next
        }
    }

    // MARK: - The vault's serial chain

    @discardableResult
    func enqueue(_ key: VaultKey, _ work: @escaping () async -> Void) -> Task<Void, Never> {
        generation += 1
        let previous = chains[key]
        let task = Task {
            await previous?.value
            await work()
        }
        chains[key] = task
        return task
    }

    func serial<T: Sendable>(_ key: VaultKey, _ work: @escaping () async throws -> T) async throws -> T {
        generation += 1
        let previous = chains[key]
        let task = Task { () async throws -> T in
            await previous?.value
            return try await work()
        }
        chains[key] = Task {
            _ = await task.result
        }
        return try await task.value
    }

    /// What one pass over a vault does: read the zone again when it has to, take in what arrived, send what changed.
    func cycle(_ key: VaultKey, fetch: Bool) async {
        guard await storeIsCurrent(key) else { return }
        if fetch {
            try? await engine?.fetchNow()
        }
        try? await fetchAllNow(key)
        await drain(key)
        await produce(key)
    }

    /// The first step of a pass: a store that is older than the last state this Mac synced from it (a restored backup) reads nothing
    /// from iCloud and sends nothing. A vault that cannot be read now is not judged; the passes that read it judge it.
    private func storeIsCurrent(_ key: VaultKey) async -> Bool {
        let mine = token(key)
        guard let (database, _) = runningRow(key), unlocked.contains(key), let snapshot = await snapshot(key) else { return true }
        guard mine == token(key), let (_, row) = runningRow(key) else { return false }
        return notRolledBack(key, snapshot, row, database)
    }

    /// Asks the engine to send everything the vault still has waiting.
    func readd(_ key: VaultKey) {
        guard let engine, let (database, row) = runningRow(key) else { return }
        let waiting = (try? database.read { try $0.outbox(key.vaultID).map(\.accountID) }) ?? []
        // Never a zone: only turning sync on creates one. A zone another Mac removed must not come back because this Mac signed in again.
        var changes: [SyncChange] = []
        if row.pendingVault != nil {
            changes.append(.saveRecord(key.vaultRecord))
        }
        changes += waiting.map { .saveRecord(key.itemRecord($0)) }
        queued[key] = Set(waiting)
        if !changes.isEmpty {
            engine.add(changes)
        }
    }
}
