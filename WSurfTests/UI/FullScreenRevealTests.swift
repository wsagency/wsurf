// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Real full screen on a real display: while the system's strip is hidden the page and the chrome use the whole screen,
/// when the menu bar comes down the layout moves below the strip and the menu bar, and it comes back up after. The menu
/// bar is brought down the way a click on it does, by pressing the app's own menu bar item through accessibility in
/// process: no event is posted and no permission is asked. The display goes full screen for a few seconds, so this runs
/// only when asked: `TEST_RUNNER_WSURF_REAL_FULLSCREEN=1`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WSURF_REAL_FULLSCREEN"] != nil))
struct FullScreenRevealTests {
    @Test(.boundedWebViews)
    func theStripTakesRoomOnlyWhileItShows() async throws {
        let app = BrowserApplication()
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        app.register(coordinator)
        coordinator.showBrowser()
        let window = try #require(coordinator.nativeWindow)
        defer {
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            coordinator.closeWindow()
        }
        try #require(await waitUntil { (try? addressTop(in: window)) != nil })
        let windowedTop = try addressTop(in: window)

        window.toggleFullScreen(nil)
        // The host publishes no traffic-light inset once the window is in full screen.
        try #require(await waitUntil { window.styleMask.contains(.fullScreen) && coordinator.windowControlsInset == 0 })
        try #require(await waitUntil { stripBottom(of: window) >= window.frame.maxY }, "the strip goes out of sight")
        try #require(await waitUntil { coordinator.titleStripInset == 0 })
        #expect(abs(try addressTop(in: window) - windowedTop) < 0.5, "no band above the toolbar while the strip is hidden")

        try openAppMenu()
        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)
        let shown = await waitUntil { NSMenu.menuBarVisible() && window.frame.maxY - stripBottom(of: window) >= strip }
        try #require(await waitUntil { coordinator.titleStripInset == window.frame.maxY - stripBottom(of: window) })
        let covered = window.frame.maxY - stripBottom(of: window)
        let fieldTop = try addressTopOnScreen(in: window)
        NSApp.mainMenu?.items.compactMap(\.submenu).forEach { $0.cancelTracking() }
        #expect(shown, "the menu bar and the strip came down")
        #expect(fieldTop <= window.frame.maxY - covered, "the address field at \(fieldTop) clears the strip at \(window.frame.maxY - covered)")

        try #require(await waitUntil { !NSMenu.menuBarVisible() && coordinator.titleStripInset == 0 }, "the strip went back up")
        #expect(abs(try addressTop(in: window) - windowedTop) < 0.5)

        window.toggleFullScreen(nil)
        try #require(await waitUntil { !window.styleMask.contains(.fullScreen) && coordinator.windowControlsInset > 0 })
        #expect(coordinator.titleStripInset == 0)
        #expect(abs(try addressTop(in: window) - windowedTop) < 0.5, "leaving full screen puts the layout back")
    }

    // MARK: - Measuring

    /// The bottom edge of the strip's title bar on screen; above the window's top while it is hidden.
    private func stripBottom(of window: NSWindow) -> CGFloat {
        guard let bar = window.standardWindowButton(.closeButton)?.superview, let strip = bar.window else { return .infinity }
        return strip.convertToScreen(bar.convert(bar.bounds, to: nil)).minY
    }

    private func addressField(in window: NSWindow) throws -> NSView {
        let root = try #require(window.contentView)
        // The Start Page carries a field of its own, lower down; the toolbar's is the highest.
        let fields = descendants(of: root).filter { $0 is MentionTextField }
        return try #require(fields.max { addressTopOnScreen(of: $0) < addressTopOnScreen(of: $1) }, "the address field")
    }

    private func addressTopOnScreen(of view: NSView) -> CGFloat {
        view.window?.convertToScreen(view.convert(view.bounds, to: nil)).maxY ?? 0
    }

    private func addressTopOnScreen(in window: NSWindow) throws -> CGFloat {
        addressTopOnScreen(of: try addressField(in: window))
    }

    /// How far the address field's top edge is below the window's top edge.
    private func addressTop(in window: NSWindow) throws -> CGFloat {
        window.frame.maxY - (try addressTopOnScreen(in: window))
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants)
    }

    /// Opens the app menu (the menu bar's first item after the Apple menu), which brings the menu bar down in full screen.
    private func openAppMenu() throws {
        let bar = try #require(
            NSApp.accessibilityChildren()?
                .compactMap { $0 as? NSAccessibilityProtocol }
                .first { $0.accessibilityRole() == .menuBar },
            "the app's menu bar"
        )
        let item = try #require(bar.accessibilityChildren()?.dropFirst().first as? NSAccessibilityProtocol, "the app menu")
        _ = item.accessibilityPerformPress()
    }
}
