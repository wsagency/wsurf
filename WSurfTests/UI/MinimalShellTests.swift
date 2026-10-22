// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The Minimal window style: its sensor, its bar and its tab list. Views take the style as an input, so no case writes the
/// app-wide setting.
@MainActor
struct MinimalShellTests {
    private typealias Travel = MinimalShellSensor.ScrollTravel

    // MARK: - Scroll travel (ported from Linen)

    @Test func aSmallScrollMovesNothing() {
        var travel = Travel()

        #expect(travel.add(6, beginsGesture: true) == nil)
        #expect(travel.add(6, beginsGesture: false) == nil)
    }

    @Test func scrollingPastTheThresholdReportsItsDirectionOnce() {
        var travel = Travel()

        #expect(travel.add(10, beginsGesture: true) == nil)
        #expect(travel.add(10, beginsGesture: false) == true)
        #expect(travel.add(10, beginsGesture: false) == nil, "the distance starts again after a report")

        var down = Travel()
        #expect(down.add(-20, beginsGesture: true) == false)
    }

    @Test func turningBackStartsTheDistanceAgain() {
        var travel = Travel()

        #expect(travel.add(12, beginsGesture: true) == nil)
        #expect(travel.add(-12, beginsGesture: false) == nil, "12 up and 12 down do not add up")
        #expect(travel.add(-4, beginsGesture: false) == false)
    }

    @Test func aNewGestureForgetsTheLastOne() {
        var travel = Travel()

        #expect(travel.add(12, beginsGesture: true) == nil)
        #expect(travel.add(12, beginsGesture: true) == nil)
    }

    // MARK: - Traffic lights

    private func window(with sensor: MinimalShellSensor.SensorView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        sensor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.addSubview(sensor)
        return window
    }

    private func controlsHidden(in window: NSWindow) -> [Bool] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0)?.isHidden }
    }

    @Test func theSensorHidesTheWindowControlsUntilTheyArePinned() {
        let sensor = MinimalShellSensor.SensorView()
        let window = window(with: sensor)
        defer {
            sensor.removeFromSuperview()
            window.close()
        }

        #expect(controlsHidden(in: window) == [true, true, true])

        sensor.pinsWindowControls = true
        #expect(controlsHidden(in: window) == [false, false, false])

        sensor.pinsWindowControls = false
        #expect(controlsHidden(in: window) == [true, true, true])
    }

    @Test func leavingTheWindowGivesTheControlsBack() {
        let sensor = MinimalShellSensor.SensorView()
        let window = window(with: sensor)
        defer { window.close() }

        sensor.removeFromSuperview()

        #expect(controlsHidden(in: window) == [false, false, false])
    }

    // MARK: - The bar

    @Test func theBarIsAsWideAsItsAddressNeedsAndNoWiderThanTheWindow() {
        #expect(IslandBar.width(fullAddress: false, available: 2_000) == 720)
        #expect(IslandBar.width(fullAddress: true, available: 2_000) == 860)
        #expect(IslandBar.width(fullAddress: true, available: 500) == 500)
        #expect(IslandBar.width(fullAddress: false, available: -20) == 0)
    }

    @Test func theBarFollowsTheThemesSpacingAndCorners() {
        #expect(IslandBar.edgeGap(pageSpacing: LoomChrome.canvasInset) == 14, "Linen's gap at the default spacing")
        #expect(IslandBar.edgeGap(pageSpacing: 0) == 8)
        #expect(IslandBar.cornerRadius(cornerScale: 1) == IslandBar.height / 2, "a capsule by default")
        #expect(IslandBar.cornerRadius(cornerScale: 1.5) == IslandBar.height / 2, "never rounder than a capsule")
        #expect(IslandBar.cornerRadius(cornerScale: 0.5) == IslandBar.height / 4)
        #expect(IslandBar.cornerRadius(cornerScale: 0) == 0, "square corners stay square")
    }

    @Test func theTabButtonShowsHowManyTabsAreOpen() {
        #expect(IslandBar.tabCountSymbol(1) == "1.square")
        #expect(IslandBar.tabCountSymbol(50) == "50.square")
        #expect(IslandBar.tabCountSymbol(0) == "square.on.square")
        #expect(IslandBar.tabCountSymbol(51) == "square.on.square")
    }

    /// The owner's list for the Minimal bar: what the toolbar and the address carry has to be there too. The address is the
    /// toolbar's own Ask surface, so its row's badges, its question block and its engine badge come with it.
    @Test func theBarCarriesEveryControlTheToolbarAndAddressHave() throws {
        let island = try source("WSurf/UI/Shell/Minimal/IslandBar.swift")
        for control in [
            "AskSurface(placement: .toolbar", "ToolbarNavigationControls(", "ExternalControlMark(",
            "ExternalConnectionBadge(", "SidebarDownloadsButton(", "StoreInstallButton(", "ExtensionActionsCluster(",
            "SidePanelToggle(",
        ] {
            #expect(island.contains(control), "\(control)")
        }
        let row = try source("WSurf/UI/Ask/AskSurfaceRow.swift")
        for badge in [
            "AutofillSaveBadge(", "InputHistoryBadge(", "TranslationBadge(", "ReaderBadge(", "SiteControlsMenu(",
            "PermissionBadge(", "TabAudioBadge(",
        ] {
            #expect(row.contains(badge), "\(badge)")
        }
        #expect(try source("WSurf/UI/Ask/AskSurface.swift").contains("AskQuestionBlock("))
        #expect(try source("WSurf/UI/Ask/AskSurfaceAppearance.swift").contains(#"engine == .webKit ? "WK" : "Cr""#))
    }

    // MARK: - The tab list and switching

    @Test func theTabListNeverChangesTheStandardSidebar() throws {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.browser.cancelPendingSave() }
        let sidebar = coordinator.sidebar
        let (visible, peeking, style, width) = (sidebar.isVisible, sidebar.isPeeking, sidebar.style, sidebar.width)
        let (host, window) = hosted(MinimalShell(browser: coordinator.browser, coordinator: coordinator))
        defer { window.close() }

        for open in [true, false, true] {
            coordinator.isMinimalTabListOpen = open
            host.layoutSubtreeIfNeeded()
            #expect(sidebar.isVisible == visible && sidebar.isPeeking == peeking)
            #expect(sidebar.style == style && sidebar.width == width)
        }
    }

    @Test func switchingTheWindowStyleKeepsEveryTabAndTheSidePanel() throws {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        let browser = coordinator.browser
        defer { browser.cancelPendingSave() }
        for _ in 0..<5 {
            _ = browser.newTab(activate: false)
        }
        let tabs = browser.tabs.map(\.id)
        let active = browser.activeTabID
        coordinator.sidePanel.toggle(.activity)
        let panelVisible = coordinator.sidePanel.isVisible
        let sidebarVisible = coordinator.sidebar.isVisible

        let (host, window) = hosted(BrowserView(browser: browser, coordinator: coordinator, style: .standard))
        defer { window.close() }
        for style in [BrowserWindowStyle.minimal, .standard, .minimal] {
            host.rootView = AnyView(BrowserView(browser: browser, coordinator: coordinator, style: style))
            host.layoutSubtreeIfNeeded()
            #expect(browser.tabs.map(\.id) == tabs)
            #expect(browser.activeTabID == active)
            #expect(coordinator.sidePanel.isVisible == panelVisible)
            #expect(coordinator.sidebar.isVisible == sidebarVisible, "the Standard sidebar keeps its own state")
        }
    }

    @Test func hideSidebarOpensTheTabListInTheMinimalWindowOnly() {
        let minimal = CommandPaletteCatalog.commands(
            context: CommandPaletteContext(isSidebarVisible: false, isMinimal: true),
            perform: { _ in }
        )
        let standard = CommandPaletteCatalog.commands(context: CommandPaletteContext(), perform: { _ in })

        #expect(minimal.first { $0.id == "action-toggleSidebar" }?.title == String(localized: "Show Tabs"))
        #expect(minimal.first { $0.id == "action-toggleWindowStyle" }?.title == String(localized: "Use Standard Window Style"))
        #expect(standard.first { $0.id == "action-toggleSidebar" }?.title == String(localized: "Hide Sidebar"))
        #expect(standard.first { $0.id == "action-toggleWindowStyle" }?.title == String(localized: "Use Minimal Window Style"))
        #expect(standard.first { $0.id == "action-toggleWindowStyle" }?.shortcut == "⇧⌘M")
    }

    // MARK: - Helpers

    private func hosted(_ view: some View) -> (NSHostingView<AnyView>, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func source(_ path: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
