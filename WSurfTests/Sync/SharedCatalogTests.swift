// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

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
