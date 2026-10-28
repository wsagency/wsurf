// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A launch opens the window in front first and the others after it has drawn, in the order a plain restore opens them; a quit
/// in between loses no window and no tab; what a window does not need to draw waits for it.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct LaunchRestoreTests {
    /// Runs `body` with profiles of its own, so the saved windows of other suites cannot be restored with them.
    private func withProfiles(_ count: Int, _ body: ([Profile]) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profiles = (0..<count).map { catalog.add(name: "Launch restore \($0)") }
        var failure: (any Error)?
        do {
            try await body(profiles)
        } catch {
            failure = error
        }
        for profile in profiles {
            await catalog.remove(profile)
        }
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    /// One app run. Runs that share `defaults` follow each other, as launches of the installed app do.
    private func run(_ defaults: UserDefaults, notifications: NotificationCenter = NotificationCenter()) -> BrowserApplication {
        BrowserApplication(defaults: defaults, notifications: notifications)
    }

    /// What the sidebar shows: tab IDs and folder names in order, folders with their rows.
    private func layout(of browser: BrowserModel, in parent: UUID? = nil) -> [String] {
        browser.sidebarTree.rows(in: parent).map { item in
            switch item {
            case .tab(let id):
                "tab \(id)"
            case .folder(let id):
                "folder \(browser.folder(id: id)?.name ?? "?") \(layout(of: browser, in: id))"
            }
        }
    }

    /// `count` windows of `profile` saved as open, used longest ago first, each with pages in a folder and a blank tab in front;
    /// their IDs in that order and what each shows.
    private func saveWindows(of profile: Profile, count: Int) -> (ids: [UUID], layouts: [UUID: [String]]) {
        let context = BrowserProfileContext.shared(for: profile)
        var ids: [UUID] = []
        var layouts: [UUID: [String]] = [:]
        for index in 0..<count {
            let model = BrowserModel(context: context, windowID: UUID())
            let pages = (0..<4).map { model.addPage("https://window\(index)-page\($0).example/") }
            model.createFolder(named: "Folder \(index)", containing: Array(pages[1...2]))
            model.newTab()
            model.saveBlocking()
            model.cancelPendingSave()
            ids.append(model.windowID)
            layouts[model.windowID] = layout(of: model)
        }
        return (ids, layouts)
    }

    /// The steps of a quit after the delegate has saved every window: close the tabs, tell the app it terminates, let AppKit
    /// close each window.
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

    // MARK: - The order

    @Test func theWindowInFrontOpensFirstAndTheOthersFollowInTheRestoreOrder() async throws {
        try await withProfiles(1) { profiles in
            let saved = saveWindows(of: profiles[0], count: 3)
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            let restore = app.beginLaunchRestore(of: profiles, lastWindowID: saved.ids[1], launchProfileID: nil, show: false)
            #expect(app.windows.map(\.windowID) == [saved.ids[1]], "only the window used last opens before the others")
            #expect(app.isLaunching)

            #expect(app.continueLaunchRestore(restore, show: false))
            #expect(app.windows.map(\.windowID) == saved.ids, "the others follow, and the windows stand in the restore order")
            #expect(!app.isLaunching)
            for coordinator in app.windows {
                #expect(layout(of: coordinator.browser) == saved.layouts[coordinator.windowID])
            }
            finish(app)
        }
    }

    /// Without a window used last, the last regular window is in front, as when every window came forward in turn.
    @Test func withoutAWindowUsedLastTheLastWindowOpensFirst() async throws {
        try await withProfiles(1) { profiles in
            let saved = saveWindows(of: profiles[0], count: 2)
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            let restore = app.beginLaunchRestore(of: profiles, lastWindowID: nil, launchProfileID: nil, show: false)
            #expect(app.windows.map(\.windowID) == [saved.ids[1]])
            app.continueLaunchRestore(restore, show: false)
            #expect(app.windows.map(\.windowID) == saved.ids)
            finish(app)
        }
    }

    // MARK: - A quit in between

    @Test func aQuitBeforeTheOtherWindowsOpenLosesNoWindowOrTab() async throws {
        try await withProfiles(1) { profiles in
            var saved = saveWindows(of: profiles[0], count: 3)
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            let notifications = NotificationCenter()
            let app = run(defaults, notifications: notifications)
            let restore = app.beginLaunchRestore(of: profiles, lastWindowID: saved.ids[1], launchProfileID: nil, show: false)
            let front = try #require(app.windows.first)
            // The person opens a tab in the window in front, then quits before the others are up.
            front.browser.newTab()
            saved.layouts[front.windowID] = layout(of: front.browser)
            notifications.post(name: NSApplication.willTerminateNotification, object: nil)

            #expect(!app.continueLaunchRestore(restore, show: false), "a quit stops the restore")
            #expect(app.windows.count == 1, "and no window opens during it")
            try await quit(app)

            let next = run(defaults)
            next.restoreWindows(of: profiles, show: false)
            #expect(Set(next.windows.map(\.windowID)) == Set(saved.ids), "every window comes back")
            for coordinator in next.windows {
                #expect(layout(of: coordinator.browser) == saved.layouts[coordinator.windowID], "with its tabs and folders")
            }
            finish(next)
        }
    }

    /// The window a profile closed last comes back at the next launch even when a quit stopped this one before it opened.
    @Test func aQuitBeforeTheWindowClosedLastOpensKeepsItForTheNextLaunch() async throws {
        try await withProfiles(2) { profiles in
            let open = saveWindows(of: profiles[0], count: 1)
            let closed = saveWindows(of: profiles[1], count: 1)
            let closedModel = BrowserModel(context: BrowserProfileContext.shared(for: profiles[1]), windowID: closed.ids[0])
            closedModel.restoreSession()
            closedModel.markSessionClosed()
            closedModel.closeAllTabs(saving: false)
            let defaults = InMemoryUserDefaults(inheriting: .standard)
            defaults.set([profiles[1].id.uuidString, closed.ids[0].uuidString], forKey: BrowserApplication.closedAsLastKey)
            let notifications = NotificationCenter()
            let app = run(defaults, notifications: notifications)
            let restore = app.beginLaunchRestore(of: profiles, lastWindowID: open.ids[0], launchProfileID: nil, show: false)
            #expect(app.windows.map(\.windowID) == open.ids)
            notifications.post(name: NSApplication.willTerminateNotification, object: nil)
            #expect(!app.continueLaunchRestore(restore, show: false))
            try await quit(app)

            let next = run(defaults)
            next.restoreWindows(of: profiles, show: false)
            #expect(Set(next.windows.map(\.windowID)) == Set(open.ids + closed.ids))
            let reopened = try #require(next.windows.first { $0.windowID == closed.ids[0] })
            #expect(layout(of: reopened.browser) == closed.layouts[closed.ids[0]])
            finish(next)
        }
    }

    // MARK: - What waits for the window

    @Test func atLaunchAWindowBuildsItsAssistantAndVoicesAfterItIsUp() async throws {
        try await withProfiles(1) { profiles in
            _ = saveWindows(of: profiles[0], count: 1)
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            let restore = app.beginLaunchRestore(of: profiles, lastWindowID: nil, launchProfileID: nil, show: false)
            let window = try #require(app.windows.first)
            #expect(window.voiceConfigurationID == nil, "the voices wait for the next turn")
            #expect(window.selectedModel == window.modelSettings.model(for: window.selectedProvider), "the chosen model shows at once")
            app.continueLaunchRestore(restore, show: false)
            #expect(await waitUntil { window.voiceConfigurationID != nil }, "and are built then")

            let later = app.newWindow(profile: profiles[0], show: false)
            #expect(later.voiceConfigurationID != nil, "a window opened after launch builds them as it opens")
            finish(app)
        }
    }

    @Test func aRestoredFavoriteLoadsAfterTheWindowHasDrawn() async throws {
        let database = AppDatabase.temporary()
        let saved = BrowserModel(windowID: UUID(), database: database)
        saved.addPage("about:blank").isFavorite = true
        saved.newTab()
        saved.saveBlocking()
        saved.cancelPendingSave()

        let restored = BrowserModel(windowID: saved.windowID, database: database)
        defer {
            restored.closeAllTabs(saving: false)
        }
        restored.restoreSession()
        let favorite = try #require(restored.tabs.first { $0.isFavorite })
        #expect(favorite.isDeferred, "nothing loads before the window draws")
        #expect(await waitUntil { !favorite.isDeferred }, "the favorite loads after it")
    }

    /// A launch whose windows hold no Chromium tab leaves Chromium stopped, and so does the read of its framework that follows a
    /// launch (`prepareInBackground`). CEF cannot be stopped in a process, so the check is that it is no more started than before.
    @Test func aLaunchWithoutAChromiumTabLeavesChromiumStopped() async throws {
        let runtime = ChromiumRuntime.shared
        let wasRunning = runtime.isInitialized
        try await withProfiles(1) { profiles in
            _ = saveWindows(of: profiles[0], count: 2)
            let app = run(InMemoryUserDefaults(inheriting: .standard))
            let restore = app.beginLaunchRestore(of: profiles, lastWindowID: nil, launchProfileID: nil, show: false)
            #expect(app.continueLaunchRestore(restore, show: false))
            await runtime.prepareInBackground().value

            #expect(runtime.isInitialized == wasRunning)
            for coordinator in app.windows {
                #expect(!runtime.hasContext(contextID: coordinator.context.contextID))
            }
            finish(app)
        }
    }
}
