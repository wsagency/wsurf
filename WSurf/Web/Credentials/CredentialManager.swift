// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Synchronization

nonisolated enum CredentialLockReason: Sendable {
    case manual, profileSwitch, screenLock, sleep, termination, timeout
}

nonisolated struct UnconfirmedPasskey: Identifiable, Equatable, Sendable {
    let id: UUID
    let rpID: String
    let userName: String
    let revision: UInt64
}

nonisolated enum CredentialManagerError: Error {
    /// Native registration succeeded but setup or the vault write did not. The external passkey still
    /// exists; it is never deleted automatically.
    case externalPasskeyRemains(credentialID: Data, underlying: any Error)
    /// App cancellation arrived after registration started, so the provider may have created a passkey.
    case registrationOutcomeUnknown
}

/// The native passkey calls a manager (or a vault creation) makes, as closures so a test drives the real manager with a stub.
/// `.native` is the only production value.
struct VaultNativeUnlock {
    var register: (ASPresentationAnchor) async throws -> VaultUnlockRegistration
    var verifyRegistration: (VaultUnlockRegistration, ASPresentationAnchor, () throws -> Void) async throws -> VaultUnlockProof
    var assert: ([VaultUnlock], ASPresentationAnchor) async throws -> VaultUnlockProof
    var cancel: () -> Void

    static func native(_ unlocker: PasskeyVaultUnlocker) -> VaultNativeUnlock {
        VaultNativeUnlock(
            register: { try await unlocker.register(in: $0) },
            verifyRegistration: { try await unlocker.verifyRegistration($0, in: $1, beforeAssertion: $2) },
            assert: { try await unlocker.assert(among: $0, in: $1) },
            cancel: { unlocker.cancel() }
        )
    }
}

enum NewVaultChoice {
    /// A new WSurf passkey. `authorizedBy` is the unlocked vault that authorizes it; `nil` creates the profile's first vault.
    case newPasskey(authorizedBy: CredentialManager?)
    /// An enrolled passkey of another vault, asserted again for this creation.
    case existing(sourceVaultID: UUID, credentialID: Data, prfInput: Data)
}

/// Counts the unlocks and locks of each profile's vault managers, in memory only. A vault's name is listed only while that vault is
/// unlocked, so a page that lists a profile's vaults reads the list again whenever its count changes, including for a vault it has
/// not selected. Observing it fires for any profile; a reader compares only its own profile's count.
@MainActor
@Observable
final class VaultStateChanges {
    static let shared = VaultStateChanges()
    private var counts: [UUID: UInt64] = [:]

    func count(for profileID: UUID) -> UInt64 {
        counts[profileID, default: 0]
    }

    fileprivate func note(_ profileID: UUID) {
        counts[profileID, default: 0] &+= 1
    }
}

/// Per-vault unlock state: one manager per (profile, vault). Every await re-checks the captured `VaultAccess` *before* a durable
/// mutation; nothing throws after a committed mutation, so a receipt always reflects what is on disk.
@MainActor
@Observable
final class CredentialManager {
    var isUnlocked: Bool {
        authorizationEpoch != nil
    }
    var authorizationEpoch: UInt64? {
        guard let current, current.isAuthorized(at: now()) else { return nil }
        return current.epoch
    }
    /// Identifies the vault content a read may rely on: `nil` while any write is in flight or no access is current,
    /// otherwise a value that differs after every write that started or ended since it was read. It says nothing about
    /// authorization: callers pair it with the `authorizationEpoch` they captured, and it is a plain stored-state read
    /// so it is safe on the main actor at any time.
    var stableGeneration: UInt64? {
        writesInFlight == 0 && current != nil ? writeGeneration : nil
    }
    private(set) var unlockCredentials: [VaultUnlock] = []
    private(set) var lastLockReason: CredentialLockReason?
    /// How long this vault's next unlock lasts. The lease in force keeps the length it began with, except that a shorter choice
    /// applies to it at once (`setAutoLock`).
    private(set) var autoLock: CredentialAutoLock
    /// Registrations saved to the vault whose delivery to the website could not be confirmed (page closed, navigated or
    /// locked after the commit, or the outcome is unknown). Memory only and bounded: a restart forgets them, and nothing
    /// here is a secret. Settings shows the details only while unlocked.
    private(set) var unconfirmedPasskeys: [UnconfirmedPasskey] = []
    /// Scratch files the last unlock could not remove. Reported by the store for every unlock surface, cleared when the next
    /// unlock starts, and never part of an unlock's outcome.
    private(set) var scratchCleanupWarnings: [URL] = []

    func noteUnconfirmedPasskey(rpID: String, userName: String, revision: UInt64) {
        guard !isRetired else { return }
        unconfirmedPasskeys.append(UnconfirmedPasskey(id: UUID(), rpID: rpID, userName: userName, revision: revision))
        if unconfirmedPasskeys.count > 16 {
            unconfirmedPasskeys.removeFirst(unconfirmedPasskeys.count - 16)
        }
    }

    func dismissUnconfirmedPasskeys() {
        unconfirmedPasskeys.removeAll()
    }

    /// The profile whose vault this manager guards; lets a caller prove a request and manager belong together.
    var profileID: UUID {
        profile.id
    }

    let vaultID: UUID
    @ObservationIgnored private let profile: Profile
    @ObservationIgnored private let store: ProfileVaultStore
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private let native: VaultNativeUnlock
    @ObservationIgnored private var pending: [VaultAccess] = []
    private var current: VaultAccess?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// When the current lease began, which is when the unlock completed. A shorter choice counts from here.
    @ObservationIgnored private var leaseStart: ContinuousClock.Instant?
    @ObservationIgnored private var isRetired = false
    /// Counts vault writes between their start and their end, and changes whenever one starts or ends.
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var writeGeneration: UInt64 = 0
    /// Bumped by every unlock start and every lock: a scratch report is published only by the unlock that still owns it.
    @ObservationIgnored private var unlockGeneration: UInt64 = 0

    init(
        profile: Profile,
        vaultID: UUID,
        store: ProfileVaultStore,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        native: VaultNativeUnlock? = nil
    ) {
        self.profile = profile
        self.vaultID = vaultID
        self.store = store
        self.now = now
        self.native = native ?? .native(PasskeyVaultUnlocker())
        autoLock = CredentialAutoLock.stored(for: vaultID, in: ProfileSettingsStore.defaults(for: profile))
    }

    // MARK: - Registry

    /// A vault creation in flight: the lease it owns (nil when the source vault's own access authorizes it) and its native
    /// prompt, so a profile-level lock revokes the lease and cancels the prompt.
    private final class Creation {
        let lease: VaultAccess?
        let native: VaultNativeUnlock

        init(lease: VaultAccess?, native: VaultNativeUnlock) {
            self.lease = lease
            self.native = native
        }
    }

    private static var managers: [UUID: [UUID: CredentialManager]] = [:]
    private static var stores: [UUID: ProfileVaultStore] = [:]
    private static var creations: [UUID: [Creation]] = [:]
    private static var retiredProfiles: Set<UUID> = []
    private static var observers: [any NSObjectProtocol] = []
    /// One counter for every manager and creation in the process: an epoch handed to a consumer as a bare number names exactly
    /// one lease, so vault A's epoch can never select vault B's manager. Never reset before the process ends.
    private static var lastEpoch: UInt64 = 0

    private static func nextEpoch() -> UInt64 {
        lastEpoch += 1
        return lastEpoch
    }

    /// The profile's one store. Private browsing has no vault.
    static func store(for profile: Profile) throws -> ProfileVaultStore {
        guard !retiredProfiles.contains(profile.id) else { throw CredentialVaultError.unauthorized }
        guard profile.id != Profile.privateID else { throw CredentialVaultError.privateBrowsing }
        if let existing = stores[profile.id] {
            return existing
        }
        // UserDefaults is documented thread-safe; the SDK does not always mark it Sendable.
        nonisolated(unsafe) let defaults = ProfileSettingsStore.defaults(for: profile)
        let store = ProfileVaultStore(profileID: profile.id, directory: profile.supportDirectory, defaults: defaults)
        stores[profile.id] = store
        installObserversOnce()
        return store
    }

    /// `native` applies only when this call registers the manager (nil: the real passkey prompt); tests inject a stub.
    static func forVault(_ profile: Profile, vaultID: UUID, native: VaultNativeUnlock? = nil) throws -> CredentialManager {
        let store = try store(for: profile)
        if let existing = managers[profile.id]?[vaultID] {
            return existing
        }
        let manager = CredentialManager(profile: profile, vaultID: vaultID, store: store, native: native)
        managers[profile.id, default: [:]][vaultID] = manager
        return manager
    }

    /// The profile's managers whose lease is live, in a stable order.
    static func unlockedManagers(for profile: Profile) -> [CredentialManager] {
        (managers[profile.id]?.values.filter(\.isUnlocked) ?? []).sorted { $0.vaultID.uuidString < $1.vaultID.uuidString }
    }

    /// `selected` if it is unlocked and listed, else the lowest-numbered listed vault that is unlocked.
    static func unlockedAuthorizer(in listing: [VaultListing], selected: CredentialManager?, profile: Profile) -> CredentialManager? {
        if let selected, selected.isUnlocked, listing.contains(where: { $0.vaultID == selected.vaultID }) {
            return selected
        }
        let open = unlockedManagers(for: profile)
        return listing.sorted { $0.ordinal < $1.ordinal }.lazy.compactMap { vault in open.first { $0.vaultID == vault.vaultID } }.first
    }

    /// Locks every live manager and stops every vault creation, for events that affect the whole session (sleep, screen lock,
    /// termination).
    static func lockAll(reason: CredentialLockReason) {
        for profileID in Set(stores.keys).union(managers.keys).union(creations.keys) {
            lock(profileID: profileID, reason: reason)
        }
    }

    /// Locks one profile's vault managers, creations and ceremonies, and withdraws its pending autofill vault choices. A profile
    /// switch locks the profile being left, before its first suspension, and leaves other profiles alone.
    static func lock(profileID: UUID, reason: CredentialLockReason) {
        for manager in managers[profileID]?.values.map({ $0 }) ?? [] {
            manager.lock(reason: reason)
        }
        revokeCreations(profileID)
        WebAuthnAdapter.cancel(profileID: profileID)
        AutofillSaveCoordinator.shared.vaultAccessEnded(profileID: profileID)
    }

    private static func revokeCreations(_ profileID: UUID) {
        for creation in creations[profileID] ?? [] {
            creation.lease?.revoke()
            creation.native.cancel()
        }
    }

    /// Profile erasure: unregister, revoke every lease and creation, then drain the store before the caller deletes the directory.
    static func retire(profileID: UUID) async {
        retiredProfiles.insert(profileID)
        let retiring = managers.removeValue(forKey: profileID)?.values.map { $0 } ?? []
        for manager in retiring {
            manager.isRetired = true
            manager.lock(reason: .profileSwitch)
        }
        revokeCreations(profileID)
        WebAuthnAdapter.cancel(profileID: profileID)
        AutofillSaveCoordinator.shared.vaultAccessEnded(profileID: profileID)
        await stores.removeValue(forKey: profileID)?.close()
    }

    /// Creates a vault and returns its id. The new vault stays locked: no grant is published for it.
    static func createVault(
        profile: Profile,
        name: String,
        choice: NewVaultChoice,
        in anchor: ASPresentationAnchor,
        native: VaultNativeUnlock? = nil
    ) async throws -> UUID {
        let store = try store(for: profile)
        var source: CredentialManager?
        if case .newPasskey(let authorizedBy) = choice {
            source = authorizedBy
        }
        if let source, source.profileID != profile.id || source.isRetired {
            throw CredentialVaultError.unauthorized
        }
        let seam = native ?? source?.native ?? .native(PasskeyVaultUnlocker())
        let lease = try source?.currentAccess()
            ?? VaultAccess(profileID: profile.id, epoch: nextEpoch(), deadline: store.now().advanced(by: .seconds(300)))
        let creation = Creation(lease: source == nil ? lease : nil, native: seam)
        creations[profile.id, default: []].append(creation)
        defer { creations[profile.id]?.removeAll { $0 === creation } }
        func requireLease() throws {
            guard !retiredProfiles.contains(profile.id) else { throw CredentialVaultError.unauthorized }
            try lease.checkAuthorization(at: store.now())
        }

        try requireLease()
        switch choice {
        case .newPasskey:
            let registration: VaultUnlockRegistration
            do {
                registration = try await seam.register(anchor)
            } catch PasskeyUnlockError.registrationCompleted(let credentialID, let underlying) {
                throw CredentialManagerError.externalPasskeyRemains(credentialID: credentialID, underlying: underlying)
            } catch PasskeyUnlockError.registrationOutcomeUnknown {
                throw CredentialManagerError.registrationOutcomeUnknown
            }
            let proof: VaultUnlockProof
            do {
                proof = try await seam.verifyRegistration(registration, anchor, requireLease)
            } catch {
                throw CredentialManagerError.externalPasskeyRemains(credentialID: registration.credentialID, underlying: error)
            }
            let authority: VaultCreationAuthority = source.map { .unlockedVault(vaultID: $0.vaultID, access: lease) }
                ?? .firstVault(lease: lease)
            do {
                return try await store.createVault(name: name, unlock: proof, authorizedBy: authority)
            } catch {
                throw CredentialManagerError.externalPasskeyRemains(credentialID: proof.credentialID, underlying: error)
            }
        case .existing(let sourceVaultID, let credentialID, let prfInput):
            let proof = try await seam.assert([VaultUnlock(credentialID: credentialID, prfInput: prfInput)], anchor)
            try requireLease()
            return try await store.createVault(
                name: name,
                unlock: proof,
                authorizedBy: .existingPasskey(vaultID: sourceVaultID, credentialID: proof.credentialID, prf: proof.prf, lease: lease)
            )
        }
    }

    private static func installObserversOnce() {
        guard observers.isEmpty else { return }
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: CredentialLockReason) -> any NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lockAll(reason: reason) }
            }
        }
        observers = CredentialLockEvent.all.map { event -> any NSObjectProtocol in
            let center: NotificationCenter = switch event.center {
            case .workspace:
                NSWorkspace.shared.notificationCenter
            case .distributed:
                DistributedNotificationCenter.default()
            case .application:
                .default
            }
            return observe(center, event.name, event.reason)
        }
    }

    // MARK: - Access epochs

    func beginAccess() -> VaultAccess {
        // A newer unlock attempt owns the report from here on: an older one still verifying can no longer publish its warning.
        unlockGeneration &+= 1
        scratchCleanupWarnings = []
        let access = VaultAccess(profileID: profile.id, epoch: Self.nextEpoch(), deadline: now().advanced(by: .seconds(300)))
        if isRetired {
            access.revoke()
        } else {
            pending.append(access)
        }
        return access
    }

    /// Reads this vault's wrapper plaintext (also for a vault still in a v1 file or an interrupted migration) into `unlockCredentials`.
    func discoverUnlocks() async throws {
        try Task.checkCancellation()
        guard !isRetired else { throw CredentialVaultError.unauthorized }
        let unlocks = try await store.discovery(vaultID: vaultID).unlocks
        try Task.checkCancellation()
        guard !isRetired else { throw CredentialVaultError.unauthorized }
        unlockCredentials = unlocks
    }

    /// `confirmMigration` is the user's explicit consent to migrate a v1 vault; without it a v1 or half-migrated vault is refused
    /// before anything is written. `verifying` reports the store's verification start (`true`) and end (`false`).
    func completeUnlock(
        credentialID: Data,
        prf: SymmetricKey,
        access: VaultAccess,
        confirmMigration: Bool = false,
        verifying: (@Sendable (Bool) -> Void)? = nil
    ) async throws {
        try requirePending(access)
        unlockGeneration &+= 1
        let generation = unlockGeneration
        scratchCleanupWarnings = []
        let scratch = ScratchReports()
        func publishScratch() {
            if unlockGeneration == generation {
                scratchCleanupWarnings = scratch.urls
            }
        }
        do {
            try await store.unlock(
                vaultID: vaultID,
                credentialID: credentialID,
                prf: prf,
                confirmMigration: confirmMigration,
                access: access,
                verifying: verifying,
                scratchWarning: { scratch.add($0) }
            )
            publishScratch()
            let unlocks = try await store.discovery(vaultID: vaultID).unlocks
            try requirePending(access)
            try activate(access)
            unlockCredentials = unlocks
            VaultStateChanges.shared.note(profile.id)
            AutofillSuggestions.shared.vaultUnlocked(profileID: profile.id)
        } catch {
            publishScratch()
            discard(access)
            throw error
        }
    }

    // MARK: - Native unlock management

    func unlock(in anchor: ASPresentationAnchor, confirmMigration: Bool = false, verifying: (@Sendable (Bool) -> Void)? = nil) async throws {
        let access = beginAccess()
        do {
            try requirePending(access)
            // The consent comes before the passkey prompt: no assertion is asked for a migration that would be refused.
            switch await store.openState() {
            case .legacy, .resumeMigration:
                guard confirmMigration else { throw CredentialStoreError.migrationNeedsConfirmation }
            case .provisional, .firstRun, .failClosed:
                break
            }
            let unlocks = try await store.discovery(vaultID: vaultID).unlocks
            try requirePending(access)
            let proof = try await native.assert(unlocks, anchor)
            try await completeUnlock(
                credentialID: proof.credentialID, prf: proof.prf, access: access, confirmMigration: confirmMigration, verifying: verifying
            )
        } catch {
            discard(access)
            throw error
        }
    }

    func addUnlock(in anchor: ASPresentationAnchor) async throws -> VaultCommitReceipt {
        let access = try currentAccess()
        _ = try await preflightAddingUnlock(using: access)
        try requireCurrent(access)

        let registration: VaultUnlockRegistration
        do {
            registration = try await native.register(anchor)
        } catch PasskeyUnlockError.registrationCompleted(let credentialID, let underlying) {
            throw CredentialManagerError.externalPasskeyRemains(credentialID: credentialID, underlying: underlying)
        } catch PasskeyUnlockError.registrationOutcomeUnknown {
            throw CredentialManagerError.registrationOutcomeUnknown
        }

        let proof: VaultUnlockProof
        do {
            proof = try await native.verifyRegistration(registration, anchor) {
                try self.requireCurrent(access)
            }
        } catch {
            throw CredentialManagerError.externalPasskeyRemains(
                credentialID: registration.credentialID,
                underlying: error
            )
        }
        return try await completeAddUnlock(proof, using: access)
    }

    func preflightAddingUnlock(using access: VaultAccess) async throws -> VaultDiscovery {
        try requireCurrent(access)
        let discovery = try await guarded(using: access) { try await store.discovery(vaultID: vaultID) }
        try requireCurrent(access)
        unlockCredentials = discovery.unlocks
        guard discovery.unlocks.count < CredentialVaultLimits.wrappers else {
            throw CredentialVaultError.oversized
        }
        return discovery
    }

    func completeAddUnlock(_ proof: VaultUnlockProof, using access: VaultAccess) async throws -> VaultCommitReceipt {
        do {
            try requireCurrent(access)
            let receipt = try await writing { try await guarded(using: access) { try await store.addUnlock(vaultID: vaultID, proof, using: access) } }
            if current === access, access.isAuthorized(at: now()),
               !unlockCredentials.contains(where: { $0.credentialID == proof.credentialID }) {
                unlockCredentials.append(VaultUnlock(credentialID: proof.credentialID, prfInput: proof.prfInput))
            }
            return receipt
        } catch {
            throw CredentialManagerError.externalPasskeyRemains(credentialID: proof.credentialID, underlying: error)
        }
    }

    func completeRemoveUnlock(
        credentialID: Data,
        verifiedRemaining: VaultUnlockProof,
        using access: VaultAccess
    ) async throws -> VaultCommitReceipt {
        try requireCurrent(access)
        let receipt = try await writing {
            try await guarded(using: access) {
                try await store.removeUnlock(
                    vaultID: vaultID, credentialID: credentialID, verifiedRemaining: verifiedRemaining, using: access
                )
            }
        }
        if current === access, access.isAuthorized(at: now()) {
            unlockCredentials.removeAll { $0.credentialID == credentialID }
        }
        return receipt
    }

    func removeUnlock(credentialID: Data, in anchor: ASPresentationAnchor) async throws -> VaultCommitReceipt {
        let access = try currentAccess()
        guard unlockCredentials.contains(where: { $0.credentialID == credentialID }) else { throw CredentialVaultError.invalidData }
        let remaining = unlockCredentials.filter { $0.credentialID != credentialID }
        guard !remaining.isEmpty else { throw CredentialVaultError.noUnlocks }
        let proof = try await native.assert(remaining, anchor)
        try requireCurrent(access)
        return try await completeRemoveUnlock(
            credentialID: credentialID,
            verifiedRemaining: proof,
            using: access
        )
    }

    /// Renames the vault under the lease the caller decided under (`authorizedEpoch`). The name is sealed in the head, so a
    /// locked vault cannot be renamed.
    func renameVault(_ name: String, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.renameVault(vaultID: vaultID, name: name, using: access)
        }
    }

    /// Stores the vault's choice, and applies it to the running lease only when it is shorter: the lease then ends at the unlock plus
    /// the new time, at once when that has passed. A longer choice, or "When WSurf quits", applies from the next unlock, so no
    /// choice ever extends a lease. Only an unlocked vault accepts it.
    func setAutoLock(_ choice: CredentialAutoLock) throws {
        let instant = now()
        guard let access = current, let start = leaseStart, access.isAuthorized(at: instant) else { throw CredentialVaultError.unauthorized }
        CredentialAutoLock.store(choice, for: vaultID, in: ProfileSettingsStore.defaults(for: profile))
        autoLock = choice
        guard let end = choice.lifetime.map({ start.advanced(by: $0) }), end < access.deadline else { return }
        if end <= instant {
            lock(reason: .timeout)
        } else {
            access.shorten(to: end)
            arm(timerFor: access, until: end, from: instant)
        }
    }

    // MARK: - Vault access

    func snapshot() async throws -> StoreSnapshot {
        try await reading { access in try await store.snapshot(vaultID: vaultID, using: access) }
    }

    /// `authorizedEpoch` is the lease the caller's decision was made under. It is compared with the current access in the
    /// same main-actor segment that captures it, before any write starts, so a lock and re-unlock that landed after the
    /// decision (for example while a task was queued) can never carry the write into the newer lease.
    func commit(
        _ accounts: [CredentialAccount], expectedRevision: UInt64, authorizedEpoch: UInt64, cause: String? = nil
    ) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.commit(vaultID: vaultID, accounts, expectedRevision: expectedRevision, cause: cause, using: access)
        }
    }

    /// The per-account write of spec §13.5: only the touched accounts are compared and written, so an unrelated concurrent
    /// write survives. The lease and epoch rules are `commit`'s: a caller whose decision was made under another lease is refused
    /// before anything starts. `removing` moves live accounts to Trash in the same write, each bound to its stamp.
    func commitAccounts(
        _ writes: [AccountWrite], removing: [UUID: AccountStamp] = [:], authorizedEpoch: UInt64, cause: String? = nil
    ) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.commitAccounts(vaultID: vaultID, writes, removing: removing, cause: cause, using: access)
        }
    }

    /// The names a transfer header shows: this profile's, and this vault's, which stays `nil` unless the lease is still current.
    func displayNames() async throws -> (profile: String, vault: String?) {
        let listing = try await reading { _ in try await store.listing() }
        return (profile.name, listing.first { $0.vaultID == vaultID }?.name)
    }

    func delete(_ scope: RemovalScope, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.delete(vaultID: vaultID, scope: scope, expectedRevision: expectedRevision, using: access)
        }
    }

    func updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.updatePasswordSavePolicy(vaultID: vaultID, blockedOrigins, expectedRevision: expectedRevision, using: access)
        }
    }

    // MARK: - Trash and earlier versions (this manager's lease only)

    func trashPage(after: Int?) async throws -> TrashPage {
        try await reading { access in try await store.trashPage(vaultID: vaultID, after: after, using: access) }
    }

    func revisionPage(accountID: UUID, after: Int?) async throws -> RevisionPage {
        try await reading { access in try await store.revisionPage(vaultID: vaultID, accountID: accountID, after: after, using: access) }
    }

    func revisionValuePage(accountID: UUID, after: Int?) async throws -> RevisionValuePage {
        try await reading { access in try await store.revisionValuePage(vaultID: vaultID, accountID: accountID, after: after, using: access) }
    }

    /// Verified Trash and earlier-version counts: integers from the sealed heads, each checked against the stored rows.
    func historyCounts() async throws -> (live: HistoryCounts, trash: HistoryCounts) {
        try await reading { access in try await store.historyCounts(vaultID: vaultID, using: access) }
    }

    var preMigrationBackup: URL? {
        store.preMigrationBackup()
    }

    func previewUndelete(entryID: UUID) async throws -> UndeletePreview {
        try await reading { access in try await store.previewUndelete(vaultID: vaultID, entryID: entryID, using: access) }
    }

    func undelete(entryID: UUID, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.undelete(vaultID: vaultID, entryID: entryID, expectedRevision: expectedRevision, using: access)
        }
    }

    /// Undo of the page's own last action (`ProfileVaultStore.undo`), as one write under the lease the caller decided under.
    func undo(
        writes: [AccountWrite], returning: [RemovalScope], removing: [UUID: AccountStamp], authorizedEpoch: UInt64
    ) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.undo(vaultID: vaultID, writes: writes, returning: returning, removing: removing, using: access)
        }
    }

    func previewRestoreRevision(revisionID: UUID) async throws -> CredentialAccount {
        try await reading { access in try await store.previewRestoreRevision(vaultID: vaultID, revisionID: revisionID, using: access) }
    }

    func restoreRevision(revisionID: UUID, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt {
        try await authorizedWrite(epoch: authorizedEpoch) { access in
            try await store.restoreRevision(vaultID: vaultID, revisionID: revisionID, expectedRevision: expectedRevision, using: access)
        }
    }

    func removedIdentifiers() async throws -> RemovedIdentifiers {
        try await reading { access in try await store.removedIdentifiers(vaultID: vaultID, using: access) }
    }

    /// When and by what cause each saved credential's earlier versions were made, by credential. No value is read out: the import report
    /// shows which parts changed and when, never what they were.
    func revisionLog() async throws -> [UUID: [RevisionItem]] {
        try await reading { access in try await store.revisionLog(vaultID: vaultID, using: access) }
    }

    /// A purge needs a fresh assertion of an enrolled passkey on top of the unlock: a cached lease alone never purges.
    func purge(entryIDs: [UUID], emptyAll: Bool, in anchor: ASPresentationAnchor) async throws -> PurgeReceipt {
        let access = try currentAccess()
        let unlocks = try await guarded(using: access) { try await store.discovery(vaultID: vaultID) }.unlocks
        try requireCurrent(access)
        let proof = try await native.assert(unlocks, anchor)
        try requireCurrent(access)
        return try await writing {
            try await guarded(using: access) {
                try await store.purge(
                    vaultID: vaultID, entryIDs: entryIDs, emptyAll: emptyAll,
                    authorization: FreshAuthorization(credentialID: proof.credentialID, prf: proof.prf), using: access
                )
            }
        }
    }

    /// Deletes this vault and its Trash for good. Like a purge it needs a fresh assertion of a passkey enrolled in THIS vault on top of
    /// the unlock, and it is bound to `authorizedEpoch`, the lease the user confirmed under: a lock or re-unlock since, a declined
    /// prompt and another vault's passkey delete nothing. Once it has committed the manager is retired: unregistered, locked, and
    /// unable to unlock again.
    func deleteVault(authorizedEpoch: UInt64, in anchor: ASPresentationAnchor) async throws {
        let access = try currentAccess()
        guard access.epoch == authorizedEpoch else { throw CredentialVaultError.unauthorized }
        let unlocks = try await guarded(using: access) { try await store.discovery(vaultID: vaultID) }.unlocks
        try requireCurrent(access)
        let proof = try await native.assert(unlocks, anchor)
        try requireCurrent(access)
        try await writing {
            try await guarded(using: access) {
                try await store.deleteVault(
                    vaultID: vaultID, authorization: FreshAuthorization(credentialID: proof.credentialID, prf: proof.prf), using: access
                )
            }
        }
        retireAfterDeletion()
    }

    /// Deletes this vault when it holds nothing to lose: no credential, no Trash entry, no earlier version and no excluded website
    /// (tombstones do not count), as the store reads its rows inside the deleting transaction. No passkey is asked for; it
    /// still needs the unlock and the lease the caller decided under, and the last vault is still refused. A vault that holds
    /// anything throws `vaultNotEmpty` with nothing written.
    func deleteEmptyVault(authorizedEpoch: UInt64) async throws {
        let access = try currentAccess()
        guard access.epoch == authorizedEpoch else { throw CredentialVaultError.unauthorized }
        try await writing { try await guarded(using: access) { try await store.deleteEmptyVault(vaultID: vaultID, using: access) } }
        retireAfterDeletion()
    }

    /// After the store committed the deletion: unregistered, locked, unable to unlock again. Nothing here throws.
    private func retireAfterDeletion() {
        if Self.managers[profile.id]?[vaultID] === self {
            Self.managers[profile.id]?[vaultID] = nil
        }
        isRetired = true
        unlockCredentials = []
        lock(reason: .manual)
        AutofillSaveCoordinator.shared.vaultAccessEnded(profileID: profile.id)
    }

    /// Synchronous revocation is the security boundary; actor cleanup is conditional on the exact
    /// revoked identities so a delayed cleanup can never clear a newer unlock.
    func lock(reason: CredentialLockReason) {
        let revoked = pending + (current.map { [$0] } ?? [])
        for access in revoked {
            access.revoke()
        }
        pending = []
        current = nil
        unlockGeneration &+= 1
        // Ceremonies bound to this vault stop here, synchronously, before any suspension can let one continue.
        WebAuthnAdapter.cancel(manager: self)
        lastLockReason = reason
        leaseStart = nil
        timer?.cancel()
        timer = nil
        native.cancel()
        VaultStateChanges.shared.note(profile.id)
        let store = store
        Task { for access in revoked { await store.lock(ifUsing: access) } }
    }

    // MARK: - Private

    /// The scratch paths one unlock's store call reported, collected from the store's executor and read on the main actor.
    private nonisolated final class ScratchReports: Sendable {
        private let reported = Mutex<[URL]>([])

        var urls: [URL] {
            reported.withLock { $0 }
        }

        func add(_ url: URL) {
            reported.withLock { $0.append(url) }
        }
    }

    private func currentAccess() throws -> VaultAccess {
        guard let current else { throw CredentialVaultError.unauthorized }
        try requireCurrent(current)
        return current
    }

    private func requireCurrent(_ access: VaultAccess) throws {
        guard current === access else { throw CredentialVaultError.unauthorized }
        do {
            try access.withAuthorization(now: now) {}
        } catch CredentialVaultError.expired {
            if current === access {
                lock(reason: .timeout)
            }
            throw CredentialVaultError.expired
        }
    }

    private func requirePending(_ access: VaultAccess) throws {
        guard pending.contains(where: { $0 === access }) else { throw CredentialVaultError.unauthorized }
        do {
            try access.withAuthorization(now: now) {}
        } catch {
            discard(access)
            throw error
        }
    }

    /// Runs a vault operation; an expiry reported by the vault locks the manager. Returns the vault's
    /// result verbatim, so a committed receipt is never converted into an error.
    private func guarded<T>(using access: VaultAccess, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch CredentialVaultError.expired {
            if current === access {
                lock(reason: .timeout)
            }
            throw CredentialVaultError.expired
        }
    }

    /// A read under the current lease; a result is discarded if a lock landed while it was in flight.
    private func reading<T>(_ operation: (VaultAccess) async throws -> T) async throws -> T {
        let access = try currentAccess()
        let result = try await guarded(using: access) { try await operation(access) }
        try requireCurrent(access)
        return result
    }

    /// A durable write under the lease the caller decided under (`epoch`), marked in flight before its first suspension.
    private func authorizedWrite<T>(epoch: UInt64, _ operation: (VaultAccess) async throws -> T) async throws -> T {
        let access = try currentAccess()
        guard access.epoch == epoch else { throw CredentialVaultError.unauthorized }
        return try await writing { try await guarded(using: access) { try await operation(access) } }
    }

    /// Marks a vault write as in flight before its first suspension and clears the mark on success, failure and
    /// cancellation alike: a write that threw or was cancelled may still have landed.
    private func writing<T>(_ operation: () async throws -> T) async rethrows -> T {
        writeGeneration &+= 1
        writesInFlight += 1
        defer { writesInFlight -= 1; writeGeneration &+= 1 }
        return try await operation()
    }

    private func activate(_ access: VaultAccess) throws {
        let instant = now()
        try access.checkAuthorization(at: instant)
        pending.removeAll { $0 === access }
        if let previous = current, previous !== access {
            previous.revoke()
        }
        current = access
        // The length is read once, here, from this vault's own setting; the unlock itself was bounded by five minutes (`beginAccess`).
        autoLock = CredentialAutoLock.stored(for: vaultID, in: ProfileSettingsStore.defaults(for: profile))
        let end = autoLock.lifetime.map { instant.advanced(by: $0) }
        // ponytail: "When WSurf quits" is a ten-year deadline and no timer; a lock event is its only end. Upgrade: an optional deadline.
        access.beginLease(until: end ?? instant.advanced(by: .seconds(315_360_000)))
        leaseStart = instant
        arm(timerFor: access, until: end, from: instant)
    }

    /// The one timer that ends `access` at `end`; none when the vault stays open until a lock event.
    private func arm(timerFor access: VaultAccess, until end: ContinuousClock.Instant?, from instant: ContinuousClock.Instant) {
        timer?.cancel()
        timer = nil
        guard let end else { return }
        timer = Task { [weak self] in
            try? await ContinuousClock().sleep(for: end - instant)
            guard !Task.isCancelled, let self, self.current === access else { return }
            self.lock(reason: .timeout)
        }
    }

    private func discard(_ access: VaultAccess) {
        access.revoke()
        pending.removeAll { $0 === access }
        let store = store
        Task { await store.lock(ifUsing: access) }
    }
}
