// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing

@testable import WSurf
@testable import WSurfCore
import WSurfVault

extension CloudVaultEnrollmentTests {
    static func restoreV2Schema(_ db: Database) throws {
        // Recreate the 0.1.31 v2 file, which predates both per-vault owners and the asset outbox.
        try db.execute(sql: """
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
    }

    enum OldRemoval: CaseIterable {
        case v2Queued, v2Failed, upgradedQueued, upgradedFailed

        var stored: String {
            self == .v2Queued || self == .upgradedQueued ? "removedDeleted" : "removalFailed"
        }
    }

    @Test(arguments: OldRemoval.allCases, [false, true])
    func aRemovalWithoutAnOwnerNeedsANewChoiceForThisAccount(legacy: OldRemoval, remove: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (old, vault) = try await rig.syncedMac(holding: syncAccounts(1))
        let user = rig.cloud.user
        let directory = try #require(old.host.syncDirectory(profileID: rig.profile))
        let database = try #require(old.sync.database(rig.profile))
        old.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        old.sync.pauseDiscovery()
        try database.write { tx in
            try Self.restoreV2Schema(tx.db)
            try tx.db.execute(sql: "UPDATE vault SET enabled = 0, status = ?", arguments: [legacy.stored])
        }
        if legacy == .upgradedQueued || legacy == .upgradedFailed {
            // An earlier 0.2 build had already upgraded this v2 file and left the receipt without an owner.
            let upgraded = try #require(try VaultSyncDatabase.open(directory: directory, create: false))
            try upgraded.write { tx in
                try tx.db.execute(sql: "UPDATE vault SET status = ?", arguments: [legacy.stored])
                try tx.db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'vaultUnconfirmedRemovals'")
            }
        }
        let file = rig.root.appending(path: "router.json")
        let oldQueue = Data("old unconfirmed zone deletion".utf8)
        var vaultState: [String: Any] = ["remote": [:]]
        if legacy != .v2Queued {
            vaultState["accountUser"] = legacy == .upgradedQueued ? "stale-checkpoint-account" : user
        }
        let checkpoint: [String: Any] = ["engineState": oldQueue.base64EncodedString(), "vaults": vaultState]
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: file)
        let entitlements = CloudTabsTests.Launch.entitlements
        let gate = CloudSyncGate.Inputs(
            tabsFlag: false, vaultFlag: true, isRunningTests: false, isStaged: false, ownsSession: true, entitlement: { entitlements[$0] }, offersMacSync: true
        )
        var transport: FakeSyncEngine?
        var attemptedDiscovery = false
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [], host: { old.host }, windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, queue in
                let engine = FakeSyncEngine(cloud: rig.cloud, delegate: delegate)
                engine.offline = true
                engine.duringAccountLookup = { attemptedDiscovery = true }
                if queue == oldQueue {
                    engine.add([.deleteZone(rig.zone)])
                }
                transport = engine
                return engine
            }
        )
        let app = try #require(started)
        defer { app.prepareToTerminate() }
        let sync = try #require(app.vaults)
        let engine = try #require(transport)
        #expect(await waitUntil { attemptedDiscovery })
        func status(_ handler: VaultSync) -> VaultSyncStatus {
            handler.status(profileID: rig.profile, vaultID: rig.vaultID)
        }
        #expect(status(sync) == .removalUnconfirmed)
        sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID, confirmingAccount: user)
        await sync.settle()
        #expect(engine.pending.isEmpty)
        engine.offline = false
        app.beat()
        if legacy == .v2Queued || legacy == .upgradedQueued {
            #expect(await waitUntil { app.vaults == nil })
            app.setVaultDiscovery(true)
        }
        let online = try #require(app.vaults)
        #expect(await waitUntil { online.engine != nil })
        await online.settle()
        try await engine.sendNow()
        #expect(rig.cloud.recordCount == 2)
        #expect(status(online) == .removalUnconfirmed)

        let other = "other-apple-account"
        rig.cloud.switchUser(other)
        if remove {
            rig.cloud.createZone(rig.zone)
        }
        // Discovery still shows the first account. A removal confirmed during the switch cannot delete in the new account.
        online.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID, confirmingAccount: user)
        await online.settle()
        try await engine.sendNow()
        #expect((rig.cloud.zones[rig.zone] != nil) == remove && status(online) == .removalUnconfirmed)
        await engine.simulateAccount(.switchAccounts(user: other))
        app.setVaultDiscovery(true)
        let current = try #require(app.vaults)
        #expect(await waitUntil { current.engine != nil })
        await current.settle()
        try await engine.sendNow()
        #expect(status(current) == .removalUnconfirmed)
        #expect((rig.cloud.zones[rig.zone] != nil) == remove && rig.cloud.recordCount == 0)
        // A retry without a target or a confirmation displayed for the previous account cannot authorize either choice.
        current.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        current.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID, confirmingAccount: user)
        await #expect(throws: VaultSyncFailure.unavailable) {
            try await current.enable(profileID: rig.profile, vaultID: rig.vaultID, confirmingAccount: user)
        }
        await current.settle()
        try await engine.sendNow()
        #expect((rig.cloud.zones[rig.zone] != nil) == remove && rig.cloud.recordCount == 0 && status(current) == .removalUnconfirmed)
        if remove {
            current.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID, confirmingAccount: other)
            await current.settle()
            try await engine.sendNow()
            #expect(rig.cloud.zones[rig.zone] == nil && status(current) == .removed(.deleted))
        } else {
            try await current.enable(profileID: rig.profile, vaultID: rig.vaultID, confirmingAccount: other)
            await current.settle()
            try await engine.sendNow()
            #expect(current.isSyncing(profileID: rig.profile, vaultID: rig.vaultID) && rig.cloud.recordCount == 2)
        }
        #expect(vault.accounts.count == 1)
    }
}
