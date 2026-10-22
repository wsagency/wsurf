// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// The Minimal window's tab list can be kept open: it docks at the leading edge and the page and the bar are laid out
/// beside it, not under it. Unpinned, the window is what it was. Views take the choice as an input, so no case writes the
/// app-wide setting.
@MainActor
struct MinimalPinnedSidebarTests {
    private let spacing = LoomChrome.canvasInset

    // MARK: - How much the page gives up

    @Test func aListThatFloatsTakesNoRoomFromThePage() {
        let inset = SidebarMetrics.pinnedTabListInset(isPinned: false, sidebarWidth: 268, container: 1_200, pageSpacing: spacing)

        #expect(inset == 0)
    }

    @Test func aPinnedListTakesItsWidthAndItsMargin() {
        let inset = SidebarMetrics.pinnedTabListInset(isPinned: true, sidebarWidth: 268, container: 1_200, pageSpacing: spacing)

        #expect(inset == 268 + spacing)
    }

    /// The page never gives up more room than the Standard sidebar could take, however wide the list was left.
    @Test func aPinnedListIsClampedLikeTheSidebar() {
        func inset(_ width: CGFloat, in container: CGFloat) -> CGFloat {
            SidebarMetrics.pinnedTabListInset(isPinned: true, sidebarWidth: width, container: container, pageSpacing: spacing)
        }

        #expect(inset(900, in: 1_000) == 400 + spacing, "at most 40 % of a narrow window")
        #expect(inset(900, in: 3_000) == SidebarMetrics.maxWidth + spacing)
        #expect(inset(50, in: 1_000) == SidebarMetrics.minWidth + spacing)
    }

    // MARK: - Where the layouts put the page and the bar

    private struct Layout {
        /// The horizontal center of every address field, left to right: the bar's, and the Start Page's.
        var fieldCenters: [CGFloat]
        /// How far the Minimal shell starts below the window's top edge.
        var shellTop: CGFloat?
    }

    private func layout(
        style: BrowserWindowStyle,
        pinned: Bool?,
        strip: CGFloat = 0,
        coordinator: AppCoordinator
    ) -> Layout {
        let view = BrowserView(browser: coordinator.browser, coordinator: coordinator, style: style, keepsSidebarOpen: pinned)
            .environment(\.titleStripInset, strip)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: AnyView(view))
        host.safeAreaRegions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()

        let fields = descendants(of: host, as: MentionTextField.self)
        let centers = fields.map { host.convert($0.bounds, from: $0).midX }.sorted()
        let shell = descendants(of: host, as: MinimalShellSensor.SensorView.self).first.map { sensor -> CGFloat in
            let frame = host.convert(sensor.bounds, from: sensor)
            return host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        }
        return Layout(fieldCenters: centers, shellTop: shell)
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

    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(browser: BrowserModel(database: .temporary()))
    }

    @Test func pinningTheListPutsThePageAndTheBarBesideIt() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.browser.cancelPendingSave() }
        let inset = SidebarMetrics.pinnedTabListInset(
            isPinned: true, sidebarWidth: coordinator.sidebar.width, container: 1_200, pageSpacing: spacing
        )

        let floating = layout(style: .minimal, pinned: false, coordinator: coordinator)
        let pinned = layout(style: .minimal, pinned: true, coordinator: coordinator)

        try #require(!floating.fieldCenters.isEmpty, "the bar's address field is hosted")
        try #require(pinned.fieldCenters.count == floating.fieldCenters.count)
        for (before, after) in zip(floating.fieldCenters, pinned.fieldCenters) {
            #expect(abs(after - before - inset / 2) < 1, "centered over the page beside the list: \(before) -> \(after)")
        }
    }

    /// Nothing changes for anyone who never pins the list: with no choice given, the window follows the app-wide setting,
    /// which starts off, and lays out as an unpinned one does.
    @Test func theMinimalWindowStartsUnpinned() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.browser.cancelPendingSave() }
        #expect(!BrowserSettings.application.keepsMinimalSidebarOpen)
        #expect(!coordinator.keepsMinimalSidebarOpen)

        let unpinned = layout(style: .minimal, pinned: false, coordinator: coordinator)
        let followingTheSetting = layout(style: .minimal, pinned: nil, coordinator: coordinator)

        try #require(!unpinned.fieldCenters.isEmpty)
        #expect(unpinned.fieldCenters == followingTheSetting.fieldCenters)
    }

    @Test func theStandardWindowIgnoresThePin() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.browser.cancelPendingSave() }

        let unpinned = layout(style: .standard, pinned: false, coordinator: coordinator)
        let pinned = layout(style: .standard, pinned: true, coordinator: coordinator)

        try #require(!unpinned.fieldCenters.isEmpty)
        #expect(unpinned.fieldCenters == pinned.fieldCenters)
    }

    /// The owner's full-screen case: the list is kept open, the window is full screen and the system's strip is down.
    @Test func aPinnedListInFullScreenSitsBesideThePageAndBelowTheStrip() throws {
        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)
        let coordinator = makeCoordinator()
        defer { coordinator.browser.cancelPendingSave() }
        let inset = SidebarMetrics.pinnedTabListInset(
            isPinned: true, sidebarWidth: coordinator.sidebar.width, container: 1_200, pageSpacing: spacing
        )

        let windowed = layout(style: .minimal, pinned: false, coordinator: coordinator)
        let fullScreen = layout(style: .minimal, pinned: true, strip: strip, coordinator: coordinator)

        let shellTop = try #require(fullScreen.shellTop, "the Minimal shell is hosted")
        #expect(shellTop >= strip, "the shell at \(shellTop) must clear the strip at \(strip)")
        try #require(windowed.fieldCenters.count == fullScreen.fieldCenters.count)
        for (before, after) in zip(windowed.fieldCenters, fullScreen.fieldCenters) {
            #expect(abs(after - before - inset / 2) < 1, "still beside the list: \(before) -> \(after)")
        }
    }
}
