// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore

extension ProfileSwitchTests {
    @MainActor
    private final class VaultRemovalLaunch {
        var engine: FakeSyncEngine?
        var lookups = 0

        func start(
            _ catalog: ProfileStore, file: URL, cloud: FakeSyncCloud, host: any VaultSyncHost, discovery: Bool, refuse: Bool = false
        ) throws -> CloudSync {
            let gate = CloudSyncGate.Inputs(
                tabsFlag: false, vaultFlag: discovery, isRunningTests: false, isStaged: false, ownsSession: true,
                entitlement: { CloudTabsTests.Launch.entitlements[$0] }, offersMacSync: true
            )
            let started = CloudSync.start(
                gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: catalog.profiles, profileStore: catalog,
                host: { host }, windows: { [] }, clock: TestClock(), makeEngine: { delegate, state in
                    let engine = FakeSyncEngine(cloud: cloud, delegate: delegate, state: state)
                    engine.failsZoneDeletes = refuse
                    engine.duringAccountLookup = { self.lookups += 1 }
                    self.engine = engine
                    return engine
                }
            )
            return try #require(started)
        }
    }

    @Test(arguments: [false, true])
    func deletingAProfileFromSettingsFinishesOnlyItsApprovedVaultRemovalAfterRestart(alreadyAbsent: Bool) async throws {
        let files = FileManager.default, root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json"), routerFile = root.appending(path: "iCloudSync.json")
        let catalog = ProfileStore(file: file), work = catalog.add(name: "Work"), kept = catalog.add(name: "Kept")
        let host = FakeVaultHost(root: work.supportDirectory.deletingLastPathComponent())
        let owner = FakeSyncCloud(user: "synthetic-owner"), visitor = FakeSyncCloud(user: "synthetic-visitor")
        let previous = CloudSync.shared
        defer {
            CloudSync.shared = previous
            for directory in [root, work.supportDirectory, kept.supportDirectory] {
                try? files.removeItem(at: directory)
            }
        }

        let first = VaultRemovalLaunch()
        let app = try first.start(catalog, file: routerFile, cloud: owner, host: host, discovery: true)
        CloudSync.shared = app
        defer { app.prepareToTerminate() }
        let sync = try #require(app.vaults)
        try #require(await waitUntil { sync.engine != nil })
        let engine = try #require(first.engine)
        let active = try host.addVault(profile: work.id), disabled = try host.addVault(profile: work.id)
        let other = try host.addVault(profile: kept.id)
        active.add(syncAccounts(1)[0])
        for vault in [active, disabled, other] {
            try await sync.enable(profileID: vault.profileID, vaultID: vault.vaultID)
        }
        for _ in 0..<4 {
            await sync.settle()
            try await engine.sendNow()
        }
        sync.disable(profileID: work.id, vaultID: disabled.vaultID)
        let zone = SyncZone.vault(profileID: work.id, vaultID: active.vaultID)
        let unapproved = UUID()
        let never = SyncZone.vault(profileID: work.id, vaultID: unapproved)
        // Older releases could mark a vault enabled without recording a per-vault account choice.
        do {
            let opened = try VaultSyncDatabase.open(directory: work.supportDirectory, create: false)
            let db = try #require(opened)
            try db.write { try $0.save(VaultRow(vaultID: unapproved)) }
        }
        let keptZones = [SyncZone.vault(profileID: work.id, vaultID: disabled.vaultID), never, SyncZone.vault(profileID: kept.id, vaultID: other.vaultID)]
        owner.createZone(never)
        visitor.createZone(zone)
        try #require(sync.hasSyncedVaults(profileID: work.id) && owner.names(in: zone).count == 2)
        let preserved = keptZones.map { owner.names(in: $0) }
        engine.offline = true

        // Hold the same window handoff that follows the Settings confirmation. These are the exact bytes a killed app leaves.
        let selection = ProfileStore.selection(profile: .original(), catalog: catalog)
        let coordinator = AppCoordinator(browser: BrowserModel(context: .shared(for: .original()), windowID: UUID()), profiles: selection)
        let pause = HostPause()
        let busy = Task { await coordinator.profileSwitches.run { await pause.wait() } }
        defer { pause.release() }
        try #require(await waitUntil { pause.isWaiting })
        let deleting = Task { await coordinator.deleteProfile(work) }
        try #require(await waitUntil { !catalog.profiles.contains(work) })
        let checkpoint = try Data(contentsOf: file)
        let syncFile = work.supportDirectory.appending(path: VaultSyncDatabase.fileName)
        try #require(files.fileExists(atPath: syncFile.path))
        pause.release()
        await busy.value
        try await deleting.value.get()
        #expect(!files.fileExists(atPath: syncFile.path))
        #expect(!engine.pending.contains(.deleteZone(zone)))
        app.prepareToTerminate()
        CloudSync.shared = nil

        try checkpoint.write(to: file, options: .atomic)
        let visiting = ProfileStore(file: file)
        let visitingHost = CredentialVaultSyncHost(profiles: { visiting.profiles })
        let away = VaultRemovalLaunch()
        let awayApp = try away.start(visiting, file: routerFile, cloud: visitor, host: visitingHost, discovery: false)
        defer { awayApp.prepareToTerminate() }
        awayApp.beat()
        #expect(await waitUntil(timeout: .seconds(2)) { away.lookups > 0 })
        try await away.engine?.sendNow()
        #expect(visitor.zones[zone] != nil && owner.names(in: zone).count == 2)
        struct Checkpoint: Decodable { var pendingErasures: [Profile]? }
        try #require(await waitUntil {
            let saved = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: file))
            return saved != nil && (saved?.pendingErasures ?? []).isEmpty
        })
        #expect(try String(contentsOf: file, encoding: .utf8).contains(active.vaultID.uuidString))
        awayApp.prepareToTerminate()

        let returning = ProfileStore(file: file)
        let back = VaultRemovalLaunch()
        let backApp = try back.start(returning, file: routerFile, cloud: owner, host: CredentialVaultSyncHost(profiles: { returning.profiles }), discovery: false, refuse: true)
        defer { backApp.prepareToTerminate() }
        #expect(await waitUntil(timeout: .seconds(2)) { back.lookups > 0 })
        #expect(owner.names(in: zone).count == 2)
        #expect(try String(contentsOf: file, encoding: .utf8).contains(active.vaultID.uuidString))
        if alreadyAbsent {
            owner.removeZoneSilently(zone)
        }
        back.engine?.failsZoneDeletes = false
        #expect(try await waitUntil(timeout: .seconds(3)) {
            backApp.beat()
            let saved = try String(contentsOf: file, encoding: .utf8)
            return owner.zones[zone] == nil && !saved.contains(active.vaultID.uuidString)
        })
        #expect(keptZones.allSatisfy { owner.zones[$0] != nil } && keptZones.map { owner.names(in: $0) } == preserved)
        #expect(visitor.zones[zone] != nil && returning.profiles == [.original(), kept])
        #expect(try !String(contentsOf: file, encoding: .utf8).contains(work.id.uuidString))

        // A restored first-upload queue must not recreate the withdrawn zone after its receipt was saved.
        back.engine?.add([.saveZone(zone)])
        try await back.engine?.sendNow()
        #expect(owner.zones[zone] == nil)
        owner.createZone(zone)
        backApp.beat()
        try await back.engine?.sendNow()
        #expect(owner.zones[zone] != nil)
    }

    @Test func aVaultRemovalRequiresAReceiptForItsConcreteZoneOwner() async throws {
        let removal = VaultProfileRemoval(profileID: UUID(), vaultID: UUID(), owner: "synthetic-owner")
        let expectedZone = SyncZone.vault(profileID: removal.profileID, vaultID: removal.vaultID)
        var user = "synthetic-visitor"
        await #expect(throws: VaultSyncFailure.self) {
            try await removal.delete(currentUser: { user }) { _ in Issue.record("Sent to the visiting account") }
        }
        user = "synthetic-owner"
        await #expect(throws: VaultSyncFailure.self) {
            try await removal.delete(currentUser: { user }) { id in
                #expect(id.ownerName == "synthetic-owner" && id.zoneName == expectedZone)
                user = "synthetic-visitor"
                throw CKError(.zoneNotFound)
            }
        }
        user = "synthetic-owner"
        await #expect(throws: CKError.self) {
            try await removal.delete(currentUser: { user }) { _ in throw CKError(.serviceUnavailable) }
        }
        try await removal.delete(currentUser: { user }) { _ in throw CKError(.userDeletedZone) }
    }
}
