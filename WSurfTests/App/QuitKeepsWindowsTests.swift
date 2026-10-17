// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import GRDB
import Testing
import WebKit

@testable import WSurf

/// A quit must not turn open windows into closed ones, and a window the user closed last must come back
/// when nothing else was open.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct QuitKeepsWindowsTests {
    /// Runs `body` with a profile of its own, so the saved windows of other suites cannot be restored with it.
    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Quit keeps windows")
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
    private func run(_ defaults: UserDefaults, notifications: NotificationCenter = NotificationCenter()) -> BrowserApplication {
        BrowserApplication(defaults: defaults, notifications: notifications)
    }

    private func newDefaults() -> UserDefaults {
        InMemoryUserDefaults(inheriting: .standard)
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

    /// The steps of a quit in the order the application delegate and AppKit take them: save every window, close
    /// the tabs, tell the app it will terminate, then let AppKit close each window.
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

    private func launch(_ app: BrowserApplication, _ profile: Profile) -> [AppCoordinator] {
        app.restoreWindows(of: [profile], show: false)
        return app.windows
    }

    private func finish(_ app: BrowserApplication) {
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
    }

    // MARK: - A quit keeps the windows

    @Test func windowsOpenAtQuitComeBackWithTheirTabsFoldersAndOrder() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let tabs = (0..<3).map { _ in first.browser.newTab() }
            first.browser.createFolder(named: "Work", containing: [tabs[1], tabs[2]])
            second.browser.newTab()
            let shown = Dictionary(uniqueKeysWithValues: [first, second].map { ($0.windowID, layout(of: $0.browser)) })

            try await quit(app)

            let next = run(defaults)
            let restored = launch(next, profile)
            #expect(Set(restored.map(\.windowID)) == [first.windowID, second.windowID])
            for coordinator in restored {
                #expect(layout(of: coordinator.browser) == shown[coordinator.windowID])
            }
            finish(next)
        }
    }

    @Test func aQuitLeavesNoWindowRecordedAsClosed() async throws {
        try await withProfile { profile in
            let app = run(newDefaults())
            let window = app.newWindow(profile: profile, show: false)
            window.browser.newTab()

            try await quit(app)

            let saved = BrowserModel.savedWindows(in: window.browser.context.database, includeClosed: true)
            #expect(saved.map(\.id) == [window.windowID])
            #expect(saved.allSatisfy { $0.closedAt == nil })
        }
    }

    @Test func aWindowAppKitClosesDuringTheTerminationNotificationIsNotAUserClose() async throws {
        try await withProfile { profile in
            let center = NotificationCenter()
            let defaults = newDefaults()
            let app = run(defaults, notifications: center)
            let window = app.newWindow(profile: profile, show: false)
            window.browser.newTab()
            window.browser.saveBlocking()

            center.post(name: NSApplication.willTerminateNotification, object: nil)
            window.nativeWindow?.close()

            #expect(app.isTerminating)
            #expect(BrowserModel.savedWindows(in: window.browser.context.database).map(\.id) == [window.windowID])
            let next = run(defaults)
            #expect(launch(next, profile).map(\.windowID) == [window.windowID])
            finish(next)
        }
    }

    @Test func privateWindowsAreNeverRestored() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let regular = app.newWindow(profile: profile, show: false)
            let incognito = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)
            incognito.browser.newTab()
            #expect(incognito.profiles.isPrivate)

            try await quit(app)

            let next = run(defaults)
            let restored = launch(next, profile)
            #expect(restored.map(\.windowID) == [regular.windowID])
            #expect(restored.allSatisfy { !$0.profiles.isPrivate })
            finish(next)
        }
    }

    // MARK: - Closing a window

    @Test func closingOneWindowRecordsItAsClosed() async throws {
        try await withProfile { profile in
            let app = run(newDefaults())
            let kept = app.newWindow(profile: profile, show: false)
            let closed = app.newWindow(profile: profile, show: false)
            kept.browser.saveBlocking()

            closed.closeWindow()

            let database = kept.browser.context.database
            #expect(BrowserModel.savedWindows(in: database).map(\.id) == [kept.windowID])
            #expect(BrowserModel.savedWindows(in: database, includeClosed: true)
                .first { $0.id == closed.windowID }?.closedAt != nil)
            finish(app)
        }
    }

    // MARK: - The last window comes back

    @Test func theLastWindowTheUserClosedComesBackAtTheNextLaunch() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let window = app.newWindow(profile: profile, show: false)
            let tabs = (0..<3).map { _ in window.browser.newTab() }
            window.browser.createFolder(named: "Reading", containing: [tabs[0], tabs[1]])
            let shown = layout(of: window.browser)

            window.closeWindow()
            try await quit(app)

            let next = run(defaults)
            let restored = launch(next, profile)
            #expect(restored.map(\.windowID) == [window.windowID])
            #expect(restored.first.map { layout(of: $0.browser) } == shown)
            #expect(BrowserModel.savedWindows(in: window.browser.context.database).map(\.id) == [window.windowID])
            finish(next)
        }
    }

    @Test func aWindowClosedWhileAnotherStaysOpenIsNotBroughtBack() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let closed = app.newWindow(profile: profile, show: false)
            let kept = app.newWindow(profile: profile, show: false)
            closed.browser.newTab()

            closed.closeWindow()
            try await quit(app)

            let next = run(defaults)
            #expect(launch(next, profile).map(\.windowID) == [kept.windowID])
            finish(next)
        }
    }

    @Test func onlyTheVeryLastOfSeveralClosedWindowsComesBack() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let earlier = app.newWindow(profile: profile, show: false)
            let last = app.newWindow(profile: profile, show: false)

            earlier.closeWindow()
            last.closeWindow()
            try await quit(app)

            let next = run(defaults)
            #expect(launch(next, profile).map(\.windowID) == [last.windowID])
            finish(next)
        }
    }

    @Test func aWindowOpenedAfterTheLastCloseTakesItsPlace() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let closed = app.newWindow(profile: profile, show: false)
            closed.closeWindow()
            let opened = app.newWindow(profile: profile, show: false)

            try await quit(app)

            let next = run(defaults)
            #expect(launch(next, profile).map(\.windowID) == [opened.windowID])
            finish(next)
        }
    }

    @Test func aWindowOpenedInAnotherProfileAfterTheLastCloseTakesItsPlace() async throws {
        try await withProfile { first in
            try await withProfile { second in
                let defaults = newDefaults()
                let app = run(defaults)
                let closed = app.newWindow(profile: first, show: false)
                closed.closeWindow()
                let opened = app.newWindow(profile: second, show: false)

                try await quit(app)

                let next = run(defaults)
                next.restoreWindows(of: [first, second], show: false)
                #expect(next.windows.map(\.windowID) == [opened.windowID])
                finish(next)
            }
        }
    }

    @Test func aWindowReopenedAndLeftOpenIsNotRestoredTwice() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let closed = app.newWindow(profile: profile, show: false)
            closed.browser.newTab()
            closed.closeWindow()

            app.newWindow(profile: profile, windowID: closed.windowID, restoring: true, show: false)
            try await quit(app)

            let next = run(defaults)
            #expect(launch(next, profile).map(\.windowID) == [closed.windowID])
            finish(next)
        }
    }

    @Test func aPrivateWindowDoesNotHideOrReplaceTheLastRegularWindow() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let regular = app.newWindow(profile: profile, show: false)
            let incognito = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)

            regular.closeWindow()
            incognito.closeWindow()
            try await quit(app)

            let next = run(defaults)
            #expect(launch(next, profile).map(\.windowID) == [regular.windowID])
            finish(next)
        }
    }

    @Test func aPrivateWindowOpenedAfterTheLastCloseDoesNotCancelTheRestore() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let regular = app.newWindow(profile: profile, show: false)
            regular.closeWindow()
            app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)

            try await quit(app)

            let next = run(defaults)
            #expect(launch(next, profile).map(\.windowID) == [regular.windowID])
            finish(next)
        }
    }

    @Test func aClosedWindowThatNoLongerExistsOpensNothing() async throws {
        try await withProfile { profile in
            let defaults = newDefaults()
            let app = run(defaults)
            let window = app.newWindow(profile: profile, show: false)
            window.closeWindow()
            try window.browser.context.database.writer.write { db in
                try db.execute(sql: "DELETE FROM sessionWindow")
            }

            let next = run(defaults)
            #expect(launch(next, profile).isEmpty)
        }
    }
}
