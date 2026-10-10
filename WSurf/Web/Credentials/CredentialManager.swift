// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Observation

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

/// Profile-scoped unlock state. Every await re-checks the captured `VaultAccess` *before* a durable
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
    /// Registrations saved to the vault whose delivery to the website could not be confirmed (page closed, navigated or
    /// locked after the commit, or the outcome is unknown). Memory only and bounded: a restart forgets them, and nothing
    /// here is a secret. Settings shows the details only while unlocked.
    private(set) var unconfirmedPasskeys: [UnconfirmedPasskey] = []

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

    @ObservationIgnored private let profile: Profile
    @ObservationIgnored private let vault: CredentialVault
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private let unlocker = PasskeyVaultUnlocker()
    @ObservationIgnored private var pending: [VaultAccess] = []
    private var current: VaultAccess?
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var isRetired = false
    /// Counts vault writes between their start and their end, and changes whenever one starts or ends.
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var writeGeneration: UInt64 = 0

    init(
        profile: Profile,
        directory: URL,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) throws {
        vault = try CredentialVault(profileID: profile.id, directory: directory, now: now)
        self.profile = profile
        self.now = now
    }

    // MARK: - Registry

    private static var managers: [UUID: CredentialManager] = [:]
    private static var retiredProfiles: Set<UUID> = []
    private static var observers: [any NSObjectProtocol] = []

    static func forProfile(_ profile: Profile) throws -> CredentialManager {
        guard !retiredProfiles.contains(profile.id) else { throw CredentialVaultError.unauthorized }
        if let existing = managers[profile.id] {
            return existing
        }
        let manager = try CredentialManager(profile: profile, directory: profile.supportDirectory)
        managers[profile.id] = manager
        installObserversOnce()
        return manager
    }

    /// Locks every live manager, for events that affect the whole session (sleep, screen lock, termination).
    static func lockAll(reason: CredentialLockReason) {
        for manager in managers.values {
            manager.lock(reason: reason)
        }
    }

    /// Locks one profile's manager, if it has one. A profile switch locks the profile being left, before its first
    /// suspension, and leaves other profiles' managers alone.
    static func lock(profileID: UUID, reason: CredentialLockReason) {
        managers[profileID]?.lock(reason: reason)
    }

    /// Profile erasure: unregister and revoke access, then drain vault work before the caller deletes the directory.
    static func retire(profileID: UUID) async {
        retiredProfiles.insert(profileID)
        guard let manager = managers.removeValue(forKey: profileID) else { return }
        manager.isRetired = true
        manager.lock(reason: .profileSwitch)
        await manager.vault.lock()
    }

    func vaultExists() async throws -> Bool {
        try Task.checkCancellation()
        guard !isRetired else { throw CredentialVaultError.unauthorized }
        do {
            let unlocks = try await vault.discovery().unlocks
            try Task.checkCancellation()
            guard !isRetired else { throw CredentialVaultError.unauthorized }
            unlockCredentials = unlocks
            return true
        } catch CredentialVaultError.missingVault {
            try Task.checkCancellation()
            guard !isRetired else { throw CredentialVaultError.unauthorized }
            unlockCredentials = []
            return false
        } catch {
            guard !isRetired else { throw CredentialVaultError.unauthorized }
            throw error
        }
    }

    private static func installObserversOnce() {
        guard observers.isEmpty else { return }
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: CredentialLockReason) -> any NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lockAll(reason: reason) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            observe(workspace, NSWorkspace.willSleepNotification, .sleep),
            // Login-session switch-out; NSApplication focus loss would cancel ceremonies behind provider UI.
            observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .screenLock),
            observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .screenLock),
            observe(.default, NSApplication.willTerminateNotification, .termination),
        ]
    }

    // MARK: - Access epochs

    func beginAccess() -> VaultAccess {
        epoch += 1
        let access = VaultAccess(profileID: profile.id, epoch: epoch, deadline: now().advanced(by: .seconds(300)))
        if isRetired {
            access.revoke()
        } else {
            pending.append(access)
        }
        return access
    }

    func completeUnlock(credentialID: Data, prf: SymmetricKey, access: VaultAccess) async throws {
        try requirePending(access)
        do {
            try await vault.unlock(credentialID: credentialID, prf: prf, access: access)
            let unlocks = try await vault.discovery().unlocks
            try requirePending(access)
            try activate(access)
            unlockCredentials = unlocks
        } catch {
            discard(access)
            throw error
        }
    }

    /// The create is durable once the vault write returns; expiry afterward must not turn success into failure.
    func completeCreate(_ proof: VaultUnlockProof, access: VaultAccess) async throws {
        try requirePending(access)
        do {
            try await writing { try await vault.create(unlock: proof, access: access) }
        } catch {
            discard(access)
            throw error
        }
        unlockCredentials = [VaultUnlock(credentialID: proof.credentialID, prfInput: proof.prfInput)]
        if pending.contains(where: { $0 === access }) {
            do {
                try activate(access)
            } catch {
                discard(access)
            }
        }
    }

    // MARK: - Native unlock management

    func create(in anchor: ASPresentationAnchor) async throws {
        let access = beginAccess()
        do {
            try requirePending(access)
            do {
                _ = try await vault.discovery()
                throw CredentialVaultError.alreadyExists
            } catch CredentialVaultError.missingVault {}
            try requirePending(access)
        } catch {
            discard(access)
            throw error
        }

        let registration: VaultUnlockRegistration
        do {
            registration = try await unlocker.register(in: anchor)
        } catch PasskeyUnlockError.registrationCompleted(let credentialID, let underlying) {
            discard(access)
            throw CredentialManagerError.externalPasskeyRemains(credentialID: credentialID, underlying: underlying)
        } catch PasskeyUnlockError.registrationOutcomeUnknown {
            discard(access)
            throw CredentialManagerError.registrationOutcomeUnknown
        } catch {
            discard(access)
            throw error
        }

        let proof: VaultUnlockProof
        do {
            proof = try await unlocker.verifyRegistration(registration, in: anchor) {
                try self.requirePending(access)
            }
        } catch {
            discard(access)
            throw CredentialManagerError.externalPasskeyRemains(
                credentialID: registration.credentialID,
                underlying: error
            )
        }
        do {
            try await completeCreate(proof, access: access)
        } catch {
            throw CredentialManagerError.externalPasskeyRemains(credentialID: proof.credentialID, underlying: error)
        }
    }

    func unlock(in anchor: ASPresentationAnchor) async throws {
        let access = beginAccess()
        do {
            try requirePending(access)
            let unlocks = try await vault.discovery().unlocks
            try requirePending(access)
            let proof = try await unlocker.assert(among: unlocks, in: anchor)
            try await completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: access)
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
            registration = try await unlocker.register(in: anchor)
        } catch PasskeyUnlockError.registrationCompleted(let credentialID, let underlying) {
            throw CredentialManagerError.externalPasskeyRemains(credentialID: credentialID, underlying: underlying)
        } catch PasskeyUnlockError.registrationOutcomeUnknown {
            throw CredentialManagerError.registrationOutcomeUnknown
        }

        let proof: VaultUnlockProof
        do {
            proof = try await unlocker.verifyRegistration(registration, in: anchor) {
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
        let discovery = try await guarded(using: access) { try await vault.discovery() }
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
            let receipt = try await writing { try await guarded(using: access) { try await vault.addUnlock(proof, using: access) } }
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
                try await vault.removeUnlock(credentialID: credentialID, verifiedRemaining: verifiedRemaining, using: access)
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
        let proof = try await unlocker.assert(among: remaining, in: anchor)
        try requireCurrent(access)
        return try await completeRemoveUnlock(
            credentialID: credentialID,
            verifiedRemaining: proof,
            using: access
        )
    }

    // MARK: - Vault access

    func snapshot() async throws -> VaultSnapshot {
        let access = try currentAccess()
        let snapshot = try await guarded(using: access) { try await vault.snapshot(using: access) }
        try requireCurrent(access) // reads are discarded if a lock landed while they were in flight
        return snapshot
    }

    /// `authorizedEpoch` is the lease the caller's decision was made under. It is compared with the current access in the
    /// same main-actor segment that captures it, before any write starts, so a lock and re-unlock that landed after the
    /// decision (for example while a task was queued) can never carry the write into the newer lease.
    func commit(_ accounts: [CredentialAccount], expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt {
        let access = try currentAccess()
        guard access.epoch == authorizedEpoch else { throw CredentialVaultError.unauthorized }
        return try await writing { try await guarded(using: access) { try await vault.commit(accounts, expectedRevision: expectedRevision, using: access) } }
    }

    func updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt {
        let access = try currentAccess()
        guard access.epoch == authorizedEpoch else { throw CredentialVaultError.unauthorized }
        return try await writing {
            try await guarded(using: access) { try await vault.updatePasswordSavePolicy(blockedOrigins, expectedRevision: expectedRevision, using: access) }
        }
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
        // Ceremonies bound to this vault stop here, synchronously, before any suspension can let one continue.
        WebAuthnAdapter.cancel(profileID: profile.id)
        lastLockReason = reason
        timer?.cancel()
        timer = nil
        unlocker.cancel()
        let vault = vault
        Task { for access in revoked { await vault.lock(ifUsing: access) } }
    }

    // MARK: - Private

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
        timer?.cancel()
        timer = Task { [weak self] in
            try? await ContinuousClock().sleep(for: access.deadline - instant)
            guard !Task.isCancelled, let self, self.current === access else { return }
            self.lock(reason: .timeout)
        }
    }

    private func discard(_ access: VaultAccess) {
        access.revoke()
        pending.removeAll { $0 === access }
        let vault = vault
        Task { await vault.lock(ifUsing: access) }
    }
}
