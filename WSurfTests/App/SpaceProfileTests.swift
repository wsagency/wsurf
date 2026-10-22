// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

/// Spaces with their own sign-ins: a separate space is a new profile, and choosing a space of another profile is
/// the profile switch WSurf already does. Deleting a space never deletes a profile.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SpaceProfileTests {
    @MainActor
    private final class Fixture {
        let app = BrowserApplication()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("space-profiles-\(UUID()).json")
        let suite = AppDatabase.defaultsSuite("SpaceProfileTests-\(UUID().uuidString)")
        let catalog: ProfileStore
        let work: Profile
        let coordinator: AppCoordinator
        private let savedNotices: UserDefaults

        init() {
            savedNotices = SpaceSwitchNotice.defaults
            catalog = ProfileStore(file: file)
            work = catalog.add(name: "Work", symbol: "briefcase", color: .blue)
            let selection = ProfileStore.selection(profile: .original(), catalog: catalog)
            coordinator = AppCoordinator(browser: BrowserModel(context: .shared(for: .original()), windowID: UUID()), profiles: selection)
            app.register(coordinator)
            coordinator.prepareBrowser(restoring: false, show: false)
            // The explanation was seen, so choosing a space of another profile switches without a sheet.
            SpaceSwitchNotice.defaults = UserDefaults(suiteName: suite)!
            SpaceSwitchNotice.stopAsking()
        }

        func close() {
            app.windows.forEach { $0.closeWindow() }
            SpaceSwitchNotice.defaults.removePersistentDomain(forName: suite)
            SpaceSwitchNotice.defaults = savedNotices
            for profile in catalog.profiles where !profile.isOriginal {
                BrowserProfileContext.forget(profile.id)
                SpaceStore.forget(profile.id)
                ProfileSettingsStore.forget(profile.id)
                try? FileManager.default.removeItem(at: profile.supportDirectory)
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Separate sign-ins

    @Test func aSeparateSpaceIsANewProfileWhoseFirstSpaceItIs() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator

        let space = try #require(coordinator.createSpace(name: "Side project", symbol: "hammer", sharing: .separate))

        let created = try #require(fixture.catalog.profiles.first { $0.name == "Side project" })
        #expect(created.symbol == "hammer")
        #expect(SpaceStore.shared(for: created)?.spaces == [space])
        #expect(created.supportDirectory != Profile.original().supportDirectory)
        #expect(created.databaseURL != Profile.original().databaseURL)
        #expect(await waitUntil { coordinator.profiles.current.id == created.id })
        #expect(coordinator.context.profile.id == created.id)
        #expect(coordinator.browser.currentSpaceID == space.id)
    }

    @Test func aSpaceSharingAnotherProfilesSignInsJoinsThatProfile() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let profileCount = fixture.catalog.profiles.count

        let space = try #require(coordinator.createSpace(name: "Clients", symbol: "person.2", sharing: .profile(fixture.work.id)))

        #expect(fixture.catalog.profiles.count == profileCount)
        #expect(SpaceStore.shared(for: fixture.work)?.spaces.last == space)
        #expect(await waitUntil { coordinator.profiles.current.id == fixture.work.id })
        #expect(coordinator.browser.currentSpaceID == space.id)
    }

    @Test func theNewProfileIsNotTheDeveloperProfile() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        try trust.setDeveloperProfile(Profile.originalID)

        _ = fixture.coordinator.createSpace(name: "Side project", symbol: "hammer", sharing: .separate)

        let created = try #require(fixture.catalog.profiles.first { $0.name == "Side project" })
        #expect(!MCPDeveloperAccess.isDeveloperProfile(created, trust: trust))
        #expect(trust.developerProfileID == Profile.originalID)
    }

    // MARK: - Switching

    @Test func choosingASpaceOfAnotherProfileSwitchesAndLandsInIt() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let second = try #require(SpaceStore.shared(for: fixture.work)).add(name: "Work B")
        let left = coordinator.browser.newTab()

        await coordinator.switchProfile(to: fixture.work, landingIn: second.id)

        #expect(coordinator.profiles.current.id == fixture.work.id)
        #expect(coordinator.browser.currentSpaceID == second.id)
        #expect(coordinator.browser.activeTab?.spaceID == second.id)
        #expect(!coordinator.browser.tabs.contains { $0 === left })
        #expect(coordinator.notice == fixture.work.name)
        #expect(!coordinator.isSwitchingProfile)
    }

    @Test func theSwitcherListsEveryProfilesSpacesInProfileOrder() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let entries = coordinator.spaceEntries
        let index = try #require(entries.firstIndex { $0.profile.id == fixture.work.id })

        #expect(entries.prefix(index).allSatisfy { $0.profile.isOriginal })
        #expect(entries.count == index + 1)
        #expect(coordinator.showsSpaceSwitcher)

        coordinator.switchToSpace(at: index)

        #expect(await waitUntil { coordinator.profiles.current.id == fixture.work.id })
        #expect(coordinator.browser.currentSpaceID == entries[index].id)
    }

    @Test func theSwitcherExplainsAProfileSwitchUntilToldNotTo() throws {
        let saved = SpaceSwitchNotice.defaults
        let suite = AppDatabase.defaultsSuite("SpaceSwitchNotice-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: suite))
        SpaceSwitchNotice.defaults = defaults
        defer {
            defaults.removePersistentDomain(forName: suite)
            SpaceSwitchNotice.defaults = saved
        }

        #expect(SpaceSwitchNotice.isNeeded)
        SpaceSwitchNotice.stopAsking()
        #expect(!SpaceSwitchNotice.isNeeded)
    }

    @Test func aPrivateWindowListsNoSpaces() {
        let coordinator = AppCoordinator(browser: BrowserModel(context: .shared(for: .privateBrowsing()), windowID: UUID()))
        defer { coordinator.browser.closeAllTabs(saving: false) }

        #expect(coordinator.spaceEntries.isEmpty)
        #expect(!coordinator.showsSpaceSwitcher)
        #expect(coordinator.createSpace(name: "Nope", symbol: "star", sharing: .separate) == nil)
    }

    // MARK: - Deleting

    @Test func deletingASpaceNeverRemovesItsProfile() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        await coordinator.switchProfile(to: fixture.work)
        let store = try #require(SpaceStore.shared(for: fixture.work))
        let first = try #require(store.spaces.first)
        let extra = try #require(coordinator.createSpace(name: "Extra", symbol: "star"))

        coordinator.deleteSpace(extra)

        #expect(store.spaces == [first])
        #expect(fixture.catalog.profiles.contains { $0.id == fixture.work.id })
        #expect(!coordinator.canDeleteSpace(first))
        coordinator.deleteSpace(first)
        #expect(store.spaces == [first])
        #expect(fixture.catalog.profiles.contains { $0.id == fixture.work.id })
        let personal = try #require(coordinator.spaceEntries.first { $0.profile.isOriginal })
        #expect(!coordinator.canDeleteSpace(personal.space))
    }

    @Test func spacesNeverEraseAProfileOrChooseTheDeveloperProfile() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "WSurf/App/AppCoordinator+Spaces.swift",
            "WSurf/Profiles/Space.swift",
            "WSurf/Web/Model/BrowserModel+Spaces.swift",
            "WSurf/UI/Sidebar/Spaces/SpaceEditor.swift",
            "WSurf/UI/Sidebar/Spaces/SidebarSpaceSwitcher.swift",
        ]
        for file in files {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for name in ["Profile.erase", "profiles.remove", ".remove(profile", "prepareToRemove", "setDeveloperProfile", "MCPTrustStore"] {
                #expect(!source.contains(name), "\(file) names \(name)")
            }
        }
    }

    // MARK: - The editor

    @Test func theEditorOffersEachProfilesSignInsOrSeparateOnes() {
        let work = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)

        #expect(SpaceEditor.SharingOption(profile: work).title.contains("Work"))
        #expect(SpaceEditor.sharing(work.id) == .profile(work.id))
        #expect(SpaceEditor.sharing(nil) == .separate)
        #expect(SpaceEditor.choice(name: " Clients ", symbol: "person.2", sharing: .separate)?.sharing == .separate)
    }
}
