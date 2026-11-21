// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import WSurfCore
@testable import WSurfVault

extension VaultSyncEnrollmentTests {
    enum RotationOrder: CaseIterable {
        case beforeRename, afterPreparingRename, conflict
    }

    @Test(arguments: RotationOrder.allCases, [false, true])
    func aLocalRenamePreservesRotatedCloudUnlockMethods(order: RotationOrder, addsLocalPasskey: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (owner, first) = try await rig.syncedMac(holding: [])
        let (joining, second) = try await rig.addedMac()
        let rotated = try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [2])
        first.wrappers = rotated
        first.name = "Remote name"
        await owner.wrote(first)
        try await owner.pump()
        let server = try #require(rig.record(VaultSync.vaultRecordName))
        if order == .beforeRename {
            try await joining.engine.fetchNow()
        }
        second.name = "Local rename"
        if addsLocalPasskey {
            second.wrappers += try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [3])
        }
        await joining.wrote(second)
        if order == .afterPreparingRename {
            try await joining.engine.fetchNow()
        }
        try await joining.pump()

        let saved = try #require(rig.record(VaultSync.vaultRecordName))
        let payload = try #require(VaultRecordPayload.decode(saved.payload))
        let remote = try #require(VaultRecordPayload.decode(server.payload))
        let wrappers = try VaultWrapperList.decode(payload.wrappers)
        #expect(wrappers.map(\.credentialID) == (addsLocalPasskey ? [2, 3] : [2]).map { Data(repeating: $0, count: 32) })
        #expect(try VaultWrapperList.encode([wrappers[0]]) == remote.wrappers, "the server's exact replacement survives")
        #expect(try VaultSyncCodec.openVault(payload.sealed, wrappers: payload.wrappers, key: rig.key) == second.name)
        #expect(second.wrappers[0].credentialID == Data(repeating: 1, count: 32))
    }

    enum UnreadableHeader: CaseIterable {
        case differentKey, invalidWrappers, malformed
    }

    @Test(arguments: UnreadableHeader.allCases, [false, true])
    func aRenameNeverReplacesAnUnreadableServerHeader(damage: UnreadableHeader, fetchBeforeSend: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (mac, vault) = try await rig.syncedMac(holding: [])
        var header = try #require(rig.record(VaultSync.vaultRecordName))
        var payload = try #require(VaultRecordPayload.decode(header.payload))
        let bytes: Data
        switch damage {
        case .differentKey:
            let different = VaultSyncKey.derive(dek: SymmetricKey(size: .bits256), profileID: rig.profile, vaultID: rig.vaultID)
            payload.sealed = try VaultSyncCodec.sealVault(name: "Other key", wrappers: payload.wrappers, key: different)
            bytes = try payload.encoded()
        case .invalidWrappers:
            payload.wrappers = try VaultWrapperList.encode([])
            payload.sealed = try VaultSyncCodec.sealVault(name: "No methods", wrappers: payload.wrappers, key: rig.key)
            bytes = try payload.encoded()
        case .malformed:
            bytes = Data([0])
        }
        rig.cloud.overwrite(header.id, payload: bytes)
        header = try #require(rig.record(VaultSync.vaultRecordName))
        vault.name = "New name"
        await mac.wrote(vault)
        if fetchBeforeSend {
            try await mac.engine.fetchNow()
        }
        try await mac.pump()
        mac.sync.beat()
        try await mac.pump()
        #expect(rig.record(VaultSync.vaultRecordName) == header)
    }

    @Test func simultaneousPasskeyAdditionsCannotExceedTheWrapperLimit() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (owner, first) = try await rig.syncedMac(holding: [])
        let (peer, second) = try await rig.addedMac()
        first.wrappers += try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: Array(2...32))
        await owner.wrote(first)
        try await owner.pump()
        let saved = try #require(rig.record(VaultSync.vaultRecordName))
        second.wrappers += try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [33])
        await peer.wrote(second)
        try await peer.pump()
        #expect(rig.record(VaultSync.vaultRecordName) == saved)
        #expect(peer.sync.record(for: saved.id) == nil && second.wrappers.count == 2)
    }

    @Test func aLocalPasskeyRemovalPreservesARemoteRenameAndAddition() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (owner, first) = try rig.mac()
        first.wrappers = try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [1, 2])
        try await owner.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await owner.pump()
        let (peer, second) = try rig.mac()
        second.wrappers = first.wrappers
        try await peer.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        second.wrappers.removeFirst()
        await peer.wrote(second)
        first.name = "Renamed elsewhere"
        first.wrappers += try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [3])
        await owner.wrote(first)
        try await owner.pump()
        try await peer.pump()
        let saved = try #require(rig.record(VaultSync.vaultRecordName))
        let payload = try #require(VaultRecordPayload.decode(saved.payload))
        #expect(payload.wrappers == (try VaultWrapperList.encode(Array(first.wrappers.dropFirst()))))
        #expect(try VaultSyncCodec.openVault(payload.sealed, wrappers: payload.wrappers, key: rig.key) == first.name)
        #expect(second.name == "Personal" && second.wrappers.count == 1)
    }

    enum RestoredConsent: CaseIterable {
        case current, renew, renewWithoutCheckpoint, renamedAgain, onlyLocalPasskeysChanged
    }

    @Test(arguments: [false, true], RestoredConsent.allCases)
    func restoringAPendingHeaderUsesCurrentCloudPasskeys(olderSchema: Bool, consent: RestoredConsent) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (mac, local) = try await rig.syncedMac(holding: [])
        let (peer, remote) = try await rig.addedMac()
        if consent == .onlyLocalPasskeysChanged {
            local.wrappers += try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [3])
        } else {
            local.name = "Pending on relaunch"
        }
        let localWrappers = try VaultWrapperList.encode(local.wrappers)
        await mac.wrote(local)
        let database = try #require(mac.sync.database(rig.profile))
        mac.lock(local)
        mac.sync.pauseDiscovery()
        if consent != .current {
            try database.write { tx in
                try tx.db.execute(sql: """
                    UPDATE vault SET approvedUser = consentUser;
                    ALTER TABLE vault DROP COLUMN consentUser;
                    DELETE FROM grdb_migrations WHERE identifier = 'vaultExplicitConsent';
                    """)
            }
        }
        if olderSchema {
            try database.write { tx in
                // The v4 outbox held only the local HMAC, the wrapped header and its old change tag.
                try tx.db.execute(sql: """
                    ALTER TABLE vault DROP COLUMN localWrappers;
                    ALTER TABLE vault DROP COLUMN pendingLocalWrappers;
                    ALTER TABLE vault DROP COLUMN serverVault;
                    DELETE FROM grdb_migrations WHERE identifier = 'v5';
                    """)
            }
        }
        if consent == .onlyLocalPasskeysChanged {
            remote.name = "Renamed elsewhere"
        }
        remote.wrappers = try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [4])
        await peer.wrote(remote)
        try await peer.pump()
        let rotated = try #require(rig.record(VaultSync.vaultRecordName))
        let engine = FakeSyncEngine(cloud: rig.cloud)
        try await engine.fetchNow()
        let state = consent == .renewWithoutCheckpoint ? VaultSyncAppState() : mac.sync.state
        let restored = VaultSync(host: mac.host, state: state, persist: { _ in }, excludedProfiles: [])
        engine.delegate = restored
        _ = restored.acceptDiscoveryAccount(rig.cloud.user)
        restored.attach(engine)
        await restored.settle()
        try await engine.sendNow()
        #expect(rig.record(VaultSync.vaultRecordName) == rotated)
        local.unlock()
        restored.vaultUnlocked(profileID: rig.profile, vaultID: rig.vaultID)
        await restored.settle()
        if consent != .current {
            #expect(!restored.isSyncing(profileID: rig.profile, vaultID: rig.vaultID))
            if consent == .renamedAgain {
                local.name = "Latest local name"
            }
            try await restored.enable(profileID: rig.profile, vaultID: rig.vaultID)
        }
        try await engine.sendNow()
        await restored.settle()
        let saved = try #require(rig.record(VaultSync.vaultRecordName))
        let payload = try #require(VaultRecordPayload.decode(saved.payload))
        let expectedName = consent == .onlyLocalPasskeysChanged ? remote.name : local.name
        #expect(try VaultSyncCodec.openVault(payload.sealed, wrappers: payload.wrappers, key: rig.key) == expectedName)
        #expect(payload.wrappers == VaultRecordPayload.decode(rotated.payload)?.wrappers)
        #expect(try VaultWrapperList.encode(local.wrappers) == localWrappers)
    }

    @Test(arguments: [false, true], [false, true])
    func anUnmarkedRestoredEnrollmentReadsItsZoneOnce(alreadyUnlocked: Bool, sameInstance: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (mac, vault) = try await rig.syncedMac(holding: [])
        let (peer, peerVault) = try await rig.addedMac()
        // The old build stopped with a clean enrolled row and no full-read marker.
        let db = try #require(mac.sync.database(rig.profile))
        #expect(try db.read { try $0.vault(rig.vaultID)?.needsFetch } == false)
        if !alreadyUnlocked {
            mac.lock(vault)
        }
        let entry = syncAccounts(1)[0]
        peerVault.add(entry)
        await peer.wrote(peerVault)
        try await peer.pump()

        let engine = FakeSyncEngine(cloud: rig.cloud)
        try await engine.fetchNow()
        let restored: VaultSync
        if sameInstance {
            await mac.sync.handle(.account(.signOut))
            mac.sync.pauseDiscovery()
            restored = mac.sync
        } else {
            restored = VaultSync(host: mac.host, state: mac.sync.state, persist: { _ in }, excludedProfiles: [])
        }
        engine.delegate = restored
        restored.attach(engine)
        await restored.settle()
        for _ in 0..<3 {
            restored.beat()
            await restored.settle()
        }
        #expect(engine.fetchAllCount == 1)
        if !alreadyUnlocked {
            #expect(vault.accounts.isEmpty)
            vault.unlock()
            restored.vaultUnlocked(profileID: rig.profile, vaultID: rig.vaultID)
            await restored.settle()
        }
        #expect(vault.accounts[entry.id] == entry)
    }
}
