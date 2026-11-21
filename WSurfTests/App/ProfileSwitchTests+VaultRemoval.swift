// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore

extension ProfileSwitchTests {
    @MainActor
    final class VaultRemovalLaunch {
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
        try await VaultManagerFixture.with(vaults: [.locked, .locked]) { profile, _, vaults in
            try await checkApprovedRemoval(profile, vaults: vaults, alreadyAbsent: alreadyAbsent)
        }
    }

    private func checkApprovedRemoval(_ profile: Profile, vaults: [FixtureVault], alreadyAbsent: Bool) async throws {
        let files = FileManager.default, root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json"), routerFile = root.appending(path: "iCloudSync.json")
        let catalog = ProfileStore(file: file), kept = catalog.add(name: "Kept")
        let work = try #require(catalog.adopt(id: profile.id, name: "Work", symbol: "key", color: .blue))
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
        let active = try host.addVault(profile: work.id, vault: vaults[0].vaultID)
        let disabled = try host.addVault(profile: work.id, vault: vaults[1].vaultID)
        let other = try host.addVault(profile: kept.id)
        active.add(syncAccounts(1)[0])
        for vault in [active, disabled, other] {
            try await sync.enable(profileID: vault.profileID, vaultID: vault.vaultID)
        }
        for _ in 0..<4 {
            await sync.settle()
            try await engine.sendNow()
        }
        try sync.disable(profileID: work.id, vaultID: disabled.vaultID)
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
        let original = try #require(owner.records(in: zone))
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
        #expect(original.allSatisfy { owner.record($0.id) == $0 })
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

    @Test func aLegacyWithdrawalCanConfirmAbsenceButCannotIdentifyAReplacementByName() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "profiles.json")
        let cloud = FakeSyncCloud(user: "synthetic-owner"), profileID = UUID(), vaultID = UUID()
        // This is the exact previous checkpoint format, which contains no per-request marker.
        let old = VaultProfileRemoval(profileID: profileID, vaultID: vaultID, owner: cloud.user)
        struct OldList: Encodable {
            var profiles: [Profile]
            var currentID: UUID
            var vaultRemovals: [VaultProfileRemoval]
        }
        try JSONFileStore.writeAtomically(OldList(profiles: [.original()], currentID: Profile.originalID, vaultRemovals: [old]), to: file, sortedKeys: true)
        let catalog = ProfileStore(file: file), launch = VaultRemovalLaunch()
        let zone = SyncZone.vault(profileID: profileID, vaultID: vaultID)
        cloud.createZone(zone)
        let copy = SyncRecord(id: SyncRecordID(zone: zone, name: "vault"), type: .vault, schema: 1, payload: Data("replacement".utf8))
        guard case .saved = cloud.save(copy) else { throw VaultSyncFailure.unavailable }
        let contents = try #require(cloud.records(in: zone))
        let app = try launch.start(catalog, file: root.appending(path: "router.json"), cloud: cloud, host: CredentialVaultSyncHost(profiles: { catalog.profiles }), discovery: false)
        defer { app.prepareToTerminate() }
        try #require(await waitUntil { launch.lookups > 0 })
        #expect(catalog.vaultRemovals == [old] && cloud.records(in: zone) == contents)
        cloud.removeZoneSilently(zone)
        #expect(await waitUntil { app.beat(); return catalog.vaultRemovals.isEmpty })
        #expect(ProfileStore(file: file).vaultRemovals.isEmpty)
    }

    @Test func aVaultRemovalRequiresAReceiptForItsConcreteZoneOwner() async throws {
        let removal = VaultProfileRemoval(profileID: UUID(), vaultID: UUID(), owner: "synthetic-owner")
        let expectedZone = SyncZone.vault(profileID: removal.profileID, vaultID: removal.vaultID)
        var user = "synthetic-visitor"
        await #expect(throws: VaultSyncFailure.self) {
            try await removal.withOwnedZone(currentUser: { user }) { _ in Issue.record("Sent to the visiting account") }
        }
        user = "synthetic-owner"
        await #expect(throws: VaultSyncFailure.self) {
            try await removal.withOwnedZone(currentUser: { user }) { id in
                #expect(id.ownerName == "synthetic-owner" && id.zoneName == expectedZone)
                user = "synthetic-visitor"
                throw CKError(.zoneNotFound)
            }
        }
        user = "synthetic-owner"
        await #expect(throws: CKError.self) {
            try await removal.withOwnedZone(currentUser: { user }) { _ in throw CKError(.serviceUnavailable) }
        }
        try await removal.withOwnedZone(currentUser: { user }) { _ in throw CKError(.userDeletedZone) }
    }
}
