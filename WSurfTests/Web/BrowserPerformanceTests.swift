// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import WSurf

// XCTest owns and runs one instance serially. Sendable lets its synchronous
// measurement callback enter the app target's main-actor boundary.
nonisolated final class BrowserPerformanceTests: XCTestCase, @unchecked Sendable {
    func testCreatingAUsableStartPageTab() {
        MainActor.assumeIsolated {
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                let browser = BrowserModel(database: .temporary())
                let tab = browser.newTab()

                XCTAssertTrue(tab.hasNoPageYet)
                XCTAssertTrue(browser.activeTab === tab)
                browser.cancelPendingSave()
            }
        }
    }

    func testSwitchingTabsInACrowdedSession() {
        MainActor.assumeIsolated {
            let browser = BrowserModel(database: .temporary())
            let first = browser.newTab()
            let second = browser.newTab()
            let entries = (0..<100).map { index in
                HistoryStore.Entry(
                    url: "https://fixture-\(index).example/",
                    title: "Fixture \(index)",
                    lastVisit: Date(timeIntervalSinceReferenceDate: Double(index))
                )
            }
            _ = browser.importBookmarksFolder(named: "Performance fixtures", entries: entries)

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<250 {
                    browser.activate(first)
                    browser.activate(second)
                }
            }
            browser.cancelPendingSave()
        }
    }

    /// Switching among five spaces of 60 tabs each: every switch settles and filters all 300 rows of the window and
    /// activates the space's last tab.
    func testSwitchingSpacesInACrowdedSession() {
        MainActor.assumeIsolated {
            let browser = BrowserModel(database: .temporary())
            let spaces = (0..<5).map { _ in UUID() }
            browser.adoptSpaces(spaces)
            browser.newTab()
            for space in spaces {
                browser.switchSpace(to: space)
                for index in 0..<59 {
                    browser.addPage("https://fixture-\(index).example/\(space.uuidString)")
                }
            }
            XCTAssertEqual(browser.tabs.count, 300)

            // ponytail-merge: written before the robust gate; six runs so the memory gate drops the warm-up and judges five.
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for index in 0..<50 {
                    browser.switchSpace(to: spaces[index % spaces.count])
                }
            }
            XCTAssertEqual(browser.sidebarTree.root.count, 60)
            browser.cancelPendingSave()
        }
    }

    /// The sweep over 500 tabs when 50 of them have sat unused: the filter reads every tab, and the stale ones close
    /// into the archive. Each run starts with a fresh set of 50, so the setup stays out of the measurement.
    func testSweepingACrowdedSessionForStaleTabs() {
        MainActor.assumeIsolated {
            let browser = BrowserModel(database: .temporary())
            browser.newTab()
            for index in 0..<449 {
                browser.addPage("https://fixture-\(index).example/")
            }
            let now = Date()
            let options = XCTMeasureOptions.budgeted
            options.invocationOptions = [.manuallyStart]

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                for index in 0..<50 {
                    browser.addPage("https://stale-\(index).example/").lastActiveAt = now.addingTimeInterval(-3 * 86_400)
                }
                startMeasuring()
                let archived = browser.archiveTabs(unusedFor: .day, now: now)
                XCTAssertEqual(archived, 50)
            }
            XCTAssertEqual(browser.tabs.count, 450)
            XCTAssertEqual(browser.tabArchive.entries.count, TabArchive.capacity)
            browser.cancelPendingSave()
        }
    }

    /// The ⌘K archive list while a query is typed: the full archive matched and ranked against it, minus the pages that
    /// are open among 300 tabs. The open set is rebuilt in every run, as the palette does on each keystroke.
    func testArchivedTabSearchProjection() {
        MainActor.assumeIsolated {
            let archive = TabArchive(database: .temporary())
            archive.add((0..<TabArchive.capacity).map {
                (title: "Archived page \($0)", url: "https://archive-\($0).example/page")
            })
            let tabs = (0..<300).map { index in
                // Ranking reads metadata only; page loads are unrelated work. The first five tabs show archived pages.
                let tab = BrowserTab(restoring: true)
                tab.title = "Open tab \(index)"
                tab.urlString = index < 5
                    ? "https://archive-\(index).example/page"
                    : "https://open-\(index).example/page"
                return tab
            }
            XCTAssertEqual(archive.entries.count, TabArchive.capacity)
            var section: OmniboxSection?

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                section = Omnibox.archivedSection(
                    query: "archived page 2",
                    entries: archive.entries,
                    excluding: Set(tabs.map(\.urlString)),
                    restore: { _ in }
                )
            }

            // Pages 2 and 20 through 29 match; page 2 is open.
            XCTAssertEqual(section?.items.count, 10)
        }
    }

    func testCommandPaletteHistoryRanking() {
        MainActor.assumeIsolated {
            let database = AppDatabase.temporary()
            let history = HistoryStore(database: database, windowSize: 1_000)
            for index in 0..<500 {
                _ = history.record(
                    url: "https://docs.example/project/\(index)",
                    title: "Project documentation \(index)",
                    transition: .link,
                    fromVisit: nil
                )
            }

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                _ = Omnibox.historySection(
                    query: "project 42",
                    store: history,
                    limit: 5,
                    open: { _ in }
                )
            }
        }
    }

    func testCommandPaletteResultProjection() {
        MainActor.assumeIsolated {
            Omnibox.$agentOnlyForTesting.withValue(false) {
                let history = HistoryStore(database: .temporary(), windowSize: 1_000)
                for index in 0..<500 {
                    _ = history.record(
                        url: "https://docs.example/project/\(index)",
                        title: "Project documentation \(index)",
                        transition: .link,
                        fromVisit: nil
                    )
                }
                let tabs = (0..<100).map { index in
                    // Ranking reads metadata only; page loads are unrelated work.
                    let tab = BrowserTab(restoring: true)
                    tab.title = "Project tab \(index)"
                    tab.urlString = "https://tabs.example/project/\(index)"
                    return tab
                }
                let phrases = (0..<10).map { "project suggestion \($0)" }
                let actions = CommandPaletteActions()
                var projected: [OmniboxSection] = []
                XCTAssertTrue(tabs.allSatisfy { !$0.isMaterialised })

                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                    projected = CommandPaletteProjection.sections(
                        query: "project",
                        agentName: "Assistant",
                        history: history,
                        tabs: tabs,
                        phrases: phrases,
                        actions: actions
                    )
                }

                // Open tabs that match come first while typing (`CommandPaletteSection.typingOrder`).
                XCTAssertEqual(projected.map(\.id), ["tabs", "top", "suggestions", "history"])
                XCTAssertEqual(projected.flattened.count, CommandPaletteBudget.typing)
                XCTAssertTrue(tabs.allSatisfy { !$0.isMaterialised })
            }
        }
    }

    func testStartPageFrequentSiteProjection() {
        MainActor.assumeIsolated {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let visits = (0..<400).map { index in
                HistoryStore.VisitedPage(
                    id: Int64(400 - index),
                    url: "https://site-\(index % 20).example/page/\(index)",
                    title: "Fixture \(index)",
                    visitedAt: calendar.date(
                        from: DateComponents(
                            year: 2026,
                            month: 7,
                            day: (index % 28) + 1
                        )
                    )!,
                    transition: .link
                )
            }

            let settings = BrowserSettings(defaults: UserDefaults(suiteName: AppDatabase.defaultsSuite("BrowserPerformanceTests.\(UUID())"))!)
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                let sites = StartPageSnapshot.frequentSites(
                    from: visits,
                    hiddenHosts: [],
                    settings: settings,
                    calendar: calendar
                )
                XCTAssertEqual(sites.count, 10)
                XCTAssertEqual(sites.first?.visits, 20)
            }
        }
    }

    func testAskSurfaceResultProjection() {
        MainActor.assumeIsolated {
            Omnibox.$agentOnlyForTesting.withValue(false) {
                let history = HistoryStore(database: .temporary(), windowSize: 1_000)
                for index in 0..<500 {
                    _ = history.record(
                        url: "https://docs.example/project/\(index)",
                        title: "Project documentation \(index)",
                        transition: .link,
                        fromVisit: nil
                    )
                }
                let tab = BrowserTab(restoring: true)
                tab.title = "Project documentation"
                tab.urlString = "https://docs.example/project/open"
                let phrases = (0..<12).map { "project documentation \($0)" }
                var projected: [OmniboxSection] = []
                XCTAssertFalse(tab.isMaterialised)

                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                    projected = AskSurfaceResults.sections(
                        placement: .startPage,
                        query: "project 42",
                        isFocused: true,
                        isListening: false,
                        currentURL: "",
                        agentOnly: false,
                        settings: .application,
                        agentName: "Assistant",
                        history: history,
                        tabs: [tab],
                        phrases: phrases,
                        open: { _ in },
                        switchTo: { _ in },
                        ask: { _ in }
                    )
                }

                XCTAssertEqual(projected.map(\.id), ["top", "suggestions", "history", "ask"])
                XCTAssertLessThanOrEqual(projected.flattened.count, 10)
                XCTAssertFalse(tab.isMaterialised)
            }
        }
    }

    func testLayingOutACrowdedSidebar() {
        MainActor.assumeIsolated {
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            let browser = coordinator.browser
            let tabs = (0..<300).map { _ in browser.newTab(activate: false) }
            // Every tenth row is marked, the way Select All would mark them: each wears a glass layer.
            for tab in tabs.enumerated() where tab.offset % 10 == 0 {
                browser.sidebarSelection.toggle(.tab(tab.element.id))
            }
            let context = SidebarRowContext(
                browser: browser,
                coordinator: coordinator,
                selection: browser.sidebarSelection,
                drag: nil,
                pinsCarried: false,
                space: "BrowserPerformanceTests",
                frames: SidebarFrames()
            )
            let rows = VStack(spacing: SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)) {
                ForEach(tabs) { SidebarTabRow(tab: $0, depth: 0, context: context) }
            }
            .glassGroup()
            .frame(width: 220)
            .environment(\.sidebarStyle, .full)
            .environment(\.chromeWash, .of(NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1), isLight: false))
            .environment(\.chromeIsLight, false)
            .environment(\.colorScheme, .dark)
            .environment(\.windowColorScheme, .dark)

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                let host = NSHostingView(rootView: rows)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                window.close()
            }
            browser.cancelPendingSave()
        }
    }

    /// The crowded sidebar under a theme that moves every layout knob: thin row edges instead of glass on the marked
    /// rows, square corners, color favicons on every loaded row, and the spacing extremes (largest icons, least
    /// padding and margin, a flush page). The knobs are a preview of the app-wide theme, so nothing is written to the
    /// test host's defaults. Its memory samples spiked in an aged host, so it warms up first and each run releases
    /// everything it built; the footprint after each run is printed to tell retained growth from a transient spike.
    func testLayingOutACrowdedSidebarWithEveryLayoutOption() throws {
        try MainActor.assumeIsolated {
            let settings = BrowserSettings.application
            guard settings.themePreview == nil else {
                throw XCTSkip("Layout measurement must not replace an existing theme preview.")
            }
            settings.beginThemePreview()
            defer { settings.cancelThemePreview() }
            var adjustment = settings.themeAdjustment
            adjustment.pageFrame = .hairline
            adjustment.rowFrame = .hairline
            adjustment.cornerScale = 0
            adjustment.loadedFavicons = .color
            adjustment.pageSpacing = ThemeAdjustment.pageSpacingRange.lowerBound
            adjustment.sidebarMargin = ThemeAdjustment.sidebarMarginRange.lowerBound
            adjustment.rowPadding = ThemeAdjustment.rowPaddingRange.lowerBound
            adjustment.tabIconSize = ThemeAdjustment.tabIconSizeRange.upperBound
            settings.previewThemeAdjustment(adjustment)
            XCTAssertTrue(settings.chromeShape == ThemeShape(adjustment))

            let favicon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
                NSColor.systemOrange.setFill()
                bounds.fill()
                return true
            }
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            let browser = coordinator.browser
            let tabs = (0..<300).map { _ in browser.newTab(activate: false) }
            for tab in tabs.enumerated() {
                tab.element.urlString = "https://fixture-\(tab.offset).example/"
                tab.element.isLoading = false
                tab.element.favicon = favicon
                if tab.offset % 10 == 0 {
                    browser.sidebarSelection.toggle(.tab(tab.element.id))
                }
            }
            let context = SidebarRowContext(
                browser: browser,
                coordinator: coordinator,
                selection: browser.sidebarSelection,
                drag: nil,
                pinsCarried: false,
                space: "BrowserPerformanceTests",
                frames: SidebarFrames()
            )
            let rows = VStack(spacing: SidebarMetrics.rowVerticalSpacing(settings: settings)) {
                ForEach(tabs) { SidebarTabRow(tab: $0, depth: 0, context: context) }
            }
            .glassGroup()
            .frame(width: 220)
            .environment(\.sidebarStyle, .full)
            .environment(\.chromeWash, .of(NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1), isLight: false))
            .environment(\.chromeIsLight, false)
            .environment(\.colorScheme, .dark)
            .environment(\.windowColorScheme, .dark)

            // Each run frees what it built before it ends, so a window, its backing store and the rows' graph from one
            // run never land in another run's memory sample.
            @MainActor func layOut() {
                autoreleasepool {
                    let host = NSHostingView(rootView: rows)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    window.contentView = nil
                    window.close()
                }
            }
            // Two unmeasured runs fill the caches every layout knob touches once: the favicon at 24 pt, text layout,
            // the inverse and edge colors of each row style.
            layOut()
            layOut()

            var footprints: [UInt64] = []
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                layOut()
                footprints.append(Self.physicalFootprint())
            }
            // Growth from run to run is retained memory; a single high sample that the next run gives back is not.
            print("Layout option sidebar footprint after each run (kB): \(footprints.map { $0 / 1_024 })")
            browser.cancelPendingSave()
        }
    }

    /// Ten switches between the Standard and Minimal window styles in a 300-tab window, each laid out and drawn. The
    /// style is an input of the view, so nothing is written to the test host's defaults. Budgeted in Tools/check-performance.sh.
    func testSwitchingWindowStyles() {
        MainActor.assumeIsolated {
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            let browser = coordinator.browser
            for index in 0..<300 {
                browser.newTab(activate: false).urlString = "https://fixture-\(index).example/"
            }
            let count = browser.tabs.count
            let host = NSHostingView(rootView: AnyView(BrowserView(browser: browser, coordinator: coordinator, style: .standard)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            // ponytail-merge: written before the robust gate; six runs so the memory gate drops the warm-up and judges five.
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<5 {
                    for style in [BrowserWindowStyle.minimal, .standard] {
                        host.rootView = AnyView(BrowserView(browser: browser, coordinator: coordinator, style: style))
                        host.layoutSubtreeIfNeeded()
                        host.displayIfNeeded()
                    }
                }
                XCTAssertEqual(browser.tabs.count, count)
            }
            window.contentView = nil
            window.close()
            browser.cancelPendingSave()
        }
    }

    /// The Minimal bar with its tab list open over a 300-tab window. Each run builds and frees its own window.
    func testLayingOutTheMinimalShell() {
        MainActor.assumeIsolated {
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            let browser = coordinator.browser
            for index in 0..<300 {
                browser.newTab(activate: false).urlString = "https://fixture-\(index).example/"
            }

            // ponytail-merge: written before the robust gate; six runs so the memory gate drops the warm-up and judges five.
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                autoreleasepool {
                    coordinator.isMinimalTabListOpen = true
                    let host = NSHostingView(rootView: MinimalShell(browser: browser, coordinator: coordinator))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    window.contentView = nil
                    window.close()
                }
            }
            browser.cancelPendingSave()
        }
    }

    /// The real sidebar over a window of 1,025 rows, 1,000 tabs in 25 open folders of 40 and two live tabs (the two that
    /// the switching case activates), in a 280 x 700 window.
    @MainActor
    private struct ThousandRowSidebar {
        let coordinator: AppCoordinator
        let first: BrowserTab
        let second: BrowserTab

        var browser: BrowserModel {
            coordinator.browser
        }

        init() {
            coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            let browser = coordinator.browser
            let pages = (0..<1_000).map { browser.addPage("https://fixture-\($0).example/") }
            for index in 0..<25 {
                browser.createFolder(named: "Folder \(index)", containing: Array(pages[index * 40..<(index + 1) * 40]))
            }
            first = browser.newTab()
            second = browser.newTab()
        }

        func window() -> (NSWindow, NSHostingView<AnyView>) {
            // Lazy whatever the Mac's accessibility settings are: this is the list the cases measure.
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
            return (window, host)
        }

        func scrollView(in view: NSView) -> NSScrollView? {
            func all(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { all($0) }
            }
            return all(view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        }
    }

    /// Opening the sidebar over 1,000 tabs in 25 folders: the window is built, laid out and drawn once per run, which is
    /// what showing a sidebar, switching to a space or restoring a window costs. Budgeted in Tools/check-performance.sh.
    func testLayingOutAThousandRowSidebar() {
        MainActor.assumeIsolated {
            let rig = ThousandRowSidebar()
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                autoreleasepool {
                    let (window, host) = rig.window()
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    window.contentView = nil
                    window.close()
                }
            }
            rig.browser.cancelPendingSave()
        }
    }

    /// Switching between two tabs four times over a sidebar of 1,000 tabs that is on screen: every switch changes which
    /// row is current, and the sidebar is laid out and drawn after each.
    func testSwitchingTabsOverAThousandRowSidebar() {
        MainActor.assumeIsolated {
            let rig = ThousandRowSidebar()
            let (window, host) = rig.window()
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<2 {
                    for tab in [rig.first, rig.second] {
                        rig.browser.activate(tab)
                        RunLoop.current.run(until: Date())
                        host.layoutSubtreeIfNeeded()
                        host.displayIfNeeded()
                    }
                }
            }
            window.contentView = nil
            window.close()
            rig.browser.cancelPendingSave()
        }
    }

    /// Twelve switches among four loaded WebKit pages in the window the app builds, each laid out and drawn: the main-thread work of
    /// a switch the person sees (perf audit 0.1.22, item 3). The window is the app's own, in a profile of its own, with onboarding
    /// marked done in this host's defaults as `LaunchPerformanceTests` does, or every pass would draw it.
    func testSwitchingLoadedTabsInAWindow() {
        MainActor.assumeIsolated {
            let defaults = StageMode.defaults
            let completed = defaults.object(forKey: "onboarding.completed")
            defaults.set(true, forKey: "onboarding.completed")
            defer { defaults.set(completed, forKey: "onboarding.completed") }
            let catalog = ProfileStore.shared
            let previous = catalog.current
            let profile = catalog.add(name: "Tab switch performance")
            LiveWindowRig.useSharedDataStore(for: profile)
            let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
            let coordinator = app.newWindow(profile: profile, show: false)
            let browser = coordinator.browser
            @MainActor func draw() {
                RunLoop.current.run(until: Date())
                coordinator.nativeWindow?.contentView?.layoutSubtreeIfNeeded()
                coordinator.nativeWindow?.contentView?.displayIfNeeded()
            }
            @MainActor func spin(until condition: () -> Bool) -> Bool {
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline, !condition() {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
                }
                return condition()
            }
            let tabs = (0..<4).map { index in
                let tab = browser.newTab()
                tab.loadHTML(
                    "<!doctype html><title>Page \(index)</title>" + String(repeating: "<p>Paragraph of page \(index).</p>", count: 200),
                    baseURL: URL(string: "https://switch-\(index).example/")
                )
                draw()
                XCTAssertTrue(spin { !tab.hasNoPageYet && !tab.isLoading }, "page \(index) loaded")
                return tab
            }
            draw()

            measure(metrics: [XCTClockMetric()], options: .budgeted) {
                for _ in 0..<3 {
                    for tab in tabs {
                        browser.activate(tab)
                        draw()
                    }
                }
            }
            coordinator.closeWindow()
            coordinator.releaseWindowHost()
            let done = XCTestExpectation(description: "profile removed")
            Task {
                for tab in tabs {
                    await tab.waitForRetirement()
                }
                await catalog.remove(profile)
                await LiveWindowRig.releaseSharedDataStore(for: profile)
                catalog.markCurrent(previous)
                done.fulfill()
            }
            XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 120), .completed)
            withExtendedLifetime(app) {}
        }
    }

    /// Scrolling down a sidebar of 1,000 tabs in 30 steps of 300 pt, laid out and drawn at each step, as a drag of the
    /// scroll bar or a fling does.
    func testScrollingAThousandRowSidebar() {
        MainActor.assumeIsolated {
            let rig = ThousandRowSidebar()
            let (window, host) = rig.window()
            guard let scroll = rig.scrollView(in: host) else {
                XCTFail("the sidebar has no scroll view")
                return
            }
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                for step in 1...30 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 300))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.current.run(until: Date())
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                }
            }
            window.contentView = nil
            window.close()
            rig.browser.cancelPendingSave()
        }
    }

    /// The test host's physical footprint, the figure XCTMemoryMetric samples.
    private static func physicalFootprint() -> UInt64 {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    /// What a 300-row sidebar asks the theme for while it draws: the loaded and unloaded text, the accent, and the
    /// icon and URL inks, ten times over. With a copy that changes the palette, so no color is the plain default.
    func testResolvingThemeColorsForACrowdedSidebar() {
        MainActor.assumeIsolated {
            let suite = AppDatabase.defaultsSuite("BrowserPerformanceTests-\(UUID().uuidString)")
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = BrowserSettings(defaults: defaults)
            settings.editColors(scheme: .dark) {
                $0.hue = 0.1
                $0.primary = 0x3366FF
                $0.icons = SidebarTextStyle(colorRGB: 0xFFAA00, opacity: 0.6)
                $0.url = SidebarTextStyle(colorRGB: 0x88DDFF, opacity: 0.8)
            }
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                var colors = 0
                for _ in 0..<10 {
                    for _ in 0..<300 {
                        let theme = settings.resolvedTheme
                        colors += settings.sidebarTextColor(scheme: .dark) == theme.dark.loadedInk ? 1 : 0
                        colors += settings.sidebarTextColor(isDeferred: true, scheme: .dark) == theme.dark.unloadedInk ? 1 : 0
                        colors += settings.resolvedTheme.accent == theme.accent ? 1 : 0
                        colors += theme.dark.controlInk == nil ? 0 : 1
                        colors += theme.dark.urlInk == nil ? 0 : 1
                    }
                }
                XCTAssertEqual(colors, 15_000)
            }
        }
    }

    /// Choosing each built-in theme ten times: every choice rebuilds the cached colors once.
    func testSwitchingThemes() {
        MainActor.assumeIsolated {
            let suite = AppDatabase.defaultsSuite("BrowserPerformanceTests-\(UUID().uuidString)")
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = BrowserSettings(defaults: defaults)
            let ids = ThemeCatalog.builtIn.map(\.id)
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                var switched = 0
                for _ in 0..<10 {
                    for id in ids {
                        settings.themeID = id
                        let theme = settings.resolvedTheme
                        if theme.id == id {
                            switched += 1
                        }
                    }
                }
                XCTAssertEqual(switched, 10 * ids.count)
            }
        }
    }
}
