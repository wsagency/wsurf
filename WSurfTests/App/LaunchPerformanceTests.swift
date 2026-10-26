// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import XCTest

@testable import WSurf

// XCTest owns and runs one instance serially. Sendable lets its synchronous measurement callback enter the main actor.
/// The launch path without live web views: a restored tab is unloaded until it is shown, and every restored window here shows a
/// blank tab, which draws the Start page and loads nothing. Budgeted in Tools/check-performance.sh.
nonisolated final class LaunchPerformanceTests: XCTestCase, @unchecked Sendable {
    /// Restoring a saved 300-tab window (10 folders of 30) from the session tables into a model: what each restored window pays
    /// before it can draw.
    func testRestoringA300TabWindowIntoTheModel() {
        MainActor.assumeIsolated {
            let database = AppDatabase.temporary()
            let model = BrowserModel(windowID: UUID(), database: database)
            Self.fill(model, tabs: 300, folders: 10)
            model.saveBlocking()
            model.cancelPendingSave()
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                let restored = BrowserModel(windowID: model.windowID, database: database)
                restored.restoreSession()
                XCTAssertEqual(restored.tabs.count, 301)
                restored.cancelPendingSave()
            }
        }
    }

    /// A launch that brings back four saved windows of 41 tabs: every window restored, laid out and drawn, which is what the
    /// first window waited for when launch opened every window before any could draw.
    func testOpeningEveryWindowOfAFourWindowLaunch() {
        MainActor.assumeIsolated {
            withLaunchFixture { profile, _ in
                measureLaunch { app in
                    app.restoreWindows(of: [profile], show: false)
                    XCTAssertEqual(app.windows.count, 4)
                    app.windows.forEach(Self.draw)
                }
            }
        }
    }

    /// The same launch to its first window: the window in front, the one used last, is restored, laid out and drawn while the
    /// three others wait for it to be on screen (`BrowserApplication.beginLaunchRestore`).
    func testOpeningTheFrontWindowOfAFourWindowLaunch() {
        MainActor.assumeIsolated {
            withLaunchFixture { profile, ids in
                measureLaunch { app in
                    _ = app.beginLaunchRestore(of: [profile], lastWindowID: ids[1], launchProfileID: nil, show: false)
                    XCTAssertEqual(app.windows.map(\.windowID), [ids[1]])
                    app.windows.forEach(Self.draw)
                }
            }
        }
    }

    // MARK: - Fixture

    /// `tabs` unloaded pages in `folders` folders, and a blank tab in front, which the window shows.
    @MainActor
    static func fill(_ model: BrowserModel, tabs: Int, folders: Int) {
        let pages = (0..<tabs).map { model.addPage("https://fixture-\($0).example/") }
        let size = max(1, tabs / max(1, folders))
        for index in 0..<folders where (index + 1) * size <= pages.count {
            model.createFolder(named: "Folder \(index)", containing: Array(pages[index * size..<(index + 1) * size]))
        }
        model.newTab()
    }

    @MainActor
    static func draw(_ coordinator: AppCoordinator) {
        guard let view = coordinator.nativeWindow?.contentView else {
            XCTFail("the window was not made")
            return
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    /// A profile of its own with four saved windows of 40 pages in 4 folders and a blank tab, oldest first, and their IDs.
    @MainActor
    func withLaunchFixture(_ body: (Profile, [UUID]) -> Void) {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Launch performance")
        let context = BrowserProfileContext.shared(for: profile)
        let ids = (0..<4).map { _ in
            let model = BrowserModel(context: context, windowID: UUID())
            Self.fill(model, tabs: 40, folders: 4)
            model.saveBlocking()
            model.cancelPendingSave()
            return model.windowID
        }
        let views = TabWebView.liveInstances.allObjects.count
        body(profile, ids)
        XCTAssertLessThanOrEqual(TabWebView.liveInstances.allObjects.count, views, "the launch loaded no page")
        finish {
            await catalog.remove(profile)
            catalog.markCurrent(previous)
        }
    }

    /// Measures `launch` alone on a new run of the app each pass. Each pass then quits the way the app does, so the windows stay
    /// saved as open for the next pass: a window closed by the quit is not one the person closed.
    @MainActor
    func measureLaunch(_ launch: @escaping @MainActor (BrowserApplication) -> Void) {
        let options = XCTMeasureOptions.budgeted
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let notifications = NotificationCenter()
            let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: notifications)
            startMeasuring()
            launch(app)
            stopMeasuring()
            notifications.post(name: NSApplication.willTerminateNotification, object: nil)
            for coordinator in app.windows {
                coordinator.nativeWindow?.contentView = nil
                coordinator.nativeWindow?.close()
                coordinator.browser.cancelPendingSave()
            }
        }
    }

    /// Runs `work` to its end from this synchronous test (`VaultScalePerformanceTests.finish`).
    @MainActor
    func finish(_ work: @escaping @MainActor () async throws -> Void) {
        let done = XCTestExpectation(description: "async step")
        Task {
            do {
                try await work()
            } catch {
                XCTFail("\(error)")
            }
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 120), .completed)
    }
}
