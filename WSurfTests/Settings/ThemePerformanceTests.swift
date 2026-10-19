// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import WSurf

// XCTest owns and runs one instance serially. Sendable lets its synchronous
// measurement callback enter the app target's main-actor boundary.
nonisolated final class ThemePerformanceTests: XCTestCase, @unchecked Sendable {
    func testDraggingThemeBrightness() throws {
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
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            let browser = coordinator.browser
            defer { browser.cancelPendingSave() }
            // Profile appearance forwards to the same test-host singleton that SidebarRowInkSource reads.
            XCTAssertTrue(coordinator.settings.globalSettings === settings)
            // newTab opens a live start page even with activate: false. Restore metadata instead,
            // and suppress activeTab's first-tab fallback so no fixture page becomes current.
            browser.hasNoActiveTab = true
            let tabs = (0..<300).map { browser.addPage("https://fixture-\($0).example/") }
            XCTAssertNil(browser.activeTab)
            for tab in tabs.enumerated() where tab.offset % 10 == 0 {
                browser.sidebarSelection.toggle(.tab(tab.element.id))
            }
            browser.cancelPendingSave()
            let context = SidebarRowContext(
                browser: browser,
                coordinator: coordinator,
                selection: browser.sidebarSelection,
                drag: nil,
                pinsCarried: false,
                space: "ThemePerformanceTests",
                frames: SidebarFrames()
            )
            let host = NSHostingView(rootView: BrightnessPreviewSidebar(tabs: tabs, context: context))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertEqual(tabs.count, 300)
            XCTAssertTrue(tabs.allSatisfy { !$0.isMaterialised })

            let persisted = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
            defer {
                settings.cancelThemePreview()
                XCTAssertNil(settings.themePreview)
                XCTAssertEqual(
                    NSDictionary(dictionary: UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]),
                    NSDictionary(dictionary: persisted)
                )
            }
            settings.beginThemePreview()
            let options = XCTMeasureOptions()
            options.iterationCount = 5

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                for step in 0..<30 {
                    var adjustment = settings.themeAdjustment
                    adjustment.darkBrightness = Double(step) / 29 - 0.5
                    settings.previewThemeAdjustment(adjustment)
                    host.needsLayout = true
                    host.layoutSubtreeIfNeeded()
                    host.needsDisplay = true
                    host.displayIfNeeded()
                }
            }
            XCTAssertEqual(settings.themePreview?.adjustment.darkBrightness, 0.5)
            XCTAssertTrue(tabs.allSatisfy { !$0.isMaterialised })
        }
    }

    func testRenderingTheThemeGallery() throws {
        try MainActor.assumeIsolated {
            let suite = "ThemePerformanceTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = BrowserSettings(defaults: defaults)
            XCTAssertEqual(ThemeCatalog.builtIn.count, 8)
            settings.userThemes = (0..<12).map { index in
                var theme = ThemeCatalog.builtIn[index % ThemeCatalog.builtIn.count]
                theme.basedOn = theme.id
                theme.id = "performance-\(index)"
                theme.name = "Performance fixture \(index)"
                return theme
            }
            let themes = settings.allThemes
            XCTAssertEqual(settings.userThemes.count, 12)
            XCTAssertEqual(themes.count, 20)
            let gallery = ThemeGallery(
                themes: themes,
                selection: settings.selectedTheme.id,
                mode: .system,
                adjustments: settings.themeAdjustments,
                onSelect: { _ in }
            )
            .frame(width: 468, alignment: .top)
            .environment(\.colorScheme, .light)
            let options = XCTMeasureOptions()
            options.iterationCount = 5

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                let host = NSHostingView(rootView: gallery)
                // Five rows of four cards fit without a scroll view hiding lazy grid content.
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 468, height: 800),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
    }
}

private struct BrightnessPreviewSidebar: View {
    let tabs: [BrowserTab]
    let context: SidebarRowContext

    var body: some View {
        let settings = context.coordinator.settings
        let ground = settings.resolvedTheme.dark.sidebar.resolved(in: NSAppearance(named: .darkAqua)!)
        VStack(spacing: SidebarMetrics.rowVerticalSpacing(settings: settings)) {
            ForEach(tabs) { SidebarTabRow(tab: $0, depth: 0, context: context) }
        }
        .glassGroup()
        .frame(width: 220)
        .background(Color(nsColor: ground))
        .coordinateSpace(name: context.space)
        .environment(\.sidebarStyle, .full)
        .environment(\.chromeWash, .of(ground, isLight: false))
        .environment(\.chromeIsLight, false)
        .environment(\.colorScheme, .dark)
        .environment(\.windowColorScheme, .dark)
    }
}
