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
        case missing, noVaultAccount, copiedFromTabs, intermediateApproval, intermediateApprovalWithNativeQueue

        var intermediate: Bool {
            self == .intermediateApproval || self == .intermediateApprovalWithNativeQueue
        }
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
                CREATE TABLE legacyOutbox(vaultID TEXT NOT NULL, accountID TEXT NOT NULL, version INTEGER NOT NULL,
                    envelope BLOB NOT NULL, parts BLOB NOT NULL, PRIMARY KEY(vaultID, accountID));
                INSERT INTO legacyOutbox SELECT vaultID, accountID, version, envelope, parts FROM outbox;
                DROP TABLE outbox;
                ALTER TABLE legacyOutbox RENAME TO outbox;
                DROP TABLE assetReceipt;
                DELETE FROM grdb_migrations WHERE identifier NOT IN ('v1', 'v2');
                """)
            if checkpoint.intermediate {
                // The intermediate v4 release populated approvedUser from the tab-derived account on sign-in.
                try tx.db.execute(sql: """
                    ALTER TABLE vault ADD COLUMN approvedUser TEXT;
                    UPDATE vault SET approvedUser = 'tabs-only-account';
                    ALTER TABLE outbox ADD COLUMN remainingAssets BLOB;
                    CREATE TABLE assetReceipt(vaultID TEXT NOT NULL, profileID TEXT NOT NULL, owner TEXT NOT NULL,
                        digest BLOB NOT NULL, tag TEXT NOT NULL, PRIMARY KEY(vaultID, profileID, owner, digest));
                    INSERT INTO grdb_migrations(identifier) VALUES ('v3'), ('v4');
                    """)
            }
        }

        let file = rig.root.appending(path: "router.json")
        rig.cloud.switchUser("tabs-only-account")
        let oldQueue = Data("0.1.31 opaque engine checkpoint".utf8)
        if checkpoint != .missing {
            var vaults: [String: Any] = ["remote": [:]]
            if checkpoint == .copiedFromTabs || checkpoint.intermediate {
                vaults["accountUser"] = rig.cloud.user
            }
            var legacy: [String: Any] = ["engineState": oldQueue.base64EncodedString(), "vaults": vaults]
            if checkpoint == .intermediateApprovalWithNativeQueue {
                legacy["accountBoundVaultChanges"] = true
            }
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

    enum InterruptedRemoval: CaseIterable {
        case exists, missing, completedAfterRefusal, removedAfterCheck, offline, offlineDiscovery, offlineDiscoveryWithoutAccount, offlineDiscoveryWithStaleAccount
        case otherAccount, switchesBeforeRetry
    }

    @Test(arguments: InterruptedRemoval.allCases, [false, true])
    func aLostNativeRemovalIsCheckedBeforeOfferingRetry(zone: InterruptedRemoval, predatesConsent: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (old, vault) = try await rig.syncedMac(holding: syncAccounts(1))
        let user = rig.cloud.user
        let gone = zone == .missing || zone == .completedAfterRefusal
        let discovery = zone == .offlineDiscovery || zone == .offlineDiscoveryWithoutAccount || zone == .offlineDiscoveryWithStaleAccount
        old.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        if zone == .completedAfterRefusal {
            old.engine.failsZoneDeletes = true
            try await old.engine.sendNow()
            #expect(rig.status(old) == .removalFailed)
        }
        old.sync.pauseDiscovery()
        if predatesConsent {
            let db = try #require(old.sync.database(rig.profile))
            try db.write { tx in
                try tx.db.execute(sql: """
                    CREATE TABLE oldVault(vaultID TEXT PRIMARY KEY, enabled INTEGER NOT NULL, status TEXT NOT NULL, approvedUser TEXT,
                        uploadedMark BLOB, pendingVaultPayload BLOB, pendingMark BLOB, dirty INTEGER NOT NULL DEFAULT 0,
                        needsFetch INTEGER NOT NULL DEFAULT 0, lastHeadRevision INTEGER NOT NULL DEFAULT 0, rereadOwed INTEGER NOT NULL DEFAULT 0,
                        localWrappers BLOB, serverVault BLOB, pendingLocalWrappers BLOB);
                    INSERT INTO oldVault(vaultID, enabled, status, approvedUser)
                        SELECT vaultID, 0, CASE WHEN status = 'removalPending' THEN 'removedDeleted' ELSE status END, approvedUser FROM vault;
                    DROP TABLE vault;
                    ALTER TABLE oldVault RENAME TO vault;
                    DELETE FROM grdb_migrations WHERE identifier = 'vaultExplicitConsent';
                    """)
                try tx.db.execute(sql: "UPDATE vault SET approvedUser = ?", arguments: [user])
            }
        }
        let shared = rig.root.appending(path: "interrupted.json")
        var vaultState: [String: Any] = ["remote": [:]]
        if zone != .offlineDiscoveryWithoutAccount {
            vaultState["accountUser"] = zone == .offlineDiscoveryWithStaleAccount ? "old-checkpoint-account" : user
        }
        let legacy: [String: Any] = ["engineState": Data([9]).base64EncodedString(), "vaults": vaultState]
        try JSONSerialization.data(withJSONObject: legacy).write(to: shared)
        if zone == .otherAccount {
            rig.cloud.switchUser("another-apple-account")
            rig.cloud.createZone(rig.zone)
        } else if gone {
            rig.cloud.removeZoneSilently(rig.zone)
        }
        let held = CloudTabsTests.Launch.entitlements
        let gate = CloudSyncGate.Inputs(
            tabsFlag: false, vaultFlag: true, isRunningTests: false, isStaged: false, ownsSession: true, entitlement: { held[$0] }, offersMacSync: discovery
        )
        var transport: FakeSyncEngine?
        var accountLookupStarted = false
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: shared, profiles: [], host: { old.host }, windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, queue in
                #expect(queue == nil)
                let engine = FakeSyncEngine(cloud: rig.cloud, delegate: delegate)
                engine.offline = zone == .offline || discovery
                engine.duringAccountLookup = { accountLookupStarted = true }
                transport = engine
                return engine
            }
        )
        let app = try #require(started)
        defer { app.prepareToTerminate() }
        let sync = try #require(app.vaults)
        let engine = try #require(transport)
        await sync.settle()
        func status() -> VaultSyncStatus {
            sync.status(profileID: rig.profile, vaultID: rig.vaultID)
        }
        if zone == .offline || discovery {
            if discovery {
                #expect(await waitUntil { accountLookupStarted })
                #expect(sync.engine == nil)
            }
            #expect(status() == .removalPending)
            sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
            #expect(engine.pending.isEmpty && rig.cloud.zones[rig.zone] != nil)
            engine.offline = false
            app.beat()
            if discovery {
                #expect(await waitUntil { sync.engine != nil })
            }
            await sync.settle()
        }
        if gone {
            #expect(status() == .removed(.deleted))
        } else if zone == .otherAccount {
            #expect(status() == .accountChanged)
            sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
            try await engine.sendNow()
            #expect(rig.cloud.zones[rig.zone] != nil)
        } else {
            #expect(status() == .removalFailed)
            try await engine.sendNow()
            #expect(rig.cloud.zones[rig.zone] != nil && !engine.pending.contains(.deleteZone(rig.zone)))
            if zone == .removedAfterCheck {
                rig.cloud.deleteZone(rig.zone, reason: .deleted)
                try await engine.fetchNow()
            } else {
                if zone == .switchesBeforeRetry {
                    rig.cloud.switchUser("another-apple-account")
                    rig.cloud.createZone(rig.zone)
                }
                sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
                await sync.settle()
                try await engine.sendNow()
            }
            await sync.settle()
            if zone == .switchesBeforeRetry {
                #expect(status() == .accountChanged && rig.cloud.zones[rig.zone] != nil)
            } else {
                #expect(status() == .removed(.deleted) && rig.cloud.zones[rig.zone] == nil)
            }
        }
        #expect(vault.accounts.count == 1 && !sync.isSyncing(profileID: rig.profile, vaultID: rig.vaultID))
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
