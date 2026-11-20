// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore
import WSurfVault

@MainActor
struct CloudVaultEnrollmentTests {
    @Test(arguments: [false, true], [false, true])
    func tabsCannotAuthorizeALegacyVaultAtStartup(discovery: Bool, deleteLocally: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (old, vault) = try rig.mac(holding: syncAccounts(1))
        try await old.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        old.sync.pauseDiscovery()
        let directory = try #require(old.host.syncDirectory(profileID: rig.profile))
        let db = try #require(try VaultSyncDatabase.open(directory: directory, create: false))
        try db.write { tx in
            var row = try #require(try tx.vault(rig.vaultID))
            row.approvedUser = nil
            try tx.save(row)
        }

        let file = rig.root.appending(path: "router.json")
        rig.cloud.switchUser("tabs-only-account")
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
            makeEngine: { delegate, _ in
                let made = FakeSyncEngine(cloud: rig.cloud, delegate: delegate)
                engine = made
                return made
            }
        )
        let app = try #require(started)
        defer { app.prepareToTerminate() }
        let sync = try #require(app.vaults)
        let transport = try #require(engine)
        if discovery {
            _ = await waitUntil { !optedIn || transport.pending.contains(.saveZone(rig.zone)) }
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
        if discovery {
            #expect(!optedIn && app.vaults == nil)
        }
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
