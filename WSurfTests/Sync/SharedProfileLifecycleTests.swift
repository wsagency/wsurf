// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

@MainActor
struct SharedProfileLifecycleTests {
    private struct Fixture {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let cloud = FakeSyncCloud()
        let profiles: ProfileStore
        let removed: Profile
        let kept: Profile

        init() {
            profiles = ProfileStore(file: root.appending(path: "profiles.json"))
            removed = profiles.add(name: "Remove")
            kept = profiles.add(name: "Keep")
            for category in SharedCatalogCategory.allCases {
                cloud.createZone(category.zone)
            }
        }

        var catalogFile: URL {
            root.appending(path: "iCloudSharedSpaces.json")
        }

        func open(spaces: SpaceStore? = nil) -> CloudSharedSpaces {
            let pins = ProfilePinStore.store(for: .temporary())
            return CloudSharedSpaces(stateFile: catalogFile, profiles: profiles.profiles, windows: { [] }, spaces: { _ in spaces }, pins: { _ in pins })
        }

        func attach(_ host: CloudSharedSpaces) -> FakeSyncEngine {
            let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
            host.attach(engine)
            return engine
        }

        func interruptWrites(to file: URL) throws {
            try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("saved"))
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }

        func restore(_ file: URL) throws {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: file.appendingPathExtension("saved"), to: file)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test(arguments: [false, true])
    func offlineErasureDiscardsOnlyTheRemovedProfilesEdits(parked: Bool) async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let host = f.open()
        let engine = f.attach(host)
        let group = try await host.publishProfile(f.removed)
        let keptGroup = try await host.publishProfile(f.kept)
        try await host.enable(.pins, for: f.removed)
        try await host.enable(.pins, for: f.kept)
        try await host.enable(.spaces, for: f.removed)
        try await engine.sendNow()

        let local = SharedSpaceItem(id: UUID(), kind: .pin, profileID: group, url: "https://private.example.test/")
        let kept = SharedSpaceItem(id: UUID(), kind: .pin, profileID: keptGroup, url: "https://kept.example.test/")
        let profileID = SyncRecordID(zone: SharedCatalogCategory.profiles.zone, name: group.uuidString)
        let saved = try #require(f.cloud.record(profileID))
        var remote = try #require(SharedSpaceItem(record: saved))
        var conflict = remote
        conflict.title = "Private rename"
        host.catalog.stage(conflict, for: f.removed.id)
        remote.title = "Remote rename"
        _ = try f.cloud.save(#require(remote.record(fields: saved.systemFields)))
        try await engine.fetchNow()
        try #require(host.catalog.state.conflicts[profileID]?.item == conflict)
        host.catalog.stage(local, for: f.removed.id)
        host.catalog.stage(kept, for: f.kept.id)
        let writes = f.cloud.writeCount
        engine.offline = true
        if parked {
            await engine.simulateAccount(.signOut)
        }

        try await f.profiles.remove(f.removed, settingsSync: nil, sharedSpaces: host, eraseData: { _ in
            #expect(!host.linkProfile(f.removed.id, to: group))
        }).get()
        let reopened = f.open()
        #expect(SharedCatalogCategory.allCases.allSatisfy { !reopened.isEnabled($0, for: f.removed) })
        #expect(reopened.links[f.removed.id] == nil)
        if !parked {
            #expect(reopened.isEnabled(.pins, for: f.kept) && reopened.isEnabled(.profiles, for: f.kept))
            #expect(!reopened.isEnabled(.spaces, for: f.kept))
            #expect(reopened.catalog.state.remote[profileID]?.item == remote)
        }
        let replacement = f.profiles.add(name: "Replacement")
        let next = f.attach(reopened)
        next.offline = true
        await reopened.refresh()
        #expect(f.cloud.writeCount == writes)
        next.offline = false
        if parked {
            try #require(await reopened.catalog.verifyAccount())
            #expect(reopened.catalog.state.remote[profileID]?.item == remote)
        }
        try await reopened.enable(.profiles, for: replacement)
        #expect(reopened.linkProfile(replacement.id, to: group))
        #expect(reopened.links[f.kept.id]?.profile == keptGroup)
        #expect(reopened.catalog.state.conflicts[profileID] == nil)
        #expect(reopened.catalog.state.pending[local.recordID] == nil)
        try await reopened.enable(.pins, for: f.kept)
        await reopened.refresh()
        #expect(f.cloud.record(local.recordID) == nil && next.saveAttempts[local.id.uuidString] == nil)
        #expect(f.cloud.record(kept.recordID).flatMap(SharedSpaceItem.init(record:)) == kept)
        #expect(f.cloud.record(profileID).flatMap(SharedSpaceItem.init(record:)) == remote)
        #expect(f.cloud.writeCount == writes + 1)
    }

    @Test(arguments: [false, true])
    func failedCatalogWriteKeepsTheProfileAndRevokesAcrossRestart(duringSwitch: Bool) async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let host = f.open()
        let engine = f.attach(host)
        let id = try await host.publishProfile(f.removed)
        let kept = try await host.publishProfile(f.kept)
        let settings = CloudSettingsSync(stateFile: f.root.appending(path: "settings"), read: { _, _ in [:] }, apply: { _, _, _, _ in })
        settings.attach(FakeSyncEngine(cloud: f.cloud, delegate: settings))
        try await settings.enable(.providers, localProfileID: f.removed.id, cloudProfileID: id)
        let queued = SharedSpaceItem(id: id, kind: .profile, profileID: id, title: "During switch")
        if !duringSwitch {
            try f.interruptWrites(to: f.catalogFile)
        }
        var prepared = false, erased = false
        let result = await f.profiles.remove(f.removed, beforeErasing: {
            prepared = true
            #expect(f.open().links[f.removed.id] == nil)
            do {
                try await host.enable(.profiles, for: f.removed)
                #expect(host.linkProfile(f.removed.id, to: id))
                host.catalog.stage(queued, for: f.removed.id)
                try f.interruptWrites(to: f.catalogFile)
            } catch { Issue.record(error) }
        }, settingsSync: settings, sharedSpaces: host, eraseData: { _ in erased = true })
        #expect(throws: (any Error).self) { try result.get() }
        #expect(prepared == duringSwitch && !erased)
        #expect(!settings.isEnabled(.providers, localProfileID: f.removed.id))
        #expect(host.catalog.record(for: queued.recordID) == nil)
        #expect(!host.linkProfile(f.removed.id, to: id))
        #expect(host.links[f.removed.id] == nil)
        #expect(ProfileStore(file: f.root.appending(path: "profiles.json")).profiles.contains(f.removed))
        let journal = f.catalogFile.appendingPathExtension("opt-outs")
        let stale = try Data(contentsOf: journal)
        try f.restore(f.catalogFile)
        engine.offline = true
        let reopened = f.open()
        #expect(!reopened.isEnabled(.profiles, for: f.removed) && reopened.links[f.removed.id] == nil)
        #expect(reopened.catalog.state.pending[queued.recordID] == nil)
        #expect(reopened.links[f.kept.id]?.profile == kept)
        try await f.profiles.remove(f.removed, settingsSync: nil, sharedSpaces: reopened, eraseData: { _ in erased = true }).get()
        #expect(erased && !f.profiles.profiles.contains(f.removed))
        #expect(f.cloud.record(queued.recordID) == nil)
        let adopted = try #require(f.profiles.adopt(id: f.removed.id, name: "Adopted again", symbol: "person", color: .blue))
        _ = f.attach(reopened)
        try await reopened.enable(.profiles, for: adopted)
        try #require(reopened.linkProfile(adopted.id, to: id))
        try stale.write(to: journal, options: .atomic)
        let saved = f.open()
        #expect(saved.isEnabled(.profiles, for: adopted) && saved.links[adopted.id]?.profile == id)
    }

    @Test func erasureRequestedWithAnUnreadableCheckpointSurvivesAnotherRestart() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let first = f.open()
        _ = f.attach(first)
        let id = try await first.publishProfile(f.removed)
        let kept = try await first.publishProfile(f.kept)
        try f.interruptWrites(to: f.catalogFile)

        let unreadable = f.open()
        let failure = await f.profiles.remove(f.removed, settingsSync: nil, sharedSpaces: unreadable, eraseData: { _ in Issue.record("Unexpected erasure") })
        #expect(throws: (any Error).self) { try failure.get() }
        #expect(f.profiles.profiles.contains(f.removed))
        let retry = f.open()
        try f.restore(f.catalogFile)
        try #require(retry.retryOptOuts())
        let saved = f.open()
        #expect(!saved.isEnabled(.profiles, for: f.removed) && saved.links[f.removed.id] == nil)
        #expect(saved.catalog.state.pending[.init(zone: SharedCatalogCategory.profiles.zone, name: id.uuidString)] == nil)
        #expect(saved.isEnabled(.profiles, for: f.kept) && saved.links[f.kept.id]?.profile == kept)
    }

    @Test func erasureWithoutARunningSyncServiceClearsItsSavedLink() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let host = f.open()
        _ = f.attach(host)
        let cloudID = try await host.publishProfile(f.removed)
        let kept = try await host.publishProfile(f.kept)

        try await f.profiles.remove(f.removed, settingsSync: nil, sharedSpaces: nil, eraseData: { _ in }).get()
        let reopened = f.open()
        #expect(reopened.links[f.removed.id] == nil && !reopened.isEnabled(.profiles, for: f.removed))
        #expect(reopened.links[f.kept.id]?.profile == kept)
        _ = f.attach(reopened)
        let replacement = f.profiles.add(name: "Replacement")
        try await reopened.enable(.profiles, for: replacement)
        #expect(reopened.linkProfile(replacement.id, to: cloudID))
        #expect(f.cloud.names(in: SharedCatalogCategory.profiles.zone).isEmpty)
    }

    @Test(arguments: [false, true])
    func interruptedSpaceJoinCanBeRetriedFromSettingsAfterRestart(existingLink: Bool) async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let file = f.root.appending(path: "Spaces.json")
        let store = SpaceStore(profile: f.kept, file: file)
        store.add(name: "Unrelated local Space")
        let original = store.spaces
        let host = f.open(spaces: store)
        _ = f.attach(host)
        let item = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "From the other Mac", symbol: "leaf", color: "green")
        _ = try f.cloud.save(#require(item.record(fields: nil)))
        try await host.enable(.spaces, for: f.kept)
        let prior = UUID()
        if existingLink {
            // A previous version checkpointed a local ID even when Spaces.json could not be written.
            try #require(host.linkProfile(f.kept.id, to: item.profileID))
            host.links[f.kept.id]?.spaces[prior] = item.id
            try #require(host.persistLinks())
        }
        try f.interruptWrites(to: file)
        await #expect(throws: (any Error).self) { try await host.join(item, in: f.kept) }
        #expect(store.spaces == original)
        #expect(host.availableSpaces(for: f.kept).contains(item))
        let beforeLocalWrite = try Data(contentsOf: f.catalogFile)
        let restored = SpaceStore(profile: f.kept, file: file)
        try f.restore(file)
        let reopened = f.open(spaces: restored)
        _ = f.attach(reopened)
        try await reopened.enable(.spaces, for: f.kept)
        let choice = try #require(reopened.availableSpaces(for: f.kept).first)
        try await reopened.join(choice, in: f.kept)
        try await reopened.join(choice, in: f.kept)
        let saved = SpaceStore(profile: f.kept, file: file).spaces
        let joinedID = try #require(f.open().links[f.kept.id]?.spaces.first { $0.value == item.id }?.key)
        #expect(saved == original + [Space(id: joinedID, name: item.title, symbol: "leaf", color: .green)])
        #expect(!existingLink || joinedID == prior)
        #expect(reopened.availableSpaces(for: f.kept).isEmpty)
        // A crash can also keep the local Space and lose the final catalog checkpoint.
        try beforeLocalWrite.write(to: f.catalogFile, options: .atomic)
        var newer = item
        newer.title = "Renamed on the other Mac"
        _ = try f.cloud.save(#require(newer.record(fields: f.cloud.record(item.recordID)?.systemFields)))
        let savedStore = SpaceStore(profile: f.kept, file: file)
        let retry = f.open(spaces: savedStore)
        let engine = f.attach(retry)
        if existingLink {
            try await retry.join(item, in: f.kept)
        } else {
            // Settings can offer Share on the local copy before its final link was saved.
            let local = try #require(savedStore.space(id: joinedID))
            try await retry.share(local, in: f.kept)
        }
        try await engine.sendNow()
        #expect(SpaceStore(profile: f.kept, file: file).spaces == original + [Space(id: joinedID, name: newer.title, symbol: "leaf", color: .green)])
        #expect(f.open().links[f.kept.id]?.spaces[joinedID] == item.id)
        #expect(f.cloud.record(item.recordID).flatMap(SharedSpaceItem.init(record:)) == newer)
        #expect(f.cloud.writeCount == 2)
    }
}
