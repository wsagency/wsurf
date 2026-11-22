// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
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

        func open(spaces: SpaceStore? = nil, profileStore: ProfileStore? = nil, pinStore: ProfilePinStore? = nil) -> CloudSharedSpaces {
            var stores: [UUID: ProfilePinStore] = [:]
            stores[kept.id] = pinStore
            return CloudSharedSpaces(stateFile: catalogFile, profileStore: profileStore ?? profiles, windows: { [] }, spaces: { _ in spaces }, pins: { profile in
                if let existing = stores[profile.id] {
                    return existing
                }
                let store = ProfilePinStore.store(for: AppDatabase(at: root.appending(path: "\(profile.id).sqlite")))
                stores[profile.id] = store
                return store
            })
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

    @Test(arguments: [SharedCatalogCategory.spaces, .pins])
    func firstSharedSpaceOrPinLibraryUsesTheRenewedProfileInstance(category: SharedCatalogCategory) async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let work = f.kept, renewed = UUID()
        try f.profiles.updateCloudLedger { $0.active[work.id] = [f.cloud.user: renewed] }
        let restored = ProfileStore(file: f.root.appending(path: "profiles.json"))
        let spaces = SpaceStore(profile: work, file: f.root.appending(path: "Spaces.json"))
        let host = f.open(spaces: spaces, profileStore: restored)
        let engine = f.attach(host)
        if category == .spaces {
            try await host.enable(.spaces, for: work)
            #expect(host.cloudProfileID(for: work.id) == nil)
            try await host.share(spaces.add(name: "Shared work"), in: work)
        } else {
            let pin = ProfilePin(id: UUID(), orderKey: "V", kind: .tab, url: "https://example.invalid/work")
            host.pins(work).publish([pin])
            try await host.enable(.pins, for: work)
        }
        try await engine.sendNow()
        let rows = try #require(f.cloud.records(in: category.zone)).compactMap(SharedSpaceItem.init(record:))
        #expect(rows.map(\.profileID) == [renewed])
        #expect(f.open().links[work.id]?.profile == renewed)
        for other in SharedCatalogCategory.allCases where other != category {
            #expect(host.isEnabled(other, for: work) == (category == .spaces && other == .pins))
            #expect(f.cloud.names(in: other.zone).isEmpty)
        }
        let published = try await host.publishProfile(work)
        try await engine.sendNow()
        #expect(f.cloud.names(in: SharedCatalogCategory.profiles.zone) == [renewed.uuidString])
        #expect(published == renewed)
    }

    @Test func publishingKeepsTheChosenCatalogLinkAndIsolatesAppleAccounts() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let work = f.kept, renewed = UUID(), joined = UUID()
        try f.profiles.updateCloudLedger { $0.active[work.id] = [f.cloud.user: renewed] }
        let host = f.open()
        let engine = f.attach(host)
        try await host.enable(.profiles, for: work)
        try #require(host.linkProfile(work.id, to: joined))
        #expect(try await host.publishProfile(work) == joined)

        f.cloud.switchUser("other-synthetic-owner")
        await engine.simulateAccount(.switchAccounts(user: f.cloud.user))
        let other = try await host.publishProfile(work)
        try await engine.sendNow()
        #expect(other != joined && other != renewed)
        #expect(f.cloud.names(in: SharedCatalogCategory.profiles.zone) == [other.uuidString])
    }

    @Test func newInstancePublishesTheLocalLibraryAndItsCurrentFolder() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let work = f.kept, file = f.root.appending(path: "pins.sqlite")
        let pins = ProfilePinStore.store(for: AppDatabase(at: file))
        let first = f.open(pinStore: pins)
        let engine = f.attach(first)
        var folder = ProfilePin(id: UUID(), orderKey: "V", kind: .folder, title: "Old folder")
        var chosen = ProfilePin(id: UUID(), parentID: folder.id, orderKey: "V", kind: .tab, url: "https://example.invalid/shared")
        let sibling = ProfilePin(id: UUID(), parentID: folder.id, orderKey: "W", kind: .tab, url: "https://example.invalid/sibling")
        pins.publish([folder, chosen, sibling])
        try await first.enable(.pins, for: work)
        try await engine.sendNow()
        let old = try #require(first.links[work.id]?.profile)
        first.permitsSharing = { _ in false }
        chosen.customTitle = "Local rename"
        folder.title = "Local folder"
        pins.publish([folder, chosen, sibling])
        first.pinsChanged(in: work, store: pins)

        let disk = AppDatabase(at: file)
        let restored = ProfilePinStore.store(for: disk)
        let host = f.open(pinStore: restored)
        _ = f.attach(host)
        let next = CloudProfileInstance(.shared, id: UUID(), owner: f.cloud.user)
        try await disk.writer.write { try $0.execute(sql: "ALTER TABLE profilePin RENAME TO heldPins") }
        #expect(throws: (any Error).self) { try host.replaceInstance(for: work, with: next) }
        #expect(f.open().links[work.id]?.profile == old)
        try await disk.writer.write { try $0.execute(sql: "ALTER TABLE heldPins RENAME TO profilePin") }
        try host.replaceInstance(for: work, with: next)
        await host.refresh()

        let rows = try #require(f.cloud.records(in: SharedCatalogCategory.pins.zone)).compactMap(SharedSpaceItem.init(record:)).filter { $0.profileID == next.id }
        let link = try #require(f.open().links[work.id])
        let pinID = try #require(link.pins[chosen.id]), folderID = try #require(link.pinFolders?[folder.id])
        let siblingID = try #require(link.pins[sibling.id])
        #expect(Set(rows.map(\.id)) == [pinID, folderID, siblingID])
        let row = try #require(rows.first { $0.id == pinID })
        #expect(row.customTitle == chosen.customTitle && row.parentID == folderID)
        #expect(rows.first { $0.id == folderID }?.title == folder.title)
        #expect(restored.pins.first { $0.id == chosen.id }?.customTitle == chosen.customTitle)
        #expect(restored.pins.first { $0.id == folder.id }?.title == folder.title)
        #expect(rows.first { $0.id == siblingID }?.parentID == folderID)
        #expect(restored.pins.first { $0.id == sibling.id }?.url == sibling.url)
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
        let pins = try #require(f.cloud.records(in: SharedCatalogCategory.pins.zone)).compactMap(SharedSpaceItem.init(record:))
        #expect(pins == [kept], "The replacement profile has its own local pin store.")
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
    func startupRevokesOnlyMissingProfilesBeforeSendingAnOlderCheckpoint(parked: Bool) async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let personal = Profile.original()
        let old = f.open()
        let engine = f.attach(old)
        let removedID = try await old.publishProfile(f.removed)
        let keptID = try await old.publishProfile(f.kept)
        let personalID = try await old.publishProfile(personal)
        try await engine.sendNow()
        engine.offline = true
        let removed = SharedSpaceItem(id: removedID, kind: .profile, profileID: removedID, title: "Private draft")
        let kept = SharedSpaceItem(id: keptID, kind: .profile, profileID: keptID, title: "Keep named")
        let original = SharedSpaceItem(id: personalID, kind: .profile, profileID: personalID, title: "Keep Personal")
        for (item, profile) in [(removed, f.removed), (kept, f.kept), (original, personal)] {
            old.catalog.stage(item, for: profile.id)
        }
        if parked {
            await engine.simulateAccount(.signOut)
        }
        let legacy = try Data(contentsOf: f.catalogFile)
        try await f.profiles.remove(f.removed, settingsSync: nil, sharedSpaces: old, eraseData: { _ in }).get()
        // An older build removed the local profile and left its entire catalog checkpoint behind.
        try legacy.write(to: f.catalogFile, options: .atomic)
        if parked {
            try f.interruptWrites(to: f.catalogFile)
        }
        let upgraded = f.open()
        let next = f.attach(upgraded)
        next.add([.saveRecord(removed.recordID)])
        if parked {
            try f.restore(f.catalogFile)
            try await upgraded.enable(.profiles, for: f.kept)
            try await upgraded.enable(.profiles, for: personal)
        }
        await upgraded.refresh()
        #expect(!upgraded.isEnabled(.profiles, for: f.removed))
        #expect(upgraded.links[f.removed.id] == nil && upgraded.catalog.state.pending[removed.recordID] == nil)
        #expect(upgraded.links[f.kept.id]?.profile == keptID && upgraded.links[personal.id]?.profile == personalID)
        #expect(next.saveAttempts[removedID.uuidString] == nil)
        #expect(f.cloud.record(removed.recordID).flatMap(SharedSpaceItem.init(record:))?.title == f.removed.name)
        #expect(f.cloud.record(kept.recordID).flatMap(SharedSpaceItem.init(record:)) == kept)
        #expect(f.cloud.record(original.recordID).flatMap(SharedSpaceItem.init(record:)) == original)
        let replacement = f.profiles.add(name: "Replacement")
        try await upgraded.enable(.profiles, for: replacement)
        #expect(upgraded.linkProfile(replacement.id, to: removedID))
        #expect(f.open().links[f.removed.id] == nil)
    }

    @Test func aStaleWindowCannotEnableOrLinkAnErasedProfile() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let host = f.open()
        let engine = f.attach(host)
        let selection = ProfileStore.selection(profile: f.removed, catalog: f.profiles)
        let stale = selection.current
        let cloudID = try await host.publishProfile(stale)
        try await engine.sendNow()
        let another = f.open()
        _ = f.attach(another)
        try await another.enable(.profiles, for: f.kept)
        try await f.profiles.remove(stale, settingsSync: nil, sharedSpaces: host, eraseData: { _ in }).get()
        #expect(!another.linkProfile(stale.id, to: cloudID))
        await #expect(throws: SharedCatalogError.self) { try await host.enable(.pins, for: stale) }
        await #expect(throws: SharedCatalogError.self) { try await host.publishProfile(stale) }
        #expect(!host.linkProfile(stale.id, to: cloudID))
        #expect(f.open().links[stale.id] == nil)
        #expect(SharedCatalogCategory.allCases.allSatisfy { !host.isEnabled($0, for: stale) })
        let replacement = f.profiles.add(name: "Replacement")
        try await host.enable(.profiles, for: replacement)
        #expect(host.linkProfile(replacement.id, to: cloudID))
    }

    @Test func anUnreadableProfileListCannotAuthorizeAnUploadOrRevokeANamedProfile() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let original = f.open()
        _ = f.attach(original)
        let kept = try await original.publishProfile(f.kept)
        let file = f.root.appending(path: "profiles.json")
        try f.interruptWrites(to: file)
        let profiles = ProfileStore(file: file)
        let host = f.open(profileStore: profiles)
        let next = f.attach(host)
        await host.refresh()
        #expect(next.saveAttempts[kept.uuidString] == nil)
        try f.restore(file)
        await host.refresh()
        #expect(host.links[f.kept.id]?.profile == kept && host.isEnabled(.profiles, for: f.kept))
        #expect(f.cloud.names(in: SharedCatalogCategory.profiles.zone) == [kept.uuidString])
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
