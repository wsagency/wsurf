// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct ProfileSwitchTests {
    private struct Fixture {
        let app = BrowserApplication()
        let coordinator: AppCoordinator
        let catalog: ProfileStore
        let work: Profile
        let file: URL

        init() {
            file = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "profiles.json")
            catalog = ProfileStore(file: file)
            work = catalog.add(name: "Work")
            let selection = ProfileStore.selection(profile: .original(), catalog: catalog)
            let browser = BrowserModel(context: .shared(for: .original()), windowID: UUID())
            coordinator = AppCoordinator(browser: browser, profiles: selection)
            app.register(coordinator)
            coordinator.prepareBrowser(restoring: false, show: false)
        }

        func close() {
            app.windows.forEach { $0.closeWindow() }
            BrowserProfileContext.forget(work.id)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }

        func open(_ profile: Profile) -> AppCoordinator {
            let selection = ProfileStore.selection(profile: profile, catalog: catalog)
            let window = AppCoordinator(browser: BrowserModel(context: .shared(for: profile), windowID: UUID()), profiles: selection)
            app.register(window)
            window.prepareBrowser(restoring: false, show: false)
            return window
        }
    }

    @Test func switchingToTheProfileYouAreInChangesNothing() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let current = coordinator.profiles.current
        let tab = coordinator.browser.newTab(url: URL(string: "https://example.com/"))

        await coordinator.switchProfile(to: current)

        #expect(coordinator.profiles.current.id == current.id)
        #expect(coordinator.browser.tabs.contains { $0 === tab }, "the session was left alone")
        #expect(!coordinator.isSwitchingProfile)
    }

    @Test func aSwitchClearsItsOwnStateWhenItIsDone() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator

        await coordinator.switchProfile(to: fixture.work)

        #expect(coordinator.switchingTo == nil, "the switching state does not outlive the switch")
        #expect(!coordinator.isSwitchingProfile)
    }

    @Test func choosingPersonalLeavesTheErasedProfileInASecondWindow() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let work = fixture.work, first = fixture.coordinator
        await first.switchProfile(to: work)
        let second = fixture.open(work), selection = second.profiles
        let hidden = second.browser.newTab(url: URL(string: "about:blank"))
        let checkpoint = fixture.file.appendingPathExtension("shared")
        defer { try? FileManager.default.removeItem(at: checkpoint) }
        let sharing = CloudSharedSpaces(stateFile: checkpoint, profileStore: fixture.catalog, windows: { [] })
        try await first.profiles.remove(work, beforeErasing: { await first.switchProfile(to: .original()) },
                                        settingsSync: nil, sharedSpaces: sharing, eraseData: { _ in }).get()
        try #require(selection.current.isOriginal && second.context.profile.id == work.id)

        await second.switchProfile(to: .original())
        #expect(second.context === first.context && second.context.profile.isOriginal)
        #expect(hidden.isClosed && second.browser.tab(id: hidden.id) == nil)
        #expect(selection.currentID == Profile.originalID)
        await second.switchProfile(to: work)
        #expect(second.context.profile.isOriginal)
    }

    @Test(arguments: [false, true])
    func deletingFromSettingsMovesEveryWorkWindowAfterTheProfileListIsSaved(fromWork: Bool) async throws {
        let fixture = Fixture(), files = FileManager.default
        let replacement = fixture.catalog.add(name: "Replacement")
        defer {
            fixture.close()
            BrowserProfileContext.forget(replacement.id)
            ProfileSettingsStore.forget(replacement.id)
            try? files.removeItem(at: replacement.supportDirectory)
        }
        fixture.catalog.move(replacement, to: 0)
        let work = fixture.work, first = fixture.coordinator
        await first.switchProfile(to: work)
        let second = fixture.open(work), personal = fixture.open(.original())
        let old = first.context, unchanged = personal.context
        let tabs = [first, second, personal].map { $0.browser.newTab(url: URL(string: "about:blank")) }
        let owner = fromWork ? first : personal
        fixture.app.focus(owner)
        let backup = fixture.file.appendingPathExtension("saved")
        try files.moveItem(at: fixture.file, to: backup)
        try files.createDirectory(at: fixture.file, withIntermediateDirectories: false)

        let failed = await owner.deleteProfile(work)
        #expect(throws: (any Error).self) { try failed.get() }
        #expect(first.context === old && second.context === old && personal.context === unchanged)
        #expect(zip([first, second, personal], tabs).allSatisfy { $0.browser.activeTab === $1 && !$1.isClosed })
        #expect(fixture.app.activeCoordinator === owner && fixture.catalog.profiles.contains(work))

        try files.removeItem(at: fixture.file)
        try files.moveItem(at: backup, to: fixture.file)
        try await owner.deleteProfile(work).get()

        for (window, tab) in zip([first, second], tabs) {
            #expect(window.context.profile.id == replacement.id && window.profiles.currentID == replacement.id)
            #expect(!window.isClosed && window.browser.activeTab != nil && tab.isClosed && window.browser.tab(id: tab.id) == nil)
            #expect(!old.isRegistered(window.browser) && window.context.isRegistered(window.browser))
        }
        #expect(!personal.isClosed && personal.context === unchanged && personal.browser.activeTab === tabs[2] && !tabs[2].isClosed)
        let reopened = ProfileStore(file: fixture.file)
        #expect(fixture.app.activeCoordinator === owner && !reopened.profiles.contains(work))
        #expect(reopened.currentID == owner.context.profile.id)
    }

    @Test func theTabsOfTheProfileYouLeaveDoNotComeWithYou() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let left = coordinator.browser.newTab(url: URL(string: "https://leaving.example/"))

        await coordinator.switchProfile(to: fixture.work)

        #expect(!coordinator.browser.tabs.contains { $0 === left })
        #expect(coordinator.profiles.current.id == fixture.work.id)
    }

    @Test func closingPrivateBrowsingLeavesTheRegularWindowOpen() {
        let fixture = Fixture()
        defer { fixture.close() }
        let regular = fixture.coordinator
        let regularTab = regular.browser.newTab()
        let context = BrowserProfileContext.shared(for: .privateBrowsing())
        let privateBrowser = BrowserModel(context: context, windowID: UUID())
        let privateWindow = AppCoordinator(browser: privateBrowser)
        let privateTab = privateBrowser.newTab()

        #expect(privateWindow.profiles.isPrivate)
        #expect(privateTab.isPrivate)
        #expect(!context.dataStore.isPersistent)
        privateWindow.closeWindow()

        #expect(privateBrowser.tabs.isEmpty)
        #expect(privateTab.isClosed)
        #expect(!regular.profiles.isPrivate)
        #expect(regular.browser.tabs.contains { $0 === regularTab })
        #expect(!regularTab.isClosed)
    }

    @Test func aSwitchSaysWhichProfileItLandedIn() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator

        await coordinator.switchProfile(to: fixture.work)

        #expect(coordinator.notice == fixture.work.name)
    }

    @Test func switchingBackReplacesTheExtensionWindowRegistration() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let browser = coordinator.browser
        let personalManager = coordinator.extensions
        let originalWindow = try #require(personalManager.adapter(for: browser))
        let personalTab = try #require(browser.activeTab)
        let personalTabID = personalTab.id
        let url = try #require(URL(string: "about:blank"))
        let departingPeek = browser.makePeekTab(url)
        coordinator.peek.show(departingPeek, from: personalTabID, at: .zero)
        #expect(coordinator.closePeek())
        let visiblePeek = browser.makePeekTab(url)
        coordinator.peek.show(visiblePeek, from: personalTabID, at: .zero)

        await coordinator.switchProfile(to: fixture.work)

        let workManager = coordinator.extensions
        let workWindow = try #require(workManager.adapter(for: browser))
        #expect(personalManager !== workManager)
        #expect(personalManager.adapter(for: browser) == nil)
        #expect(originalWindow.browser == nil)
        #expect(personalTab.isClosed)
        #expect(departingPeek.isClosed && visiblePeek.isClosed)
        #expect(coordinator.peek.tab == nil)
        #expect(visiblePeek.onOpenInNewTab == nil)

        await coordinator.switchProfile(to: .original())

        #expect(coordinator.extensions === personalManager)
        #expect(personalManager.adapter(for: browser) !== originalWindow)
        #expect(workManager.adapter(for: browser) == nil)
        #expect(workWindow.browser == nil)
        #expect(browser.activeTab?.id == personalTabID)
        #expect(!coordinator.isSwitchingProfile)
    }
}
