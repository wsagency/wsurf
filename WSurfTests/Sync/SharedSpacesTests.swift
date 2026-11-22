// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct SharedSpacesTests {
    final class Mac {
        private final class Windows {
            var models: [BrowserModel] = []
        }

        private let openWindows = Windows()
        var windows: [BrowserModel] {
            openWindows.models
        }

        let profile = Profile.original()
        let store: SpaceStore
        let browser: BrowserModel
        let host: CloudSharedSpaces
        let engine: FakeSyncEngine
        let dir: URL

        init(_ cloud: FakeSyncCloud) {
            dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let spaceStore = SpaceStore(profile: profile, file: dir.appending(path: "spaces.json"))
            store = spaceStore
            let model = BrowserModel(windowID: UUID(), database: .temporary())
            browser = model
            model.adoptSpaces(spaceStore.spaces.map(\.id))
            model.attachProfilePins()
            let windows = openWindows
            windows.models = [model]
            host = CloudSharedSpaces(
                stateFile: dir.appending(path: "shared.json"), windows: { windows.models },
                spaces: { _ in spaceStore }, pins: { _ in model.pinStore }
            )
            model.sharedSpacesHost = host
            engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
            host.attach(engine)
        }

        func addWindow() -> BrowserModel {
            let model = BrowserModel(context: browser.context, windowID: UUID(), database: browser.database)
            model.sharedSpacesHost = host
            model.adoptSpaces(store.spaces.map(\.id))
            model.attachProfilePins()
            openWindows.models.append(model)
            return model
        }

        func finish() {
            for window in windows {
                window.closeAllTabs(saving: false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        func sync() async throws {
            await host.refresh()
            try await engine.sendNow()
            try await engine.fetchNow()
        }
    }

    @Test func twoPopulatedMacsAndALaterJoinKeepBothLocalSessionsAndDistinctSharedTabs() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let studioHome = try #require(studio.store.spaces.first)
        let airHome = try #require(air.store.spaces.first)
        let url = "https://example.test/same"
        let first = studio.browser.addPage(url)
        let second = studio.browser.addPage(url)
        let local = air.browser.addPage(url)
        air.browser.activate(local)
        #expect(cloud.recordCount == 0)
        try await studio.host.share(studioHome, in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        let shared = try #require(air.host.availableSpaces(for: air.profile).first)
        try await air.host.join(shared, in: air.profile)
        let joined = try #require(air.store.spaces.first { $0.id != airHome.id })
        #expect(air.store.spaces.count == 2)
        #expect(air.browser.tabs.filter { $0.spaceID == joined.id }.count == 2)
        #expect(air.browser.currentSpaceID == airHome.id && air.browser.activeTab === local)
        #expect(studio.host.cloudProfileID(for: studio.profile.id) == air.host.cloudProfileID(for: air.profile.id))
        let later = Mac(cloud)
        defer { later.finish() }
        try await later.engine.fetchNow() // Another category has advanced the engine checkpoint.
        try await later.host.enable(.spaces, for: later.profile)
        try await later.host.join(shared, in: later.profile)
        #expect(later.browser.tabs.filter { $0.urlString == url }.count == 2)
        later.browser.activate(try #require(later.browser.tab(id: first.id)))
        let focusedSpace = later.browser.currentSpaceID
        studio.browser.close(first)
        try await studio.sync()
        try await air.sync()
        try await later.sync()
        #expect(air.browser.tabs.filter { $0.spaceID == joined.id }.count == 1)
        #expect(later.browser.tabs.filter { $0.urlString == url }.count == 1)
        #expect(later.browser.activeTabID == second.id && later.browser.currentSpaceID == focusedSpace)
        #expect(studio.browser.tabs.contains { $0 === second })
        #expect(air.browser.activeTab === local)
    }

    @Test func movesFolderOrderAndExplicitCloseUseTheExistingSidebarActions() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer {
            studio.finish()
            air.finish()
        }
        let first = try #require(studio.store.spaces.first)
        let second = studio.store.add(name: "Reading")
        let local = studio.store.add(name: "Local only")
        studio.browser.adoptSpaces(studio.store.spaces.map(\.id))
        let tab = studio.browser.addPage("https://one.example.test/")
        let other = studio.browser.addPage("https://two.example.test/")
        let folder = studio.browser.createFolder(named: "Before", containing: [tab, other])
        _ = studio.browser.addPage("file:///private/only")
        try await studio.host.share(first, in: studio.profile)
        try await studio.host.share(second, in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        for item in air.host.availableSpaces(for: air.profile) {
            try await air.host.join(item, in: air.profile)
        }
        let remoteFolder = try #require(air.browser.folder(id: folder.id))
        let deviceOnly = air.browser.addPage("file:///device-only/book")
        air.browser.move([.tab(deviceOnly.id)], into: remoteFolder, before: .tab(other.id))

        studio.browser.renameFolder(folder, to: "After")
        studio.browser.move([.tab(other.id)], into: folder, before: .tab(tab.id))
        try await studio.sync()
        try await air.sync()
        #expect(remoteFolder.name == "After")
        #expect(air.browser.reconciledTree().rows(in: remoteFolder.id) == [.tab(other.id), .tab(deviceOnly.id), .tab(tab.id)])
        #expect(air.browser.page(at: "file:///private/only") == nil)

        studio.browser.move([.tab(tab.id)], toSpace: second.id)
        try await studio.sync()
        try await air.sync()
        let remoteSecond = try #require(air.store.spaces.first { $0.name == "Reading" })
        #expect(air.browser.tab(id: tab.id)?.spaceID == remoteSecond.id)
        studio.browser.switchSpace(to: second.id)
        studio.browser.move([.tab(tab.id)], toSpace: local.id)
        try await studio.sync()
        try await air.sync()
        #expect(air.browser.tab(id: tab.id) == nil)
        #expect(studio.browser.tab(id: tab.id)?.spaceID == local.id)

        studio.browser.markSessionClosed()
        studio.browser.closeAllTabs(saving: false)
        try await studio.sync()
        try await air.sync()
        #expect(air.browser.tab(id: other.id) != nil)
    }

    @Test func pausingSpaceAndPinSharingRetainsBothCopiesAndSuppressesLaterChanges() async throws {
        let cloud = FakeSyncCloud()
        let mac = Mac(cloud)
        defer { mac.finish() }
        let space = try #require(mac.store.spaces.first)
        let tab = mac.browser.addPage("https://selected.example.test/")
        try await mac.host.share(space, in: mac.profile)
        try await mac.sync()
        let written = cloud.writeCount
        mac.host.pause(.spaces, for: mac.profile)
        mac.browser.renameTab(tab, to: "Device only")
        try await mac.sync()
        #expect(cloud.writeCount == written)
        #expect(mac.browser.tab(id: tab.id)?.title == "Device only")

        let pin = mac.browser.pinned("https://pin.example.test/")
        let id = try #require(pin.pinID)
        try await mac.sync()
        mac.host.pause(.pins, for: mac.profile)
        mac.browser.addFavorite(pin)
        try await mac.sync()
        #expect(mac.browser.page(for: id)?.isFavorite == true)
        let remote = try #require(cloud.records(in: SharedCatalogCategory.pins.zone)?.first)
        #expect(SharedSpaceItem(record: remote)?.favorite == false)
    }

    @Test func independentSharedSpacesKeepDeviceOnlyRowsInTheirSidebarPositions() throws {
        let mac = Mac(FakeSyncCloud())
        defer { mac.finish() }
        let home = try #require(mac.store.spaces.first)
        let other = mac.store.add(name: "Other")
        mac.browser.adoptSpaces([home.id, other.id])
        let a = mac.browser.addPage("https://first.example.test/")
        let local = mac.browser.addPage("file:///device-only/kept")
        let b = mac.browser.addPage("https://last.example.test/")
        let c = mac.browser.addPage("https://other.example.test/")
        c.spaceID = other.id
        mac.browser.sidebarDidChange()
        let rows = [(a, home.id, "Q"), (b, home.id, "R"), (c, other.id, "A")].map { tab, space, order in
            SharedSpaceItem(id: tab.id, kind: .tab, profileID: mac.profile.id, spaceID: space, order: order, title: tab.title, url: tab.urlString)
        }
        mac.browser.applySharedRows(rows, spaces: [home.id: home.id, other.id: other.id], ids: [a.id: a.id, b.id: b.id, c.id: c.id])
        #expect(mac.browser.sidebarTree.root == [.tab(a.id), .tab(local.id), .tab(b.id)])
    }

    @Test func anOfflineRenameSurvivesHostAndWindowRestorationWithoutChangingTheActiveSpace() async throws {
        let cloud = FakeSyncCloud()
        let mac = Mac(cloud)
        defer { mac.finish() }
        let home = try #require(mac.store.spaces.first)
        let archived = mac.store.add(name: "Separate")
        mac.browser.adoptSpaces(mac.store.spaces.map(\.id))
        let shared = mac.browser.addPage("https://offline.example.test/")
        try await mac.host.share(home, in: mac.profile)
        try await mac.sync()
        mac.engine.offline = true
        mac.browser.renameTab(shared, to: "Offline edit")
        mac.browser.switchSpace(to: archived.id)
        let focused = mac.browser.addPage("https://device-only.example.test/")
        mac.browser.activate(focused)
        mac.browser.saveBlocking()
        let next = BrowserModel(windowID: mac.browser.windowID, database: mac.browser.database)
        let resumed = CloudSharedSpaces(
            stateFile: mac.dir.appending(path: "shared.json"), profiles: [mac.profile],
            windows: { [weak next] in [next].compactMap { $0 } }, spaces: { _ in mac.store }, pins: { _ in next.pinStore }
        )
        next.sharedSpacesHost = resumed
        let engine = FakeSyncEngine(cloud: cloud, delegate: resumed.catalog)
        resumed.attach(engine)
        defer { next.closeAllTabs(saving: false) }
        next.adoptSpaces(mac.store.spaces.map(\.id))
        next.restoreSession()
        await resumed.refresh()
        let record = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone)?.compactMap(SharedSpaceItem.init(record:)).first { $0.id == shared.id })
        #expect(record.customTitle == "Offline edit")
        #expect(next.currentSpaceID == archived.id && next.activeTabID == focused.id)
        #expect(next.tab(id: shared.id)?.customTitle == "Offline edit")
        #expect(cloud.names(in: SharedCatalogCategory.spaces.zone).contains(focused.id.uuidString) == false)
    }

    @Test func aLinkedProfileCannotAdoptAnUnrelatedProfilesSpaceOrPin() async throws {
        let cloud = FakeSyncCloud()
        let a = Mac(cloud)
        let b = Mac(cloud)
        defer {
            a.finish()
            b.finish()
        }
        try await a.host.share(try #require(a.store.spaces.first), in: a.profile)
        let pin = a.browser.pinned("https://pin.example.test/")
        try await a.host.selectPin(try #require(pin.pinID), in: a.profile)
        try await a.sync()
        try await b.host.enable(.spaces, for: b.profile)
        try await b.host.enable(.pins, for: b.profile)
        let space = try #require(b.host.availableSpaces(for: b.profile).first)
        let otherPin = try #require(b.host.availablePins(for: b.profile).first)
        _ = try await b.host.publishProfile(b.profile)
        #expect(b.host.availableSpaces(for: b.profile).isEmpty && b.host.availablePins(for: b.profile).isEmpty)
        await #expect(throws: SharedCatalogError.self) { try await b.host.join(space, in: b.profile) }
        await #expect(throws: SharedCatalogError.self) { try await b.host.joinPin(otherPin, in: b.profile) }
    }

    @Test func vaultDiscoveryCanStartAfterAnotherCategoryAdvancedTheCheckpoint() async throws {
        let mac = Mac(FakeSyncCloud())
        defer { mac.finish() }
        let cloud = mac.engine.cloud
        let server = SimulatedMac(cloud: cloud, root: mac.dir.appending(path: "server"))
        let vault = try server.host.addVault(profile: mac.profile.id, name: "Disposable")
        server.start()
        try await server.sync.enable(profileID: mac.profile.id, vaultID: vault.vaultID)
        try await server.pump()

        var engine: FakeSyncEngine?
        var savedChoice: Bool?
        let entitlements = CloudTabsTests.Launch.entitlements
        let gate = CloudSyncGate.Inputs(
            tabsFlag: false, vaultFlag: false, isRunningTests: false, isStaged: false, ownsSession: true,
            entitlement: { entitlements[$0] }, offersMacSync: true
        )
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: mac.dir.appending(path: "router.json"),
            profiles: [mac.profile], host: { FakeVaultHost(root: mac.dir.appending(path: "vaults")) },
            rememberVaultDiscovery: { savedChoice = $0 }, windows: { [] },
            makeEngine: { delegate, _ in
                let created = FakeSyncEngine(cloud: cloud, delegate: delegate)
                engine = created
                return created
            }
        )
        let app = try #require(started)
        #expect(app.vaults == nil && engine == nil)
        try await app.sharedSpaces?.enable(.profiles, for: mac.profile)
        try await engine?.fetchNow()
        app.setVaultDiscovery(true)
        #expect(await waitUntil { app.vaults?.remoteVaults(profileID: mac.profile.id).contains(where: { $0.vaultID == vault.vaultID }) == true })
        #expect(savedChoice == true && app.vaults?.isSyncing(profileID: mac.profile.id, vaultID: vault.vaultID) == false)
        let existing = try #require(app.vaults)
        let device = try #require(engine)
        // An unenrolled zone's changes are excluded from the native engine's incremental fetch.
        device.unreadable.insert(VaultSync.vaultRecordName)
        let later = try server.host.addVault(profile: mac.profile.id, name: "Later")
        try await server.sync.enable(profileID: mac.profile.id, vaultID: later.vaultID)
        try await server.pump()
        try await device.fetchNow()
        #expect(!existing.remoteVaults(profileID: mac.profile.id).contains { $0.vaultID == later.vaultID })
        let fullReads = device.fetchAllCount
        app.beat()
        #expect(await waitUntil { existing.remoteVaults(profileID: mac.profile.id).contains { $0.vaultID == later.vaultID } })
        #expect(app.vaults === existing && !existing.isSyncing(profileID: mac.profile.id, vaultID: later.vaultID))
        #expect(device.fetchAllCount == fullReads)
        app.setVaultDiscovery(false)
        #expect(app.vaults == nil && savedChoice == false)
        #expect(cloud.zones[SyncZone.vault(profileID: mac.profile.id, vaultID: vault.vaultID)] != nil)
        cloud.switchUser("another-account")
        app.setVaultDiscovery(true)
        #expect(app.vaults?.remoteVaults(profileID: mac.profile.id).isEmpty == true)
        #expect(await waitUntil { app.vaults == nil && savedChoice == false })
        app.prepareToTerminate()
    }

    @Test(arguments: [true, false])
    func favoritingAndUnfavoritingAnAlreadySharedTabKeepsItsIdentity(sharesPins: Bool) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer {
            studio.finish()
            air.finish()
        }
        let home = try #require(studio.store.spaces.first)
        let page = studio.browser.addPage("https://favorite.example.test/")
        try await studio.host.share(home, in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        let remote = try #require(air.host.availableSpaces(for: air.profile).first)
        try await air.host.join(remote, in: air.profile)
        let sameTab = try #require(air.browser.tab(id: page.id))
        let joinedSpace = sameTab.spaceID
        if !sharesPins {
            studio.host.pause(.pins, for: studio.profile)
            air.host.pause(.pins, for: air.profile)
        }
        studio.browser.addFavorite(page)
        try await studio.sync()
        try await air.sync()
        #expect(air.browser.tab(id: page.id) === sameTab)
        #expect(sameTab.isFavorite == sharesPins)
        #expect(air.browser.tabs.filter { $0.urlString == page.urlString }.count == 1)
        if sharesPins {
            #expect(sameTab.pinID == page.pinID)
            let otherWindow = BrowserModel(windowID: UUID(), database: air.browser.database)
            otherWindow.sharedSpacesHost = air.host
            otherWindow.adoptSpaces(air.store.spaces.map(\.id))
            otherWindow.attachProfilePins()
            air.host.applyCatalog(to: otherWindow)
            #expect(otherWindow.tabs.filter { $0.urlString == page.urlString && $0.isFavorite }.map(\.pinID) == [page.pinID])
            otherWindow.closeAllTabs(saving: false)
            air.browser.saveBlocking()
            let restored = BrowserModel(windowID: air.browser.windowID, database: air.browser.database)
            restored.sharedSpacesHost = air.host
            restored.adoptSpaces(air.store.spaces.map(\.id))
            restored.restoreSession()
            #expect(restored.tabs.filter { $0.urlString == page.urlString }.map(\.id) == [page.id])
            #expect(restored.tab(id: page.id)?.pinID == page.pinID)
            restored.closeAllTabs(saving: false)
            air.browser.removeFavorite(sameTab)
            air.browser.unpin(sameTab)
        } else {
            #expect(cloud.names(in: SharedCatalogCategory.pins.zone).isEmpty)
            studio.browser.removeFavorite(page)
            studio.browser.unpin(page)
        }
        try await air.sync()
        try await studio.sync()
        try await air.sync()
        #expect(studio.browser.tab(id: page.id) === page && page.pinID == nil)
        #expect(air.browser.tab(id: page.id) === sameTab && sameTab.pinID == nil && sameTab.spaceID == joinedSpace)
    }

    @Test func sharingANestedPinIncludesItsAncestorsAndKeepsUnselectedSiblingsPrivate() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer {
            studio.finish()
            air.finish()
        }
        let chosen = studio.browser.addPage("https://nested.example.test/")
        let privateSibling = studio.browser.addPage("https://other.example.test/")
        let inside = studio.browser.createFolder(named: "Inside", containing: [chosen, privateSibling])
        let outer = studio.browser.createFolder(named: "Outer", containing: [SidebarItem.folder(inside.id)])
        studio.browser.pin(outer)
        let pinID = try #require(chosen.pinID)
        try await studio.host.selectPin(pinID, in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.pins, for: air.profile)
        let item = try #require(air.host.availablePins(for: air.profile).first)
        try await air.host.joinPin(item, in: air.profile)
        let held = air.browser.pinStore.pins
        #expect(held.map(\.id) == [outer.id, inside.id, pinID])
        #expect(held.last?.parentID == inside.id)
        #expect(air.browser.folder(containing: try #require(air.browser.page(for: pinID)))?.name == "Inside")
        #expect(studio.browser.page(at: privateSibling.urlString) != nil && air.browser.page(at: privateSibling.urlString) == nil)
        let records = try #require(cloud.records(in: SharedCatalogCategory.pins.zone))
        #expect(records.count == 3)
        #expect(records.allSatisfy { !String(decoding: $0.payload, as: UTF8.self).contains("other.example.test") })
    }

    @Test func joiningASharedSpaceAfterItsFavoriteReusesThePinAlreadyOpenOnThisMac() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let home = try #require(studio.store.spaces.first)
        let page = studio.browser.addPage("https://already-open.example.test/")
        try await studio.host.share(home, in: studio.profile)
        try await studio.host.enable(.pins, for: studio.profile)
        studio.browser.addFavorite(page)
        try await studio.sync()

        try await air.host.enable(.pins, for: air.profile)
        let pin = try #require(air.host.availablePins(for: air.profile).first)
        try await air.host.joinPin(pin, in: air.profile)
        let existing = try #require(air.browser.page(at: page.urlString))
        try await air.host.enable(.spaces, for: air.profile)
        let shared = try #require(air.host.availableSpaces(for: air.profile).first)
        try await air.host.join(shared, in: air.profile)
        #expect(air.browser.tabs.filter { $0.urlString == page.urlString }.map(\.id) == [existing.id])
        air.browser.unpin(existing)
        try await air.sync()
        try await studio.sync()
        #expect(existing.pinID == nil && page.pinID == nil)
        #expect(air.browser.tabs.filter { $0.urlString == page.urlString }.map(\.id) == [existing.id])
    }

    @Test func selectedProfilePinDoesNotPublishOrdinaryTabsOrOtherPins() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        _ = studio.browser.addPage("https://ordinary.example.test/")
        let chosen = studio.browser.pinned("https://chosen.example.test/")
        _ = studio.browser.pinned("https://local.example.test/")
        studio.browser.publishProfilePins()
        let id = try #require(chosen.pinID)
        try await studio.host.selectPin(id, in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.pins, for: air.profile)
        let remote = try #require(air.host.availablePins(for: air.profile).first)
        #expect(air.host.availablePins(for: air.profile).count == 1)
        try await air.host.joinPin(remote, in: air.profile)
        #expect(air.browser.pinStore.pins.map(\.id) == [id])
        #expect(cloud.names(in: SharedCatalogCategory.spaces.zone).isEmpty)
        #expect(!air.host.isEnabled(.spaces, for: air.profile))
    }
}
