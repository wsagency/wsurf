// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Testing
@testable import WSurfCore

@testable import WSurf

extension CloudTabsTests {
    @Test(arguments: [false, true])
    func launchUpgradingA031PeerMirrorHoldsReplayUntilTheAccountIsKnown(identified: Bool) async throws {
        let launch = Launch()
        defer { launch.finish() }
        let profile = Profile.original(), zone = SyncZone.profile(profile.id)
        // 0.1.31 could cache another Mac's session before this Mac's first save.
        let peer = MirroredSession(payload: SyncSamples.session(tabs: ["https://studio.test/"]), modifiedAt: .distantPast)
        let mirrors = try JSONSerialization.jsonObject(with: JSONEncoder().encode([zone: ["studio": peer]]))
        var tabFile: [String: Any] = ["seq": 0, "devices": [:], "sessions": mirrors, "ownSystemFields": [:]]
        if identified {
            tabFile["accountUser"] = launch.cloud.user
        }
        let routerFile: [String: Any] = ["vaults": ["remote": [:]], "engineState": Data("0.1.31".utf8).base64EncodedString()]
        try FileManager.default.createDirectory(at: launch.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: tabFile).write(to: CloudTabs.stateFile(besides: launch.stateFile), options: .atomic)
        try JSONSerialization.data(withJSONObject: routerFile).write(to: launch.stateFile, options: .atomic)

        let tabs = try #require(launch.start(optedIn: true))
        launch.engine.available = false
        try await launch.sendAll()
        #expect(launch.cloud.zones[zone] == nil)
        launch.engine.available = true
        await tabs.sync.refresh()
        try await launch.sendAll()
        #expect(!tabs.isOptedIn(profile.id) && launch.cloud.zones[zone] == nil && launch.cloud.recordCount == 0)
    }

    enum WithdrawnSession: CaseIterable { case currentFiles, staleTabsFile, signedOut, returnedWhileClosed }

    @Test(arguments: WithdrawnSession.allCases)
    func anOptedOutLaunchWithdrawsItsFirstUnacknowledgedSessionFromDisk(restart: WithdrawnSession) async throws {
        let launch = Launch()
        defer { launch.finish() }
        let install = MemoryInstallIDStorage(value: UUID().uuidString)
        let tabs = try #require(launch.start(optedIn: true, installIDs: install))
        let profile = Profile.original(), id = launch.personalSessionID
        await tabs.sync.refresh()
        let file = CloudTabs.stateFile(besides: launch.stateFile)
        let before = try Data(contentsOf: file)
        tabs.sync.share(SyncSamples.session(tabs: ["https://first.test/"]), profileID: profile.id, force: true)
        var held: (@MainActor () async -> Void)?
        launch.engine.holdSendReceipt = { held = $0 }
        try await launch.engine.sendNow()
        launch.engine.holdSendReceipt = nil
        try #require(held != nil && launch.cloud.record(id) != nil && tabs.sync.state.ownSystemFields[id.zone] == nil)
        launch.cloud.deleteRecord(.init(zone: SyncZone.devices, name: id.name))
        tabs.setOptIn(false, for: profile)
        let writes = launch.cloud.writeCount
        if restart == .signedOut || restart == .returnedWhileClosed {
            launch.engine.available = false
            await launch.engine.simulateAccount(.signOut)
            if restart == .returnedWhileClosed {
                await launch.engine.simulateAccount(.signIn(user: "B"))
                // The process exits in B. The next launch finds A without receiving another account-change event.
                try before.write(to: file, options: .atomic)
            }
        } else if restart == .staleTabsFile {
            try before.write(to: file, options: .atomic)
        }

        let restored = try #require(launch.start(installIDs: install))
        try #require(launch.engines.count == 2)
        let engine = try #require(launch.engines.last)
        engine.available = false
        try await engine.sendNow()
        #expect(!restored.isOptedIn(profile.id) && launch.cloud.names(in: id.zone) == [id.name])
        engine.available = true
        if restart == .signedOut {
            await engine.simulateAccount(.signIn(user: launch.cloud.user))
        } else if restart == .returnedWhileClosed {
            await restored.sync.refresh()
        }
        try await engine.sendNow()
        #expect(launch.cloud.recordCount == 0 && launch.cloud.writeCount == writes)
        _ = try #require(launch.start(installIDs: install))
        #expect(launch.engines.count == 2)
    }

    @Test(arguments: [false, true])
    func aDelayedSwitchPreservesPersonalsSavedChoiceAfterAnotherLaunch(reenroll: Bool) async throws {
        let launch = Launch(), other = FakeSyncCloud(user: "B")
        defer { launch.finish() }
        let install = MemoryInstallIDStorage(value: UUID().uuidString), profile = Profile.original()
        let saved = try await prepareReturn(launch, via: other, install: install, reenroll: reenroll)
        let id = saved.id, engineStateB = saved.engineState

        let reopened = try #require(launch.start(installIDs: install))
        let third = try #require(launch.engines.last)
        try #require(launch.engines.count == 3 && reopened.isOptedIn(profile.id) == reenroll)
        third.available = false
        await third.simulateAccount(.switchAccounts(user: launch.cloud.user), from: other.user)
        #expect(reopened.isOptedIn(profile.id) == reenroll && launch.defaults.bool(forKey: CloudTabs.optInKey) == reenroll)
        try #require(try JSONDecoder().decode(SyncRouterState.self, from: Data(contentsOf: launch.stateFile)).engineState == engineStateB)
        let replayed = try #require(launch.start(installIDs: install))
        let fourth = try #require(launch.engines.last)
        fourth.available = false
        await fourth.simulateAccount(.switchAccounts(user: launch.cloud.user), from: other.user)
        #expect(replayed.isOptedIn(profile.id) == reenroll && launch.defaults.bool(forKey: CloudTabs.optInKey) == reenroll)
        if reenroll {
            replayed.setOptIn(false, for: profile)
        }
        let writes = launch.cloud.writeCount
        fourth.available = true
        try await fourth.sendNow()
        #expect(launch.cloud.record(id) == nil && launch.cloud.writeCount == writes)
    }

    @Test func aVaultOnlyAccountRoundTripCannotRestoreAnOlderPersonalConsent() async throws {
        let launch = Launch(), other = FakeSyncCloud(user: "B")
        defer { launch.finish() }
        let install = MemoryInstallIDStorage(value: UUID().uuidString), profile = Profile.original()
        let saved = try await prepareReturn(launch, via: other, install: install, reenroll: true)
        let original = try #require(launch.cloud.record(saved.id))
        let peerID = SyncRecordID(zone: saved.id.zone, name: "studio")
        other.createZone(saved.id.zone)
        _ = other.save(SyncRecord(id: saved.id, type: .deviceSession, schema: 1, payload: original.payload))
        _ = launch.cloud.save(SyncRecord(id: peerID, type: .deviceSession, schema: 1, payload: original.payload))
        let peer = try #require(launch.cloud.record(peerID)), foreign = try #require(other.record(saved.id))
        try saved.routerInB.write(to: launch.stateFile, options: .atomic)
        install.failsReads = true
        var gate = launch.gate()
        gate.vaultFlag = true
        func startWithVault() throws -> (CloudSync, FakeSyncEngine) {
            var transport: FakeSyncEngine?
            let sync = CloudSync.start(
                gate: gate, installIDs: install, stateFile: launch.stateFile, profiles: [profile],
                host: { FakeVaultHost(root: launch.directory) }, optInDefaults: { _ in launch.defaults },
                windows: { launch.models }, clock: launch.clock,
                makeEngine: { delegate, checkpoint in
                    let engine = FakeSyncEngine(cloud: launch.cloud, delegate: delegate, state: checkpoint)
                    transport = engine
                    return engine
                }
            )
            return (try #require(sync), try #require(transport))
        }
        let (visiting, vaultEngine) = try startWithVault()
        defer { visiting.prepareToTerminate() }
        try #require(visiting.tabs == nil && visiting.vaults != nil)
        await vaultEngine.simulateAccount(.switchAccounts(user: launch.cloud.user), from: other.user)
        vaultEngine.cloud = other
        await vaultEngine.simulateAccount(.switchAccounts(user: other.user), from: launch.cloud.user)
        try await vaultEngine.fetchNow()
        try #require(visiting.vaults?.state.accountUser == other.user)

        install.failsReads = false
        let (returned, engine) = try startWithVault()
        defer { returned.prepareToTerminate() }
        let restored = try #require(returned.tabs)
        restored.sync.share(SyncSamples.session(tabs: ["https://unapproved.test/"]), profileID: profile.id, force: true)
        await restored.sync.refresh()
        try await engine.sendNow()
        #expect(launch.cloud.record(saved.id) == original)
        await engine.simulateAccount(.switchAccounts(user: launch.cloud.user), from: other.user)
        await restored.sync.refresh()
        try await engine.sendNow()
        #expect(!restored.isOptedIn(profile.id) && !launch.defaults.bool(forKey: CloudTabs.optInKey))
        #expect(launch.cloud.record(saved.id) == original && launch.cloud.record(peerID) == peer && other.record(saved.id) == foreign)
    }

    private func prepareReturn(
        _ launch: Launch, via other: FakeSyncCloud, install: MemoryInstallIDStorage, reenroll: Bool
    ) async throws -> (id: SyncRecordID, routerInB: Data, engineState: Data) {
        let profile = Profile.original()
        launch.models = [BrowserModel(database: .temporary())]
        let original = try #require(launch.start(optedIn: true, installIDs: install))
        let id = launch.personalSessionID
        await original.sync.refresh()
        original.sync.share(SyncSamples.session(tabs: ["https://first.test/"]), profileID: profile.id, force: true)
        launch.engine.holdSendReceipt = { _ in }
        try await launch.engine.sendNow()
        try #require(launch.cloud.record(id) != nil && original.sync.state.ownSystemFields[id.zone] == nil)
        original.setOptIn(false, for: profile)
        await launch.engine.simulateAccount(.signOut)
        launch.engine.cloud = other
        await launch.engine.simulateAccount(.signIn(user: other.user))
        try await launch.engine.fetchNow()
        let routerInB = try Data(contentsOf: launch.stateFile)
        let engineStateB = try #require(try JSONDecoder().decode(SyncRouterState.self, from: routerInB).engineState)

        let visiting = try #require(launch.start(installIDs: install))
        let second = try #require(launch.engines.last)
        second.cloud = other
        await visiting.sync.refresh()
        second.cloud = launch.cloud
        await visiting.sync.refresh()
        try #require(visiting.sync.wantsRecordDeletion(id))
        second.available = false
        if reenroll {
            visiting.setOptIn(true, for: profile)
        }
        try #require(launch.cloudSync?.router.state.engineState == engineStateB)

        return (id, routerInB, engineStateB)
    }

    @Test func nativeRowDeleteErrorsSettleOnlyDefinitivelyAbsentTabRecords() {
        let session = CKRecord.ID(recordName: "air", zoneID: .init(zoneName: SyncZone.profile(UUID()), ownerName: CKCurrentUserDefaultName))
        let device = CKRecord.ID(recordName: "air", zoneID: .init(zoneName: SyncZone.devices, ownerName: CKCurrentUserDefaultName))
        let foreign = CKRecord.ID(recordName: "other", zoneID: .init(zoneName: "shared-spaces", ownerName: CKCurrentUserDefaultName))
        for code in [CKError.Code.unknownItem, .zoneNotFound, .userDeletedZone] {
            #expect(CloudKitMapping.completedRecordDeletes([], failures: [session: CKError(code), foreign: CKError(code)]) == [CloudKitMapping.syncID(session)])
        }
        for code in [CKError.Code.notAuthenticated, .networkUnavailable, .permissionFailure] {
            #expect(CloudKitMapping.completedRecordDeletes([device], failures: [session: CKError(code)]) == [CloudKitMapping.syncID(device)])
        }
    }
}
