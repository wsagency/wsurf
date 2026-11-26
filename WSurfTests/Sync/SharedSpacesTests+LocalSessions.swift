// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    @Test func aRemoteCloseKeepsTheOtherMacsLocalFavorite() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let page = studio.browser.addPage("https://favorite.example.test/")
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        try await air.host.join(try #require(air.host.availableSpaces(for: air.profile).first), in: air.profile)
        air.host.pause(.pins, for: air.profile)
        let favorite = try #require(air.browser.page(at: page.urlString))
        air.browser.addFavorite(favorite)
        let pin = try #require(favorite.pinID)
        #expect(!air.host.isEnabled(.pins, for: air.profile))
        studio.browser.close(page)
        try await studio.sync()
        try await air.sync()
        #expect(air.browser.page(for: pin) === favorite && favorite.isFavorite)
        #expect(air.browser.pinStore.pins.contains { $0.id == pin && $0.isFavorite })
        #expect(air.host.links[air.profile.id]?.slots[favorite.id] == nil)
        #expect(cloud.names(in: SharedCatalogCategory.pins.zone).isEmpty)
    }

    @Test(arguments: [false, true])
    func restoredSessionCannotRepublishAClosedSharedTab(remoteClose: Bool) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let page = studio.browser.addPage("https://closed.example.test/")
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        try await air.host.join(try #require(air.host.availableSpaces(for: air.profile).first), in: air.profile)
        let mac = remoteClose ? air : studio
        mac.browser.saveBlocking()
        mac.browser.saveDebounce = .seconds(120)
        mac.browser.saveDeadline = .seconds(120)
        studio.browser.close(page)
        try await studio.sync()
        try await air.sync()
        let address = "https://closed.example.test/"
        #expect(mac.browser.page(at: address) == nil)
        mac.browser.closeAllTabs(saving: false) // System quit after the cloud write and before the delayed session write.
        let next = BrowserModel(context: mac.browser.context, windowID: mac.browser.windowID, database: mac.browser.database)
        next.sharesSpaceTabsOverride = false
        let host = CloudSharedSpaces(
            stateFile: mac.dir.appending(path: "shared.json"), profiles: [mac.profile], windows: { [weak next] in [next].compactMap { $0 } },
            spaces: { _ in mac.store }, pins: { _ in next.pinStore }
        )
        next.sharedSpacesHost = host
        next.adoptSpaces(mac.store.spaces.map(\.id))
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        defer { next.closeAllTabs(saving: false) }
        next.restoreSession()
        #expect(next.page(at: address) == nil)
        next.scheduleSave()
        await host.refresh()
        let records = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone))
        #expect(!records.compactMap(SharedSpaceItem.init(record:)).contains { !$0.removed && $0.url == address })
    }

    @Test func explicitlyReopeningAClosedSharedTabSharesItAgain() async throws {
        let mac = Mac(FakeSyncCloud())
        defer { mac.finish() }
        let page = mac.browser.addPage("https://reopen.example.test/")
        try await mac.host.share(try #require(mac.store.spaces.first), in: mac.profile)
        try await mac.sync()
        mac.browser.close(page)
        mac.browser.reopenLastClosedTab()
        try await mac.sync()
        let records = try #require(mac.engine.cloud.records(in: SharedCatalogCategory.spaces.zone))
        #expect(records.compactMap(SharedSpaceItem.init(record:)).filter { !$0.removed && $0.url == "https://reopen.example.test/" }.count == 1)
    }

    @Test(arguments: [false, true])
    func rejoiningCannotStealRowsFromAnExistingWindow(closed: Bool) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let page = studio.browser.addPage("https://retained.example.test/")
        let folder = studio.browser.createFolder(named: "Work", containing: [page])
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        let shared = try #require(air.host.availableSpaces(for: air.profile).first)
        try await air.host.join(shared, in: air.profile)
        let original = try #require(air.browser.page(at: page.urlString))
        let originalFolder = try #require(air.browser.folder(containing: original))
        let space = try #require(air.store.spaces.first { $0.id == original.spaceID })
        air.host.stopSharing(space, in: air.profile)
        air.browser.renameTab(original, to: "Device copy")
        let second = air.addWindow()
        if closed {
            air.browser.markSessionClosed()
            air.browser.closeAllTabs(saving: false)
        } else {
            air.browser.saveBlocking()
        }
        try await air.host.join(shared, in: air.profile)
        let receiving = closed ? second : air.browser
        let imported = try #require(receiving.tabs.first { $0.urlString == page.urlString && $0.id != original.id })
        #expect(receiving.folder(containing: imported)?.name == folder.name)
        receiving.saveBlocking()
        if closed {
            air.browser.restoreSession()
        }
        #expect(air.browser.tab(id: original.id)?.customTitle == "Device copy")
        #expect(air.browser.folder(containing: try #require(air.browser.tab(id: original.id)))?.id == originalFolder.id)
    }

    @Test func localInactivityArchivesOnlyDeviceOnlyTabs() async throws {
        let mac = Mac(FakeSyncCloud())
        defer { mac.finish() }
        let home = try #require(mac.store.spaces.first)
        let other = mac.store.add(name: "Local")
        mac.browser.adoptSpaces(mac.store.spaces.map(\.id))
        let shared = mac.browser.addPage("https://shared.example.test/")
        try await mac.host.share(home, in: mac.profile)
        try await mac.sync()
        mac.browser.switchSpace(to: other.id)
        let local = mac.browser.addPage("https://local.example.test/")
        mac.browser.activate(mac.browser.addPage("https://active.example.test/"))
        let now = Date()
        shared.lastActiveAt = now.addingTimeInterval(-172_800)
        local.lastActiveAt = shared.lastActiveAt
        #expect(mac.browser.archiveTabs(unusedFor: .day, now: now) == 1)
        #expect(mac.browser.tab(id: shared.id) === shared && mac.browser.tab(id: local.id) == nil)
        try await mac.sync()
        #expect(mac.host.catalog.item(shared.id, in: .spaces)?.removed == false)
    }
}
