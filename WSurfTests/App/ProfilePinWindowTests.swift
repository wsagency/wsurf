// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Pins belong to the profile, so they outlast every window and every quit.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ProfilePinWindowTests {
    /// Runs `body` with a profile of its own, so the saved windows of other suites cannot be restored with it.
    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Pins outlast windows")
        var failure: (any Error)?
        do {
            try await body(profile)
        } catch {
            failure = error
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    /// One app run. Runs that share `defaults` follow each other, as launches of the installed app do.
    private func run(_ defaults: UserDefaults) -> BrowserApplication {
        BrowserApplication(defaults: defaults, notifications: NotificationCenter())
    }

    /// The steps of a quit in the order the application delegate and AppKit take them.
    private func quit(_ app: BrowserApplication) async throws {
        for coordinator in app.windows {
            coordinator.browser.saveBlocking()
        }
        try await app.clearDataOnQuitIfNeeded()
        await app.closeTabsForTermination()
        app.finishTermination()
        for coordinator in app.windows {
            coordinator.nativeWindow?.close()
        }
    }

    private func finish(_ app: BrowserApplication) {
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
    }

    private func pin(in window: AppCoordinator) {
        window.browser.pinned("https://one.example/")
        window.browser.pin(window.browser.createFolder(named: "Work"))
    }

    @Test func aWindowTheUserClosesLeavesItsPinsForTheNextWindow() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            let first = app.newWindow(profile: profile, show: false)
            pin(in: first)

            first.closeWindow()
            let second = app.newWindow(profile: profile, show: false)

            #expect(second.browser.pinOutline == "https://one.example/ Work[]")
            // The window's own first tab is not one of the pins.
            #expect(second.browser.activeTab?.pinID == nil)
            #expect(second.browser.tabs.count == 2)
            finish(app)
        }
    }

    @Test func anExtensionWindowOpensWithoutClosingThePinsOfTheProfile() async throws {
        try await withProfile { profile in
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            let first = app.newWindow(profile: profile, show: false)
            pin(in: first)
            let pins = first.browser.pinStore.pins
            #expect(pins.count == 2)

            _ = app.openExtensionWindow(
                for: first.extensions, profile: profile, privately: false, focused: false,
                urls: [URL(string: "https://opened.example/")!], tabs: []
            )

            #expect(app.windows.count == 2)
            let opened = try #require(app.windows.last)
            // The window's own first tab gave way to the requested page, and the pins were left alone.
            #expect(opened.browser.tabs.filter { $0.pinID == nil }.count == 1)
            #expect(opened.browser.pinOutline == "https://one.example/ Work[]")
            #expect(first.browser.pinOutline == "https://one.example/ Work[]")
            #expect(first.browser.pinStore.pins == pins)
            finish(app)
        }
    }

    @Test func everyWindowShowsThePinsOnceAfterAQuitAndARelaunch() async throws {
        try await withProfile { profile in
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            let app = run(defaults)
            let first = app.newWindow(profile: profile, show: false)
            pin(in: first)
            let second = app.newWindow(profile: profile, show: false)
            #expect(second.browser.pinOutline == first.browser.pinOutline)

            try await quit(app)

            let next = run(defaults)
            next.restoreWindows(of: [profile], show: false)
            #expect(Set(next.windows.map(\.windowID)) == [first.windowID, second.windowID])
            let fresh = next.newWindow(profile: profile, show: false)
            #expect(next.windows.count == 3)
            for coordinator in next.windows {
                #expect(coordinator.browser.pinOutline == "https://one.example/ Work[]")
                #expect(coordinator.browser.tabs.filter { $0.pinID != nil }.count == 1)
            }
            #expect(fresh.browser.folders.map(\.name) == ["Work"])
            finish(next)
        }
    }
}
