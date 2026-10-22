// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A window of a fresh profile, so no test reaches the spaces of the default profile, which the test process shares.
@MainActor
private final class SpaceWindowFixture {
    let catalogFile = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString).json")
    let catalog: ProfileStore
    let profile: Profile
    let coordinator: AppCoordinator

    init() {
        catalog = ProfileStore(file: catalogFile)
        profile = catalog.add(name: "Spaces fixture", symbol: "house", color: .teal)
        let context = BrowserProfileContext.shared(for: profile)
        coordinator = AppCoordinator(
            browser: BrowserModel(context: context, windowID: UUID(), database: .temporary()),
            profiles: ProfileStore.selection(profile: profile, catalog: catalog)
        )
        coordinator.refreshSpaces()
    }

    var store: SpaceStore {
        coordinator.spaceStore!
    }

    var browser: BrowserModel {
        coordinator.browser
    }

    /// Where this profile's spaces start in the switcher, which also lists the default profile's.
    var base: Int {
        coordinator.spaceEntries.firstIndex { $0.profile.id == profile.id } ?? 0
    }

    func tearDown() {
        browser.closeAllTabs(saving: false)
        BrowserProfileContext.forget(profile.id)
        SpaceStore.forget(profile.id)
        ProfileSettingsStore.forget(profile.id)
        try? FileManager.default.removeItem(at: profile.supportDirectory)
        try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        try? FileManager.default.removeItem(at: catalogFile)
    }
}

@MainActor
@Suite(.serialized, .boundedWebViews)
struct SpaceSwitcherTests {
    // MARK: - The switcher

    @Test func theSwitcherShowsOnceThereIsASecondSpace() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString).json")
        let catalog = ProfileStore(file: file)
        let coordinator = AppCoordinator(
            browser: BrowserModel(context: .shared(for: .original()), windowID: UUID(), database: .temporary()),
            profiles: ProfileStore.selection(profile: .original(), catalog: catalog)
        )
        defer {
            coordinator.browser.closeAllTabs(saving: false)
            try? FileManager.default.removeItem(at: file)
        }

        #expect(coordinator.spaceEntries.count == 1)
        #expect(!coordinator.showsSpaceSwitcher)

        let second = catalog.add(name: "Second")
        defer {
            BrowserProfileContext.forget(second.id)
            SpaceStore.forget(second.id)
        }

        #expect(coordinator.showsSpaceSwitcher)
        #expect(coordinator.spaceEntries.last?.profile.id == second.id)
    }

    @Test func aNewSpaceJoinsTheSwitcherAndIsShown() {
        let fixture = SpaceWindowFixture()
        defer { fixture.tearDown() }
        let before = fixture.coordinator.spaceEntries.count

        let recipes = fixture.coordinator.createSpace(name: "Recipes", symbol: "fork.knife")

        #expect(fixture.coordinator.spaceEntries.count == before + 1)
        #expect(fixture.coordinator.spaceEntries[fixture.base + 1].space == recipes)
        #expect(fixture.browser.currentSpaceID == recipes?.id)
    }

    @Test func controlNumberShowsThatSpaceOfTheSwitcher() {
        let fixture = SpaceWindowFixture()
        defer { fixture.tearDown() }
        fixture.browser.newTab()
        fixture.coordinator.createSpace(name: "Recipes", symbol: "fork.knife")
        fixture.coordinator.createSpace(name: "Travel", symbol: "airplane")
        let entries = fixture.coordinator.spaceEntries
        let base = fixture.base

        fixture.coordinator.switchToSpace(at: base)
        #expect(fixture.browser.currentSpaceID == entries[base].id)

        fixture.coordinator.switchToSpace(at: base + 1)
        #expect(fixture.browser.currentSpaceID == entries[base + 1].id)

        fixture.coordinator.switchToSpace(at: entries.count)
        #expect(fixture.browser.currentSpaceID == entries[base + 1].id)
        #expect(SpaceShortcut.label(at: 0) == "⌃1")
        #expect(SpaceShortcut.label(at: 9) == nil)
    }

    @Test func controlOneToNineAreHiddenAndBoundOnlyToSpaces() throws {
        let fixture = SpaceWindowFixture()
        defer { fixture.tearDown() }
        let menu = MainMenu(coordinator: fixture.coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let items = root.items.compactMap(\.submenu).flatMap(\.items)

        for slot in SpaceShortcut.slots {
            let bound = items.filter { $0.keyEquivalent == "\(slot)" && $0.keyEquivalentModifierMask == [.control] }
            #expect(bound.count == 1, "⌃\(slot) is bound \(bound.count) times")
            #expect(bound.first?.isHidden == true)
            #expect(bound.first?.title == String(localized: "Show Space \(slot)"))
        }
        // The first slot past the switcher's spaces does nothing until a space fills it.
        let slot = fixture.coordinator.spaceEntries.count + 1
        let next = try #require(items.first { $0.keyEquivalent == "\(slot)" && $0.keyEquivalentModifierMask == [.control] })
        #expect(!menu.validateMenuItem(next))
        fixture.coordinator.createSpace(name: "Recipes", symbol: "fork.knife")
        #expect(menu.validateMenuItem(next))
    }

    // MARK: - Swiping

    @Test func aSwipeNeedsAQuarterOfTheSidebarOrAFlick() {
        #expect(SpaceSwipe.step(travel: -60, velocity: 0, width: 200) == 1)
        #expect(SpaceSwipe.step(travel: 60, velocity: 0, width: 200) == -1)
        #expect(SpaceSwipe.step(travel: -40, velocity: 0, width: 200) == 0)
        #expect(SpaceSwipe.step(travel: -30, velocity: -400, width: 200) == 1)
        #expect(SpaceSwipe.step(travel: -30, velocity: 400, width: 200) == 0)
        #expect(SpaceSwipe.step(travel: -15, velocity: -900, width: 200) == 0)
    }

    /// The default profile's space sits before this profile's in the switcher; a swipe never switches profile.
    @Test func aSwipeGoesToTheNeighborAndNeverLeavesTheProfile() {
        let fixture = SpaceWindowFixture()
        defer { fixture.tearDown() }
        fixture.browser.newTab()
        let recipes = fixture.coordinator.createSpace(name: "Recipes", symbol: "fork.knife")
        let first = fixture.store.spaces[0]
        fixture.coordinator.switchToSpace(at: fixture.base)

        fixture.coordinator.switchSpace(by: 1)
        #expect(fixture.browser.currentSpaceID == recipes?.id)
        fixture.coordinator.switchSpace(by: 1)
        #expect(fixture.browser.currentSpaceID == recipes?.id)

        fixture.coordinator.switchSpace(by: -1)
        #expect(fixture.browser.currentSpaceID == first.id)
        fixture.coordinator.switchSpace(by: -1)
        #expect(fixture.browser.currentSpaceID == first.id)
        #expect(!fixture.coordinator.isSwitchingProfile)
        #expect(fixture.coordinator.context.profile.id == fixture.profile.id)
    }

    // MARK: - Organizing

    @Test func moveToSpaceOffersOnlyThisProfilesOtherSpaces() throws {
        let fixture = SpaceWindowFixture()
        defer { fixture.tearDown() }
        let tab = fixture.browser.newTab()
        let first = try #require(fixture.store.spaces.first)
        let recipes = fixture.store.add(name: "Recipes")
        fixture.coordinator.refreshSpaces()

        #expect(fixture.coordinator.spaceMoveTargets.map(\.id) == [recipes.id])
        fixture.coordinator.moveToSpace([.tab(tab.id)], space: recipes)
        #expect(tab.spaceID == recipes.id)
        #expect(fixture.browser.currentSpaceID == first.id)

        let foreign = Space(id: UUID(), name: "Elsewhere", symbol: "globe", color: .red)
        let other = fixture.browser.newTab()
        fixture.coordinator.moveToSpace([.tab(other.id)], space: foreign)
        #expect(other.spaceID == first.id)
    }

    @Test func aPrivateWindowHasNoSpaces() {
        let coordinator = AppCoordinator(browser: BrowserModel(context: .shared(for: .privateBrowsing()), windowID: UUID()))
        defer { coordinator.browser.closeAllTabs(saving: false) }
        coordinator.refreshSpaces()

        #expect(coordinator.spaceStore == nil)
        #expect(coordinator.spaceEntries.isEmpty)
        #expect(coordinator.spaceMoveTargets.isEmpty)
        #expect(coordinator.browser.currentSpaceID == nil)
    }

    @Test func deletingASpaceClosesItsTabsAndKeepsTheProfile() throws {
        let fixture = SpaceWindowFixture()
        defer { fixture.tearDown() }
        let homeTab = fixture.browser.newTab()
        let first = try #require(fixture.store.spaces.first)
        let recipes = try #require(fixture.coordinator.createSpace(name: "Recipes", symbol: "fork.knife"))
        _ = fixture.browser.newTab()

        fixture.coordinator.deleteSpace(recipes)

        #expect(fixture.store.spaces == [first])
        #expect(fixture.browser.currentSpaceID == first.id)
        #expect(fixture.browser.tabs.map(\.id) == [homeTab.id])
        #expect(fixture.catalog.profiles.contains { $0.id == fixture.profile.id })
    }

    @Test func aProfilesLastSpaceCannotBeDeleted() throws {
        let fixture = SpaceWindowFixture()
        defer { fixture.tearDown() }
        let only = try #require(fixture.store.spaces.first)

        #expect(!fixture.coordinator.canDeleteSpace(only))
        fixture.coordinator.deleteSpace(only)
        #expect(fixture.store.spaces == [only])
    }

    @Test func theEditorTrimsTheNameAndRefusesAnEmptyOne() {
        #expect(SpaceEditor.choice(name: "  Recipes ", symbol: "fork.knife") == SpaceEditor.Choice(name: "Recipes", symbol: "fork.knife"))
        #expect(SpaceEditor.choice(name: "Recipes", symbol: nil)?.symbol == Space.defaultSymbol)
        #expect(SpaceEditor.choice(name: "   ", symbol: "house") == nil)
        #expect(Set(SpaceEditor.symbols).count == SpaceEditor.symbols.count)
    }

    /// The switcher draws its icons with the sidebar's own quiet buttons: no new glass, so the glass budget is unchanged.
    @Test func theSwitcherAddsNoGlass() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["SidebarSpaceSwitcher.swift", "SpaceEditor.swift", "SpaceSwipeCatcher.swift"] {
            let source = try String(contentsOf: root.appending(path: "WSurf/UI/Sidebar/Spaces/\(file)"), encoding: .utf8)
            for glass in [".glassEffect(", ".glassGroup(", "chromeGlass", "GlassEffectContainer"] {
                #expect(!source.contains(glass), "\(file) uses \(glass)")
            }
        }
    }
}
