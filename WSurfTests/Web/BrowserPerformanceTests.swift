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

            let settings = BrowserSettings(defaults: UserDefaults(suiteName: "BrowserPerformanceTests.\(UUID())")!)
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

    /// What a 300-row sidebar asks the theme for while it draws: the loaded and unloaded text, the accent, and the
    /// icon and URL inks, ten times over. With a copy that changes the palette, so no color is the plain default.
    func testResolvingThemeColorsForACrowdedSidebar() {
        MainActor.assumeIsolated {
            let suite = "BrowserPerformanceTests-\(UUID().uuidString)"
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
            let suite = "BrowserPerformanceTests-\(UUID().uuidString)"
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
