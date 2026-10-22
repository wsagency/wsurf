// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Testing
import WSurfCore

@testable import WSurf
@testable import WSurfVault

// Two Macs of one profile id over one fake cloud, through the real stores and managers (spec amendment 2026-10-22): Mac A is a
// hand-built store in its own folder; Mac B is the profile in the process-wide registry, where the app's own adoption runs. The
// passkeys are stubs that answer with the proof a test chooses, and the sync's hooks are called by the test unless a test installs
// `CloudSync.shared`. The suites that use it are serial: real stores, the manager registry and the process-wide `CloudSync.shared`.

/// A vault synced between two Macs. A made it; B adds it with the same passkey.
@MainActor
final class DevicePair {
    let cloud = FakeSyncCloud()
    let profile: Profile
    /// The unlock passkey both Macs answer with: the same credential and the same PRF output.
    let proof: VaultUnlockProof
    let vaultID: UUID
    let envA: VaultTestEnvironment
    let storeA: ProfileVaultStore
    let managerA: CredentialManager
    let passkeysA: VaultPasskeys
    let passkeysB = VaultPasskeys()
    let clockA = TestClock()
    let clockB = TestClock()
    let syncA: VaultSync
    let syncB: VaultSync
    let engineA: FakeSyncEngine
    let engineB: FakeSyncEngine
    private(set) var managerB: CredentialManager?

    private init(
        profile: Profile, proof: VaultUnlockProof, vaultID: UUID, envA: VaultTestEnvironment, storeA: ProfileVaultStore,
        managerA: CredentialManager, passkeysA: VaultPasskeys
    ) {
        self.profile = profile
        self.proof = proof
        self.vaultID = vaultID
        self.envA = envA
        self.storeA = storeA
        self.managerA = managerA
        self.passkeysA = passkeysA
        passkeysA.adopt(proof)
        passkeysB.adopt(proof)
        let hostA = CredentialVaultSyncHost(
            profiles: { [profile] in [profile] },
            manager: { _, id in id == vaultID ? managerA : nil },
            directory: { _ in envA.directory }
        )
        syncA = VaultSync(host: hostA, state: VaultSyncAppState(), persist: { _ in }, excludedProfiles: [], clock: clockA)
        syncB = VaultSync(
            host: CredentialVaultSyncHost(profiles: { [profile] in [profile] }), state: VaultSyncAppState(), persist: { _ in },
            excludedProfiles: [], clock: clockB
        )
        engineA = FakeSyncEngine(cloud: cloud, delegate: syncA)
        engineB = FakeSyncEngine(cloud: cloud, delegate: syncB)
        syncA.attach(engineA)
        syncB.attach(engineB)
    }

    /// Mac A with its vault created and unlocked; Mac B with an empty profile in the registry.
    static func make() async throws -> DevicePair {
        let profile = try await VaultManagerFixture.newProfile("Sync")
        let env = try VaultTestEnvironment.make()
        let store = ProfileVaultStore(profileID: profile.id, directory: env.directory, defaults: env.defaults)
        let proof = VaultFixtures.proof(1)
        let lease = VaultAccess(profileID: profile.id, epoch: 1, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
        let vaultID = try await store.createVault(name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: lease))
        let passkeys = VaultPasskeys()
        let manager = VaultManagerFixture.manager(profileID: profile.id, vaultID: vaultID, store: store, passkeys: passkeys)
        try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: manager.beginAccess())
        return DevicePair(profile: profile, proof: proof, vaultID: vaultID, envA: env, storeA: store, managerA: manager, passkeysA: passkeys)
    }

    func cleanup() async {
        // Close the sync databases before their folders go.
        syncA.profileErased(profile.id)
        syncB.profileErased(profile.id)
        await storeA.close()
        envA.cleanUp()
        await VaultManagerFixture.cleanup(profile)
    }

    // MARK: Entries

    func account(_ name: String, password: String = "pw") -> CredentialAccount {
        VaultFixtures.account(username: name, password: password, origin: "https://\(name).test")
    }

    /// Replaces the vault's entries with `accounts`.
    func save(_ accounts: [CredentialAccount], in manager: CredentialManager) async throws {
        let epoch = try #require(manager.authorizationEpoch)
        let revision = try await manager.snapshot().revision
        _ = try await manager.commit(accounts, expectedRevision: revision, authorizedEpoch: epoch)
    }

    func edit(_ manager: CredentialManager, _ id: UUID, _ change: (inout CredentialAccount) -> Void) async throws {
        let epoch = try #require(manager.authorizationEpoch)
        let snapshot = try await manager.snapshot()
        var accounts = snapshot.accounts
        let index = try #require(accounts.firstIndex { $0.id == id })
        change(&accounts[index])
        _ = try await manager.commit(accounts, expectedRevision: snapshot.revision, authorizedEpoch: epoch, changing: [id])
    }

    func accounts(_ manager: CredentialManager) async throws -> [UUID: CredentialAccount] {
        Dictionary(try await manager.snapshot().accounts.map { ($0.id, $0) }) { first, _ in first }
    }

    // MARK: Sync

    var statusA: VaultSyncStatus {
        syncA.status(profileID: profile.id, vaultID: vaultID)
    }

    var statusB: VaultSyncStatus {
        syncB.status(profileID: profile.id, vaultID: vaultID)
    }

    func enableA() async throws {
        try await syncA.enable(profileID: profile.id, vaultID: vaultID)
        try await pump()
    }

    func pump() async throws {
        for _ in 0..<5 {
            await syncA.settle()
            try await engineA.sendNow()
            await syncA.settle()
            await syncB.settle()
            try await engineB.sendNow()
            await syncB.settle()
        }
    }

    func converge() async throws {
        for _ in 0..<5 {
            try await pump()
            try await engineA.fetchNow()
            await syncA.settle()
            try await engineB.fetchNow()
            await syncB.settle()
        }
        try await pump()
    }

    /// The person wrote to a vault: the debounce passes and the sync produces.
    func wrote(_ sync: VaultSync, _ clock: TestClock) async {
        sync.noteWrite(profileID: profile.id, vaultID: vaultID)
        _ = await waitUntil { clock.pendingCount > 0 }
        clock.advance(by: .seconds(2))
        for _ in 0..<20 {
            await Task.yield()
        }
        await sync.settle()
    }

    /// What the app does for "Add to This Mac…": the passkey assertion, the adoption, then the sync.
    func addToB() async throws {
        try await engineB.fetchNow()
        await syncB.settle()
        let remote = try #require(syncB.remoteVaults(profileID: profile.id).first)
        let added = try await CredentialManager.adoptSyncedVault(
            profile: profile, remote: remote, in: VaultManagerFixture.anchor(), native: passkeysB.native
        )
        #expect(added == vaultID)
        await syncB.adopted(profileID: profile.id, vaultID: added)
        managerB = try CredentialManager.forVault(profile, vaultID: added, native: passkeysB.native)
    }

    func unlockB() async throws {
        try await unlockBWithoutSync()
        syncB.vaultUnlocked(profileID: profile.id, vaultID: vaultID)
        await syncB.settle()
    }

    /// B's vault is open and its sync has not been told: what B holds before its first pass.
    func unlockBWithoutSync() async throws {
        let manager = try #require(managerB)
        try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: manager.beginAccess())
    }

    /// A tombstone as one from before imports kept anything: it knows the entry and no login, and no exchange id.
    func rememberBlank(_ id: UUID, in manager: CredentialManager) async throws {
        let epoch = try #require(manager.authorizationEpoch)
        _ = try await manager.rememberRemoved([id: RemovedMemory()], authorizedEpoch: epoch)
    }

    /// What the Settings page does with a Passwords-app transfer: the claim, then the staging.
    func stageTransfer(_ data: ASExportedCredentialData, with coordinator: CredentialExchangeCoordinator, into manager: CredentialManager, owner: UUID) async throws {
        let token = UUID()
        #expect(coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)) == .accepted)
        try coordinator.claimImport(token: token, for: manager, owner: owner)
        try await coordinator.stage(data, into: manager, owner: owner)
    }
}

func withDevicePair(_ body: (DevicePair) async throws -> Void) async throws {
    let pair = try await DevicePair.make()
    do {
        try await body(pair)
    } catch {
        await pair.cleanup()
        throw error
    }
    await pair.cleanup()
}
