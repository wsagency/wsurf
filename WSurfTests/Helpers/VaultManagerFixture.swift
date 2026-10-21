// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import WSurf

/// A deterministic stand-in for the native passkey calls: `register` mints credential 1, 2, 3, ... with a fresh PRF secret, and
/// `assert` answers with the proof of the first requested credential it knows. Only the OS prompt is replaced; every manager and
/// store call around it is real. `beforeAssert` runs while the "prompt" is open, to let a test lock, switch profile or edit state.
@MainActor
final class VaultPasskeys {
    private(set) var registered: [VaultUnlockProof] = []
    /// Credential ids asserted, in order: one entry per native assertion the code under test asked for.
    private(set) var assertions: [Data] = []
    private(set) var cancelCount = 0
    var beforeAssert: (() async throws -> Void)?
    /// Runs while a registration "prompt" is open, before the stub mints the credential.
    var beforeRegister: (() async throws -> Void)?
    /// When set, every assertion answers with this passkey whatever was requested (a passkey the vault does not enrol).
    var answer: VaultUnlockProof?

    func proof(for credentialID: Data) -> VaultUnlockProof? {
        registered.first { $0.credentialID == credentialID }
    }

    /// A passkey known to the stub without a registration, for tests that unlock a vault built outside the manager.
    func adopt(_ proof: VaultUnlockProof) {
        registered.append(proof)
    }

    var native: VaultNativeUnlock {
        VaultNativeUnlock(
            register: { [self] _ in
                try await beforeRegister?()
                let proof = VaultFixtures.proof(UInt8(registered.count + 1))
                registered.append(proof)
                return VaultUnlockRegistration(credentialID: proof.credentialID, prfInput: proof.prfInput, registrationOutput: nil)
            },
            verifyRegistration: { [self] registration, _, beforeAssertion in
                try beforeAssertion()
                guard let proof = proof(for: registration.credentialID) else { throw PasskeyUnlockError.invalidNativeResult }
                return proof
            },
            assert: { [self] unlocks, _ in
                try await beforeAssert?()
                guard let proof = answer ?? unlocks.lazy.compactMap({ self.proof(for: $0.credentialID) }).first else {
                    throw PasskeyUnlockError.invalidNativeResult
                }
                assertions.append(proof.credentialID)
                return proof
            },
            cancel: { [self] in cancelCount += 1 }
        )
    }
}

enum VaultState {
    case unlocked, locked
}

struct FixtureVault {
    let manager: CredentialManager
    let vaultID: UUID
    let proof: VaultUnlockProof
}

/// A reader/writer gate for the process-wide manager registry. A session-wide lock (sleep, screen lock, termination, `lockAll`) locks the
/// managers of every profile, so a test that fires one runs `exclusive` and every fixture profile holds the gate shared until `cleanup`.
/// A writer is only admitted once no holder is left (it waits as long as the test does; no timeout admits it anyway), and a cancelled
/// waiter leaves without entering. A test that already holds a profile may take more (two fixture profiles in one test) even while
/// a writer waits, which would otherwise wait for the very test that is waiting for it.
nonisolated final class RegistryGate: Sendable {
    static let shared = RegistryGate()

    private struct State {
        var holders: [UUID: Test.ID?] = [:]
        var writer = false
        var writersWaiting = 0
    }

    private let state = Mutex(State())

    func enterShared(_ profileID: UUID) async throws {
        let owner = Test.current?.id
        while !state.withLock({ state in
            let joining = owner.map { owner in state.holders.values.contains { $0 == owner } } ?? false
            guard !state.writer, joining || state.writersWaiting == 0 else { return false }
            state.holders[profileID] = .some(owner)
            return true
        }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func leaveShared(_ profileID: UUID) {
        state.withLock { _ = $0.holders.removeValue(forKey: profileID) }
    }

    func enterExclusive() async throws {
        state.withLock { $0.writersWaiting += 1 }
        do {
            while !state.withLock({ state in
                guard !state.writer, state.holders.isEmpty else { return false }
                state.writer = true
                state.writersWaiting -= 1
                return true
            }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            state.withLock { $0.writersWaiting -= 1 }
            throw error
        }
    }

    func leaveExclusive() {
        state.withLock { $0.writer = false }
    }
}

@MainActor
enum VaultManagerFixture {
    @TaskLocal private static var holdsExclusive = false

    /// Runs `body` while no other fixture profile is alive, for tests that fire a session-wide lock.
    static func exclusive(_ body: () async throws -> Void) async throws {
        try await RegistryGate.shared.enterExclusive()
        do {
            try await $holdsExclusive.withValue(true) { try await body() }
        } catch {
            RegistryGate.shared.leaveExclusive()
            throw error
        }
        RegistryGate.shared.leaveExclusive()
    }

    /// A profile of the registry-backed fixtures that holds the registry gate (shared) until `cleanup`, so a session-wide lock fired by an
    /// `exclusive` test can never overlap it. Every fixture profile that touches the manager registry comes from here or from `make`.
    static func newProfile(_ name: String = "Vaults") async throws -> Profile {
        let profile = freshProfile(name)
        if !holdsExclusive {
            try await RegistryGate.shared.enterShared(profile.id)
        }
        return profile
    }

    /// A profile that has not entered the gate: only for `make`, which enters it itself.
    private static func freshProfile(_ name: String = "Vaults") -> Profile {
        Profile(id: UUID(), name: name, symbol: "key", color: .blue)
    }

    /// The presentation anchor of a fixture call. The managers, the settings model, vault routing and the vault choice take their
    /// anchor lazily and ask for it only to show a native prompt, and here every prompt is answered without one: the
    /// `VaultPasskeys` stub for the passkey, `VaultChoicePrompt.answersForTesting` for the choice. So `in: anchor()` makes no
    /// window, and the vault suites need none. Asking for it is a prompt a test forgot to stub: that is recorded, and a window
    /// that is never shown comes back so the run goes on.
    static func anchor(sourceLocation: SourceLocation = #_sourceLocation) -> ASPresentationAnchor {
        Issue.record("a vault call asked for a window to present a native prompt; stub it (VaultPasskeys, answersForTesting)",
                     sourceLocation: sourceLocation)
        return ASPresentationAnchor()
    }

    /// Builds `vaults.count` vaults (each with its own passkey) on the profile's real store, registered like production managers
    /// (`CredentialManager.forVault`), then leaves each in the requested state, in ordinal order. The caller cleans up.
    static func make(
        profile: Profile = freshProfile(),
        passkeys: VaultPasskeys = VaultPasskeys(),
        vaults states: [VaultState]
    ) async throws -> (profile: Profile, passkeys: VaultPasskeys, vaults: [FixtureVault]) {
        if !holdsExclusive {
            try await RegistryGate.shared.enterShared(profile.id)
        }
        do {
            return try await build(profile: profile, passkeys: passkeys, vaults: states)
        } catch {
            // A fixture that failed to build is never handed to its caller, so nobody else would leave the gate for it.
            await cleanup(profile)
            throw error
        }
    }

    private static func build(
        profile: Profile, passkeys: VaultPasskeys, vaults states: [VaultState]
    ) async throws -> (profile: Profile, passkeys: VaultPasskeys, vaults: [FixtureVault]) {
        var vaults: [FixtureVault] = []
        for _ in states {
            let choice = NewVaultChoice.newPasskey(authorizedBy: vaults.first?.manager)
            if let first = vaults.first, !first.manager.isUnlocked {
                try await unlock(first)
            }
            let vaultID = try await CredentialManager.createVault(
                profile: profile, name: "Vault \(vaults.count + 1)", choice: choice, in: anchor(), native: passkeys.native
            )
            let proof = try #require(passkeys.registered.last)
            let manager = try CredentialManager.forVault(profile, vaultID: vaultID, native: passkeys.native)
            vaults.append(FixtureVault(manager: manager, vaultID: vaultID, proof: proof))
        }
        for (vault, state) in zip(vaults, states) {
            switch state {
            case .unlocked where !vault.manager.isUnlocked:
                try await unlock(vault)
            case .locked where vault.manager.isUnlocked:
                vault.manager.lock(reason: .manual)
            default:
                break
            }
        }
        return (profile, passkeys, vaults)
    }

    static func unlock(_ vault: FixtureVault) async throws {
        try await vault.manager.completeUnlock(
            credentialID: vault.proof.credentialID, prf: vault.proof.prf, access: vault.manager.beginAccess()
        )
    }

    /// Replaces the unlocked vault's accounts through its manager, under its current epoch.
    @discardableResult
    static func save(_ accounts: [CredentialAccount], in vault: FixtureVault) async throws -> VaultCommitReceipt {
        let epoch = try #require(vault.manager.authorizationEpoch)
        let revision = try await vault.manager.snapshot().revision
        return try await vault.manager.commit(accounts, expectedRevision: revision, authorizedEpoch: epoch)
    }

    static func cleanup(_ profile: Profile) async {
        await CredentialManager.retire(profileID: profile.id)
        try? FileManager.default.removeItem(at: profile.supportDirectory)
        ProfileSettingsStore.forget(profile.id)
        RegistryGate.shared.leaveShared(profile.id)
    }

    /// `Profile.erase` for a profile of this fixture family: the app's own erasure, then the gate is left. Every fixture profile that
    /// is erased (rather than `cleanup`ed) goes through here.
    static func erase(_ profile: Profile) async {
        await Profile.erase(profile)
        RegistryGate.shared.leaveShared(profile.id)
    }

    /// `make`, then `body`, then `cleanup` whether `body` threw or not.
    static func with(
        passkeys: VaultPasskeys = VaultPasskeys(),
        vaults states: [VaultState],
        _ body: @MainActor (_ profile: Profile, _ passkeys: VaultPasskeys, _ vaults: [FixtureVault]) async throws -> Void
    ) async throws {
        let profile = try await newProfile()
        do {
            let made = try await make(profile: profile, passkeys: passkeys, vaults: states)
            try await body(made.profile, made.passkeys, made.vaults)
        } catch {
            await cleanup(profile)
            throw error
        }
        await cleanup(profile)
    }

    /// A manager (not in the registry) for a vault of a hand-built directory; the caller owns `store` and closes it.
    static func manager(
        profileID: UUID,
        vaultID: UUID,
        store: ProfileVaultStore,
        passkeys: VaultPasskeys,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) -> CredentialManager {
        CredentialManager(
            profile: Profile(id: profileID, name: "Hand built", symbol: "key", color: .blue),
            vaultID: vaultID, store: store, now: now, native: passkeys.native
        )
    }

    /// Relative path → bytes of every regular file under `directory`; empty when it does not exist.
    static func image(of directory: URL) -> [String: Data] {
        (try? VaultStoreFixture.directoryImage(of: directory)) ?? [:]
    }

    /// Every head, record and journal row of the vault and its linked Trash (they share an ordinal), read on a read-only connection.
    static func rows(of vaultID: UUID, in profile: Profile) throws -> [String: Data] {
        try rows(of: vaultID, inDirectory: profile.supportDirectory)
    }

    /// `rows(of:in:)` for a hand-built store directory (a `standalone` fixture's `environment.directory`).
    static func rows(of vaultID: UUID, inDirectory directory: URL) throws -> [String: Data] {
        var configuration = GRDB.Configuration()
        configuration.readonly = true
        // The store may still be finishing a write or a checkpoint: wait for it like the store's own connections do.
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(
            path: directory.appendingPathComponent("Credentials.store").path, configuration: configuration
        )
        let owned = "SELECT vaultID FROM vault WHERE ordinal = (SELECT ordinal FROM vault WHERE vaultID = ?)"
        return try queue.read { db in
            var image: [String: Data] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT vaultID, revision, sealed FROM head WHERE vaultID IN (\(owned))", arguments: [vaultID.lowerText]) {
                let vault: String = row["vaultID"], revision: Int64 = row["revision"], sealed: Data = row["sealed"]
                image["head/\(vault)/\(revision)"] = sealed
            }
            for row in try Row.fetchAll(db, sql: "SELECT vaultID, recordID, sealed FROM record WHERE vaultID IN (\(owned))", arguments: [vaultID.lowerText]) {
                let vault: String = row["vaultID"], record: String = row["recordID"], sealed: Data = row["sealed"]
                image["record/\(vault)/\(record)"] = sealed
            }
            for row in try Row.fetchAll(db, sql: "SELECT vaultID, seq, sealed FROM journal WHERE vaultID IN (\(owned))", arguments: [vaultID.lowerText]) {
                let vault: String = row["vaultID"], seq: Int64 = row["seq"], sealed: Data = row["sealed"]
                image["journal/\(vault)/\(seq)"] = sealed
            }
            return image
        }
    }

    /// One unlocked vault over a private directory and an injected clock (for lease-expiry tests). It is not in the manager registry.
    struct Standalone {
        let profile: Profile
        let store: ProfileVaultStore
        let manager: CredentialManager
        let vault: FixtureVault
        let passkeys: VaultPasskeys
        let clock: TestClock
        let environment: VaultTestEnvironment

        func cleanup() async {
            await store.close()
            environment.cleanUp()
        }
    }

    static func standalone(
        clock: TestClock = TestClock(),
        passkeys: VaultPasskeys = VaultPasskeys(),
        unlocked: Bool = true
    ) async throws -> Standalone {
        let environment = try VaultTestEnvironment.make()
        let profile = Profile(id: environment.profileID, name: "Standalone", symbol: "key", color: .blue)
        let store = ProfileVaultStore(
            profileID: profile.id, directory: environment.directory, defaults: environment.defaults, now: { clock.now }
        )
        let proof = VaultFixtures.proof(UInt8(passkeys.registered.count + 1))
        passkeys.adopt(proof)
        let lease = VaultAccess(profileID: profile.id, epoch: 0, deadline: clock.now.advanced(by: .seconds(300)))
        let vaultID = try await store.createVault(name: "Standalone", unlock: proof, authorizedBy: .firstVault(lease: lease))
        let manager = CredentialManager(profile: profile, vaultID: vaultID, store: store, now: { clock.now }, native: passkeys.native)
        let vault = FixtureVault(manager: manager, vaultID: vaultID, proof: proof)
        if unlocked {
            try await unlock(vault)
        }
        return Standalone(profile: profile, store: store, manager: manager, vault: vault, passkeys: passkeys, clock: clock, environment: environment)
    }
}
