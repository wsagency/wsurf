// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

extension TabSyncTests {
    @Test(arguments: [false, true])
    func aMissingZoneOnBaselineRetryEndsSharingBeforeItsDeletionPage(relaunch: Bool) async throws {
        let cloud = FakeSyncCloud(), profile = UUID(), install = "air"
        let zone = SyncZone.profile(profile), local = SyncSamples.session(tabs: ["https://air.test/"])
        let studio = SyncDevice(cloud: cloud, installID: "studio")
        studio.start(sharing: [profile])
        studio.sync.share(SyncSamples.session(tabs: ["https://studio.test/"]), profileID: profile, force: true)
        try await studio.engine.sendNow()

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabsFile = directory.appending(path: "iCloudTabs.json"), routerFile = directory.appending(path: "iCloudSync.json")
        let air = SyncDevice(cloud: cloud, installID: install)
        // Keep the last tab file from before the partial read. The router still checkpoints its cursor.
        try JSONEncoder().encode(air.sync.state).write(to: tabsFile, options: .atomic)
        let router = SyncRouter(state: .init(), persist: { checkpoint in
            do {
                try JSONEncoder().encode(checkpoint).write(to: routerFile, options: .atomic)
            } catch {
                Issue.record(error)
            }
        }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.engine.unreadable = [studio.installID]
        let held = HeldTabRead(air.engine)
        held.userDeletedZone = true
        air.sync.reconcile(sharing: [profile])
        air.sync.attach(held)
        await air.sync.refresh()
        #expect(air.engine.fetchAllCount == 2 && air.sync.state.sessions[zone] == nil)
        air.sync.share(local, profileID: profile, force: true)
        #expect(router.record(for: air.id(in: zone)) != nil)

        // The retry gets CKError.userDeletedZone. No database-deletion page has been delivered.
        cloud.deleteZone(zone, reason: .deleted)
        let client: SyncDevice
        let routing: SyncRouter
        let engine: FakeSyncEngine
        if relaunch {
            let tabs = try JSONDecoder().decode(TabSyncState.self, from: Data(contentsOf: tabsFile))
            let checkpoint = try JSONDecoder().decode(SyncRouterState.self, from: Data(contentsOf: routerFile))
            client = SyncDevice(cloud: cloud, installID: install, state: tabs)
            routing = SyncRouter(state: checkpoint, persist: { _ in }, tabs: client.sync, vaults: nil)
            engine = FakeSyncEngine(cloud: cloud, delegate: routing, state: checkpoint.engineState)
            let reader = HeldTabRead(engine)
            reader.userDeletedZone = true
            client.sync.reconcile(sharing: [profile])
            client.sync.attach(reader)
            #expect(!routing.allowsZoneCreation(zone))
            try await engine.sendNow()
            #expect(cloud.zones[zone] == nil)
        } else {
            client = air
            routing = router
            engine = air.engine
        }
        var checkedBeforeDelivery = false
        engine.beforeFetchDelivery = {
            engine.beforeFetchDelivery = nil
            checkedBeforeDelivery = true
            client.sync.share(local, profileID: profile, force: true)
            #expect(client.box.ended == [profile])
            #expect(!routing.allowsZoneCreation(zone) && routing.record(for: client.id(in: zone)) == nil)
            try await engine.sendNow()
            #expect(cloud.zones[zone] == nil)
        }
        await client.sync.refresh()
        try await engine.fetchNow()
        #expect(checkedBeforeDelivery && client.box.ended == [profile])
    }

    @Test func aFirstSaveDuringAnAbsentBaselineStillEstablishesTheZone() async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        var savedBeforeTheReadReturned = false
        air.engine.afterFullZoneRead = {
            guard air.engine.fetchAllCount == 2 else { return }
            air.engine.afterFullZoneRead = nil
            air.engine.duringAccountLookup = {
                air.engine.duringAccountLookup = nil
                air.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: profile, force: true)
                try await air.engine.sendNow()
                savedBeforeTheReadReturned = cloud.record(air.id(in: zone)) != nil
                cloud.deleteZone(zone, reason: .deleted)
            }
        }
        air.start(sharing: [profile])
        await air.sync.refresh()
        await air.sync.refresh()
        #expect(savedBeforeTheReadReturned && air.box.ended == [profile])
        #expect(!router.allowsZoneCreation(zone))
    }

    enum FirstFetchDelivery: CaseIterable { case beforeFirstSend, afterFirstSend, removedAgain, switchedAccount }

    @Test(arguments: FirstFetchDelivery.allCases)
    func aDeletionFetchedAfterAnAbsentFirstBaselineRespectsTheEnrolledAccount(delivery: FirstFetchDelivery) async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        let local = SyncSamples.session(tabs: ["https://first.test/"])
        cloud.createZone(zone)
        cloud.deleteZone(zone, reason: .purged)
        air.engine.beforeFetchDelivery = {
            air.engine.beforeFetchDelivery = nil
            #expect(air.engine.fetchAllCount == 2 && air.engine.sendCount == 0)
            #expect(cloud.zones[zone] == nil)
            switch delivery {
            case .beforeFirstSend:
                break
            case .switchedAccount:
                cloud.switchUser("another-account")
            case .afterFirstSend, .removedAgain:
                air.sync.share(local, profileID: profile, force: true)
                try await air.engine.sendNow()
                #expect(cloud.record(air.id(in: zone)) != nil)
                if delivery == .removedAgain {
                    cloud.deleteZone(zone, reason: .deleted)
                }
            }
        }

        air.start(sharing: [profile])
        await air.sync.refresh()
        #expect(air.engine.fetchCount == 1)
        switch delivery {
        case .switchedAccount, .removedAgain:
            #expect(air.box.ended == (delivery == .switchedAccount ? [nil] : [profile]))
            air.sync.share(local, profileID: profile, force: true)
            try await air.engine.sendNow()
            #expect(!router.allowsZoneCreation(zone) && cloud.zones[zone] == nil)
            return
        case .beforeFirstSend, .afterFirstSend:
            #expect(air.box.ended.isEmpty)
        }
        air.sync.share(local, profileID: profile, force: true)
        try await air.engine.sendNow()
        let record = try #require(cloud.record(air.id(in: zone)))
        #expect(try SessionCodec.decodeSession(record.payload).windows == local.windows)

        cloud.deleteZone(zone, reason: .deleted)
        try await air.engine.fetchNow()
        #expect(air.box.ended == [profile])
        #expect(!router.allowsZoneCreation(zone) && router.record(for: air.id(in: zone)) == nil)
    }
}
