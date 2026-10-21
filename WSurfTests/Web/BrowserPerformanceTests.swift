// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

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
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
                for _ in 0..<250 {
                    browser.activate(first)
                    browser.activate(second)
                }
            }
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
            let options = XCTMeasureOptions()
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

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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

                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
                    projected = CommandPaletteProjection.sections(
                        query: "project",
                        agentName: "Assistant",
                        history: history,
                        tabs: tabs,
                        phrases: phrases,
                        actions: actions
                    )
                }

                XCTAssertEqual(projected.map(\.id), ["top", "suggestions", "tabs", "history"])
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
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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

                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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
    /// test host's defaults.
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

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
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
