// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

extension TabSyncTests {
    enum OldTabFiles: CaseIterable { case shipped, revision, newerRouter, signedOut, pendingDevices, bothPending }

    @Test(arguments: OldTabFiles.allCases)
    func upgradingEstablishedPersonalCannotReplayCreationBeforeAnAccountLookup(files: OldTabFiles) async throws {
        let cloud = FakeSyncCloud(), profile = UUID(), zone = SyncZone.profile(profile)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabsFile = directory.appending(path: "iCloudTabs.json"), routerFile = directory.appending(path: "iCloudSync.json")
        let prior = SyncRouter(state: .init(), persist: { _ in }, tabs: nil, vaults: nil)
        let transport = FakeSyncEngine(cloud: cloud, delegate: prior)
        if files == .pendingDevices || files == .bothPending {
            cloud.createZone(zone)
            cloud.deleteZone(zone, reason: .deleted)
        }
        transport.add([.saveZone(zone)])
        try await transport.fetchNow()
        let oldQueue = try #require(prior.state.engineState)

        // ea43123a (0.1.31) writes just engineState/vaults. 77b5152f also writes a revision for a cleared stop.
        let fields = FakeSyncCloud.fields(for: 1).base64EncodedString()
        var tabs: [String: Any] = ["seq": 1, "ownSystemFields": [zone: fields], "devices": [:], "sessions": [:]]
        var router: [String: Any] = ["engineState": oldQueue.base64EncodedString(), "vaults": ["remote": [:]]]
        if files != .signedOut {
            tabs["accountUser"] = cloud.user
        }
        if files != .shipped && files != .signedOut {
            tabs["removalRevision"] = 4
            router["explicitVaultChanges"] = true
            var removal: [String: Any] = ["revision": files == .revision ? 4 : 5]
            if files == .pendingDevices || files == .bothPending {
                cloud.createZone(SyncZone.devices)
                let pending: [String: Any] = ["account": cloud.user, "profiles": [profile.uuidString], "zones": [SyncZone.devices]]
                removal["pending"] = pending
                if files == .bothPending {
                    tabs["removalCheck"] = pending
                }
            }
            router["tabRemoval"] = removal
        }
        try JSONSerialization.data(withJSONObject: tabs).write(to: tabsFile, options: .atomic)
        try JSONSerialization.data(withJSONObject: router).write(to: routerFile, options: .atomic)
        let saved = try JSONDecoder().decode(TabSyncState.self, from: Data(contentsOf: tabsFile))
        let checkpoint = try JSONDecoder().decode(SyncRouterState.self, from: Data(contentsOf: routerFile))
        let air = SyncDevice(cloud: cloud, installID: "air", state: saved)
        // CloudTabs restores the local switch before the router binds its separate engine checkpoint.
        air.sync.reconcile(sharing: [profile])
        let routed = SyncRouter(state: checkpoint, persist: { _ in }, tabs: air.sync, vaults: nil)
        let engine = FakeSyncEngine(cloud: cloud, delegate: routed, state: checkpoint.engineState)
        #expect(engine.pending.contains(.saveZone(zone)) == (files != .shipped && files != .signedOut))
        engine.available = false
        air.sync.attach(engine)
        #expect(!routed.allowsZoneCreation(zone))
        try await engine.sendNow()
        #expect(cloud.zones[zone] == nil)
        engine.available = true
        await air.sync.refresh()
        try await engine.sendNow()
        #expect(air.box.ended == (files == .signedOut ? [nil] : [profile]) && cloud.zones[zone] == nil)
    }

    @Test(arguments: [false, true])
    func anAutomaticRemovalDuringTheFirstReadUsesCurrentZoneEvidence(existed: Bool) async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        let reader = HeldTabRead(air.engine)
        cloud.createZone(SyncZone.devices)
        cloud.createZone(zone)
        if !existed {
            cloud.deleteZone(zone, reason: .deleted)
        }
        var delivered = false
        reader.beforeReturn = { fetched in
            guard fetched == (existed ? zone : SyncZone.devices) else { return }
            reader.beforeReturn = nil
            if existed {
                cloud.deleteZone(zone, reason: .deleted)
            }
            try await air.engine.fetchNow()
            delivered = true
        }
        air.sync.reconcile(sharing: [profile])
        air.sync.attach(reader)
        await air.sync.refresh()
        await air.sync.refresh()
        #expect(delivered && air.engine.sendCount == 0 && air.box.ended == (existed ? [profile] : []))
        air.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: profile, force: true)
        try await air.engine.sendNow()
        #expect((cloud.record(air.id(in: zone)) != nil) == !existed)
    }

    @Test func anInitiallyUnboundFetchCanVerifyItsOwnAccountBeforeTreatingADeletionAsHistorical() async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        cloud.createZone(zone)
        cloud.deleteZone(zone, reason: .deleted)
        var delivered = false
        air.engine.duringAccountLookup = {
            air.engine.duringAccountLookup = {
                air.engine.duringAccountLookup = nil
                #expect(!router.allowsZoneCreation(zone))
                // An interruption before the identity reply leaves an anonymous stop in the router checkpoint.
                let saved = try JSONDecoder().decode(SyncRouterState.self, from: JSONEncoder().encode(router.state))
                let foreign = FakeSyncCloud(user: "another-user"), restored = SyncDevice(cloud: foreign, installID: "air")
                let routing = SyncRouter(state: saved, persist: { _ in }, tabs: restored.sync, vaults: nil)
                restored.engine.delegate = routing
                restored.start(sharing: [profile])
                await restored.sync.refresh()
                try await restored.engine.sendNow()
                #expect(restored.box.ended == [nil] && foreign.zones[zone] == nil)
            }
            try await air.engine.fetchNow()
            delivered = true
        }
        air.start(sharing: [profile])
        await air.sync.refresh()
        await air.sync.refresh()
        air.sync.share(SyncSamples.session(tabs: ["https://first.test/"]), profileID: profile, force: true)
        try await air.engine.sendNow()
        #expect(delivered && air.box.ended.isEmpty && cloud.record(air.id(in: zone)) != nil)
    }

    @Test(arguments: [false, true])
    func optingOutWithdrawsAnAcknowledgedOrRediscoveredOwnRow(legacyCheckpoint: Bool) async throws {
        let cloud = FakeSyncCloud(), profile = UUID(), zone = SyncZone.profile(profile)
        let air = SyncDevice(cloud: cloud, installID: "air")
        let first = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = first
        air.start(sharing: [profile])
        await air.sync.refresh()
        let local = SyncSamples.session(tabs: ["https://kept-on-server.test/"])
        let id = air.id(in: zone)
        if legacyCheckpoint {
            air.sync.share(local, profileID: profile, force: true)
        }
        try await air.engine.sendNow()
        if !legacyCheckpoint {
            let payload = try #require(SessionCodec.encodeFitted(local))
            _ = cloud.save(SyncRecord(id: id, type: .deviceSession, schema: 1, payload: payload))
            try await air.engine.fetchNow()
        }
        try #require(cloud.record(id) != nil && air.sync.state.ownSystemFields[zone] != nil)

        // 6fbeea94 already wrote observations in both files, with acknowledged tags only in the tab file.
        var tabs = air.sync.state
        var savedRouter = first.state
        if legacyCheckpoint {
            let observations: [String: Any] = ["account": cloud.user, "zones": [zone: "present", SyncZone.devices: "present"]]
            let tabFile: [String: Any] = [
                "accountUser": cloud.user, "seq": 1, "devices": [:], "sessions": [:], "removalRevision": 4,
                "ownSystemFields": tabs.ownSystemFields.mapValues { $0.base64EncodedString() }, "zoneObservations": observations,
            ]
            let routerFile: [String: Any] = [
                "vaults": ["remote": [:]], "explicitVaultChanges": true, "tabRemoval": ["revision": 4, "observations": observations],
            ]
            tabs = try JSONDecoder().decode(TabSyncState.self, from: JSONSerialization.data(withJSONObject: tabFile))
            savedRouter = try JSONDecoder().decode(SyncRouterState.self, from: JSONSerialization.data(withJSONObject: routerFile))
        }
        let reopened = SyncDevice(cloud: cloud, installID: "air", state: tabs)
        reopened.sync.reconcile(sharing: [])
        let router = SyncRouter(state: savedRouter, persist: { _ in }, tabs: reopened.sync, vaults: nil)
        let engine = FakeSyncEngine(cloud: cloud, delegate: router, state: savedRouter.engineState)
        reopened.sync.attach(engine)
        await engine.simulateAccount(.signOut)
        await engine.simulateAccount(.signIn(user: cloud.user))
        let writes = cloud.writeCount
        try await engine.sendNow()
        #expect(cloud.record(id) == nil && cloud.writeCount == writes && !reopened.sync.needsEngine)
    }

    enum FirstAccountReply: CaseIterable { case same, switched, changedAtRecheck }

    @Test(arguments: FirstAccountReply.allCases)
    func anOriginalIdentityLookupSurvivesATimedOutRemovalLookup(accountChanged: FirstAccountReply) async throws {
        let cloud = FakeSyncCloud(user: "A"), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        cloud.createZone(zone)
        cloud.deleteZone(zone, reason: .deleted)
        var timedOut = false
        air.engine.duringAccountLookup = {
            air.engine.duringAccountLookup = {
                air.engine.duringAccountLookup = nil
                timedOut = true
                #expect(!router.allowsZoneCreation(zone))
                throw URLError(.timedOut)
            }
            try await air.engine.fetchNow()
            #expect(!router.allowsZoneCreation(zone))
            try await air.engine.sendNow()
            #expect(cloud.zones[zone] == nil && air.box.ended.isEmpty)
            if accountChanged == .switched {
                cloud.switchUser("B")
                await air.engine.simulateAccount(.switchAccounts(user: "B"))
            } else if accountChanged == .changedAtRecheck {
                air.engine.duringAccountLookup = {
                    air.engine.duringAccountLookup = nil
                    cloud.switchUser("B")
                }
            }
        }
        air.start(sharing: [profile])
        await air.sync.refresh()
        if accountChanged == .same {
            #expect(air.engine.fetchAllCount >= 2 && air.sync.state.accountUser == "A")
        }
        air.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: profile, force: true)
        try await air.engine.sendNow()
        #expect(timedOut && air.box.ended == (accountChanged == .same ? [] : [nil]))
        #expect((cloud.record(air.id(in: zone)) != nil) == (accountChanged == .same))
    }

    enum ReturnToOwner: CaseIterable { case signIn, verifiedLookup, newConsent }

    @Test(arguments: ReturnToOwner.allCases)
    func aWithdrawalWaitsThroughAnotherAccountAndARestart(reenroll: ReturnToOwner) async throws {
        let first = FakeSyncCloud(user: "A"), other = FakeSyncCloud(user: "B")
        let profile = UUID(), zone = SyncZone.profile(profile)
        let air = SyncDevice(cloud: first, installID: "air"), id = air.id(in: zone)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        air.start(sharing: [profile])
        await air.sync.refresh()
        air.sync.share(SyncSamples.session(tabs: ["https://old.test/"]), profileID: profile, force: true)
        var receipt: (@MainActor () async -> Void)?
        air.engine.holdSendReceipt = { receipt = $0 }
        try await air.engine.sendNow()
        let late = try #require(receipt)
        var row = try #require(first.record(id))
        row.systemFields = nil
        other.createZone(zone)
        _ = other.save(row)
        row.id.name = "studio"
        _ = first.save(row)
        let writes = first.writeCount
        air.sync.reconcile(sharing: [])
        await air.engine.simulateAccount(.signOut)
        let visiting = FakeSyncEngine(cloud: other, delegate: router)
        await visiting.simulateAccount(.signIn(user: "B"))
        air.sync.attach(visiting)
        await late()
        try await visiting.sendNow()
        #expect(other.record(id) != nil && !router.wantsRecordDeletion(id))

        var tabs = try JSONDecoder().decode(TabSyncState.self, from: JSONEncoder().encode(air.sync.state))
        if reenroll == .verifiedLookup {
            // An older tab file from B still has its change tag. The newer router parked an A-only withdrawal.
            tabs = TabSyncState()
            tabs.accountUser = other.user
            tabs.ownSystemFields[zone] = try #require(other.record(id)?.systemFields)
        }
        let checkpoint = try JSONDecoder().decode(SyncRouterState.self, from: JSONEncoder().encode(router.state))
        let reopened = SyncDevice(cloud: first, installID: "air", state: tabs)
        reopened.sync.reconcile(sharing: [])
        let resumed = SyncRouter(state: checkpoint, persist: { _ in }, tabs: reopened.sync, vaults: nil)
        reopened.engine.delegate = resumed
        try #require(reopened.sync.needsEngine)
        let inB = FakeSyncEngine(cloud: other, delegate: resumed, state: checkpoint.engineState)
        reopened.sync.attach(inB)
        await reopened.sync.refresh()
        try await inB.sendNow()
        #expect(!reopened.sync.needsEngine && !resumed.wantsRecordDeletion(id) && other.record(id) != nil)
        if reenroll != .verifiedLookup {
            await inB.simulateAccount(.signOut)
        }
        reopened.sync.attach(reopened.engine)
        if reenroll == .verifiedLookup {
            // The transport is back in A before an account-change notification.
            await reopened.sync.refresh()
        } else {
            await reopened.engine.simulateAccount(.signIn(user: "A"))
        }
        if reenroll == .newConsent {
            reopened.sync.reconcile(sharing: [profile])
            await reopened.sync.refresh()
            reopened.sync.share(SyncSamples.session(tabs: ["https://new.test/"]), profileID: profile, force: true)
        }
        try await reopened.engine.sendNow()
        if reenroll == .newConsent {
            let latest = try #require(first.record(id))
            #expect(try SessionCodec.decodeSession(latest.payload).windows.first?.nodes.first?.url == "https://new.test/")
        } else {
            #expect(first.record(id) == nil && first.writeCount == writes && !reopened.sync.needsEngine)
        }
        #expect(first.record(row.id) != nil && other.record(id) != nil && other.writeCount == 1)
    }

    enum AfterFirstTabSave: CaseIterable { case restart, signOut, signedOutRestart, newConsent, otherAccount, otherInstallation }

    @Test(arguments: AfterFirstTabSave.allCases)
    func optingOutBeforeTheFirstReceiptRemovesOnlyTheApprovedInstallation(after: AfterFirstTabSave) async throws {
        let cloud = FakeSyncCloud(), air = SyncDevice(cloud: cloud, installID: "air")
        let profile = UUID(), zone = SyncZone.profile(profile), id = air.id(in: zone)
        let routed = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = routed
        air.start(sharing: [profile])
        await air.sync.refresh()
        air.sync.share(SyncSamples.session(tabs: ["https://retired.test/"]), profileID: profile, force: true)
        var receipt: (@MainActor () async -> Void)?
        air.engine.holdSendReceipt = { receipt = $0 }
        try await air.engine.sendNow()
        air.engine.holdSendReceipt = nil
        let acknowledgedLater = try #require(receipt)
        let row = try #require(cloud.record(id))
        cloud.deleteRecord(air.id(in: SyncZone.devices))
        #expect(air.sync.state.ownSystemFields[zone] == nil)
        var peer = row
        peer.id.name = "studio"
        peer.systemFields = nil
        if after != .restart {
            _ = cloud.save(peer)
        }
        let writes = cloud.writeCount
        air.sync.reconcile(sharing: [])
        if after == .signOut || after == .signedOutRestart {
            await air.engine.simulateAccount(.signOut)
            #expect(!routed.wantsRecordDeletion(id))
            try await air.engine.sendNow()
            #expect(cloud.record(id) != nil)
        }
        if after == .signOut {
            await air.engine.simulateAccount(.signIn(user: cloud.user))
            try await air.engine.sendNow()
            await acknowledgedLater()
            try await air.engine.sendNow()
            #expect(cloud.record(id) == nil && cloud.record(peer.id) != nil && cloud.writeCount == writes)
            return
        }

        let tabs = try JSONDecoder().decode(TabSyncState.self, from: JSONEncoder().encode(air.sync.state))
        let checkpoint = try JSONDecoder().decode(SyncRouterState.self, from: JSONEncoder().encode(routed.state))
        if after == .otherAccount {
            cloud.switchUser("different")
            cloud.createZone(zone)
            var foreign = row
            foreign.systemFields = nil
            _ = cloud.save(foreign)
        }
        let reopened = SyncDevice(cloud: cloud, installID: after == .otherInstallation ? "replacement" : "air", state: tabs)
        reopened.sync.reconcile(sharing: [])
        let router = SyncRouter(state: checkpoint, persist: { _ in }, tabs: reopened.sync, vaults: nil)
        let engine = FakeSyncEngine(cloud: cloud, delegate: router, state: checkpoint.engineState)
        if after == .otherInstallation {
            #expect(!reopened.sync.needsEngine && !router.wantsRecordDeletion(id))
            _ = router.acceptsUploadAccount(cloud.user)
            engine.add([.deleteRecord(id), .deleteRecord(peer.id)])
            try await engine.sendNow()
            #expect(cloud.record(id) != nil && cloud.record(peer.id) != nil && cloud.writeCount == writes)
            return
        }
        #expect(reopened.sync.needsEngine)
        engine.available = false
        if reopened.sync.needsEngine {
            reopened.sync.attach(engine)
        }
        try await engine.sendNow()
        #expect(cloud.record(id) != nil)
        if after == .newConsent {
            reopened.sync.reconcile(sharing: [profile])
            reopened.sync.share(SyncSamples.session(tabs: ["https://new.test/"]), profileID: profile, force: true)
        }
        engine.available = true
        if after == .signedOutRestart {
            await engine.simulateAccount(.signIn(user: cloud.user))
        }
        try await engine.sendNow()
        if after == .otherAccount {
            #expect(cloud.record(id) != nil && !reopened.sync.needsEngine)
        } else if after == .newConsent {
            let latest = try #require(cloud.record(id))
            #expect(try SessionCodec.decodeSession(latest.payload).windows.first?.nodes.first?.url == "https://new.test/")
            #expect(cloud.record(peer.id) != nil)
        } else {
            #expect(cloud.record(id) == nil && !reopened.sync.needsEngine && cloud.writeCount == writes)
            #expect((cloud.record(peer.id) != nil) == (after != .restart))
        }
    }
}
