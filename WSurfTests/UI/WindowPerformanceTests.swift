// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest

@testable import WSurf

/// What a person does in a window and feels as a hitch: opening a window, closing tabs, Settings, typing in the palette and the
/// address field, scrolling a sidebar with folders, pins and splits, and the History page. Each case measures the main-thread
/// work until the window is laid out and drawn (not the time to pixels), as `BrowserPerformanceTests` does, and prints
/// `WSURF-BENCH` lines with the per-operation figures that the budget (a total over a pass) hides.
///
/// Budgets are in `Tools/check-performance.sh`. A case that builds a page (a window, a Settings page) is held to the clock only
/// where the page's footprint swings more than a budget can hold, and says so.
///
/// XCTest owns and runs one instance serially. Sendable lets its synchronous measurement callback enter the app target's
/// main-actor boundary.
nonisolated final class WindowPerformanceTests: XCTestCase, @unchecked Sendable {
    // MARK: - Fixtures

    /// The rig of `testOpeningTheNewTabPaletteInACrowdedWindow`: a Standard `BrowserView` over 300 unloaded rows, in a 1,280 x 800
    /// borderless window that is never ordered in.
    @MainActor
    private struct CrowdedWindow {
        let coordinator: AppCoordinator
        let host: NSHostingView<BrowserView>
        let window: NSWindow

        var browser: BrowserModel {
            coordinator.browser
        }

        init(rows: Int = 300, history: HistoryStore? = nil, startPageRows: Int = 0) {
            coordinator = AppCoordinator(browser: BrowserModel(database: .temporary(), history: history))
            for index in 0..<rows {
                PerfProbe.addBackgroundTab(to: coordinator.browser, address: "https://fixture-\(index).example/")
            }
            for _ in 0..<startPageRows {
                PerfProbe.addBackgroundTab(to: coordinator.browser, address: nil)
            }
            host = NSHostingView(rootView: BrowserView(browser: coordinator.browser, coordinator: coordinator, style: .standard))
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }

        func draw() {
            PerfProbe.draw(host)
        }

        /// Frees the window. `openPalette` makes the coordinator's own host window, so that goes too.
        func close() {
            window.contentView = nil
            window.close()
            if let own = coordinator.nativeWindow {
                own.contentView = nil
                own.close()
            }
            coordinator.releaseWindowHost()
            coordinator.browser.cancelPendingSave()
        }

        func editableField() -> NSTextField? {
            Self.textFields(in: host).first { $0.isEditable }
        }

        /// The field editor of the first editable field, made first responder.
        func fieldEditor() -> NSTextView? {
            let candidates = Self.textFields(in: host).filter(\.isEditable)
            guard let field = candidates.first(where: { "\(type(of: $0))".contains("Mention") }) ?? candidates.first else { return nil }
            window.makeFirstResponder(field)
            return field.currentEditor() as? NSTextView
        }

        private static func textFields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
        }
    }

    @MainActor
    private static func liveWebViews() -> Int {
        TabWebView.liveInstances.allObjects.count
    }

    /// Fails when drawing the window gave its background tabs pages. Only the tab on screen may have one.
    @MainActor
    private static func assertRowsStayUnloaded(_ browser: BrowserModel, allowing allowed: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        let loaded = browser.tabs.filter(\.isMaterialised).count
        XCTAssertLessThanOrEqual(loaded, allowed, "background tabs of the crowded window got web views", file: file, line: line)
    }

    @MainActor
    private func finish(_ work: @escaping @MainActor () async -> Void) {
        let done = XCTestExpectation(description: "async step")
        Task {
            await work()
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 120), .completed)
    }

    /// Frees a window the way `LaunchPerformanceTests` does for the windows of a `BrowserApplication`.
    @MainActor
    private static func tearDown(_ coordinator: AppCoordinator) {
        coordinator.nativeWindow?.contentView = nil
        coordinator.nativeWindow?.close()
        coordinator.browser.cancelPendingSave()
        coordinator.releaseWindowHost()
        coordinator.application = nil
        coordinator.windowDidClose()
    }

    @MainActor
    private static func drawWindow(of coordinator: AppCoordinator) {
        guard let view = coordinator.nativeWindow?.contentView else { return }
        PerfProbe.draw(view)
    }

    /// A history of 50,000 pages in a file of its own, in a directory that the case removes.
    @MainActor
    private static func largeHistory() throws -> (database: AppDatabase, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WindowPerformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = AppDatabase(at: directory.appendingPathComponent("History.sqlite"))
        try HistoryPerformanceFixture.populate(database, pages: 50_000)
        return (database, directory)
    }

    @MainActor
    private static func perOperation(_ name: String, _ samples: [Double], _ extra: String = "") {
        PerfProbe.report(name, PerfProbe.summary(samples) + (extra.isEmpty ? "" : " " + extra))
    }

    // MARK: - W1 Opening a second window

    /// Cmd-N: a window from an app that already has one, made by `BrowserApplication.newWindow` and drawn, in a profile of its own.
    /// The window makes a pooled `WKWebView`, so the case is held to the clock only. Each pass frees its window outside the
    /// measurement. After the measurement, six more windows print the main-thread CPU of the 500 ms that follow a new window.
    func testOpeningASecondWindow() {
        MainActor.assumeIsolated {
            PerfProbe.withOnboardingDone {
                let catalog = ProfileStore.shared
                let previous = catalog.current
                let profile = catalog.add(name: "Second window performance")
                LiveWindowRig.useSharedDataStore(for: profile)
                let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
                let first = app.newWindow(profile: profile, show: false)
                Self.drawWindow(of: first)
                PerfProbe.idle(0.5)

                let options = XCTMeasureOptions.budgeted
                options.invocationOptions = [.manuallyStart, .manuallyStop]
                measure(metrics: [XCTClockMetric()], options: options) {
                    startMeasuring()
                    let second = app.newWindow(profile: profile, show: false)
                    Self.drawWindow(of: second)
                    stopMeasuring()
                    Self.tearDown(second)
                }

                var made: [Double] = []
                var madeCPU: [Double] = []
                var after: [Double] = []
                let clock = ContinuousClock()
                for _ in 0..<6 {
                    let cpu0 = PerfProbe.mainCPUms()
                    let started = clock.now
                    let second = app.newWindow(profile: profile, show: false)
                    Self.drawWindow(of: second)
                    made.append(PerfProbe.ms(clock.now - started))
                    madeCPU.append(PerfProbe.mainCPUms() - cpu0)
                    let cpu1 = PerfProbe.mainCPUms()
                    PerfProbe.idle(0.5)
                    after.append(PerfProbe.mainCPUms() - cpu1)
                    Self.tearDown(second)
                }
                Self.perOperation("W1.second-window.make-and-draw", made, "cpuMedianMs=\(String(format: "%.2f", madeCPU.sorted()[madeCPU.count / 2]))")
                Self.perOperation("W1.second-window.after500msCpu", after)

                Self.tearDown(first)
                finish {
                    await catalog.remove(profile)
                    await LiveWindowRig.releaseSharedDataStore(for: profile)
                    catalog.markCurrent(previous)
                }
                withExtendedLifetime(app) {}
            }
        }
    }

    // MARK: - W2 Closing tabs

    /// Cmd-W on ten background rows of a 300-row window, each drawn. Ten fresh rows are added outside the measurement.
    func testClosingBackgroundTabsInACrowdedWindow() {
        MainActor.assumeIsolated {
            let rig = CrowdedWindow()
            let browser = rig.browser
            rig.draw()
            let options = XCTMeasureOptions.budgeted
            options.invocationOptions = [.manuallyStart]
            var perClose: [Double] = []
            var pass = 0
            let clock = ContinuousClock()

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                pass += 1
                let rows = (0..<10).map { PerfProbe.addBackgroundTab(to: browser, address: "https://closing-\(pass)-\($0).example/") }
                rig.draw()
                startMeasuring()
                for row in rows {
                    let started = clock.now
                    browser.close(row)
                    rig.draw()
                    if pass > 1 {
                        perClose.append(PerfProbe.ms(clock.now - started))
                    }
                }
            }
            Self.perOperation("W2.close-background-tab", perClose)
            XCTAssertEqual(browser.tabs.count, 300)
            Self.assertRowsStayUnloaded(browser)
            rig.close()
        }
    }

    /// Cmd-W on the tab in front: each close activates a neighbour, and drawing may make that tab's page, so the clock only. The
    /// ten front rows are start-page rows; each pass adds five more at the front and closes five.
    func testClosingTheFrontTabInACrowdedWindow() {
        MainActor.assumeIsolated {
            let rig = CrowdedWindow(startPageRows: 10)
            let browser = rig.browser
            guard let first = browser.tabs.first(where: { $0.title == SystemPages.startTitle || $0.pageTitle == SystemPages.startTitle }) else {
                XCTFail("no start-page row")
                return
            }
            browser.activate(first)
            rig.draw()
            let options = XCTMeasureOptions.budgeted
            options.invocationOptions = [.manuallyStart]
            var perClose: [Double] = []
            var pass = 0
            var viewsBefore = 0
            var viewsAfter = 0
            let clock = ContinuousClock()

            measure(metrics: [XCTClockMetric()], options: options) {
                pass += 1
                let rows = (0..<5).map { _ in PerfProbe.addBackgroundTab(to: browser, address: nil) }
                if let front = rows.first {
                    browser.activate(front)
                }
                rig.draw()
                viewsBefore = Self.liveWebViews()
                startMeasuring()
                for _ in 0..<5 {
                    let started = clock.now
                    browser.closeActiveTab()
                    rig.draw()
                    if pass > 1 {
                        perClose.append(PerfProbe.ms(clock.now - started))
                    }
                }
                viewsAfter = Self.liveWebViews()
            }
            Self.perOperation("W2b.close-front-tab", perClose, "liveWebViewsBefore=\(viewsBefore) liveWebViewsAfter=\(viewsAfter)")
            rig.close()
        }
    }

    // MARK: - W3, W4, W5 Settings

    /// Settings opened from the model, as `AppCoordinator.openSettings` does without `showBrowser()` (which would make the
    /// coordinator its own second window here): the Settings tab, routed to a pane.
    @MainActor
    private static func openSettings(_ rig: CrowdedWindow, _ category: SettingsCategory) {
        rig.browser.showSettings()
        rig.coordinator.routeSettings(to: category)
    }

    @MainActor
    private static func settingsTab(in browser: BrowserModel) -> BrowserTab? {
        browser.tabs.first { $0.internalPage == .settings }
    }

    /// Opening the Settings page in a 300-row window and closing it again, three times, each step drawn.
    func testOpeningSettingsInACrowdedWindow() {
        MainActor.assumeIsolated {
            let rig = CrowdedWindow()
            let browser = rig.browser
            rig.draw()
            var opens: [Double] = []
            var closes: [Double] = []
            var pass = 0
            let clock = ContinuousClock()

            // Settings is a page of its own: opening it makes a web view, and its footprint swings by +-3 MB a pass (measured
            // -967 to 3260 kB), more than a budget can hold. The clock only.
            measure(metrics: [XCTClockMetric()], options: .budgeted) {
                pass += 1
                for _ in 0..<3 {
                    let started = clock.now
                    Self.openSettings(rig, .general)
                    rig.draw()
                    let opened = clock.now
                    if let tab = Self.settingsTab(in: browser) {
                        browser.close(tab)
                    }
                    rig.draw()
                    if pass > 1 {
                        opens.append(PerfProbe.ms(opened - started))
                        closes.append(PerfProbe.ms(clock.now - opened))
                    }
                }
            }
            Self.perOperation("W3.open-settings", opens, "liveWebViews=\(Self.liveWebViews())")
            Self.perOperation("W3.close-settings", closes)
            XCTAssertNil(Self.settingsTab(in: browser))
            rig.close()
        }
    }

    /// The panes of Settings, one after the other, in a 300-row window. Each switch is `routeSettings`, which loads the pane's
    /// address into the tab, as the navigator does (0.1.17: General to Appearance and back took 762-864 ms in this window).
    func testSwitchingSettingsPanesInACrowdedWindow() {
        MainActor.assumeIsolated {
            let rig = CrowdedWindow()
            rig.draw()
            Self.openSettings(rig, .general)
            rig.draw()
            rig.draw()
            let panes: [SettingsCategory] = [.appearance, .websites, .search, .privacy, .general]
            var perPane: [SettingsCategory: [Double]] = [:]
            var pass = 0
            let clock = ContinuousClock()

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                pass += 1
                for pane in panes {
                    let started = clock.now
                    rig.coordinator.routeSettings(to: pane)
                    rig.draw()
                    if pass > 1 {
                        perPane[pane, default: []].append(PerfProbe.ms(clock.now - started))
                    }
                }
            }
            for pane in panes {
                Self.perOperation("W4.settings-pane.\(pane.rawValue)", perPane[pane] ?? [])
            }
            if let appearance = perPane[.appearance], let others = perPane[.websites] {
                let slow = appearance.sorted()[appearance.count / 2] > 2 * others.sorted()[others.count / 2]
                PerfProbe.report("W4.settings-pane.appearance-flag", "slowerThanWebsitesBy2x=\(slow)")
            }
            rig.close()
        }
    }

    /// Dragging the brightness slider with Settings (Appearance) open in a 300-row window: 30 preview steps, each laid out and
    /// drawn. The guards and the preview are those of `ThemePerformanceTests.testDraggingThemeBrightness`.
    func testPreviewingBrightnessWithSettingsOpenInACrowdedWindow() throws {
        try MainActor.assumeIsolated {
            guard let bundleID = Bundle.main.bundleIdentifier,
                  bundleID.hasPrefix("io.wsagency.wsurf.dev-") || bundleID.hasPrefix("io.wsagency.wsurf.ci-") else {
                throw XCTSkip("Brightness measurement requires an isolated dev or CI test-host identity.")
            }
            #if DEBUG
            guard !StageMode.isActive else {
                throw XCTSkip("Brightness measurement requires the test host's own defaults, not a stage suite.")
            }
            #endif
            let settings = BrowserSettings.application
            guard settings.themePreview == nil else {
                throw XCTSkip("Brightness measurement must not replace an existing theme preview.")
            }
            let rig = CrowdedWindow()
            defer { rig.close() }
            XCTAssertTrue(rig.coordinator.settings.globalSettings === settings)
            rig.window.appearance = NSAppearance(named: .darkAqua)
            rig.draw()
            Self.openSettings(rig, .appearance)
            rig.draw()
            rig.draw()

            let persisted = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
            defer {
                settings.cancelThemePreview()
                rig.draw()
                XCTAssertNil(settings.themePreview)
                XCTAssertEqual(
                    NSDictionary(dictionary: UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]),
                    NSDictionary(dictionary: persisted)
                )
            }
            settings.beginThemePreview()
            var perStep: [Double] = []
            var pass = 0
            let clock = ContinuousClock()

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                pass += 1
                for step in 0..<30 {
                    let started = clock.now
                    var adjustment = settings.themeAdjustment
                    adjustment.darkBrightness = Double(step) / 29 - 0.5
                    settings.previewThemeAdjustment(adjustment)
                    rig.host.needsLayout = true
                    rig.host.layoutSubtreeIfNeeded()
                    rig.host.needsDisplay = true
                    rig.host.displayIfNeeded()
                    if pass > 1 {
                        perStep.append(PerfProbe.ms(clock.now - started))
                    }
                }
            }
            Self.perOperation("W5.brightness-step-with-settings", perStep)
            XCTAssertEqual(settings.themePreview?.adjustment.darkBrightness, 0.5)
        }
    }

    // MARK: - W6, W7 Typing

    /// Typing `github wiki` into the Cmd-K palette of a 300-row window with 5,000 history pages, a keystroke at a time through the
    /// field editor, each drawn. Search suggestions are off for the case (and restored): they would go to the network.
    func testTypingInTheCommandPaletteOfACrowdedWindow() {
        MainActor.assumeIsolated {
            Omnibox.$agentOnlyForTesting.withValue(false) {
                let rig = CrowdedWindow()
                defer { rig.close() }
                let settings = rig.coordinator.context.settings
                let suggestions = settings.showsSearchSuggestions
                settings.showsSearchSuggestions = false
                defer { settings.showsSearchSuggestions = suggestions }
                _ = rig.browser.history.merge((0..<5_000).map {
                    HistoryStore.Entry(
                        url: "https://docs.example/project/\($0)", title: "Project documentation \($0) github wiki",
                        visitCount: 1 + $0 % 7, lastVisit: Date(timeIntervalSinceNow: -Double($0) * 600)
                    )
                })
                rig.draw()
                rig.coordinator.openPalette()
                rig.draw()
                rig.draw()
                guard let field = rig.fieldEditor() else {
                    XCTFail("the palette has no editable field")
                    return
                }
                let options = XCTMeasureOptions.budgeted
                options.invocationOptions = [.manuallyStart]
                var perKey: [Double] = []
                var pass = 0
                let clock = ContinuousClock()

                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                    pass += 1
                    field.selectAll(nil)
                    field.delete(nil)
                    rig.draw()
                    startMeasuring()
                    for character in "github wiki" {
                        let started = clock.now
                        field.insertText(String(character), replacementRange: field.selectedRange())
                        rig.draw()
                        if pass > 1 {
                            perKey.append(PerfProbe.ms(clock.now - started))
                        }
                    }
                }
                XCTAssertEqual(field.string, "github wiki")
                let visible = NSApp.windows.filter(\.isVisible).count
                Self.perOperation("W6.palette-keystroke", perKey, "field=editor visibleAppWindows=\(visible) appActive=\(NSApp.isActive)")
                rig.coordinator.closePalette()
                rig.draw()
            }
        }
    }

    /// Typing `githubwiki` into the Start page's address field over a history of 50,000 pages, with the full-text search in the
    /// background as the app runs it, each keystroke drawn.
    func testTypingInTheStartPageAddressFieldOverALargeHistory() throws {
        try MainActor.assumeIsolated {
            let (database, directory) = try Self.largeHistory()
            defer {
                try? database.writer.close()
                try? FileManager.default.removeItem(at: directory)
            }
            try Omnibox.$agentOnlyForTesting.withValue(false) {
                let store = HistoryStore(database: database, searchesInBackground: true)
                let rig = CrowdedWindow(rows: 0, history: store)
                defer { rig.close() }
                let settings = rig.coordinator.context.settings
                let suggestions = settings.showsSearchSuggestions
                settings.showsSearchSuggestions = false
                defer { settings.showsSearchSuggestions = suggestions }
                rig.browser.newTab()
                rig.draw()
                rig.draw()
                guard let field = rig.fieldEditor() else {
                    throw XCTSkip("the Start page has no editable field editor")
                }
                let options = XCTMeasureOptions.budgeted
                options.invocationOptions = [.manuallyStart]
                var perKey: [Double] = []
                var pass = 0
                let clock = ContinuousClock()
                let searchesBefore = store.backgroundSearchCount

                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                    pass += 1
                    field.selectAll(nil)
                    field.delete(nil)
                    rig.draw()
                    startMeasuring()
                    for character in "githubwiki" {
                        let started = clock.now
                        field.insertText(String(character), replacementRange: field.selectedRange())
                        rig.draw()
                        if pass > 1 {
                            perKey.append(PerfProbe.ms(clock.now - started))
                        }
                    }
                }
                XCTAssertEqual(field.string, "githubwiki")
                Self.perOperation("W7.address-keystroke", perKey, "backgroundSearches=\(store.backgroundSearchCount - searchesBefore) field=editor")
            }
        }
    }

    // MARK: - W8 Scrolling a sidebar with folders, pins and splits

    /// A real, lazy `Sidebar` of 280 x 700 over 20 pinned tabs, 10 open folders of 40, 10 splits of two rows and 300 loose rows.
    /// The rows are unloaded; the sidebar scrolls 30 steps of 300 pt, each laid out and drawn. Afterwards 150 steps of 100 pt
    /// print the distribution of a step (0.1.17: median 3.8-4.6 ms but p99 38 ms for folders alone).
    func testScrollingASidebarWithFoldersPinsAndSplits() {
        MainActor.assumeIsolated {
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            let browser = coordinator.browser
            for index in 0..<20 {
                browser.pinned("https://pinned-\(index).example/")
            }
            for index in 0..<10 {
                let pages = (0..<40).map { browser.addPage("https://folder-\(index)-\($0).example/") }
                browser.createFolder(named: "Folder \(index)", containing: pages)
            }
            for index in 0..<10 {
                let left = browser.addPage("https://split-\(index)-a.example/")
                let right = browser.addPage("https://split-\(index)-b.example/")
                browser.split(left, with: right, axis: .sideBySide)
            }
            let loose = (0..<300).map { browser.addPage("https://loose-\($0).example/") }
            browser.activate(loose[0])
            let sidebar = Sidebar(browser: browser, coordinator: coordinator)
                .frame(width: 280, height: 700)
                .environment(\.sidebarDrawsEveryRow, false)
            let host = NSHostingView(rootView: AnyView(sidebar))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 700)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            func scrollViews(in view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
            }
            guard let scroll = scrollViews(in: host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else {
                XCTFail("the sidebar has no scroll view")
                return
            }
            let loaded = browser.tabs.filter(\.isMaterialised).count
            XCTAssertLessThanOrEqual(loaded, 4, "the sidebar fixture realised pages")

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                for step in 1...30 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 300))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    PerfProbe.draw(host)
                }
            }

            var times: [Double] = []
            let clock = ContinuousClock()
            for round in 0..<2 {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                PerfProbe.draw(host)
                for step in 1...150 {
                    let started = clock.now
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 100))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    PerfProbe.draw(host)
                    if round == 1 {
                        times.append(PerfProbe.ms(clock.now - started))
                    }
                }
            }
            Self.perOperation(
                "W8.sidebar-scroll-step-100pt", times,
                "over16_7ms=\(times.filter { $0 > 16.7 }.count) over33ms=\(times.filter { $0 > 33 }.count) "
                    + "documentHeight=\(Int(scroll.documentView?.frame.height ?? 0)) liveWebViews=\(Self.liveWebViews()) "
                    + "materialised=\(browser.tabs.filter(\.isMaterialised).count)"
            )
            window.contentView = nil
            window.close()
            browser.cancelPendingSave()
        }
    }

    // MARK: - W9 The History page

    /// Opening the History page over 50,000 pages and closing its tab, three times, each drawn.
    func testShowingTheHistoryPageOfALargeHistory() throws {
        try MainActor.assumeIsolated {
            let (database, directory) = try Self.largeHistory()
            defer {
                try? database.writer.close()
                try? FileManager.default.removeItem(at: directory)
            }
            let rig = CrowdedWindow(rows: 20, history: HistoryStore(database: database))
            defer { rig.close() }
            let browser = rig.browser
            rig.draw()
            var opens: [Double] = []
            var pass = 0
            let clock = ContinuousClock()

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                pass += 1
                for _ in 0..<3 {
                    let started = clock.now
                    browser.showHistory()
                    rig.draw()
                    if pass > 1 {
                        opens.append(PerfProbe.ms(clock.now - started))
                    }
                    if let tab = browser.tabs.first(where: { $0.internalPage == .history }) {
                        browser.close(tab)
                    }
                    rig.draw()
                }
            }
            Self.perOperation("W9.show-history", opens)
            XCTAssertNil(browser.tabs.first { $0.internalPage == .history })
        }
    }
}
