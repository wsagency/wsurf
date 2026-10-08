// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
struct BrowserProfileContextTests {
    @Test func windowsOfOneProfileShareServices() async {
        let profile = Profile(id: UUID(), name: "Shared window fixture", symbol: "person", color: .gray)
        let first = BrowserProfileContext.shared(for: profile)
        let second = BrowserProfileContext.shared(for: profile)
        defer {
            BrowserProfileContext.forget(profile.id)
            ProfileSettingsStore.forget(profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        }

        #expect(first === second)
        #expect(first.contextID == second.contextID)
        #expect(first.dataStore === second.dataStore)
        #expect(first.sitePermissions === second.sitePermissions)
        #expect(first.settings === second.settings)
        #expect(first.modelSettings === second.modelSettings)
        #expect(first.actionPolicy === second.actionPolicy)

        first.sitePermissions.setAutoplay(.block, for: "https://example.com")
        #expect(second.sitePermissions.autoplay(for: "https://example.com") == .block)
        first.pageZoom.set(1.25, for: "example.com", defaultZoom: 1)
        #expect(second.pageZoom.level(for: "example.com") == 1.25)
        first.actionPolicy.allowAlways(.publication, host: "example.com")
        #expect(second.actionPolicy.isAlwaysAllowed(.publication, host: "example.com"))
        first.settings.searchEngineID = "kagi"
        #expect(second.settings.searchEngineID == "kagi")
        await first.sitePermissions.waitForPendingSave()
    }

    @Test func separateProfilesOwnSeparatePersistentServices() async {
        let firstProfile = Profile(id: UUID(), name: "First", symbol: "person", color: .gray)
        let secondProfile = Profile(id: UUID(), name: "Second", symbol: "person", color: .gray)
        let first = BrowserProfileContext.shared(for: firstProfile)
        let second = BrowserProfileContext.shared(for: secondProfile)
        defer {
            BrowserProfileContext.forget(firstProfile.id)
            BrowserProfileContext.forget(secondProfile.id)
            ProfileSettingsStore.forget(firstProfile.id)
            ProfileSettingsStore.forget(secondProfile.id)
            try? FileManager.default.removeItem(at: firstProfile.supportDirectory)
            try? FileManager.default.removeItem(at: secondProfile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: firstProfile))
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: secondProfile))
        }

        #expect(first !== second)
        #expect(first.contextID != second.contextID)
        #expect(first.dataStore !== second.dataStore)
        #expect(first.sitePermissions !== second.sitePermissions)
        #expect(first.settings !== second.settings)
        #expect(first.actionPolicy !== second.actionPolicy)
        first.sitePermissions.setAutoplay(.block, for: "https://example.com")
        first.actionPolicy.allowAlways(.publication, host: "example.com")
        #expect(second.sitePermissions.autoplay(for: "https://example.com") == nil)
        #expect(!second.actionPolicy.isAlwaysAllowed(.publication, host: "example.com"))
        await first.sitePermissions.waitForPendingSave()
    }

    @Test func privateContextsDoNotPersistOrShareProfileServices() async {
        let first = BrowserProfileContext.shared(for: .privateBrowsing())
        let second = BrowserProfileContext.shared(for: .privateBrowsing())

        #expect(first.settings !== second.settings)
        #expect(first.modelSettings !== second.modelSettings)
        #expect(first.actionPolicy !== second.actionPolicy)
        #expect(first.sitePermissions !== second.sitePermissions)
        #expect(first.pageZoom !== second.pageZoom)
        #expect(first.contentBlocker !== second.contentBlocker)
        #expect(first.webViewPool !== second.webViewPool)

        first.sitePermissions.setAutoplay(.block, for: "https://example.com")
        first.pageZoom.set(1.5, for: "example.com", defaultZoom: 1)
        first.actionPolicy.allowAlways(.publication, host: "example.com")
        let selection = "private-\(UUID())"
        first.settings.searchEngineID = selection
        #expect(second.sitePermissions.autoplay(for: "https://example.com") == nil)
        #expect(second.pageZoom.level(for: "example.com") == nil)
        #expect(!second.actionPolicy.isAlwaysAllowed(.publication, host: "example.com"))
        #expect(second.settings.searchEngineID != selection)
        await first.endPrivateSession()
        await second.endPrivateSession()
    }

    @Test func privateShutdownIsSafeForRegularContext() async {
        let regular = BrowserProfileContext.shared(for: .original())
        await regular.endPrivateSession()
        #expect(BrowserProfileContext.existing(for: regular.profile.id) === regular)
        BrowserProfileContext.forget(regular.profile.id)
    }

    @Test func privateWindowsHaveSeparateEphemeralSessions() async {
        let first = BrowserProfileContext.shared(for: .privateBrowsing())
        let second = BrowserProfileContext.shared(for: .privateBrowsing())

        #expect(first !== second)
        #expect(first.profile.id == second.profile.id)
        #expect(first.contextID != second.contextID)
        #expect(BrowserProfileContext.existing(for: first.profile.id) == nil)
        #expect(first.dataStore !== second.dataStore)
        #expect(!first.dataStore.isPersistent)
        #expect(!second.dataStore.isPersistent)
        #expect(first.database.isEphemeral)
        #expect(second.database.isEphemeral)
        first.pageZoom.set(1.5, for: "example.com", defaultZoom: 1)
        #expect(second.pageZoom.level(for: "example.com") == nil)
        first.sitePermissions.setAutoplay(.block, for: "https://example.com")
        #expect(second.sitePermissions.autoplay(for: "https://example.com") == nil)
        first.actionPolicy.allowAlways(.publication, host: "example.com")
        #expect(!second.actionPolicy.isAlwaysAllowed(.publication, host: "example.com"))
        await first.endPrivateSession()
        await second.endPrivateSession()
    }

    @Test(.boundedWebViews) func deferredTabKeepsItsOriginalPrivateStore() throws {
        let first = BrowserProfileContext.shared(for: .privateBrowsing())
        let tab = BrowserTab(restoring: true, privately: true,
                             sitePermissions: first.sitePermissions, context: first)
        let second = BrowserProfileContext.shared(for: .privateBrowsing())
        let other = BrowserTab(privately: true, sitePermissions: second.sitePermissions, context: second)
        defer { tab.detach(); other.detach() }

        let firstView = try #require(tab.page.webKit)
        let secondView = try #require(other.page.webKit)
        #expect(firstView.configuration.websiteDataStore === first.dataStore)
        #expect(secondView.configuration.websiteDataStore === second.dataStore)
        #expect(firstView.configuration.websiteDataStore !== secondView.configuration.websiteDataStore)
    }

    @Test(.boundedWebViews, .exclusiveExternalApp)
    func sameProfileEnginePreferenceReachesAllWindows() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Engine ownership</title><p>Profile-owned page</p>"),
        ])
        let url = try server.url("/")
        let origin = SitePermissions.origin(for: url)
        let profiles = [
            Profile(id: UUID(), name: "Engine owner", symbol: "person", color: .gray),
            Profile(id: UUID(), name: "Other engine owner", symbol: "person", color: .gray),
        ]
        let contexts = profiles.map { BrowserProfileContext.shared(for: $0) }
        let privateContext = BrowserProfileContext(profile: .privateBrowsing(), settingsOwner: profiles[0])
        let first = BrowserModel(context: contexts[0], windowID: UUID())
        let second = BrowserModel(context: contexts[0], windowID: UUID())
        let other = BrowserModel(context: contexts[1], windowID: UUID())
        let privateWindow = BrowserModel(context: privateContext, windowID: UUID())
        let owners = [first, second, other, privateWindow]
        let tabs = owners.map { $0.newTab(url: url) }
        let windows = tabs.map { tab in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = tab.page
            window.orderFront(nil)
            return window
        }

        func loaded(_ indices: [Int], engine: BrowserEngine) async -> Bool {
            await waitUntil {
                for index in indices where windows[index].contentView !== tabs[index].page {
                    windows[index].contentView = tabs[index].page
                }
                return indices.allSatisfy {
                    tabs[$0].page.engine == engine && tabs[$0].page.url == url
                        && tabs[$0].page.title == "Engine ownership" && !tabs[$0].page.isLoading
                }
            }
        }

        var failure: (any Error)?
        do {
            try #require(await loaded([0, 1, 2, 3], engine: .webKit))
            let otherPage = tabs[2].page
            let privatePage = tabs[3].page

            // A single store notification must reach both registered owners, not just the last one.
            contexts[0].sitePermissions.setEngine(.chromium, for: origin)
            try #require(await loaded([0, 1], engine: .chromium))
            for tab in tabs.prefix(2) {
                #expect(try await tab.page.evaluateJavaScript("navigator.userAgent.includes('Chrome/')") as? Bool == true)
            }
            #expect(tabs[2].page === otherPage)
            #expect(tabs[3].page === privatePage)
            #expect(other.engine(for: tabs[2]) == .webKit)
            #expect(privateWindow.engine(for: tabs[3]) == .webKit)

            // Queue delivery, then rebind before yielding. The still-live old page makes a
            // missing delivery-time context guard observable even though the destination
            // also prefers WebKit. No timing sleeps or guessed task scheduling are needed.
            let switchedPage = tabs[0].page
            contexts[0].sitePermissions.setEngine(.webKit, for: origin)
            first.context = contexts[1]
            first.adopt(database: contexts[1].database, sitePermissions: contexts[1].sitePermissions)
            try #require(await loaded([1], engine: .webKit))
            #expect(tabs[0].page === switchedPage, "queued old-profile delivery cannot replace a switched owner's page")
            #expect(tabs[0].page.engine == .chromium)

            contexts[0].sitePermissions.setEngine(.chromium, for: origin)
            try #require(await loaded([1], engine: .chromium))
            #expect(tabs[0].page === switchedPage)
            #expect(tabs[2].page === otherPage)
            #expect(tabs[3].page === privatePage)

            // Returning and closing one same-profile owner cannot clear the other's subscription.
            first.context = contexts[0]
            first.adopt(database: contexts[0].database, sitePermissions: contexts[0].sitePermissions)
            first.markSessionClosed()
            first.closeAllTabs(saving: false)
            first.context.unregister(first)
            await tabs[0].waitForRetirement()
            contexts[0].sitePermissions.setEngine(.webKit, for: origin)
            try #require(await loaded([1], engine: .webKit))
            #expect(tabs[2].page === otherPage)
            #expect(tabs[3].page === privatePage)

            // A queued event also cannot replace a page belonging to a closed session.
            let closedPage = tabs[1].page
            contexts[0].sitePermissions.setEngine(.chromium, for: origin)
            second.markSessionClosed()
            await contexts[0].sitePermissions.waitForPendingSave()
            #expect(tabs[1].page === closedPage)
            #expect(tabs[1].page.engine == .webKit)
        } catch {
            failure = error
        }
        for owner in owners {
            owner.markSessionClosed()
            owner.closeAllTabs(saving: false)
        }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        windows.forEach { $0.close() }
        await privateContext.endPrivateSession()
        for (profile, context) in zip(profiles, contexts) {
            await context.sitePermissions.waitForPendingSave()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            try? FileManager.default.removeItem(at: ChromiumRuntime.shared.cacheDirectory(profileID: profile.id))
            BrowserProfileContext.forget(profile.id)
            ProfileSettingsStore.forget(profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        }
        if let failure {
            throw failure
        }
    }

    @Test func memoryOnlySettingsNeverLoadOrOverwriteSavedSiteData() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-\(UUID()).json")
        let saved = Data("existing profile data".utf8)
        try saved.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let permissions = SitePermissions(storageURL: file, persists: false)
        permissions.setAutoplay(.block, for: "https://example.com")
        await permissions.waitForPendingSave()

        #expect(try Data(contentsOf: file) == saved)
        #expect(permissions.autoplay(for: "https://example.com") == .block)
        let zoomFile = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-\(UUID()).json")
        let savedZoom = Data(#"{"saved.example":1.4}"#.utf8)
        try savedZoom.write(to: zoomFile)
        defer { try? FileManager.default.removeItem(at: zoomFile) }
        let zoom = PageZoomStore(file: zoomFile, persists: false)
        #expect(zoom.level(for: "saved.example") == nil)
        zoom.set(1.6, for: "memory.example", defaultZoom: 1)
        #expect(zoom.level(for: "memory.example") == 1.6)
        #expect(try Data(contentsOf: zoomFile) == savedZoom)
    }
}
