// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    @Test func openSpaceFindsItsSharedPagesInAnExistingWindow() async throws {
        let mac = Mac(FakeSyncCloud())
        defer { mac.finish() }
        let app = BrowserApplication()
        let profiles = ProfileStore(file: mac.dir.appending(path: "profiles.json"))
        func coordinator(_ model: BrowserModel) -> AppCoordinator {
            let window = AppCoordinator(browser: model, profiles: .selection(profile: mac.profile, catalog: profiles))
            app.register(window)
            return window
        }
        let local = try #require(mac.store.spaces.first)
        let space = mac.store.add(name: "Work")
        mac.browser.adoptSpaces(mac.store.spaces.map(\.id))
        mac.browser.switchSpace(to: space.id)
        let shared = mac.browser.addPage("https://shared.example.test/")
        try await mac.host.share(space, in: mac.profile)
        mac.browser.switchSpace(to: local.id)
        let first = coordinator(mac.browser)
        let second = coordinator(mac.addWindow())
        defer {
            first.closeWindow()
            second.closeWindow()
        }
        let kept = second.browser.addPage("https://local.example.test/")
        second.browser.activate(kept)
        second.openSharedSpace(SpaceEntry(space: space, profile: mac.profile))
        #expect(first.browser.currentSpaceID == space.id && first.browser.activeTab === shared)
        #expect(second.browser.currentSpaceID == local.id && second.browser.activeTab === kept)
        #expect(second.browser.tab(id: shared.id) == nil)
    }

    @Test func legacySpaceRemainsDiscoverableWhenTheCurrentProfileAlreadyHasAnotherLink() async throws {
        let cloud = FakeSyncCloud()
        let air = Mac(cloud)
        defer { air.finish() }
        let other = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let old = SharedSpaceItem(id: UUID(), kind: .space, profileID: UUID(), title: "Work")
        cloud.createZone(SharedCatalogCategory.spaces.zone)
        _ = cloud.save(try #require(old.record(fields: nil)))
        _ = try await air.host.publishProfile(air.profile)
        try await air.host.enable(.spaces, for: air.profile)
        let found = try #require(air.host.spaceChoices(from: air.profile, profiles: [air.profile, other]).first)
        #expect(found.destination == .chooseProfile)
        #expect(air.host.spaceTitle(found.item).contains(String(old.id.uuidString.prefix(8))))
        #expect(air.host.cloudProfileID(for: air.profile.id) != old.profileID)
        let group = SharedSpaceItem(id: old.profileID, kind: .profile, profileID: old.profileID, title: "Work", publicationSource: .init(macName: "Studio"))
        _ = cloud.save(try #require(group.record(fields: nil)))
        try await air.sync()
        #expect(air.host.spaceTitle(found.item).contains("Studio"))
    }

    @Test func discoveryUsesThePublisherProfileOrExistingLinkBeforeOfferingToJoin() async throws {
        let cloud = FakeSyncCloud()
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let studioWork = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let airWork = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let studioStore = SpaceStore(profile: studioWork, file: dir.appending(path: "studio-spaces.json"))
        let airStore = SpaceStore(profile: studioWork, file: dir.appending(path: "adopted-spaces.json"))
        let localStore = SpaceStore(profile: airWork, file: dir.appending(path: "air-spaces.json"))
        let studioPins = ProfilePinStore.store(for: .temporary())
        let airPins = ProfilePinStore.store(for: .temporary())
        let studio = CloudSharedSpaces(stateFile: dir.appending(path: "studio.json"), profiles: [studioWork], windows: { [] },
                                      computerName: { "Studio" }, spaces: { _ in studioStore }, pins: { _ in studioPins })
        let air = CloudSharedSpaces(stateFile: dir.appending(path: "air.json"), profiles: [studioWork, airWork], windows: { [] },
                                   computerName: { "Air" }, spaces: { $0.id == studioWork.id ? airStore : localStore }, pins: { _ in airPins })
        studio.attach(FakeSyncEngine(cloud: cloud, delegate: studio.catalog))
        air.attach(FakeSyncEngine(cloud: cloud, delegate: air.catalog))
        try await studio.share(try #require(studioStore.spaces.first), in: studioWork)
        await studio.refresh()
        try await air.enable(.spaces, for: airWork)
        let absent = try #require(air.spaceChoices(from: airWork, profiles: [airWork], adoptableProfiles: [studioWork.id]).first)
        #expect(absent.destination == .addProfile)
        let found = try #require(air.spaceChoices(from: airWork, profiles: [airWork, studioWork]).first)
        #expect(found.destination == .join(studioWork))
        #expect(air.spaceTitle(found.item) == "Work — Studio")
        let joined = try await air.join(found.item, in: studioWork, expecting: found.owner)
        let available = try #require(air.spaceChoices(from: airWork, profiles: [airWork, studioWork]).first)
        #expect(available.destination == .open(SpaceEntry(space: joined, profile: studioWork)))
        air.pause(.spaces, for: airWork)
        let whilePaused = air.spaceChoices(from: airWork, profiles: [airWork, studioWork])
        #expect(whilePaused.map(\.destination) == [.open(SpaceEntry(space: joined, profile: studioWork))])
        #expect(!air.isEnabled(.spaces, for: airWork))
        #expect(air.cloudProfileID(for: airWork.id) == nil)
        #expect(localStore.spaces.count == 1 && airStore.spaces.count == 2)
        let fromAir = airStore.add(name: "Air project")
        try await air.share(fromAir, in: studioWork)
        await air.refresh()
        await studio.refresh()
        let second = try #require(studio.spaceChoices(from: studioWork, profiles: [studioWork]).first { $0.item.title == "Air project" })
        #expect(second.destination == .join(studioWork))
        #expect(studio.spaceTitle(second.item) == "Air project — Air")
        air.catalog.resetAccount(to: "another-account")
        await #expect(throws: SharedCatalogError.self) { try await air.join(found.item, in: airWork, expecting: found.owner) }
        #expect(localStore.spaces.count == 1)
    }

    @Test func openingStudioWorkSharesTabOpensAndClosesBothWaysAndKeepsAirWorkLocal() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Mac Studio")
        let air = Mac(cloud, name: "MacBook Air")
        defer {
            air.finish()
            studio.finish()
        }
        let studioWork = studio.store.add(name: "Work")
        let airWork = air.store.add(name: "Work")
        for (mac, space) in [(studio, studioWork), (air, airWork)] {
            mac.browser.adoptSpaces(mac.store.spaces.map(\.id))
            mac.browser.switchSpace(to: space.id)
        }
        let studioTab = studio.browser.addPage("https://work.example.test/studio")
        let localTab = air.browser.addPage(studioTab.urlString)
        air.browser.activate(localTab)
        try await studio.host.share(studioWork, in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        let remote = try #require(air.host.availableSpaces(for: air.profile).first { $0.title == "Work" })
        #expect(air.host.cloudProfileID(for: air.profile.id) == nil)
        #expect(air.browser.activeTab === localTab)
        let profiles = ProfileStore(file: air.dir.appending(path: "profiles.json"))
        let coordinator = AppCoordinator(browser: air.browser, profiles: .selection(profile: air.profile, catalog: profiles))
        let joined = try await joinFromSettings(remote, on: air, in: coordinator)
        #expect(joined.name == "Work" && joined.id != airWork.id && air.browser.currentSpaceID == joined.id)
        let studioTabOnAir = try #require(air.browser.tabs.first { $0.spaceID == joined.id && $0.urlString == studioTab.urlString })
        let airTab = air.browser.addPage("https://work.example.test/air")
        air.browser.scheduleSave()
        try await air.sync()
        try await studio.sync()
        let airTabOnStudio = try #require(studio.browser.tabs.first { $0.spaceID == studioWork.id && $0.urlString == airTab.urlString })
        air.browser.close(studioTabOnAir)
        try await air.sync()
        try await studio.sync()
        #expect(studio.browser.tab(id: studioTab.id) == nil)
        studio.browser.close(airTabOnStudio)
        try await studio.sync()
        try await air.sync()
        #expect(air.browser.tab(id: airTab.id) == nil)
        #expect(air.browser.tab(id: localTab.id) === localTab && localTab.spaceID == airWork.id)
        #expect(air.store.space(id: airWork.id) == airWork)
        #expect(air.host.links[air.profile.id]?.spaces[airWork.id] == nil)
        var renamed = joined
        renamed.name = "Shared Work"
        air.store.update(renamed)
        try await air.sync()
        try await studio.sync()
        let saved = try #require(cloud.record(remote.recordID))
        #expect(SharedSpaceItem(record: saved)?.spacePublisher?.source.macName == "Mac Studio")
        #expect(studio.store.space(id: studioWork.id)?.name == "Shared Work")
    }

    private func joinFromSettings(_ item: SharedSpaceItem, on mac: Mac, in coordinator: AppCoordinator) async throws -> Space {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: SharedSpacesSettingsView(profile: mac.profile, host: mac.host, coordinator: coordinator)
            .environment(\.accessibilityEnabled, true))
        window.contentView = view
        window.orderBack(nil)
        let join = String(localized: "Join and Open")
        try #require(await waitUntil { self.sharedSpaceButton(join, in: view)?.isAccessibilityEnabled?() == true })
        _ = sharedSpaceButton(join, in: view)?.accessibilityPerformPress?()
        let edit = String(localized: "Space Settings…")
        try #require(await waitUntil { self.sharedSpaceButton(edit, in: view)?.isAccessibilityEnabled?() == true })
        return try #require(mac.host.joinedSpace(item, in: mac.profile))
    }

    func sharedSpaceButton(_ title: String, in node: AnyObject) -> AnyObject? {
        if node.accessibilityRole?() == .button, [node.accessibilityTitle?(), node.accessibilityLabel?()].contains(title) {
            return node
        }
        return (node.accessibilityChildren?() ?? []).lazy.compactMap { self.sharedSpaceButton(title, in: $0 as AnyObject) }.first
    }
}
