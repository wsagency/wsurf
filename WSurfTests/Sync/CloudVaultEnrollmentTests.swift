// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing

@testable import WSurf
@testable import WSurfCore
import WSurfVault

@MainActor
struct CloudVaultEnrollmentTests {
    enum LegacyCheckpoint: CaseIterable {
        case missing, noVaultAccount, copiedFromTabs
    }

    enum LegacyRestart: CaseIterable {
        case save, delete, discoverySave, discoveryDelete
    }

    @Test(arguments: LegacyCheckpoint.allCases, LegacyRestart.allCases)
    func tabsCannotAuthorizeALegacyVaultAtStartup(checkpoint: LegacyCheckpoint, restart: LegacyRestart) async throws {
        let discovery = restart == .discoverySave || restart == .discoveryDelete
        let deleteLocally = restart == .delete || restart == .discoveryDelete
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (old, vault) = try rig.mac(holding: syncAccounts(1))
        try await old.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        old.sync.pauseDiscovery()
        let directory = try #require(old.host.syncDirectory(profileID: rig.profile))
        let db = try #require(try VaultSyncDatabase.open(directory: directory, create: false))
        try db.write { tx in
            // Recreate the 0.1.31 v2 file, which predates both per-vault owners and the asset outbox.
            try tx.db.execute(sql: """
                CREATE TABLE legacyVault(vaultID TEXT PRIMARY KEY, enabled INTEGER NOT NULL, status TEXT NOT NULL, uploadedMark BLOB,
                    pendingVaultPayload BLOB, pendingMark BLOB, dirty INTEGER NOT NULL DEFAULT 0,
                    needsFetch INTEGER NOT NULL DEFAULT 0, lastHeadRevision INTEGER NOT NULL DEFAULT 0, rereadOwed INTEGER NOT NULL DEFAULT 0);
                INSERT INTO legacyVault SELECT vaultID, enabled, status, uploadedMark, pendingVaultPayload, pendingMark, dirty,
                    needsFetch, lastHeadRevision, rereadOwed FROM vault;
                DROP TABLE vault;
                ALTER TABLE legacyVault RENAME TO vault;
                CREATE TABLE legacyInbox(vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL, envelope BLOB NOT NULL,
                    PRIMARY KEY(vaultID, accountID));
                INSERT INTO legacyInbox SELECT vaultID, accountID, version, envelope FROM inbox;
                DROP TABLE inbox;
                ALTER TABLE legacyInbox RENAME TO inbox;
                ALTER TABLE outbox DROP COLUMN remainingAssets;
                DROP TABLE assetReceipt;
                DELETE FROM grdb_migrations WHERE identifier NOT IN ('v1', 'v2');
                """)
        }

        let file = rig.root.appending(path: "router.json")
        rig.cloud.switchUser("tabs-only-account")
        let oldQueue = Data("0.1.31 opaque engine checkpoint".utf8)
        if checkpoint != .missing {
            var vaults: [String: Any] = ["remote": [:]]
            if checkpoint == .copiedFromTabs {
                vaults["accountUser"] = rig.cloud.user
            }
            let legacy: [String: Any] = ["engineState": oldQueue.base64EncodedString(), "vaults": vaults]
            try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        }
        var tabs = TabSyncState()
        tabs.accountUser = rig.cloud.user
        try JSONEncoder().encode(tabs).write(to: CloudTabs.stateFile(besides: file))
        let defaults = try #require(UserDefaults(suiteName: AppDatabase.defaultsSuite(UUID().uuidString)))
        let held = CloudTabsTests.Launch.entitlements
        let gate = CloudSyncGate.Inputs(
            tabsFlag: true, vaultFlag: true, isRunningTests: false, isStaged: false,
            ownsSession: true, entitlement: { held[$0] }, offersMacSync: discovery
        )
        var engine: FakeSyncEngine?
        var optedIn = true
        if deleteLocally {
            rig.cloud.createZone(rig.zone)
        }
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [], host: { old.host },
            rememberVaultDiscovery: { optedIn = $0 }, optInDefaults: { _ in defaults }, windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, restoredQueue in
                let made = FakeSyncEngine(cloud: rig.cloud, delegate: delegate)
                if restoredQueue == oldQueue {
                    made.add([deleteLocally ? .deleteZone(rig.zone) : .saveZone(rig.zone)])
                }
                engine = made
                return made
            }
        )
        let app = try #require(started)
        defer { app.prepareToTerminate() }
        let sync = try #require(app.vaults)
        let transport = try #require(engine)
        if discovery {
            _ = await waitUntil { !optedIn || sync.engine != nil }
        }
        await sync.settle()
        if deleteLocally {
            sync.vaultDeleted(profileID: rig.profile, vaultID: rig.vaultID)
        }
        try await transport.sendNow()
        await sync.settle()
        #expect(rig.cloud.recordCount == 0)
        #expect((rig.cloud.zones[rig.zone] != nil) == deleteLocally)
        #expect(vault.accounts.count == 1)
        #expect(!sync.isSyncing(profileID: rig.profile, vaultID: rig.vaultID))
        guard !deleteLocally else { return }
        if discovery, !optedIn {
            app.setVaultDiscovery(true)
            #expect(await waitUntil { app.vaults?.engine != nil })
        }
        let enrolling = try #require(app.vaults)
        try await enrolling.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await transport.sendNow()
        await enrolling.settle()
        try await transport.sendNow()
        #expect(rig.cloud.recordCount == 2)
    }

    @Test func togglingDiscoveryResumesBothDirectionsUnderTheExistingLease() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let local = syncAccounts(1)[0]
        let (owner, vault) = try await rig.syncedMac(holding: [local])
        let (peer, otherVault) = try await rig.addedMac()
        owner.sync.pauseDiscovery()
        let file = rig.root.appending(path: "router.json")
        try JSONEncoder().encode(SyncRouterState(vaults: owner.sync.state)).write(to: file)
        let held = CloudTabsTests.Launch.entitlements
        let gate = CloudSyncGate.Inputs(
            tabsFlag: false, vaultFlag: true, isRunningTests: false, isStaged: false,
            ownsSession: true, entitlement: { held[$0] }, offersMacSync: true
        )
        var engine: FakeSyncEngine?
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [], host: { owner.host }, windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, _ in
                let made = FakeSyncEngine(cloud: rig.cloud, delegate: delegate)
                engine = made
                return made
            }
        )
        let app = try #require(started)
        defer { app.prepareToTerminate() }
        let initial = try #require(app.vaults)
        #expect(await waitUntil { initial.engine != nil })
        await initial.settle()
        app.setVaultDiscovery(false)
        let lease = vault.lease
        vault.edit(syncChanging(local, password: "While off"))
        let remote = SyncVaultFixtures.account(username: "peer", origin: "https://remote.test")
        otherVault.add(remote)
        await peer.wrote(otherVault)
        try await peer.pump()
        // Other Devices continues fetching through the shared engine while the vault handler is detached.
        try await engine?.fetchNow()

        app.setVaultDiscovery(true)
        let resumed = try #require(app.vaults)
        #expect(await waitUntil { resumed.engine != nil })
        await resumed.settle()
        try await engine?.sendNow()
        await resumed.settle()
        let record = try #require(rig.item(local))
        #expect(try VaultSyncCodec.openItem(record.payload, accountID: local.id, key: rig.key).account?.password == "While off")
        #expect(vault.accounts[remote.id] != nil && vault.lease == lease)
    }
}
