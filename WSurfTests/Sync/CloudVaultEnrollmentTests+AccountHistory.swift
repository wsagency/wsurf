// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing

@testable import WSurf
@testable import WSurfCore
import WSurfVault

extension CloudVaultEnrollmentTests {
    /// SQLite dump made by 11492140 after switching accounts. Vault 91 came from 0.1.31's v2 removedDeleted row.
    /// Vault 92 was genuinely enrolled in the previous account. The two surviving rows differ only in their vault ID.
    nonisolated private static let priorAccountDatabase = """
        CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
        INSERT INTO grdb_migrations VALUES('v1');
        INSERT INTO grdb_migrations VALUES('v2');
        INSERT INTO grdb_migrations VALUES('v3');
        INSERT INTO grdb_migrations VALUES('v4');
        INSERT INTO grdb_migrations VALUES('v5');
        INSERT INTO grdb_migrations VALUES('vaultExplicitConsent');
        INSERT INTO grdb_migrations VALUES('vaultAssetPublication');
        CREATE TABLE vault(
            vaultID TEXT PRIMARY KEY, enabled INTEGER NOT NULL, status TEXT NOT NULL, uploadedMark BLOB,
            pendingVaultPayload BLOB, pendingMark BLOB, dirty INTEGER NOT NULL DEFAULT 0,
            needsFetch INTEGER NOT NULL DEFAULT 0, lastHeadRevision INTEGER NOT NULL DEFAULT 0, rereadOwed INTEGER NOT NULL DEFAULT 0,
            approvedUser TEXT, localWrappers BLOB, serverVault BLOB, pendingLocalWrappers BLOB, consentUser TEXT);
        INSERT INTO vault VALUES('00000000-0000-4000-8000-000000000091',0,'accountChanged',NULL,NULL,NULL,0,0,1,0,NULL,NULL,NULL,NULL,NULL);
        INSERT INTO vault VALUES('00000000-0000-4000-8000-000000000092',0,'accountChanged',NULL,NULL,NULL,0,0,1,0,NULL,NULL,NULL,NULL,NULL);
        CREATE TABLE base(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, parts BLOB NOT NULL,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE outbox(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, envelope BLOB NOT NULL, parts BLOB NOT NULL, remainingAssets BLOB, assetPublication BLOB,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE inbox(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, envelope BLOB NOT NULL,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE conflict(
            vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, kind TEXT NOT NULL, envelope BLOB NOT NULL,
            PRIMARY KEY(vaultID, accountID));
        CREATE TABLE record(
            vaultID TEXT NOT NULL, name TEXT NOT NULL, systemFields BLOB NOT NULL, PRIMARY KEY(vaultID, name));
        CREATE TABLE assetReceipt(
            vaultID TEXT NOT NULL, profileID TEXT NOT NULL, owner TEXT NOT NULL, digest BLOB NOT NULL, tag TEXT NOT NULL,
            PRIMARY KEY(vaultID, profileID, owner, digest));
        """

    @Test(arguments: [false, true])
    func aLostRemovalAndAGenuineAccountSwitchAllowOnlyNewChoicesInTheVerifiedAccount(catalogFails: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (old, ordinary) = try rig.mac(holding: syncAccounts(1))
        old.sync.pauseDiscovery()
        await old.sync.settle()
        let lost = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000091"))
        let switched = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000092"))
        _ = try old.host.addVault(profile: rig.profile, vault: lost)
        _ = try old.host.addVault(profile: rig.profile, vault: switched)
        let directory = try #require(old.host.syncDirectory(profileID: rig.profile))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = try DatabaseQueue(path: directory.appending(path: VaultSyncDatabase.fileName).path)
        try await raw.write { try $0.execute(sql: Self.priorAccountDatabase) }
        let file = rig.root.appending(path: "router.json")
        var state = VaultSyncAppState()
        let user = rig.cloud.user
        state.accountUser = user
        try JSONEncoder().encode(SyncRouterState(vaults: state)).write(to: file)
        let held = CloudTabsTests.Launch.entitlements
        let gate = CloudSyncGate.Inputs(
            tabsFlag: false, vaultFlag: true, isRunningTests: false, isStaged: false, ownsSession: true, entitlement: { held[$0] }, offersMacSync: true
        )
        let pause = HostPause()
        var lookups = 0
        var transport: FakeSyncEngine?
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [], host: { old.host }, windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, _ in
                let engine = FakeSyncEngine(cloud: rig.cloud, delegate: delegate)
                engine.duringAccountLookup = {
                    lookups += 1
                    if lookups == 2 {
                        await pause.wait()
                        if catalogFails {
                            throw URLError(.notConnectedToInternet)
                        }
                    }
                }
                transport = engine
                return engine
            }
        )
        let app = try #require(started)
        let sync = try #require(app.vaults)
        let engine = try #require(transport)
        defer { app.prepareToTerminate() }
        func status(_ id: UUID) -> VaultSyncStatus {
            sync.status(profileID: rig.profile, vaultID: id)
        }
        #expect(status(lost) == .accountChanged && status(switched) == .accountChanged && status(ordinary.vaultID) == .off)
        #expect(sync.canManageCloudCopy(profileID: rig.profile, vaultID: lost) && sync.canManageCloudCopy(profileID: rig.profile, vaultID: switched))
        #expect(!sync.canManageCloudCopy(profileID: rig.profile, vaultID: ordinary.vaultID))
        #expect(await waitUntil { pause.isWaiting })
        #expect(sync.engine == nil && sync.accountAvailable == true)
        #expect(sync.connectedAccount == nil)
        await #expect(throws: VaultSyncFailure.unavailable) {
            try await sync.removeFromICloud(profileID: rig.profile, vaultID: lost, confirmingAccount: user)
        }
        await #expect(throws: VaultSyncFailure.unavailable) {
            try await sync.enable(profileID: rig.profile, vaultID: lost, confirmingAccount: user)
        }
        pause.release()
        if catalogFails {
            #expect(await waitUntil { lookups >= 3 })
            #expect(sync.connectedAccount == nil)
            app.beat()
        }
        try #require(await waitUntil { sync.engine != nil })
        await sync.settle()
        let lostZone = SyncZone.vault(profileID: rig.profile, vaultID: lost)
        let switchedZone = SyncZone.vault(profileID: rig.profile, vaultID: switched)
        #expect(sync.connectedAccount == user)
        rig.cloud.createZone(lostZone)
        rig.cloud.createZone(rig.zone)
        #expect(try await sync.checkCloudCopy(profileID: rig.profile, vaultID: lost, for: user))
        #expect(try await !sync.checkCloudCopy(profileID: rig.profile, vaultID: switched, for: user))
        await #expect(throws: VaultSyncFailure.unavailable) {
            _ = try await sync.checkCloudCopy(profileID: rig.profile, vaultID: ordinary.vaultID, for: user)
        }
        await #expect(throws: VaultSyncFailure.unavailable) {
            try await sync.removeFromICloud(profileID: rig.profile, vaultID: ordinary.vaultID, confirmingAccount: user)
        }
        try await engine.sendNow()
        #expect(rig.cloud.zones[lostZone] != nil && rig.cloud.zones[switchedZone] == nil && rig.cloud.recordCount == 0)
        try await sync.removeFromICloud(profileID: rig.profile, vaultID: lost, confirmingAccount: user)
        await sync.settle()
        try await engine.sendNow()
        #expect(rig.cloud.zones[lostZone] == nil && status(lost) == .removed(.deleted))
        #expect(!sync.hasSyncedVaults(profileID: rig.profile) && ordinary.accounts.count == 1 && rig.cloud.zones[rig.zone] != nil)

        rig.cloud.createZone(switchedZone)
        if catalogFails {
            // Lose the transport after confirmation but before the target account can be verified.
            let confirming = HostPause()
            engine.duringAccountLookup = { await confirming.wait() }
            let removal = Task { try await sync.removeFromICloud(profileID: rig.profile, vaultID: switched, confirmingAccount: user) }
            try #require(await waitUntil { confirming.isWaiting })
            app.setVaultDiscovery(false)
            confirming.release()
            await #expect(throws: VaultSyncFailure.unavailable) { try await removal.value }
            engine.duringAccountLookup = nil
            #expect(engine.pending.isEmpty)
        } else {
            // The check started in this account. A same-named zone in a new account cannot supply its answer.
            var identityReads = 0
            engine.duringAccountLookup = {
                identityReads += 1
                if identityReads == 3 {
                    rig.cloud.switchUser("another-account")
                    rig.cloud.createZone(switchedZone)
                }
            }
            await #expect(throws: VaultSyncFailure.unavailable) {
                _ = try await sync.checkCloudCopy(profileID: rig.profile, vaultID: switched, for: user)
            }
            engine.duringAccountLookup = nil
        }
        #expect(rig.cloud.zones[switchedZone] != nil && rig.cloud.recordCount == 0)
    }
}
