// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Testing

@testable import WSurfCore

@MainActor
struct SharedCatalogTests {
    private final class Client {
        let sync: SharedCatalogSync
        let engine: FakeSyncEngine
        let profile: UUID

        init(_ cloud: FakeSyncCloud, profile: UUID = UUID(), state: SharedCatalogState = .init()) {
            self.profile = profile
            sync = SharedCatalogSync(state: state, persist: { _ in })
            let router = SyncRouter(state: .init(), persist: { _ in }, tabs: nil, vaults: nil, additional: [sync])
            self.router = router
            engine = FakeSyncEngine(cloud: cloud, delegate: router)
            sync.attach(engine)
        }
        let router: SyncRouter

        func enable() async throws {
            sync.setEnabled(true, .spaces, for: profile)
            try await sync.prepare(.spaces)
        }
    }

    @Test func competingCloseAndMovePreserveTheDeletionAndBothVersionsForReview() async throws {
        let cloud = FakeSyncCloud()
        let a = Client(cloud)
        let b = Client(cloud)
        try await a.enable()
        let item = SharedSpaceItem(id: UUID(), kind: .tab, profileID: UUID(), spaceID: UUID(), order: "V", title: "Tab", url: "https://site.test/")
        a.sync.stage(item, for: a.profile)
        try await a.engine.sendNow()
        try await b.enable()
        var moved = item
        moved.spaceID = UUID()
        b.sync.stage(moved, for: b.profile)
        let persisted = try JSONEncoder().encode(b.sync.state)
        let restarted = Client(cloud, profile: b.profile, state: try JSONDecoder().decode(SharedCatalogState.self, from: persisted))
        a.sync.stage(item.tombstone, for: a.profile)
        try await a.engine.sendNow()
        try await restarted.sync.prepare(.spaces)
        try await restarted.engine.sendNow()
        #expect(restarted.sync.item(item.id, in: .spaces) == item.tombstone)
        #expect(restarted.sync.state.conflicts[item.recordID]?.item == moved)
        #expect(cloud.record(item.recordID).flatMap(SharedSpaceItem.init(record:)) == item.tombstone)
    }

    @Test func aNewAccountAtRelaunchCannotReceiveThePreviousOutbox() async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let item = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Old account")
        client.sync.stage(item, for: client.profile)
        let restarted = Client(cloud, profile: client.profile, state: client.sync.state)
        cloud.switchUser("unrelated-user")
        try await #require(throws: SharedCatalogError.self) { try await restarted.sync.prepare(.spaces) }
        #expect(!restarted.sync.needsEngine)
        #expect(restarted.router.record(for: item.recordID) == nil)
        try await restarted.engine.sendNow()
        #expect(cloud.recordCount == 0)
    }

    @Test func switchingAccountsDuringABaselineDiscardsTheUnconfirmedCatalog() async throws {
        let cloud = FakeSyncCloud()
        let item = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Second account")
        let record = try #require(item.record(fields: nil))
        let sync = SharedCatalogSync(state: .init()) { state in
            guard state.user == "user-1", cloud.user == "user-1" else { return }
            cloud.switchUser("user-2")
            cloud.createZone(record.id.zone)
            _ = cloud.save(record)
        }
        sync.attach(FakeSyncEngine(cloud: cloud, delegate: sync))
        sync.setEnabled(true, .spaces, for: UUID())
        await #expect(throws: SharedCatalogError.self) { try await sync.prepare(.spaces) }
        #expect(sync.state.remote.isEmpty && sync.ready.isEmpty && !sync.needsEngine)
    }

    @Test(arguments: [false, true], [false, true])
    func incomingChangesCheckAccountBeforeTouchingTheCatalog(zoneRemoval: Bool, unavailable: Bool) async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        var local = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Original")
        client.sync.stage(local, for: client.profile)
        try await client.engine.sendNow()
        let saved = local
        local.title = "Pending change"
        client.sync.stage(local, for: client.profile)
        let other = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Other account")
        let incoming = try #require(other.record(fields: nil))
        if unavailable {
            client.engine.available = false
        } else {
            cloud.switchUser("next-user")
        }
        let event: SyncEvent = zoneRemoval ? .zonesDeleted([local.recordID.zone: .deleted]) : .fetched(modified: [incoming], deleted: [local.recordID])
        await client.router.handle(event)
        #expect(client.sync.state.remote[other.recordID] == nil)
        if unavailable {
            #expect(client.sync.state.pending[local.recordID]?.item == local && client.sync.state.remote[local.recordID]?.item == saved)
            #expect(client.sync.enabled(.spaces, for: client.profile) && client.sync.trustedUser == nil)
        } else {
            #expect(client.sync.state.user == "next-user" && !client.sync.needsEngine && client.sync.state.remote.isEmpty)
            #expect(client.sync.state.pausedAccounts?["user-1"]?.pending[local.recordID]?.item == local)
        }
    }

    @Test(arguments: [false, true])
    func anIncomingEventCannotCrossAnEnrollmentChangeDuringTheAccountLookup(zoneRemoval: Bool) async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let stale = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Previous enrollment")
        let record = try #require(stale.record(fields: nil))
        var changed = false
        client.engine.duringAccountLookup = {
            client.engine.duringAccountLookup = nil
            client.sync.setEnabled(false, .spaces, for: client.profile)
            try await client.enable()
            changed = true
        }
        let event: SyncEvent = zoneRemoval ? .zonesDeleted([stale.recordID.zone: .deleted]) : .fetched(modified: [record], deleted: [])
        await client.router.handle(event)
        #expect(changed && client.sync.ready.contains(.spaces) && client.sync.state.remote[stale.recordID] == nil)
    }

    @Test func anUnverifiedEventDuringAFullReadKeepsPendingEditsForANewBaseline() async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let pending = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Local")
        client.sync.stage(pending, for: client.profile)
        client.sync.setEnabled(true, .spaces, for: UUID())
        let unverified = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Unverified")
        let record = try #require(unverified.record(fields: nil))
        client.engine.afterFullZoneRead = {
            client.engine.afterFullZoneRead = nil
            client.engine.duringAccountLookup = {
                client.engine.duringAccountLookup = nil
                client.engine.available = false
                await client.router.handle(.fetched(modified: [record], deleted: []))
                client.engine.available = true
            }
        }
        await #expect(throws: CancellationError.self) { try await client.sync.prepare(.spaces) }
        #expect(client.sync.failed.contains(.spaces))
        #expect(client.sync.state.remote[unverified.recordID] == nil && client.sync.state.pending[pending.recordID]?.item == pending)
        try await client.sync.prepare(.spaces)
        try await client.engine.sendNow()
        #expect(cloud.record(pending.recordID).flatMap(SharedSpaceItem.init(record:)) == pending)
    }

    @Test func aZoneRemovalMissedDuringAnAccountOutageIsVerifiedBeforeRecreatingTheZone() async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let item = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Pending")
        client.sync.stage(item, for: client.profile)
        cloud.deleteZone(item.recordID.zone, reason: .deleted)
        client.engine.available = false
        await client.router.handle(.zonesDeleted([item.recordID.zone: .deleted]))
        #expect(client.sync.state.pending[item.recordID]?.item == item && client.sync.needsEngine)
        client.engine.available = true
        await #expect(throws: SharedCatalogError.self) { try await client.sync.prepare(.spaces) }
        try await client.engine.sendNow()
        #expect(!client.sync.needsEngine && cloud.zones[item.recordID.zone] == nil)
        try await client.enable()
        #expect(client.sync.ready.contains(.spaces) && cloud.names(in: item.recordID.zone).isEmpty)
    }

    @Test(arguments: [false, true])
    func choosingAConflictVersionUsesTheLastEditOnThisMac(keepingLocal: Bool) async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        var item = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Initial")
        client.sync.stage(item, for: client.profile)
        try await client.engine.sendNow()
        var remote = item
        remote.title = "From another Mac"
        item.title = "First local change"
        client.sync.stage(item, for: client.profile)
        cloud.overwrite(item.recordID, payload: try #require(remote.record(fields: nil)).payload)
        try await client.engine.fetchNow()
        #expect(client.sync.state.conflicts[item.recordID]?.item == item)
        #expect(client.sync.item(item.id, in: .spaces) == item && client.sync.items(.spaces).contains(item))
        item.title = "Last edit before resolving"
        client.sync.stage(item, for: client.profile)
        #expect(client.sync.state.conflicts[item.recordID]?.item == item && client.sync.record(for: item.recordID) == nil)
        #expect(client.sync.item(item.id, in: .spaces) == item && client.sync.items(.spaces).contains(item))
        let bytes = try JSONEncoder().encode(client.sync.state)
        let resumed = Client(cloud, profile: client.profile, state: try JSONDecoder().decode(SharedCatalogState.self, from: bytes))
        try await resumed.sync.prepare(.spaces)
        resumed.sync.resolve(item.recordID, keepingLocal: keepingLocal)
        try await resumed.engine.sendNow()
        #expect(cloud.record(item.recordID).flatMap(SharedSpaceItem.init(record:)) == (keepingLocal ? item : remote))
    }

    @Test func nativeAutomaticBatchesKeepOfflineEditsAndCheckOneUserForTheWholeBatch() async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let rows = ["One", "Two"].map { SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: $0) }
        client.sync.stage(rows, for: client.profile)
        let pending = rows.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudKitMapping.recordID($0.recordID)) }
        let disconnected = await CloudKitMapping.uploadBatch(pending, delegate: client.router, currentUser: {
            throw URLError(.notConnectedToInternet)
        }, discard: { _ in Issue.record("A temporarily unavailable account must keep its transport queue.") })
        #expect(disconnected == nil && client.sync.state.pending.count == 2)
        var lookups = 0
        let confirmed = await CloudKitMapping.uploadBatch(pending, delegate: client.router, currentUser: {
            lookups += 1
            return cloud.user
        }, discard: { _ in Issue.record("Both edits remain approved.") })
        #expect(lookups == 1 && confirmed?.recordsToSave.count == 2)
        let switched = await CloudKitMapping.uploadBatch(pending, delegate: client.router, currentUser: {
            "another-user"
        }, discard: { _ in })
        #expect(switched == nil && !client.sync.needsEngine && client.sync.state.pending.isEmpty)
    }

    @Test func anUnmappableCatalogRowKeepsAFullReadIncompleteWhileVaultAssetsStayFiltered() {
        for (zone, type) in [("mac-prefs-providers", "MacSetting"), (SharedCatalogCategory.spaces.zone, "SharedSpaceItem"), (SharedCatalogCategory.pins.zone, "FutureType")] {
            let id = CloudKitMapping.recordID(.init(zone: zone, name: "existing-row"))
            let record = CKRecord(recordType: type, recordID: id)
            var read = SyncZoneRead(records: [])
            CloudKitMapping.include(record, in: &read)
            #expect(read.records.isEmpty && read.skipped == 1)
        }
        let vault = CloudKitMapping.recordID(.init(zone: SyncZone.vault(profileID: UUID(), vaultID: UUID()), name: "asset"))
        var read = SyncZoneRead(records: [])
        CloudKitMapping.include(CKRecord(recordType: "VaultAsset", recordID: vault), in: &read)
        #expect(read.records.isEmpty && read.skipped == 0)
    }

    @Test func aQueuedTabDeleteWaitsForIdentityAndCannotDeleteInADifferentAccount() async throws {
        let cloud = FakeSyncCloud()
        let mac = SyncDevice(cloud: cloud, installID: "device")
        mac.start(sharing: [UUID()])
        try await mac.engine.sendNow()
        let id = mac.id(in: SyncZone.devices)
        var otherCopy = try #require(cloud.record(id))
        mac.sync.reconcile(sharing: [])
        mac.engine.available = false
        try await mac.engine.sendNow()
        #expect(mac.engine.pending.contains(.deleteRecord(id)) && cloud.record(id) != nil)
        cloud.switchUser("another-user")
        cloud.createZone(id.zone)
        otherCopy.systemFields = nil
        _ = cloud.save(otherCopy)
        mac.engine.available = true
        try await mac.engine.sendNow()
        try await mac.engine.sendNow()
        #expect(cloud.record(id) != nil && !mac.sync.needsEngine && mac.engine.pending.isEmpty)
    }

    @Test(arguments: [false, true])
    func legacyTabSharingWithAnUnknownAccountCannotAdoptTheNextSignIn(signsOut: Bool) async throws {
        let cloud = FakeSyncCloud(user: "new-user")
        var prior = TabSyncState()
        prior.ownSystemFields[SyncZone.devices] = Data([1])
        let mac = SyncDevice(cloud: cloud, installID: "device", state: prior)
        mac.start(sharing: [UUID()])
        if signsOut {
            await mac.engine.simulateAccount(.signOut)
        }
        await mac.engine.simulateAccount(.signIn(user: cloud.user))
        try await mac.engine.sendNow()
        #expect(mac.box.ended == [nil] && !mac.sync.needsEngine && cloud.recordCount == 0)
    }

    @Test(arguments: [false, true])
    func aNewTabInstallationCanFetchOtherDevicesBeforeItsFirstUpload(relaunch: Bool) async throws {
        let cloud = FakeSyncCloud()
        let profile = UUID()
        let existing = SyncDevice(cloud: cloud, installID: "existing")
        existing.start(sharing: [profile])
        try await existing.engine.sendNow()
        let fresh = SyncDevice(cloud: cloud, installID: "fresh")
        fresh.start(sharing: [profile])
        try await fresh.engine.fetchNow()
        #expect(fresh.sync.state.devices[existing.installID] != nil)
        let saved = try #require(fresh.box.state)
        #expect(saved.accountUser == cloud.user)
        let sender = relaunch ? SyncDevice(cloud: cloud, installID: fresh.installID, state: saved) : fresh
        if relaunch {
            sender.start(sharing: [profile])
        }
        try await sender.engine.sendNow()
        #expect(sender.box.ended.isEmpty && cloud.record(sender.id(in: SyncZone.devices)) != nil)
    }

    @Test func anUnavailableFirstTabFetchDoesNotPersistUnidentifiedDevices() async throws {
        let cloud = FakeSyncCloud()
        let profile = UUID()
        let existing = SyncDevice(cloud: cloud, installID: "existing")
        existing.start(sharing: [profile])
        try await existing.engine.sendNow()
        let fresh = SyncDevice(cloud: cloud, installID: "fresh")
        fresh.start(sharing: [profile])
        fresh.engine.available = false
        try await fresh.engine.fetchNow()
        #expect(fresh.sync.state.accountUser == nil && fresh.sync.state.devices.isEmpty && fresh.sync.needsEngine)
        let resumed = SyncDevice(cloud: cloud, installID: fresh.installID, state: fresh.sync.state)
        resumed.start(sharing: [profile])
        try await resumed.engine.fetchNow()
        #expect(resumed.sync.state.accountUser == cloud.user && resumed.sync.state.devices[existing.installID] != nil)
    }

    @Test func signingBackIntoTheOriginalAccountRequiresConsentBeforeReplayingItsOwnOutbox() async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let item = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Offline")
        client.sync.stage(item, for: client.profile)
        await client.engine.simulateAccount(.signOut)
        cloud.switchUser("user-2")
        await client.engine.simulateAccount(.signIn(user: "user-2"))
        try await client.enable()
        try await client.engine.sendNow()
        #expect(cloud.record(item.recordID) == nil)
        cloud.switchUser("user-1")
        await client.engine.simulateAccount(.switchAccounts(user: "user-1"))
        #expect(client.sync.record(for: item.recordID) == nil && !client.sync.needsEngine)
        try await client.enable()
        try await client.engine.sendNow()
        #expect(cloud.record(item.recordID).flatMap(SharedSpaceItem.init(record:)) == item)
    }

    @Test(arguments: [false, true], [false, true])
    func anOldReplyCannotFinishAnIdenticalEditInANewAccount(issued: Bool, failed: Bool) async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let item = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Both accounts")
        client.sync.stage(item, for: client.profile)
        let old = try #require(client.engine.handOut(item.recordID))
        cloud.switchUser("next-account")
        await client.engine.simulateAccount(.switchAccounts(user: cloud.user))
        try await client.enable()
        client.sync.stage(item, for: client.profile)
        let next = issued ? client.engine.handOut(item.recordID) : nil
        if failed {
            let error = SyncFailedSave(id: item.recordID, failure: .zoneNotFound, attempted: old)
            await client.router.handle(.sent(saved: [], deleted: [], failed: [error]))
        } else {
            await client.router.handle(.sent(saved: [old], deleted: [], failed: []))
        }
        #expect(client.sync.state.pending[item.recordID]?.item == item && client.sync.ready.contains(.spaces))
        let current = try #require(issued ? next : client.engine.handOut(item.recordID))
        guard case .saved(let saved) = cloud.save(current) else {
            Issue.record("The new account must accept its own edit.")
            return
        }
        await client.router.handle(.sent(saved: [saved], deleted: [], failed: []))
        #expect(cloud.record(item.recordID).flatMap(SharedSpaceItem.init(record:)) == item && client.sync.state.pending.isEmpty)
    }

    @Test(arguments: [false, true])
    func undoingAnInFlightEditSurvivesItsAcknowledgementAndARestart(relaunch: Bool) async throws {
        let cloud = FakeSyncCloud()
        let client = Client(cloud)
        try await client.enable()
        let first = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "First")
        client.sync.stage(first, for: client.profile)
        try await client.engine.sendNow()
        var change = first
        change.title = "Second"
        client.sync.stage(change, for: client.profile)
        let inFlight = try #require(client.engine.handOut(change.recordID))
        client.sync.stage(first, for: client.profile)
        guard case .saved(let saved) = cloud.save(inFlight) else {
            Issue.record("The in-flight edit must reach the fake server.")
            return
        }
        let receiver = relaunch ? Client(cloud, profile: client.profile, state: client.sync.state) : client
        if relaunch {
            try await receiver.sync.prepare(.spaces)
        } else {
            try await receiver.engine.fetchNow()
            await receiver.router.handle(.sent(saved: [saved], deleted: [], failed: []))
        }
        #expect(receiver.sync.state.pending[first.recordID]?.item == first)
        try await receiver.engine.sendNow()
        #expect(cloud.record(first.recordID).flatMap(SharedSpaceItem.init(record:)) == first)
        #expect(receiver.sync.state.pending.isEmpty && receiver.sync.state.conflicts.isEmpty)
    }

    @Test func codecChecksIdentityMembershipAndWebURLBeforeSendingOrOpening() throws {
        let id = UUID()
        let row = SharedSpaceItem(id: id, kind: .pin, profileID: UUID(), title: "A", url: "https://example.test")
        var wire = try #require(row.record(fields: nil))
        #expect(SharedSpaceItem(record: wire) == row)
        wire.id.name = UUID().uuidString
        #expect(SharedSpaceItem(record: wire) == nil)
        var altered = row
        altered.url = "file:///private/local"
        #expect(altered.record(fields: nil) == nil)
        altered = row
        altered.spaceID = UUID()
        #expect(altered.record(fields: nil) == nil)
        let deletion = try #require(row.tombstone.record(fields: nil))
        #expect(!String(decoding: deletion.payload, as: UTF8.self).contains("example.test"))
    }
}
