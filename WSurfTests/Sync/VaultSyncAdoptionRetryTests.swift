// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import Testing

@testable import WSurfCore
@testable import WSurfVault

@MainActor
struct VaultSyncAdoptionRetryTests {
    enum Interruption: CaseIterable {
        case missingZone, differentKey, accountChanged
    }

    @Test func aVaultCreatedByAnOlderAddCanJoinWithoutAnEnrollmentRow() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let incoming = syncAccounts(1)[0]
        _ = try await rig.syncedMac(holding: [incoming])
        let (mac, local) = try rig.mac(unlocked: false)
        await mac.sync.settle()
        let user = rig.cloud.user
        #expect(mac.sync.acceptDiscoveryAccount(user))
        mac.sync.refreshAvailableVaults(try await mac.engine.fetchVaultCards(), for: user)
        let offered = try #require(mac.sync.adoptionRetryAccount(profileID: rig.profile, vaultID: rig.vaultID))
        #expect(rig.status(mac) == .off)
        let header = rig.record(VaultSync.vaultRecordName)
        try await mac.sync.retryAdoption(profileID: rig.profile, vaultID: rig.vaultID, account: offered) { local.unlock() }
        try await mac.pump()
        #expect(local.account(incoming.id) == incoming && rig.status(mac) == .synced)
        #expect(rig.record(VaultSync.vaultRecordName) == header)
    }

    @Test(arguments: Interruption.allCases)
    func aRetryCannotCreateAZoneOrJoinWithAnotherKeyOrAccount(_ interruption: Interruption) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        _ = try await rig.syncedMac(holding: [])
        let local = syncAccounts(1)[0]
        let dek = interruption == .differentKey ? SymmetricKey(size: .bits256) : rig.dek
        let (mac, vault) = try rig.mac(holding: [local], dek: dek)
        await mac.sync.settle()
        let user = rig.cloud.user
        let cards = try await mac.engine.fetchVaultCards()
        #expect(mac.sync.acceptDiscoveryAccount(user))
        mac.sync.refreshAvailableVaults(cards, for: user)
        let account = try #require(mac.sync.adoptionRetryAccount(profileID: rig.profile, vaultID: rig.vaultID))
        switch interruption {
        case .missingZone:
            rig.cloud.removeZoneSilently(rig.zone)
        case .differentKey:
            break
        case .accountChanged:
            mac.engine.afterFullZoneRead = { rig.cloud.switchUser("another-fixture-account") }
        }

        await #expect(throws: (any Error).self) {
            try await mac.sync.retryAdoption(profileID: rig.profile, vaultID: rig.vaultID, account: account) {}
        }
        try await mac.pump()
        #expect(!mac.sync.isSyncing(profileID: rig.profile, vaultID: rig.vaultID))
        #expect(mac.engine.pending.isEmpty && rig.item(local) == nil)
        #expect(vault.account(local.id) == local)
        if interruption == .differentKey {
            #expect(rig.record(VaultSync.vaultRecordName) == cards.first)
        } else {
            #expect(rig.cloud.records(in: rig.zone) == nil)
        }
    }

    @Test func aDifferentAccountBehindThePasskeyPromptLeavesTheOriginalReceiptOff() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        _ = try await rig.syncedMac(holding: [])
        let mac = SimulatedMac(cloud: rig.cloud, root: rig.root.appending(path: "receiver"))
        mac.host.addProfile(rig.profile)
        mac.start()
        await mac.sync.settle()
        let user = rig.cloud.user
        let cards = try await mac.engine.fetchVaultCards()
        #expect(mac.sync.acceptDiscoveryAccount(user))
        mac.sync.refreshAvailableVaults(cards, for: user)
        let remote = try #require(mac.sync.remoteVaults(profileID: rig.profile).first)
        try await mac.sync.addDiscoveredVault(remote) {
            _ = try mac.host.addVault(profile: rig.profile, vault: rig.vaultID, dek: rig.dek, unlocked: false)
            rig.cloud.switchUser("switched-during-the-prompt")
            return rig.vaultID
        }
        let database = try #require(mac.sync.database(rig.profile))
        let receipt = try #require(try database.read { try $0.vault(rig.vaultID) })
        #expect(!receipt.enabled && receipt.pendingAdoptionUser == user)
        #expect(rig.status(mac) == .off && mac.engine.pending.isEmpty)
    }

    @Test func anInterruptedAddKeepsItsSourceAccountAcrossRelaunchAndAccountChanges() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        _ = try await rig.syncedMac(holding: [])
        let mac = SimulatedMac(cloud: rig.cloud, root: rig.root.appending(path: "receiver"))
        mac.host.addProfile(rig.profile)
        mac.start()
        await mac.sync.settle()
        let user = rig.cloud.user
        let cards = try await mac.engine.fetchVaultCards()
        #expect(mac.sync.acceptDiscoveryAccount(user))
        mac.sync.refreshAvailableVaults(cards, for: user)
        let remote = try #require(mac.sync.remoteVaults(profileID: rig.profile).first)
        try await mac.sync.addDiscoveredVault(remote) {
            _ = try mac.host.addVault(profile: rig.profile, vault: rig.vaultID, dek: rig.dek, unlocked: false)
            mac.sync.pauseDiscovery()
            return rig.vaultID
        }

        let restarted = VaultSync(host: mac.host, state: mac.sync.state, persist: { _ in }, excludedProfiles: [])
        let engine = FakeSyncEngine(cloud: rig.cloud, delegate: restarted)
        restarted.attach(engine)
        await restarted.settle()
        func offeredAccount() -> String? {
            restarted.adoptionRetryAccount(profileID: rig.profile, vaultID: rig.vaultID)
        }
        #expect(offeredAccount() == nil, "the previous process's catalog cannot authorize a retry")
        let other = "other-fixture-account"
        await engine.simulateAccount(.switchAccounts(user: other))
        restarted.refreshAvailableVaults(cards, for: user)
        #expect(offeredAccount() == nil)
        restarted.refreshAvailableVaults(cards, for: other)
        #expect(offeredAccount() == nil, "even the same vault ID on the other account cannot claim this Add")

        await engine.simulateAccount(.switchAccounts(user: user))
        restarted.refreshAvailableVaults(cards, for: user)
        #expect(offeredAccount() == user)
        #expect(!restarted.hasSyncedVaults(profileID: rig.profile) && engine.pending.isEmpty)
    }
}
