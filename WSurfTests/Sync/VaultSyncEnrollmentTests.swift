// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import Testing

@testable import WSurfCore
@testable import WSurfVault

@MainActor
struct VaultSyncEnrollmentTests {
    enum ExistingHeader: CaseIterable {
        case spentCursor, conflictingSave, fetchedBeforeUpload
    }

    @Test(arguments: ExistingHeader.allCases)
    func enablingUsesTheExistingHeaderEvenWhenDiscoveryMissedIt(order: ExistingHeader) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let local = syncAccounts(1)[0]
        let remote = SyncVaultFixtures.account(username: "elsewhere", origin: "https://remote.test")
        let (joining, vault) = try rig.mac(holding: [local])
        if order != .spentCursor {
            try await joining.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        }
        let (publisher, published) = try rig.mac(holding: [remote])
        published.wrappers = try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [2, 3])
        published.name = "Published elsewhere"
        try await publisher.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await publisher.pump()
        let header = try #require(rig.record(VaultSync.vaultRecordName))
        if order == .spentCursor {
            // A different category advanced the shared cursor while this zone was excluded.
            joining.engine.delegate = nil
            try await joining.engine.fetchNow()
            joining.engine.delegate = joining.sync
            try await joining.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        } else if order == .fetchedBeforeUpload {
            try await joining.engine.fetchNow()
        }
        try await joining.pump()
        joining.sync.beat()
        await joining.sync.settle()
        try await joining.pump()

        #expect(rig.record(VaultSync.vaultRecordName) == header)
        #expect(vault.wrappers.map(\.credentialID) == [Data(repeating: 1, count: 32)])
        #expect(vault.name == "Personal")
        #expect(vault.accounts[remote.id] != nil && rig.item(local) != nil)
        #expect(rig.status(joining) == .synced)
    }

    @Test(arguments: [false, true])
    func anUnrelatedKeyCannotPublishIntoAnExistingZone(firstUploadWaiting: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let local = syncAccounts(1)[0]
        var large = SyncVaultFixtures.account(username: "large", origin: "https://large.test")
        large.notes = [CredentialNote(text: String(repeating: "x", count: 800_000))]
        let (joining, vault) = try rig.mac(holding: [local, large], dek: SymmetricKey(size: .bits256))
        if firstUploadWaiting {
            try await joining.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        }
        _ = try await rig.syncedMac(holding: [])
        let header = try #require(rig.record(VaultSync.vaultRecordName))
        if !firstUploadWaiting {
            await #expect(throws: (any Error).self) {
                try await joining.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
            }
        }
        try await joining.pump()
        joining.sync.beat()
        await joining.sync.settle()
        try await joining.pump()

        #expect(rig.record(VaultSync.vaultRecordName) == header)
        #expect(rig.item(local) == nil && vault.accounts[local.id] != nil)
        #expect(rig.item(large) == nil && rig.cloud.encryptedVaultAssets.isEmpty)
    }

    @Test(arguments: [false, true])
    func existingZoneWithoutAReadableHeaderCannotBeClaimed(unreadable: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        if unreadable {
            _ = try await rig.syncedMac(holding: [])
        } else {
            rig.cloud.createZone(rig.zone)
        }
        let header = rig.record(VaultSync.vaultRecordName)
        let entry = syncAccounts(1)[0]
        let (mac, _) = try rig.mac(holding: [entry])
        mac.engine.unreadable.insert(VaultSync.vaultRecordName)
        await #expect(throws: (any Error).self) {
            try await mac.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        }
        try await mac.pump()
        #expect(rig.record(VaultSync.vaultRecordName) == header && rig.item(entry) == nil)
        #expect(!mac.sync.isSyncing(profileID: rig.profile, vaultID: rig.vaultID))
    }

    @Test func aPausedHeaderConflictCannotFinishForANewEnrollment() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (mac, vault) = try rig.mac(holding: [entry])
        try await mac.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        _ = try await rig.syncedMac(holding: [])
        let pause = HostPause()
        mac.engine.afterFullZoneRead = {
            mac.engine.afterFullZoneRead = nil
            mac.host.pauseAfterSnapshot = pause
        }
        try await mac.engine.sendNow()
        let waiting = await waitUntil { pause.isWaiting }
        guard waiting else {
            Issue.record("The first header conflict never reached verification")
            return
        }

        rig.cloud.switchUser("next-account")
        await mac.engine.simulateAccount(.switchAccounts(user: rig.cloud.user))
        vault.edit(syncChanging(entry, password: "New enrollment"))
        let enabling = Task { try await mac.sync.enable(profileID: rig.profile, vaultID: rig.vaultID) }
        pause.release()
        try await enabling.value
        try await mac.pump()

        let record = try #require(rig.item(entry))
        #expect(try VaultSyncCodec.openItem(record.payload, accountID: entry.id, key: rig.key).account?.password == "New enrollment")
        #expect(rig.status(mac) == .synced && mac.sync.state.accountUser == rig.cloud.user)
    }

    @Test(arguments: [false, true])
    func retryingALegacyRemovalUsesTheVaultsOwnAccountCheckpoint(known: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (mac, _) = try await rig.syncedMac(holding: [])
        mac.engine.failsZoneDeletes = true
        mac.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        try await mac.pump()
        mac.sync.pauseDiscovery()
        let directory = try #require(mac.host.syncDirectory(profileID: rig.profile))
        let database = try #require(try VaultSyncDatabase.open(directory: directory, create: false))
        try database.write { tx in
            var old = try #require(try tx.vault(rig.vaultID))
            old.approvedUser = nil
            try tx.save(old)
        }
        if !known {
            rig.cloud.switchUser("another-account")
            rig.cloud.createZone(rig.zone)
        }
        let state = known ? mac.sync.state : VaultSyncAppState()
        let resumed = VaultSync(host: mac.host, state: state, persist: { _ in }, excludedProfiles: [])
        let engine = FakeSyncEngine(cloud: rig.cloud, delegate: resumed)
        _ = resumed.acceptDiscoveryAccount(rig.cloud.user)
        resumed.attach(engine)
        await resumed.settle()
        resumed.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        try await engine.sendNow()
        #expect((rig.cloud.zones[rig.zone] == nil) == known)
    }

    @Test func aPausedAdoptionStillReadsChangesMadeBeforeItsFirstUnlock() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (publisher, source) = try await rig.syncedMac(holding: [])
        let (mac, vault) = try await rig.addedMac(unlock: false)
        mac.sync.pauseDiscovery()
        let entry = syncAccounts(1)[0]
        source.add(entry)
        await publisher.wrote(source)
        try await publisher.pump()

        let engine = FakeSyncEngine(cloud: rig.cloud)
        try await engine.fetchNow()
        let resumed = VaultSync(host: mac.host, state: mac.sync.state, persist: { _ in }, excludedProfiles: [])
        engine.delegate = resumed
        resumed.attach(engine)
        await resumed.settle()
        #expect(vault.isLocked && vault.accounts.isEmpty)
        vault.unlock()
        resumed.vaultUnlocked(profileID: rig.profile, vaultID: rig.vaultID)
        await resumed.settle()
        #expect(vault.accounts[entry.id] == entry)
    }

    @Test(arguments: [false, true])
    func attachingWithAnExistingLeaseSendsEditsMadeWhileDiscoveryWasOff(verifiesAfterAttach: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (mac, vault) = try await rig.syncedMac(holding: [entry])
        let lease = vault.lease
        mac.sync.pauseDiscovery()
        vault.edit(syncChanging(entry, password: "Edited with discovery off"))
        let state = verifiesAfterAttach ? VaultSyncAppState() : mac.sync.state
        let resumed = VaultSync(host: mac.host, state: state, persist: { _ in }, excludedProfiles: [])
        let engine = FakeSyncEngine(cloud: rig.cloud, delegate: resumed)
        if verifiesAfterAttach {
            resumed.attach(engine)
            await resumed.settle()
            await engine.simulateAccount(.signIn(user: rig.cloud.user))
        } else {
            #expect(resumed.acceptDiscoveryAccount(rig.cloud.user))
            resumed.attach(engine)
        }
        await resumed.settle()
        try await engine.sendNow()
        await resumed.settle()
        let record = try #require(rig.item(entry))
        #expect(try VaultSyncCodec.openItem(record.payload, accountID: entry.id, key: rig.key).account?.password == "Edited with discovery off")
        #expect(vault.lease == lease && !vault.isLocked)
    }
}
