// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

@MainActor
struct PeekExitTests {
    private let frame = CGRect(x: 0, y: 0, width: 280, height: 800)

    @Test func aPointerOnThePeekKeepsItOpen() {
        #expect(!PeekExit.hasLeft(pointer: CGPoint(x: 4, y: 400), frame: frame))
    }

    @Test func aPointerThatNeverEnteredStillEndsThePeek() {
        #expect(PeekExit.hasLeft(pointer: CGPoint(x: -40, y: 400), frame: frame))
        #expect(PeekExit.hasLeft(pointer: CGPoint(x: 120, y: -10), frame: frame))
    }

    @Test func anUnmeasuredPeekWaitsForItsFrame() {
        #expect(!PeekExit.hasLeft(pointer: CGPoint(x: 600, y: 400), frame: .zero))
    }

    @Test func theResizeEdgeKeepsAPeekOpen() {
        let edge = CGPoint(x: frame.maxX + 7, y: 400)
        #expect(!PeekExit.hasLeft(pointer: edge, frame: frame, trailingReach: PeekExit.resizeReach))
        #expect(PeekExit.hasLeft(pointer: edge, frame: frame))
    }

    @Test func pastTheResizeEdgeThePeekEnds() {
        let past = CGPoint(x: frame.maxX + PeekExit.resizeReach + 1, y: 400)
        #expect(PeekExit.hasLeft(pointer: past, frame: frame, trailingReach: PeekExit.resizeReach))
    }

    @Test func aPeekWithoutAWindowEnds() {
        #expect(PeekExit.hasLeft(pointer: nil, frame: frame))
    }

    /// The resize handle sits in the gutter after the sidebar. It is `LoomChrome.resizeGrabWidth` wide, centred in a gutter
    /// of at most the theme's largest page spacing, so its far edge is inside the reach at every spacing a theme can set.
    @Test func theResizeReachCoversTheHandleAtEveryPageSpacing() {
        for spacing in stride(from: 0.0, through: ThemeAdjustment.pageSpacingRange.upperBound, by: 1) {
            let farEdge = (CGFloat(spacing) + LoomChrome.resizeGrabWidth) / 2
            #expect(farEdge <= PeekExit.resizeReach, "spacing \(spacing)")
        }
    }
}

@MainActor
struct PeekEdgeTests {
    private let strip = CGRect(x: 0, y: 0, width: PeekEdge.width, height: 800)

    @Test func aPointerRestingOnTheEdgeOpensThePeek() {
        #expect(PeekEdge.isHeld(pointer: CGPoint(x: 3, y: 400), frame: strip))
    }

    @Test func aPointerThatCrossedTheEdgeOpensNothing() {
        #expect(!PeekEdge.isHeld(pointer: CGPoint(x: -30, y: 400), frame: strip))
        #expect(!PeekEdge.isHeld(pointer: CGPoint(x: 40, y: 400), frame: strip))
    }

    @Test func anUnknownPointerOrStripOpensNothing() {
        #expect(!PeekEdge.isHeld(pointer: nil, frame: strip))
        #expect(!PeekEdge.isHeld(pointer: CGPoint(x: 3, y: 400), frame: .zero))
    }

    @Test func theSensorRestsFor75Milliseconds() {
        #expect(PeekEdge.dwell == .milliseconds(75))
        #expect(PeekEdge.width == 10)
    }
}

@MainActor
struct PeekWatchTests {
    private let center = NotificationCenter()
    private let window = NSWindow()

    @Test func leavingTheAppChecksThePointer() {
        let watch = PeekWatch(center: center)
        var checks = 0
        watch.start(window: window, check: { checks += 1 })
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(checks == 1)
        watch.stop()
    }

    @Test func leavingTheWindowChecksThePointer() {
        let watch = PeekWatch(center: center)
        var checks = 0
        watch.start(window: window, check: { checks += 1 })
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        center.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
        #expect(checks == 1)
        watch.stop()
    }

    @Test func aStoppedWatchChecksNothing() {
        let watch = PeekWatch(center: center)
        var checks = 0
        var switches = 0
        watch.start(window: window, check: { checks += 1 }, onSwitchAway: { switches += 1 })
        watch.stop()
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(checks == 0)
        #expect(switches == 0)
    }

    @Test func restartingReplacesTheOldWatch() {
        let watch = PeekWatch(center: center)
        var checks = 0
        watch.start(window: window, check: { checks += 1 })
        watch.start(window: window, check: { checks += 1 })
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(checks == 1)
        watch.stop()
    }

    /// Switching to another app ends the peek whatever the pointer is over: it is not a pointer check.
    @Test func switchingAppsEndsThePeekInsteadOfCheckingThePointer() {
        let watch = PeekWatch(center: center)
        var checks = 0
        var switches = 0
        watch.start(window: window, check: { checks += 1 }, onSwitchAway: { switches += 1 })
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(switches == 1)
        #expect(checks == 0)

        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(checks == 1, "another window of this app coming forward is still a pointer check")
        #expect(switches == 1)
        watch.stop()
    }
}

/// What the Standard sidebar and the Minimal tab list do with the pointer, as the decisions the views make.
@MainActor
struct PeekDecisionTests {
    private let sidebar = CGRect(x: 0, y: 32, width: 268, height: 768)
    private let onSidebar = CGPoint(x: 100, y: 300)
    private let pastSidebar = CGPoint(x: 600, y: 300)

    private func sidebarPeek(
        isPeeking: Bool = true,
        isSidebarVisible: Bool = false,
        isResizing: Bool = false,
        isProfileSwitcherOpen: Bool = false,
        pointer: CGPoint?
    ) -> Bool {
        PeekExit.endsSidebarPeek(
            isPeeking: isPeeking,
            isSidebarVisible: isSidebarVisible,
            isResizing: isResizing,
            isProfileSwitcherOpen: isProfileSwitcherOpen,
            pointer: pointer,
            frame: sidebar
        )
    }

    private func tabListPeek(
        isPeeking: Bool = true,
        isPinned: Bool = false,
        isProfileSwitcherOpen: Bool = false,
        pointer: CGPoint?
    ) -> Bool {
        PeekExit.endsTabListPeek(
            isPeeking: isPeeking,
            isPinned: isPinned,
            isProfileSwitcherOpen: isProfileSwitcherOpen,
            pointer: pointer,
            frame: sidebar
        )
    }

    // MARK: - Standard sidebar

    @Test func thePointerLeavingTheSidebarEndsItsPeek() {
        #expect(!sidebarPeek(pointer: onSidebar))
        #expect(sidebarPeek(pointer: pastSidebar))
    }

    @Test func theSidebarStaysWhileItIsBeingResized() {
        #expect(!sidebarPeek(isResizing: true, pointer: pastSidebar), "the handle is dragged far past the sidebar")
        #expect(!sidebarPeek(isResizing: true, pointer: nil))
        #expect(sidebarPeek(isResizing: false, pointer: pastSidebar), "and ends once the drag has")
    }

    @Test func theSidebarStaysWhileTheProfileSwitcherItOpenedIsUp() {
        #expect(!sidebarPeek(isProfileSwitcherOpen: true, pointer: pastSidebar))
        #expect(sidebarPeek(isProfileSwitcherOpen: false, pointer: pastSidebar))
    }

    @Test func aDockedSidebarIsNeverEndedByThePointer() {
        #expect(!sidebarPeek(isSidebarVisible: true, pointer: pastSidebar))
        #expect(!sidebarPeek(isSidebarVisible: true, pointer: nil))
    }

    /// Pointing at the toggle opens the peek. An icons-only peek is 44 pt wide and the toggle sits past the traffic lights,
    /// so the toggle counts as part of the peek or the peek would end under the pointer that opened it.
    @Test func theToggleThatOpenedThePeekKeepsItOpen() {
        let iconsPeek = CGRect(x: 0, y: 0, width: SidebarMetrics.floatingIconsWidth, height: 800)
        let toggle = PeekExit.toggleReach(windowControlsInset: BrowserHost.windowControlsInset, titleStrip: 0)
        let onToggle = CGPoint(x: toggle.midX, y: toggle.midY)

        #expect(!iconsPeek.contains(onToggle), "the toggle is outside an icons-only peek")
        for pointer in [onToggle, CGPoint(x: toggle.minX + 1, y: 1), CGPoint(x: toggle.maxX - 1, y: toggle.maxY - 1)] {
            #expect(!PeekExit.endsSidebarPeek(
                isPeeking: true, isSidebarVisible: false, isResizing: false, isProfileSwitcherOpen: false,
                pointer: pointer, frame: iconsPeek, alsoOn: toggle
            ))
        }
        #expect(PeekExit.endsSidebarPeek(
            isPeeking: true, isSidebarVisible: false, isResizing: false, isProfileSwitcherOpen: false,
            pointer: CGPoint(x: toggle.maxX + 20, y: toggle.midY), frame: iconsPeek, alsoOn: toggle
        ), "beside the toggle the peek ends")
        #expect(PeekExit.endsSidebarPeek(
            isPeeking: true, isSidebarVisible: false, isResizing: false, isProfileSwitcherOpen: false,
            pointer: onToggle, frame: iconsPeek
        ), "and without the toggle's reach it would have")
    }

    @Test func theToggleSitsBelowTheFullScreenStripAndAtTheEdgeWithoutTheTrafficLights() {
        let windowed = PeekExit.toggleReach(windowControlsInset: BrowserHost.windowControlsInset, titleStrip: 0)
        let fullScreen = PeekExit.toggleReach(windowControlsInset: 0, titleStrip: 32)

        #expect(windowed.minX == BrowserHost.windowControlsInset)
        #expect(fullScreen.minX == SidebarMetrics.permanentToggleLeading(windowControlsInset: 0))
        #expect(fullScreen.minY == 32)
        #expect(fullScreen.height == Theme.topBarHeight)
    }

    @Test func aSidebarThatIsNotPeekingHasNothingToEnd() {
        #expect(!sidebarPeek(isPeeking: false, pointer: pastSidebar))
    }

    @Test func leavingTheAppEndsThePeekWithThePointerStillOverTheSidebar() {
        // The views pass no pointer when the app was switched away from.
        #expect(sidebarPeek(pointer: nil))
        #expect(!sidebarPeek(isResizing: true, pointer: nil), "but not in the middle of a resize")
        #expect(!sidebarPeek(isProfileSwitcherOpen: true, pointer: nil), "or under the switcher it opened")
    }

    // MARK: - Minimal tab list

    @Test func thePointerLeavingThePeekedListEndsIt() {
        #expect(!tabListPeek(pointer: onSidebar))
        #expect(tabListPeek(pointer: pastSidebar))
        #expect(tabListPeek(pointer: nil))
    }

    /// The pin ("Keep Sidebar Open") docks the list. A docked list is not a peek and nothing the pointer or the app does
    /// closes it, even if the list was peeking when it was pinned.
    @Test func aListKeptOpenIsNeverEndedByThePointerOrByLeavingTheApp() {
        #expect(!tabListPeek(isPinned: true, pointer: pastSidebar))
        #expect(!tabListPeek(isPinned: true, pointer: nil))
    }

    @Test func aListOpenedFromTheBarIsNotAPeek() {
        #expect(!tabListPeek(isPeeking: false, pointer: pastSidebar))
    }

    @Test func theListStaysUnderTheProfileSwitcherItOpened() {
        #expect(!tabListPeek(isProfileSwitcherOpen: true, pointer: pastSidebar))
    }

    // MARK: - Which edge has a sensor

    @Test func aHiddenStandardSidebarHasASensor() {
        #expect(PeekEdge.armsSidebar(isMinimal: false, isSidebarShowing: false))
    }

    @Test func aShowingStandardSidebarHasNone() {
        #expect(!PeekEdge.armsSidebar(isMinimal: false, isSidebarShowing: true), "docked, or already peeking")
    }

    @Test func theMinimalWindowHasNoStandardSidebarSensor() {
        #expect(!PeekEdge.armsSidebar(isMinimal: true, isSidebarShowing: false))
    }

    @Test func aClosedUnpinnedTabListHasASensor() {
        #expect(PeekEdge.armsTabList(isPinned: false, isTabListOpen: false))
    }

    @Test func aPinnedTabListHasNoSensorSoItNeverPeeks() {
        #expect(!PeekEdge.armsTabList(isPinned: true, isTabListOpen: false))
        #expect(!PeekEdge.armsTabList(isPinned: true, isTabListOpen: true))
    }

    @Test func anOpenTabListHasNoSensor() {
        #expect(!PeekEdge.armsTabList(isPinned: false, isTabListOpen: true))
    }
}

/// The pointer and the frames the sensors measure live in one space, with and without the full-screen title strip.
@MainActor
struct PeekGeometryTests {
    private final class Box {
        var frame = CGRect.zero
    }

    /// The strip's frame as SwiftUI measures it: the sensor in a shell that is laid out `strip` below the window's top, the
    /// way `BrowserView` pads its root.
    private func measuredSensor(strip: CGFloat, windowHeight: CGFloat) -> CGRect {
        let box = Box()
        let shell = ZStack(alignment: .leading) {
            Color.clear
                .frame(width: PeekEdge.width)
                .frame(maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frame = $0 }
        }
        .padding(.top, strip)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: shell)
        host.safeAreaRegions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        return box.frame
    }

    @Test func aWindowPointIsFlippedToTheTopLeft() {
        #expect(PeekEdge.shellPoint(fromWindow: CGPoint(x: 4, y: 700), contentHeight: 800) == CGPoint(x: 4, y: 100))
        #expect(PeekEdge.shellPoint(fromWindow: CGPoint(x: 0, y: 800), contentHeight: 800) == .zero)
    }

    @Test func aCoordinatorWithoutAWindowHasNoPointer() {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.browser.cancelPendingSave() }

        #expect(coordinator.pointerInShell == nil)
    }

    @Test func theSensorIsMeasuredFromTheWindowTopWithoutTheStrip() {
        let frame = measuredSensor(strip: 0, windowHeight: 400)

        #expect(frame == CGRect(x: 0, y: 0, width: PeekEdge.width, height: 400))
    }

    /// Full screen: the shell starts below the system's strip, so the sensor does too, and a pointer in the strip's band
    /// is not on it. A pointer below the band, at the same edge, is.
    @Test func inFullScreenTheSensorStartsBelowTheStripAndThePointerIsMeasuredTheSameWay() {
        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)
        let height: CGFloat = 400
        let frame = measuredSensor(strip: strip, windowHeight: height)

        #expect(frame == CGRect(x: 0, y: strip, width: PeekEdge.width, height: height - strip))

        // `mouseLocationOutsideOfEventStream` has its origin at the bottom-left.
        let inTheBand = PeekEdge.shellPoint(fromWindow: CGPoint(x: 3, y: height - strip / 2), contentHeight: height)
        let belowTheBand = PeekEdge.shellPoint(fromWindow: CGPoint(x: 3, y: height / 2), contentHeight: height)
        #expect(!PeekEdge.isHeld(pointer: inTheBand, frame: frame))
        #expect(PeekEdge.isHeld(pointer: belowTheBand, frame: frame))
    }

    /// The Minimal list is worked out from the shell, so it does not wait for the slide-in to finish: a pointer resting on
    /// the edge that opened it is on it from the first moment.
    @Test func thePeekedListCoversTheEdgeThatOpenedItBelowTheStrip() {
        let strip = BrowserWindowMetrics.fullScreenTitleStrip(isFullScreen: true)
        let shell = CGRect(x: 0, y: strip, width: 1_200, height: 800 - strip)
        let margin: CGFloat = 6

        let list = MinimalShell.peekedListFrame(shell: shell, sidebarWidth: 268, margin: margin)

        #expect(list == CGRect(x: 0, y: strip, width: 268 + 2 * margin, height: 800 - strip))
        #expect(!PeekExit.hasLeft(pointer: CGPoint(x: 3, y: 400), frame: list))
        #expect(PeekExit.hasLeft(pointer: CGPoint(x: 3, y: strip / 2), frame: list), "the strip's band is not the list")
        #expect(PeekExit.hasLeft(pointer: CGPoint(x: list.maxX + 1, y: 400), frame: list))
    }

    @Test func thePeekedListIsClampedLikeTheSidebarAndWaitsForTheShell() {
        let shell = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        let wide = MinimalShell.peekedListFrame(shell: shell, sidebarWidth: 900, margin: 6)
        let unmeasured = MinimalShell.peekedListFrame(shell: .zero, sidebarWidth: 268, margin: 6)

        #expect(wide.width == SidebarMetrics.clampWidth(900, container: 1_000) + 12)
        #expect(unmeasured.isEmpty, "an unmeasured shell leaves no frame to leave")
        #expect(!PeekExit.hasLeft(pointer: CGPoint(x: 900, y: 10), frame: unmeasured))
    }
}

/// Sources that wire the sensors and the watch: nothing may go back to opening a peek by passing over the edge.
@MainActor
struct PeekWiringTests {
    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    @Test func bothShellsOpenAPeekFromTheDwellingSensorOnly() throws {
        let standard = try source("WSurf/UI/Shell/BrowserView.swift")
        let minimal = try source("WSurf/UI/Shell/Minimal/MinimalShell.swift")

        #expect(standard.contains("PeekEdgeStrip(coordinator: coordinator) { sidebar.isPeeking = true }"))
        #expect(minimal.contains("PeekEdgeStrip(coordinator: coordinator) {"))
        for text in [standard, minimal] {
            #expect(!text.contains(".frame(width: 10)"), "the old pass-over strip")
            #expect(!text.contains("edgeSensorWidth"))
        }
        #expect(!minimal.contains("hasEnteredTabList"))
    }

    @Test func bothShellsWatchThePointerOnlyWhileSomethingPeeks() throws {
        let standard = try source("WSurf/UI/Shell/BrowserView.swift")
        let minimal = try source("WSurf/UI/Shell/Minimal/MinimalShell.swift")

        #expect(standard.contains(".onChange(of: sidebar.isFloating, initial: true)"))
        #expect(minimal.contains(".onChange(of: isPeeking && !isPinned, initial: true)"), "never while the list is pinned")
        for text in [standard, minimal] {
            #expect(text.contains("peekWatch.stop()"))
            #expect(text.contains("NSMenu.didEndTrackingNotification"))
            #expect(text.contains("onSwitchAway:"))
        }
    }

    /// `ThemeToolbarInkTests` scans for these three lines together; the peek wiring must not come between them.
    @Test func theInkEnvironmentLinesStayTogether() throws {
        #expect(try source("WSurf/UI/Shell/BrowserView.swift").contains("""
                .environment(\\.chromeWash, .of(nil, isLight: scheme == .light))
                .environment(\\.windowColorScheme, scheme)
                .animation(chromeMotion, value: sidebar.isVisible)
        """))
    }
}
