// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    @Test func joiningASpaceCombinesBothPopulatedPinLibraries() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let url = "https://both.example.test/"
        let first = studio.browser.pinned(url)
        let second = air.browser.pinned(url)
        air.browser.addFavorite(second)
        let firstID = try #require(first.pinID), secondID = try #require(second.pinID)
        let deviceOnly = air.browser.addPage("https://air-only.example.test/")
        let page = studio.browser.addPage("https://nested.example.test/")
        let folder = studio.browser.createFolder(named: "Reading", containing: [page])
        studio.browser.pin(folder)
        let nested = try #require(page.pinID)
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        let space = try #require(air.host.availableSpaces(for: air.profile).first)
        #expect(air.browser.pinStore.pins.map(\.id) == [secondID])
        try await air.host.join(space, in: air.profile)
        try await air.sync()
        try await studio.sync()
        for mac in [air, studio] {
            let rows = mac.browser.pinStore.pins
            #expect(Set(rows.map(\.id)) == [firstID, secondID, folder.id, nested])
            #expect(rows.filter { $0.url == url }.count == 2)
            #expect(rows.first { $0.id == nested }?.parentID == folder.id)
            #expect(rows.first { $0.id == secondID }?.isFavorite == true)
        }
        #expect(studio.browser.page(at: deviceOnly.urlString) == nil)
        let later = air.browser.pinned("https://future.example.test/")
        let laterID = try #require(later.pinID)
        air.browser.renameTab(later, to: "From Air")
        try await air.sync()
        try await studio.sync()
        let received = try #require(studio.browser.page(for: laterID))
        #expect(received.customTitle == "From Air")
        studio.browser.unpin(received)
        try await studio.sync()
        try await air.sync()
        try await studio.sync()
        #expect(!air.browser.pinStore.pins.contains { $0.id == laterID })
        #expect(!studio.browser.pinStore.pins.contains { $0.id == laterID })
    }
    @Test func sharingAProfileMergesStableIdentitiesAndKeepsDeviceOnlyPins() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud), air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let folder = ProfilePin(id: UUID(), orderKey: "A", kind: .folder, title: "Original", isPinned: true, sizeFactor: 1.2, tintsIcons: true, customColor: "#245F7C")
        let same = ProfilePin(id: UUID(), parentID: folder.id, orderKey: "V", kind: .tab, url: "https://same.example.test/", title: "Same")
        let empty = ProfilePin(id: UUID(), orderKey: "B", kind: .folder, title: "Empty", isPinned: true)
        let other = ProfilePin(id: UUID(), orderKey: "C", kind: .tab, url: same.url, title: "Independent")
        studio.browser.pinStore.publish([folder, same, empty])
        air.browser.pinStore.publish([folder, same, other])
        let group = try await studio.host.publishProfile(studio.profile)
        try await studio.sync()
        try await air.host.enable(.profiles, for: air.profile)
        let published = try #require(air.host.available(.profiles, for: air.profile).first)
        #expect(published.id == group && !air.host.isEnabled(.pins, for: air.profile))
        try await air.host.joinProfile(published, in: air.profile)
        try await air.sync()
        try await studio.sync()
        for mac in [studio, air] {
            let rows = try mac.browser.pinStore.readForPublication()
            #expect(Set(rows.map(\.id)) == [folder.id, same.id, empty.id, other.id])
            #expect(rows.first { $0.id == same.id }?.parentID == folder.id)
            #expect(rows.first { $0.id == folder.id }?.customColor == folder.customColor)
            #expect(mac.host.catalog.state.conflicts.isEmpty)
            #expect(!mac.host.isEnabled(.spaces, for: mac.profile))
        }
        let local = try #require(air.browser.page(for: other.id))
        let fileURL = URL(fileURLWithPath: "/test/only-on-this-mac")
        air.browser.setPin(fileURL, title: "Device only", for: local)
        try await air.sync()
        try await studio.sync()
        try await air.sync()
        #expect(air.browser.page(for: other.id)?.pinnedURL == fileURL)
        #expect(studio.browser.page(for: other.id) == nil)
        #expect(cloud.records(in: SharedCatalogCategory.pins.zone)?.compactMap(SharedSpaceItem.init(record:)).contains { $0.url == fileURL.absoluteString } == false)
    }

    @Test func joiningOnlyTheProfileDoesNotRestoreAnUnpinnedSpaceTab() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud), air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let page = studio.browser.addPage("https://from-space.example.test/")
        _ = try await studio.host.publishProfile(studio.profile)
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        studio.browser.addFavorite(page)
        let id = try #require(page.pinID)
        try await studio.sync()
        try await air.host.enable(.profiles, for: air.profile)
        try await air.host.joinProfile(try #require(air.host.available(.profiles, for: air.profile).first), in: air.profile)
        #expect(air.browser.page(for: id)?.isFavorite == true)
        studio.browser.unpin(page)
        try await studio.sync()
        try await air.sync()
        try await studio.sync()
        #expect(!air.browser.pinStore.pins.contains { $0.id == id })
        #expect(!studio.browser.pinStore.pins.contains { $0.id == id })
        #expect(cloud.records(in: SharedCatalogCategory.pins.zone)?.compactMap(SharedSpaceItem.init(record:)).first { $0.id == id }?.removed == true)
    }

    @Test func failedSQLiteImportSurvivesRestartAndPreservesTheRemotePin() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud), air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        _ = try await studio.host.publishProfile(studio.profile)
        let pin = studio.browser.pinned("https://wait-for-disk.example.test/")
        let id = try #require(pin.pinID)
        try await studio.sync()
        try await air.host.enable(.profiles, for: air.profile)
        let item = try #require(air.host.available(.profiles, for: air.profile).first)
        try await air.browser.database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER rejectPin BEFORE INSERT ON profilePin BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        await #expect(throws: SharedCatalogError.storage) { try await air.host.joinProfile(item, in: air.profile) }
        #expect(air.browser.pinStore.pins.isEmpty)
        let restored = CloudSharedSpaces(stateFile: air.dir.appending(path: "shared.json"), profiles: [air.profile],
                                         windows: { [air] in [air.browser] }, spaces: { _ in air.store }, pins: { _ in air.browser.pinStore })
        air.browser.sharedSpacesHost = restored
        let engine = FakeSyncEngine(cloud: cloud, delegate: restored.catalog)
        restored.attach(engine)
        await restored.refresh()
        try await air.browser.database.writer.write { try $0.execute(sql: "DROP TRIGGER rejectPin") }
        await restored.refresh()
        try await studio.sync()
        #expect(air.browser.pinStore.pins.map(\.id) == [id])
        #expect(studio.browser.pinStore.pins.map(\.id) == [id])
        #expect(restored.pinLibraryFailures.isEmpty && cloud.names(in: SharedCatalogCategory.pins.zone).count == 1)
    }

    @Test func resumedPinLibraryAsksWhichConcurrentEditToKeep() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud), air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let first = studio.browser.pinned("https://edits.example.test/")
        let id = try #require(first.pinID)
        _ = try await studio.host.publishProfile(studio.profile)
        try await studio.sync()
        try await air.host.enable(.profiles, for: air.profile)
        try await air.host.joinProfile(try #require(air.host.available(.profiles, for: air.profile).first), in: air.profile)
        let second = try #require(air.browser.page(for: id))
        air.host.pause(.pins, for: air.profile)
        air.browser.renameTab(second, to: "Air")
        studio.browser.renameTab(first, to: "Studio")
        try await studio.sync()
        try await air.host.enable(.pins, for: air.profile)
        try await air.sync()
        let key = SyncRecordID(zone: SharedCatalogCategory.pins.zone, name: id.uuidString)
        #expect(air.host.catalog.state.conflicts[key]?.item.customTitle == "Air")
        #expect(air.host.catalog.state.remote[key]?.item.customTitle == "Studio")
        air.host.catalog.resolve(key, keepingLocal: false)
        try await air.sync()
        #expect(second.customTitle == "Studio")
    }

    @Test func pausedPinsWaitForTheSameAccountAfterRestartAndSharingAnotherSpace() async throws {
        let owner = FakeSyncCloud(), other = FakeSyncCloud(user: "other-account")
        let mac = Mac(owner)
        defer { mac.finish() }
        let group = try await mac.host.publishProfile(mac.profile)
        try await mac.sync()
        let pin = mac.browser.pinned("https://waiting.example.test/")
        let id = try #require(pin.pinID)
        mac.host.pause(.pins, for: mac.profile)
        let host = CloudSharedSpaces(stateFile: mac.dir.appending(path: "shared.json"), profiles: [mac.profile],
                                     windows: { [] }, spaces: { _ in mac.store }, pins: { _ in mac.browser.pinStore })
        let engine = FakeSyncEngine(cloud: owner, delegate: host.catalog)
        host.attach(engine)
        await host.refresh()
        try await host.share(try #require(mac.store.spaces.first), in: mac.profile)
        await host.refresh()
        #expect(!host.isEnabled(.pins, for: mac.profile))
        #expect(owner.names(in: SharedCatalogCategory.pins.zone).isEmpty)

        engine.cloud = other
        await engine.simulateAccount(.switchAccounts(user: other.user))
        try await host.enable(.profiles, for: mac.profile)
        await host.refresh()
        #expect(host.links[mac.profile.id] == nil && other.names(in: SharedCatalogCategory.pins.zone).isEmpty)
        engine.cloud = owner
        await engine.simulateAccount(.switchAccounts(user: owner.user))
        host.accountVerificationChanged(.resolved(owner.user))
        await host.refresh()
        #expect(!host.needsEngine && host.cloudProfileID(for: mac.profile.id) == group)
        #expect(owner.names(in: SharedCatalogCategory.pins.zone).isEmpty)
        try await host.enable(.pins, for: mac.profile)
        await host.refresh()
        #expect(owner.names(in: SharedCatalogCategory.pins.zone) == [id.uuidString])
        #expect(other.names(in: SharedCatalogCategory.pins.zone).isEmpty)
    }

    @Test func aLegacyPinSelectionWaitsForTheWholeLibrarySwitchAfterRestart() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let original = Profile(id: UUID(), name: "Studio", symbol: "person", color: .blue)
        let work = Profile(id: UUID(), name: "Air", symbol: "person", color: .gray)
        let unrelated = Profile(id: UUID(), name: "Other", symbol: "person", color: .gray)
        let serverStore = ProfilePinStore.store(for: .temporary()), airStore = ProfilePinStore.store(for: .temporary())
        let otherStore = ProfilePinStore.store(for: .temporary()), personalStore = ProfilePinStore.store(for: .temporary())
        let workSpaces = SpaceStore(profile: work, file: root.appending(path: "work-spaces.json"))
        let first = ProfilePin(id: UUID(), orderKey: "A", kind: .tab, url: "https://server.example.test/")
        let second = ProfilePin(id: UUID(), orderKey: "B", kind: .tab, url: "https://client.example.test/")
        let favorite = ProfilePin(id: UUID(), orderKey: "C", kind: .tab, url: "https://favorite.example.test/", isFavorite: true)
        let hidden = ProfilePin(id: UUID(), orderKey: "A", kind: .tab, url: "https://unrelated.example.test/")
        serverStore.publish([first])
        airStore.publish([second, favorite])
        otherStore.publish([hidden])
        let server = CloudSharedSpaces(stateFile: root.appending(path: "server.json"), profiles: [original],
                                       windows: { [] }, spaces: { _ in nil }, pins: { _ in serverStore })
        server.attach(FakeSyncEngine(cloud: cloud, delegate: server.catalog))
        let group = try await server.publishProfile(original)
        await server.refresh()
        func openAir() -> CloudSharedSpaces {
            let host = CloudSharedSpaces(stateFile: root.appending(path: "air.json"), profiles: [work, unrelated],
                                         windows: { [] }, spaces: { $0.id == work.id ? workSpaces : nil }, pins: {
                                             if $0.isOriginal {
                                                 return personalStore
                                             }
                                             return $0.id == work.id ? airStore : otherStore
                                         })
            host.attach(FakeSyncEngine(cloud: cloud, delegate: host.catalog))
            return host
        }
        let legacy = openAir()
        try await legacy.enable(.profiles, for: work)
        // An older build selected one row, assigned it a different cloud ID, and exited with the write pending.
        let alias = UUID()
        legacy.links[work.id] = .init(profile: group, pins: [second.id: alias])
        legacy.catalog.setEnabled(true, .pins, for: work.id)
        let pending = try #require(CloudSharedSpaces.pinItem(second, id: alias, profile: group))
        legacy.catalog.stage(pending, for: work.id)
        legacy.pause(.profiles, for: work)
        let air = openAir()
        air.accountVerificationChanged(.resolved(cloud.user))
        #expect(!air.isEnabled(.pins, for: work) && !air.needsEngine)
        try await air.enable(.profiles, for: work)
        await air.refresh()
        #expect(air.links[work.id]?.pins[second.id] == alias)
        #expect(air.catalog.state.pending[pending.recordID]?.item == pending)
        #expect(Set(airStore.pins.map(\.id)) == [second.id, favorite.id])
        #expect(cloud.names(in: SharedCatalogCategory.pins.zone) == [first.id.uuidString])
        try await air.share(try #require(workSpaces.spaces.first), in: work)
        #expect(!air.isEnabled(.pins, for: work))
        // Personal already uses the same catalog zone. Work still needs its own baseline and consent.
        _ = try await air.publishProfile(.original())
        #expect(air.catalog.ready.contains(.pins) && !air.isEnabled(.pins, for: work))
        await air.refresh()
        #expect(cloud.names(in: SharedCatalogCategory.pins.zone) == [first.id.uuidString])
        air.pause(.profiles, for: work)
        try await air.enable(.pins, for: work)
        await air.refresh()
        await server.refresh()
        #expect(Set(serverStore.pins.map(\.id)) == [first.id, alias, favorite.id])
        #expect(Set(airStore.pins.map(\.id)) == [first.id, second.id, favorite.id])
        #expect(serverStore.pins.first { $0.id == favorite.id }?.isFavorite == true)
        #expect(air.links[work.id]?.pins[second.id] == alias)
        #expect(otherStore.pins.map(\.id) == [hidden.id])
        #expect(air.links[unrelated.id] == nil && !air.isEnabled(.profiles, for: work))
        #expect(!cloud.names(in: SharedCatalogCategory.pins.zone).contains(hidden.id.uuidString))
        await #expect(throws: SharedCatalogError.self) { try await air.enable(.pins, for: .privateBrowsing()) }
    }

    @Test func aSwitchOfferedForAReturningAccountCannotResumeAnotherAccountsLibrary() async throws {
        let first = FakeSyncCloud(), second = FakeSyncCloud(user: "second-owner")
        let mac = Mac(first)
        defer { mac.finish() }
        let firstGroup = try await mac.host.publishProfile(mac.profile)
        try await mac.sync()
        mac.engine.cloud = second
        await mac.engine.simulateAccount(.switchAccounts(user: second.user))
        _ = try await mac.host.publishProfile(mac.profile)
        try await mac.sync()
        await mac.engine.simulateAccount(.signOut)
        mac.host.accountVerificationChanged(.resolved(first.user))
        #expect(mac.host.cloudProfileID(for: mac.profile.id) == firstGroup && !mac.host.needsEngine)
        _ = mac.browser.pinned("https://waiting-for-first.example.test/")

        // Settings offered the first owner's switch, but the engine now sees the second owner's account.
        await #expect(throws: SharedCatalogError.self) { try await mac.host.enable(.pins, for: mac.profile) }
        try await mac.sync()
        #expect(mac.host.cloudProfileID(for: mac.profile.id) == nil && !mac.host.isEnabled(.pins, for: mac.profile))
        #expect(second.names(in: SharedCatalogCategory.pins.zone).isEmpty && first.names(in: SharedCatalogCategory.pins.zone).isEmpty)
    }

    @Test func anIncomingPinnedFolderKeepsAnUnrelatedLocalFolderAndItsTabs() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud), air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let localPage = air.browser.addPage("https://only-on-air.example.test/")
        let localFolder = air.browser.createFolder(named: "Air folder", containing: [localPage])
        air.browser.saveBlocking()
        let shared = ProfilePin(id: localFolder.id, orderKey: "V", kind: .folder, title: "Studio folder", isPinned: true)
        studio.browser.pinStore.publish([shared])
        _ = try await studio.host.publishProfile(studio.profile)
        try await studio.sync()
        try await air.host.enable(.profiles, for: air.profile)
        try await air.host.joinProfile(try #require(air.host.available(.profiles, for: air.profile).first), in: air.profile)
        let imported = try #require(air.browser.pinStore.pins.first)
        #expect(imported.id != localFolder.id && imported.title == shared.title)
        #expect(air.browser.folder(id: localFolder.id) === localFolder && localFolder.name == "Air folder")
        #expect(air.browser.folder(containing: localPage) === localFolder && localPage.pinID == nil)
        try await air.sync()
        try await studio.sync()
        #expect(studio.browser.pinStore.pins.map(\.id) == [shared.id])
    }
}
