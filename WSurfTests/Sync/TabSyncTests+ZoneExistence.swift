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
        if delivery == .beforeFirstSend {
            air.sync.share(local, profileID: profile, force: true)
            try await air.engine.sendNow()
        }
        let record = try #require(cloud.record(air.id(in: zone)))
        #expect(try SessionCodec.decodeSession(record.payload).windows == local.windows)

        // The historical page has finished. Only replayed engine work can run before the genuine removal arrives.
        cloud.deleteZone(zone, reason: .deleted)
        try await air.engine.sendNow()
        #expect(cloud.zones[zone] == nil)
        try await air.engine.fetchNow()
        #expect(air.box.ended == [profile])
        #expect(!router.allowsZoneCreation(zone) && router.record(for: air.id(in: zone)) == nil)
    }
}

extension TabSyncTests {
    @Test(arguments: [false, true])
    func aRestoredCreationCannotRepublishAnEstablishedZone(legacy: Bool) async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.start(sharing: [profile])
        air.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: profile, force: true)
        try await air.engine.sendNow()
        await air.sync.refresh()
        // A native checkpoint from the earlier release can contain this database change even after a successful save.
        air.engine.add([.saveZone(zone)])
        try await air.engine.fetchNow()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabsFile = directory.appending(path: "iCloudTabs.json"), routerFile = directory.appending(path: "iCloudSync.json")
        var tabBytes = try JSONEncoder().encode(air.sync.state)
        if legacy {
            var fields = try #require(JSONSerialization.jsonObject(with: tabBytes) as? [String: Any])
            fields.removeValue(forKey: "zoneObservations")
            fields.removeValue(forKey: "removalRevision")
            tabBytes = try JSONSerialization.data(withJSONObject: fields)
        }
        try tabBytes.write(to: tabsFile, options: .atomic)
        let checkpoint = legacy ? SyncRouterState(engineState: router.state.engineState) : router.state
        try JSONEncoder().encode(checkpoint).write(to: routerFile, options: .atomic)
        let state = try JSONDecoder().decode(SyncRouterState.self, from: Data(contentsOf: routerFile))
        let saved = try JSONDecoder().decode(TabSyncState.self, from: Data(contentsOf: tabsFile))
        let client = SyncDevice(cloud: cloud, installID: "air", state: saved)
        let routed = SyncRouter(state: state, persist: { _ in }, tabs: client.sync, vaults: nil)
        let engine = FakeSyncEngine(cloud: cloud, delegate: routed, state: try #require(state.engineState))
        #expect(engine.pending.contains(.saveZone(zone)))
        cloud.deleteZone(zone, reason: .deleted)
        client.sync.reconcile(sharing: [profile])
        client.sync.attach(engine)
        try await engine.sendNow()
        await client.sync.refresh()
        #expect(cloud.zones[zone] == nil && client.box.ended == [profile])
    }

    @Test(arguments: [false, true])
    func aDelayedAcceptedSaveCannotEstablishANewOptIn(deviceRow: Bool) async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = deviceRow ? SyncZone.devices : SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        let local = SyncSamples.session(tabs: ["https://same.test/"])
        air.start(sharing: [profile])
        await air.sync.refresh()
        air.sync.share(local, profileID: profile, force: true)
        var receipts: [@MainActor () async -> Void] = []
        air.engine.holdSendReceipt = { receipts.append($0) }
        try await air.engine.sendNow()
        air.engine.holdSendReceipt = nil
        let deliver = try #require(receipts.first)
        #expect(cloud.record(air.id(in: zone)) != nil)

        air.sync.reconcile(sharing: [])
        cloud.deleteZone(zone, reason: .deleted)
        air.sync.reconcile(sharing: [profile])
        air.sync.share(local, profileID: profile, force: true)
        var delivered = false
        air.engine.beforeFetchDelivery = {
            air.engine.beforeFetchDelivery = nil
            #expect(cloud.zones[zone] == nil)
            await deliver()
            delivered = true
            #expect(air.sync.state.ownSystemFields[zone] == nil)
        }
        await air.sync.refresh()
        #expect(delivered && air.box.ended.isEmpty)
        try await air.engine.sendNow()
        #expect(cloud.record(air.id(in: zone)) != nil)
    }

    @Test func olderMissingAndSavedDeviceReceiptsCannotUndoANewerIdenticalSend() async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.devices, id = air.id(in: zone)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.start(sharing: [profile])
        await air.sync.refresh()
        var held: [@MainActor () async -> Void] = []
        air.engine.holdSendReceipt = { held.append($0) }
        try await air.engine.sendNow()
        let firstSave = try #require(cloud.record(id))
        air.engine.add([.saveRecord(id)])
        air.engine.beforeRecordSave = { record in
            guard record.id == id else { return }
            air.engine.beforeRecordSave = nil
            cloud.deleteZone(zone, reason: .deleted)
        }
        try await air.engine.sendNow()
        air.engine.holdSendReceipt = nil
        try #require(held.count == 2)

        air.sync.reconcile(sharing: [])
        air.sync.reconcile(sharing: [profile])
        await air.sync.refresh()
        try await air.engine.sendNow()
        // A subsequent identical handout gets the newer server tag.
        air.engine.add([.saveRecord(id)])
        try await air.engine.sendNow()
        let current = try #require(cloud.record(id))
        #expect(try SessionCodec.decodeDevice(firstSave.payload) == SessionCodec.decodeDevice(current.payload))
        #expect(current.systemFields != firstSave.systemFields)
        for deliver in held.reversed() {
            await deliver()
            #expect(air.sync.state.ownSystemFields[zone] == current.systemFields)
            #expect(air.engine.pending.isEmpty)
        }
        #expect(air.box.ended.isEmpty)
    }
}

extension TabSyncTests {
    @Test func aDeletionPageCanPrecedeTheReceiptForTheFirstAcceptedSave() async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.start(sharing: [profile])
        await air.sync.refresh()
        air.sync.share(SyncSamples.session(tabs: ["https://first.test/"]), profileID: profile, force: true)
        var held: (@MainActor () async -> Void)?
        air.engine.holdSendReceipt = { held = $0 }
        try await air.engine.sendNow()
        air.engine.holdSendReceipt = nil
        let accepted = try #require(held)
        cloud.deleteZone(zone, reason: .deleted)
        try await air.engine.fetchNow()
        try await air.engine.sendNow()
        #expect(cloud.zones[zone] == nil)
        await accepted()
        await air.sync.refresh()
        #expect(air.box.ended == [profile] && cloud.zones[zone] == nil)
    }

    @Test func aGenuineFirstSaveStillCountsWhileAnIdenticalOlderReceiptIsOutstanding() async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.devices, id = air.id(in: zone)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.start(sharing: [profile])
        await air.sync.refresh()
        var held: [@MainActor () async -> Void] = []
        air.engine.holdSendReceipt = { held.append($0) }
        try await air.engine.sendNow()
        air.sync.reconcile(sharing: [])
        cloud.deleteZone(zone, reason: .deleted)
        air.sync.reconcile(sharing: [profile])
        await air.sync.refresh()
        try await air.engine.sendNow()
        try #require(held.count == 2 && cloud.record(id) != nil)
        air.engine.holdSendReceipt = nil
        cloud.deleteZone(zone, reason: .deleted)
        for deliver in held.reversed() {
            await deliver()
        }
        try await air.engine.sendNow()
        try await air.engine.fetchNow()
        #expect(air.box.ended == [nil] && cloud.zones[zone] == nil)
    }
}

extension TabSyncTests {
    @Test func reversedReceiptsForIdenticalSessionsKeepTheCurrentTagWithoutAnotherWrite() async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile), id = air.id(in: zone)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.start(sharing: [profile])
        await air.sync.refresh()
        air.sync.share(SyncSamples.session(tabs: ["https://same.test/"]), profileID: profile, force: true)
        var held: [@MainActor () async -> Void] = []
        air.engine.holdSendReceipt = { held.append($0) }
        try await air.engine.sendNow()
        let first = try #require(cloud.record(id))
        try await air.engine.fetchNow()
        air.engine.add([.saveRecord(id)])
        try await air.engine.sendNow()
        air.engine.holdSendReceipt = nil
        let second = try #require(cloud.record(id))
        try #require(held.count == 2 && first.payload == second.payload && first.systemFields != second.systemFields)
        let writes = cloud.writeCount
        for deliver in held.reversed() {
            await deliver()
            #expect(air.sync.state.ownSystemFields[zone] == second.systemFields)
        }
        try await air.engine.sendNow()
        #expect(cloud.writeCount == writes && air.box.ended.isEmpty)

        // Later heartbeats have distinct sequence numbers; a delayed receipt cannot force full reads for them.
        held.removeAll()
        air.engine.holdSendReceipt = { held.append($0) }
        air.engine.add([.saveRecord(id)])
        try await air.engine.sendNow()
        air.engine.holdSendReceipt = nil
        try await air.engine.fetchNow()
        let reads = air.engine.fetchAllCount
        for _ in 0..<2 {
            air.sync.share(SyncSamples.session(tabs: ["https://heartbeat.test/"]), profileID: profile, force: true)
            try await air.engine.sendNow()
        }
        let latest = try #require(cloud.record(id))
        let stale = try #require(held.first)
        await stale()
        #expect(air.engine.fetchAllCount == reads && air.sync.state.ownSystemFields[zone] == latest.systemFields)
    }

    @Test(arguments: [false, true])
    func aSuspendedFirstUploadRequiresTheSameOptInAndAccount(rejoin: Bool) async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile), id = air.id(in: zone)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        let reader = HeldTabRead(air.engine)
        air.sync.reconcile(sharing: [profile])
        air.sync.attach(reader)
        await air.sync.refresh()
        air.sync.share(SyncSamples.session(tabs: ["https://old.test/"]), profileID: profile, force: true)
        var interrupted = false
        reader.beforeReturn = { fetched in
            guard fetched == zone else { return }
            reader.beforeReturn = nil
            interrupted = true
            if rejoin {
                air.sync.reconcile(sharing: [])
                cloud.deleteZone(zone, reason: .deleted)
                air.sync.reconcile(sharing: [profile])
            } else {
                cloud.switchUser("next-account")
            }
        }
        try await air.engine.sendNow()
        #expect(interrupted && cloud.record(id) == nil)
        #expect(air.box.ended == (rejoin ? [] : [nil]))
        if rejoin {
            await air.sync.refresh()
            let fresh = SyncSamples.session(tabs: ["https://new.test/"])
            air.sync.share(fresh, profileID: profile, force: true)
            try await air.engine.sendNow()
            let record = try #require(cloud.record(id))
            #expect(try SessionCodec.decodeSession(record.payload).windows == fresh.windows)
        }
    }

    @Test func aLostFirstCreationCanRetryAfterAnOlderDeviceReceiptAndAnOfflineLookup() async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.devices, id = air.id(in: zone)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.start(sharing: [profile])
        await air.sync.refresh()
        var held: [@MainActor () async -> Void] = []
        air.engine.holdSendReceipt = { held.append($0) }
        try await air.engine.sendNow()
        air.engine.holdSendReceipt = nil
        air.sync.reconcile(sharing: [])
        cloud.deleteZone(zone, reason: .deleted)
        air.sync.reconcile(sharing: [profile])
        await air.sync.refresh()
        air.engine.losesZoneSaves = 1
        air.engine.afterFullZoneRead = {
            air.engine.afterFullZoneRead = nil
            air.engine.available = false
        }
        try await air.engine.sendNow()
        let old = try #require(held.first)
        await old()
        #expect(cloud.zones[zone] == nil && air.sync.state.ownSystemFields[zone] == nil)
        air.engine.available = true
        await air.sync.refresh()
        try await air.engine.sendNow()
        #expect(cloud.record(id) != nil && air.box.ended.isEmpty)
    }
}
