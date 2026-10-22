// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// In full screen the system draws a strip with the traffic lights over the top of the window, and the browser window
/// is full-size content with no safe area, so a layout that starts at the window's top has its address field under the
/// strip. The host reserves the strip's height for every layout. Real full screen needs a real display, so these cases
/// check the number against a real titled window and the layout against hosted views.
@MainActor
struct FullScreenTitleStripTests {
    private let titled: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    private func titledWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: titled,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - How much is reserved

    @Test func aWindowedBrowserReservesNothing() {
        #expect(BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: false) == 0)
    }

    @Test func fullScreenReservesAtLeastTheSystemTitlebar() {
        let window = titledWindow()
        defer { window.close() }
        let titlebar = window.frame.height - window.contentLayoutRect.height

        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)

        #expect(titlebar > 0, "the probe window has a titlebar")
        #expect(strip >= titlebar, "the strip \(strip) must cover the titlebar \(titlebar)")
    }

    /// The strip holds the traffic lights, so what is reserved has to reach below the lowest of them.
    @Test func fullScreenReservesRoomForTheTrafficLights() {
        let window = titledWindow()
        defer { window.close() }
        let lowestEdge = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { window.frame.height - $0.convert($0.bounds, to: nil).minY }
            .max()

        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)

        #expect(strip >= (lowestEdge ?? .infinity), "the strip \(strip) must reach below the lights at \(lowestEdge ?? -1)")
    }

    @Test func theCoordinatorPublishesTheStripToTheLayout() {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.browser.cancelPendingSave() }
        #expect(coordinator.titleStripInset == 0)

        coordinator.hostDidChange(visible: true, controlsInset: 0, titleStripInset: 28)
        #expect(coordinator.titleStripInset == 28)

        coordinator.hostDidChange(visible: true, controlsInset: BrowserHost.windowControlsInset, titleStripInset: 0)
        #expect(coordinator.titleStripInset == 0)
    }

    // MARK: - Where the layouts start

    private func hosted(_ view: some View) -> (NSHostingView<AnyView>, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view))
        host.safeAreaRegions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        var found: [T] = []
        for subview in root.subviews {
            if let match = subview as? T {
                found.append(match)
            }
            found += descendants(of: subview, as: type)
        }
        return found
    }

    /// How far `view`'s top edge is below the hosting view's top edge.
    private func top(of view: NSView, in host: NSView) -> CGFloat {
        let frame = host.convert(view.bounds, from: view)
        return host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
    }

    private func toolbarAddressTop(in host: NSView) throws -> CGFloat {
        let fields = descendants(of: host, as: MentionTextField.self)
        // The Start Page carries a field of its own, lower down; the toolbar's is the highest.
        let highest = fields.map { top(of: $0, in: host) }.min()
        return try #require(highest, "the toolbar's address field is hosted")
    }

    @Test func theStandardToolbarStartsBelowTheStrip() throws {
        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.browser.cancelPendingSave() }

        coordinator.hostDidChange(visible: true, controlsInset: BrowserHost.windowControlsInset, titleStripInset: 0)
        let (windowedHost, windowed) = hosted(BrowserRootView(coordinator: coordinator))
        defer { windowed.close() }
        let windowedTop = try toolbarAddressTop(in: windowedHost)

        coordinator.hostDidChange(visible: true, controlsInset: 0, titleStripInset: strip)
        let (fullHost, full) = hosted(BrowserRootView(coordinator: coordinator))
        defer { full.close() }
        let fullScreenTop = try toolbarAddressTop(in: fullHost)

        #expect(windowedTop < strip, "windowed, the address field sits where the strip would be: \(windowedTop)")
        #expect(fullScreenTop >= strip, "the address field at \(fullScreenTop) must clear the strip at \(strip)")
        #expect(abs(fullScreenTop - windowedTop - strip) < 0.5, "the layout moves down by exactly the strip")
    }

    @Test func theMinimalWindowStartsBelowTheStripToo() throws {
        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.browser.cancelPendingSave() }

        func layoutTop(inset: CGFloat) throws -> CGFloat {
            let view = BrowserView(browser: coordinator.browser, coordinator: coordinator, style: .minimal)
                .environment(\.titleStripInset, inset)
            let (host, window) = hosted(view)
            defer { window.close() }
            let sensors = descendants(of: host, as: MinimalShellSensor.SensorView.self)
            return top(of: try #require(sensors.first, "the Minimal shell is hosted"), in: host)
        }

        let windowed = try layoutTop(inset: 0)
        let fullScreen = try layoutTop(inset: strip)

        #expect(abs(windowed) < 0.5, "windowed, the Minimal shell fills the window: \(windowed)")
        #expect(fullScreen >= strip, "the Minimal shell at \(fullScreen) must clear the strip at \(strip)")
    }
}
