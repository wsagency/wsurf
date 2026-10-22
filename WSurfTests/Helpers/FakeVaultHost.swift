// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import WSurfCore

@testable import WSurfVault

/// Synthetic accounts for the vault sync suites. Nothing here is a real credential.
nonisolated enum SyncVaultFixtures {
    static func account(
        id: UUID = UUID(), username: String = "ada", password: String? = "secret", origin: String = "https://example.test",
        notes: [String] = []
    ) -> CredentialAccount {
        var account = CredentialAccount(
            id: id, username: username, displayName: nil, origins: [origin], loginURLs: [URL(string: origin + "/login")!],
            password: password, passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        account.notes = notes.isEmpty ? nil : notes.map { CredentialNote(text: $0) }
        return account
    }

    static func proof(_ n: UInt8) -> VaultUnlockProof {
        VaultUnlockProof(credentialID: Data(repeating: n, count: 32), prfInput: Data(repeating: n &+ 1, count: 32), prf: SymmetricKey(size: .bits256))
    }

    static func wrappers(_ dek: SymmetricKey, profile: UUID, vault: UUID, passkeys: [UInt8] = [1]) throws -> [CredentialKeyWrapper] {
        try passkeys.map { try CredentialVaultCrypto.wrap(dek, with: proof($0), profileID: profile, vaultID: vault) }
    }
}

/// One vault as a Mac holds it, in memory: the live accounts with stamps, the Trash and tombstones that feed `RemovedIdentifiers`, the
/// History a commit leaves, a lock and a lease. It keeps the rules of the real store that sync relies on: a write carries the stamp it
/// read (`staleRevision`), an exchange identity is unique (`duplicateIdentifier`), a removal moves the whole account to Trash.
@MainActor
final class FakeVault {
    struct Revision {
        let account: CredentialAccount
        let cause: String?
    }

    let profileID: UUID
    let vaultID: UUID
    var name: String
    let dek: SymmetricKey
    var wrappers: [CredentialKeyWrapper]
    private(set) var accounts: [UUID: CredentialAccount] = [:]
    private(set) var trash: [UUID: CredentialAccount] = [:]
    private(set) var tombstones: Set<UUID> = []
    /// What each tombstone kept of the entry it stands for: keyed digests, as the store keeps them. An old tombstone has none.
    private(set) var tombstoneTraces: [UUID: ImportTrace] = [:]
    private(set) var history: [UUID: [Revision]] = [:]
    private(set) var isLocked = true
    private(set) var lease: UInt64 = 0
    private(set) var commitCount = 0
    private(set) var attempts: [[UUID]] = []
    var revision: UInt64 = 1
    /// Thrown by the next commits until cleared.
    var commitFailure: (any Error)?
    private var stampVersions: [UUID: UInt64] = [:]

    init(profileID: UUID, vaultID: UUID, name: String, dek: SymmetricKey, wrappers: [CredentialKeyWrapper]) {
        self.profileID = profileID
        self.vaultID = vaultID
        self.name = name
        self.dek = dek
        self.wrappers = wrappers
    }

    var syncKey: VaultSyncKey {
        VaultSyncKey.derive(dek: dek, profileID: profileID, vaultID: vaultID)
    }

    func stamp(_ id: UUID) -> AccountStamp? {
        guard let account = accounts[id] else { return nil }
        let digest = Data(SHA256.hash(data: (try? CredentialContent.canonicalJSON(account)) ?? Data()))
        return AccountStamp(version: stampVersions[id] ?? 1, digest: digest)
    }

    func unlock() {
        isLocked = false
        lease += 1
    }

    func lock() {
        isLocked = true
        lease += 1
    }

    // MARK: What the person does

    func add(_ account: CredentialAccount) {
        accounts[account.id] = account
        stampVersions[account.id, default: 0] += 1
        revision += 1
    }

    /// A local edit: the old value is kept in History, as the real store keeps a revision.
    func edit(_ account: CredentialAccount, cause: String? = nil) {
        if let old = accounts[account.id] {
            history[account.id, default: []].append(Revision(account: old, cause: cause))
        }
        add(account)
    }

    func remove(_ id: UUID) {
        guard let old = accounts.removeValue(forKey: id) else { return }
        trash[id] = old
        revision += 1
    }

    /// The Trash entry comes back as a live entry: a deliberate change.
    func restore(_ id: UUID) {
        guard let old = trash.removeValue(forKey: id) else { return }
        add(old)
    }

    /// Emptying the Trash entry: nothing live changes, and a tombstone remains.
    func purge(_ id: UUID) {
        guard let old = trash.removeValue(forKey: id) else { return }
        tombstones.insert(id)
        tombstoneTraces[id] = memory.removedTrace(of: old)
        revision += 1
    }

    /// A tombstone from before imports kept digests: it knows the ID and nothing else.
    func addOldTombstone(_ id: UUID) {
        tombstones.insert(id)
    }

    /// The vault's import memory key, derived as the store does: from the vault key, bound to the profile and the vault.
    private var memory: ImportMemoryKey {
        ImportMemoryKey.derive(dek: dek, profileID: profileID, vaultID: vaultID)
    }

    func account(_ id: UUID) -> CredentialAccount? {
        accounts[id]
    }

    // MARK: What the sync host asks

    func snapshot() throws -> VaultSyncSnapshot {
        guard !isLocked else { throw CredentialVaultError.unauthorized }
        let live = accounts.values.sorted { $0.id.uuidString < $1.id.uuidString }
        var stamps: [UUID: AccountStamp] = [:]
        for account in live {
            stamps[account.id] = stamp(account.id)
        }
        let removed = trash.values.map { removed($0) } + tombstones.map { removed(id: $0) }
        return VaultSyncSnapshot(
            lease: lease, revision: revision, accounts: live, stamps: stamps, removed: RemovedIdentifiers(items: removed), name: name,
            wrappers: wrappers
        )
    }

    /// A Trash entry's row: the ids and what the entry stood for, as the store reads them from the entry.
    private func removed(_ account: CredentialAccount) -> RemovedIdentifier {
        RemovedIdentifier(
            entryID: UUID(), isTombstone: false, accountID: account.id, exchangeAccountID: account.exchangeAccountID,
            exchangeItemID: account.exchangeItemID, passkeyCredentialID: nil, rpID: nil, removedAt: nil,
            trace: memory.removedTrace(of: account)
        )
    }

    /// A tombstone's row: the ID and the digests it kept, if it kept any.
    private func removed(id: UUID) -> RemovedIdentifier {
        RemovedIdentifier(
            entryID: UUID(), isTombstone: true, accountID: id, exchangeAccountID: nil, exchangeItemID: nil, passkeyCredentialID: nil,
            rpID: nil, removedAt: nil, trace: tombstoneTraces[id]
        )
    }

    /// Tombstones for entries removed elsewhere that this vault never held, as the real store keeps them.
    func remember(lease: UInt64, traces: [UUID: ImportTrace]) throws -> UInt64 {
        guard !isLocked, lease == self.lease else { throw CredentialVaultError.expired }
        tombstones.formUnion(traces.keys)
        tombstoneTraces.merge(traces) { _, new in new }
        revision += 1
        return revision
    }

    func commit(lease: UInt64, writes: [AccountWrite], removing: [UUID: AccountStamp]) throws -> UInt64 {
        attempts.append(writes.map(\.accountID) + removing.keys.sorted { $0.uuidString < $1.uuidString })
        guard !isLocked, lease == self.lease else { throw CredentialVaultError.expired }
        if let commitFailure {
            throw commitFailure
        }
        for (id, stamp) in removing {
            guard self.stamp(id) == stamp else { throw CredentialVaultError.staleRevision }
        }
        var next = accounts
        for write in writes {
            switch write.expected {
            case .stamp(let stamp):
                guard self.stamp(write.accountID) == stamp else { throw CredentialVaultError.staleRevision }
            case .absent:
                guard accounts[write.accountID] == nil else { throw CredentialVaultError.staleRevision }
            }
            do {
                try write.replacement.validate()
            } catch {
                throw CredentialVaultError.invalidData
            }
            next[write.accountID] = write.replacement
        }
        for id in removing.keys {
            next[id] = nil
        }
        var seen = Set<Data>()
        for account in next.values {
            if let accountID = account.exchangeAccountID, let itemID = account.exchangeItemID, !seen.insert(accountID + itemID).inserted {
                throw CredentialVaultError.duplicateIdentifier
            }
        }
        for write in writes {
            if let old = accounts[write.accountID] {
                history[write.accountID, default: []].append(Revision(account: old, cause: CredentialChangeCause.sync))
            }
            stampVersions[write.accountID, default: 0] += 1
        }
        for id in removing.keys {
            if let old = accounts[id] {
                trash[id] = old
                history[id, default: []].append(Revision(account: old, cause: CredentialChangeCause.sync))
            }
        }
        accounts = next
        commitCount += 1
        revision += 1
        return revision
    }
}

/// A pause in the host: the next `snapshot` reads the vault, then waits here before it hands the snapshot back. A test locks the vault
/// or changes it meanwhile, as the real host’s awaits let other work run.
@MainActor
final class HostPause {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func release() {
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

/// The macOS app's side of `VaultSync`, in memory: profiles with a folder each, and their vaults.
@MainActor
final class FakeVaultHost: VaultSyncHost {
    private struct Slot: Hashable {
        let profileID: UUID
        let vaultID: UUID
    }

    let root: URL
    private(set) var directories: [UUID: URL] = [:]
    private(set) var cards: [UUID: VaultProfileCard] = [:]
    private var vaults: [Slot: FakeVault] = [:]
    /// Held once by the next `snapshot`, after it read the vault.
    var pauseAfterSnapshot: HostPause?
    /// How many times the vault was read in full, by any vault of this Mac.
    private(set) var snapshotCount = 0
    /// The next reads of a vault fail, as a read can, while the vault stays unlocked.
    var failSnapshots = 0
    /// The profile’s vaults cannot be listed.
    var listingUnavailable = false

    init(root: URL) {
        self.root = root
    }

    /// A profile on this Mac. Its folder is named by the profile ID, as the app names it.
    @discardableResult
    func addProfile(_ id: UUID, name: String = "Personal") -> URL {
        let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        directories[id] = directory
        cards[id] = VaultProfileCard(name: name, symbol: "person", color: "gray")
        return directory
    }

    @discardableResult
    func addVault(
        profile: UUID, vault: UUID = UUID(), name: String = "Personal", dek: SymmetricKey = SymmetricKey(size: .bits256),
        passkeys: [UInt8] = [1], unlocked: Bool = true
    ) throws -> FakeVault {
        if directories[profile] == nil {
            addProfile(profile)
        }
        let created = FakeVault(
            profileID: profile, vaultID: vault, name: name, dek: dek,
            wrappers: try SyncVaultFixtures.wrappers(dek, profile: profile, vault: vault, passkeys: passkeys)
        )
        vaults[Slot(profileID: profile, vaultID: vault)] = created
        if unlocked {
            created.unlock()
        }
        return created
    }

    func removeVault(profile: UUID, vault: UUID) {
        vaults[Slot(profileID: profile, vaultID: vault)] = nil
    }

    func vault(profile: UUID, vault: UUID) -> FakeVault? {
        vaults[Slot(profileID: profile, vaultID: vault)]
    }

    // MARK: VaultSyncHost

    func profileIDs() -> [UUID] {
        directories.keys.sorted { $0.uuidString < $1.uuidString }
    }

    func syncDirectory(profileID: UUID) -> URL? {
        directories[profileID]
    }

    func profileCard(profileID: UUID) -> VaultProfileCard? {
        cards[profileID]
    }

    func syncKey(profileID: UUID, vaultID: UUID) async -> VaultSyncKey? {
        guard let vault = vault(profile: profileID, vault: vaultID), !vault.isLocked else { return nil }
        return vault.syncKey
    }

    func snapshot(profileID: UUID, vaultID: UUID) async throws -> VaultSyncSnapshot {
        guard let vault = vault(profile: profileID, vault: vaultID) else { throw CredentialVaultError.missingVault }
        if failSnapshots > 0 {
            failSnapshots -= 1
            throw CredentialVaultError.expired
        }
        let snapshot = try vault.snapshot()
        snapshotCount += 1
        if let pause = pauseAfterSnapshot {
            pauseAfterSnapshot = nil
            await pause.wait()
        }
        return snapshot
    }

    /// The vaults the profile still lists, locked or not.
    func vaultIDs(profileID: UUID) async -> [UUID]? {
        guard !listingUnavailable else { return nil }
        return vaults.keys.filter { $0.profileID == profileID }.map(\.vaultID).sorted { $0.uuidString < $1.uuidString }
    }

    func commit(profileID: UUID, vaultID: UUID, lease: UInt64, writes: [AccountWrite], removing: [UUID: AccountStamp]) async throws -> UInt64 {
        guard let vault = vault(profile: profileID, vault: vaultID) else { throw CredentialVaultError.missingVault }
        return try vault.commit(lease: lease, writes: writes, removing: removing)
    }

    func remember(profileID: UUID, vaultID: UUID, lease: UInt64, traces: [UUID: ImportTrace]) async throws -> UInt64 {
        guard let vault = vault(profile: profileID, vault: vaultID) else { throw CredentialVaultError.missingVault }
        return try vault.remember(lease: lease, traces: traces)
    }
}

/// One simulated Mac: a host, a `VaultSync` and an engine over the shared fake cloud.
@MainActor
final class SimulatedMac {
    let host: FakeVaultHost
    let sync: VaultSync
    let engine: FakeSyncEngine
    let clock = TestClock()
    /// What the app would have written to its file after the last change.
    private(set) var savedState: VaultSyncAppState?

    private final class Box {
        var state: VaultSyncAppState?
    }

    private let box = Box()

    /// `knownAccount`: the app’s file already names the account the engine is signed in with, as it does after the first run.
    init(
        cloud: FakeSyncCloud, root: URL, excluded: Set<UUID> = [], state: VaultSyncAppState = VaultSyncAppState(), knownAccount: Bool = true
    ) {
        host = FakeVaultHost(root: root)
        let box = box
        var state = state
        if knownAccount, state.accountUser == nil {
            state.accountUser = cloud.user
        }
        sync = VaultSync(host: host, state: state, persist: { box.state = $0 }, excludedProfiles: excluded, debounce: .seconds(2), clock: clock)
        engine = FakeSyncEngine(cloud: cloud, delegate: sync)
    }

    var persisted: VaultSyncAppState? {
        box.state
    }

    func start() {
        sync.attach(engine)
    }

    /// The vault is unlocked: the manager's hook runs, and sync takes in what waits and sends what changed.
    func unlock(_ vault: FakeVault) async {
        vault.unlock()
        sync.vaultUnlocked(profileID: vault.profileID, vaultID: vault.vaultID)
        await sync.settle()
    }

    func lock(_ vault: FakeVault) {
        vault.lock()
        sync.vaultLocked(profileID: vault.profileID, vaultID: vault.vaultID)
    }

    /// Runs the queued work and the sends it causes until nothing more happens.
    func pump(rounds: Int = 6) async throws {
        for _ in 0..<rounds {
            await sync.settle()
            try await engine.sendNow()
            await sync.settle()
        }
    }

    /// A local write reached the vault: the debounce passes and produce runs. `timer: false` for a vault that is not synced here,
    /// where no debounce starts.
    func wrote(_ vault: FakeVault, timer: Bool = true) async {
        sync.noteWrite(profileID: vault.profileID, vaultID: vault.vaultID)
        if timer {
            _ = await waitUntil { clock.pendingCount > 0 }
            clock.advance(by: .seconds(2))
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        await sync.settle()
    }
}

/// Runs the Macs against each other until the cloud and every Mac stop changing.
@MainActor
func converge(_ macs: [SimulatedMac], rounds: Int = 6) async throws {
    for _ in 0..<rounds {
        for mac in macs {
            try await mac.pump(rounds: 2)
            try await mac.engine.fetchNow()
            await mac.sync.settle()
        }
    }
    for mac in macs {
        try await mac.pump(rounds: 2)
    }
}
