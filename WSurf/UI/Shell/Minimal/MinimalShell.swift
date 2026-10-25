// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// The chrome of the Minimal window style, drawn over the page `BrowserView` lays out: the floating bar, and the tab list
/// that slides in from the left. The tab list is the real sidebar (Favorites, folders, splits, AI marks, profile, downloads,
/// media), floating. Its open state is `AppCoordinator.isMinimalTabListOpen`; the Standard sidebar's state is never touched.
/// Kept open (`BrowserSettings.keepsMinimalSidebarOpen`) the list stays where it slides to, `pinnedInset` wide with its
/// margin, `BrowserView` lays the page out beside it and the bar centers over the page.
///
/// The page is laid out the whole height of the window and the bar floats over its end. So that the end can be read, the
/// bar slides away while the page scrolls down (the wheel, the keyboard or the page's own script, on either engine), and
/// comes back when it scrolls up, when the pointer rests at the bar's edge, and whenever the micro window's rules want the
/// address in sight (`MicroReveal`, `MicroShell.keepsBar`): another site, a prompt, the address being edited.
struct MinimalShell: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator
    /// How far from the window's leading edge the page starts while the tab list is kept open; 0 while it floats.
    var pinnedInset: CGFloat = 0

    @State private var reveal: MicroReveal
    /// Opened by resting the pointer on the left edge, so it closes again when the pointer leaves it or the app.
    @State private var isPeeking = false
    @State private var tabButtonFrame: CGRect = .zero
    @State private var tabListFrame: CGRect = .zero
    @State private var shellFrame: CGRect = .zero
    @State private var peekWatch = PeekWatch()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.titleStripInset) private var titleStripInset

    init(browser: BrowserModel, coordinator: AppCoordinator, pinnedInset: CGFloat = 0) {
        self.browser = browser
        self.coordinator = coordinator
        self.pinnedInset = pinnedInset
        _reveal = State(initialValue: coordinator.makeMinimalReveal())
    }

    private var isPinned: Bool {
        pinnedInset > 0
    }

    private var settings: BrowserSettings {
        BrowserSettings.application
    }

    private var motion: Animation? {
        reduceMotion ? nil : Theme.Motion.settle
    }

    var body: some View {
        let edge = settings.minimalBarEdge
        let spacing = settings.chromeShape.pageSpacing
        let gap = IslandBar.edgeGap(pageSpacing: spacing)

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                MinimalShellSensor(
                    onScroll: { reveal.scrolled(towardTop: $0) },
                    edge: edge,
                    zoneHeight: reveal.isRevealed ? IslandBar.height + gap + 8 : MicroShell.revealBand,
                    onPointerInZone: { reveal.pointer(inZone: $0) },
                    onPointerDown: { closeTabList(unlessAt: $0, height: proxy.size.height + titleStripInset) },
                    pinsWindowControls: coordinator.isMinimalTabListOpen || isPinned
                )
                .allowsHitTesting(false)

                PageScrollWatch(browser: browser) { reveal.scrolled(towardTop: $0) }

                // No toolbar to hold: the gutter above the page moves the window, like the bar's own ground.
                WindowDragArea()
                    .frame(height: max(spacing, 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                IslandBar(browser: browser, coordinator: coordinator, edge: edge) { tabButtonFrame = $0 }
                    .frame(width: IslandBar.width(
                        fullAddress: settings.showsFullAddress || browser.activeTab?.usesDevMode == true,
                        available: proxy.size.width - pinnedInset - 2 * gap
                    ))
                    .padding(edge == .top ? .top : .bottom, gap)
                    .offset(y: reveal.isRevealed ? 0 : (edge == .top ? -1 : 1) * (IslandBar.height + gap + 24))
                    .allowsHitTesting(reveal.isRevealed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
                    .padding(.leading, pinnedInset)

                // Kept open the list is docked, and there is nothing to peek at.
                if PeekEdge.armsTabList(isPinned: isPinned, isTabListOpen: coordinator.isMinimalTabListOpen) {
                    PeekEdgeStrip(coordinator: coordinator) {
                        isPeeking = true
                        coordinator.isMinimalTabListOpen = true
                    }
                } else {
                    tabList(width: SidebarMetrics.clampWidth(coordinator.sidebar.width, container: proxy.size.width), inset: spacing)
                        .transition(.move(edge: .leading))
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shellFrame = $0 }
        .animation(motion, value: coordinator.isMinimalTabListOpen)
        .animation(motion, value: isPinned)
        .animation(motion, value: reveal.isRevealed)
        .onAppear { reveal.start() }
        .onChange(of: browser.activeTab?.id) { old, _ in
            reveal.rest()
            // Picking another tab closes the list; closing the current one leaves it open to pick the next.
            if browser.tabs.contains(where: { $0.id == old }) {
                coordinator.isMinimalTabListOpen = false
            }
        }
        .onChange(of: browser.activeTab?.urlString) { _, _ in reveal.rest() }
        .onChange(of: coordinator.isPaletteOpen) { _, isOpen in
            if isOpen {
                coordinator.isMinimalTabListOpen = false
            }
        }
        .onChange(of: coordinator.isMinimalTabListOpen) { _, isOpen in
            if !isOpen {
                isPeeking = false
            }
        }
        // A list that is kept open is not a peek, even if it was one when it was pinned.
        .onChange(of: isPinned) { _, pinned in
            if pinned {
                isPeeking = false
            }
        }
        .onChange(of: edge) { _, _ in reveal.rest() }
        .onDisappear {
            reveal.stop()
            coordinator.isMinimalTabListOpen = false
        }
    }

    private func tabList(width: CGFloat, inset: CGFloat) -> some View {
        Sidebar(browser: browser, coordinator: coordinator)
            .frame(width: width)
            .environment(\.sidebarStyle, .full)
            .environment(\.sidebarWidth, width)
            .environment(\.sidebarIsFloating, true)
            .clipShape(LoomChrome.canvasShape)
            .compositingGroup()
            // Beside the page the card needs no shadow to tell it apart from the page it floats over.
            .shadow(color: .black.opacity(isPinned ? 0 : 0.45), radius: 22, x: 6)
            .padding(inset)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tabListFrame = $0 }
            .onHover { inside in
                if !inside {
                    closePeekedTabListUnlessPointerOnIt()
                }
            }
            .onChange(of: coordinator.holdsPeek) { _, isHeld in
                if !isHeld {
                    closePeekedTabListUnlessPointerOnIt()
                }
            }
            // A context menu over the list swallows the pointer; when it closes the pointer may be elsewhere.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                closePeekedTabListUnlessPointerOnIt()
            }
            .onChange(of: isPeeking && !isPinned, initial: true) { _, isWatching in
                if isWatching {
                    peekWatch.start(
                        window: coordinator.nativeWindow,
                        check: { closePeekedTabListUnlessPointerOnIt() },
                        onSwitchAway: { closePeekedTabListUnlessPointerOnIt(pointerGone: true) }
                    )
                } else {
                    peekWatch.stop()
                }
            }
            .onDisappear { peekWatch.stop() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Tabs"))
    }

    /// Where the open list sits once it has slid in, in the shell's `.global` space: from the shell's leading edge,
    /// the list and its margin, the shell's height. Worked out from the shell, which does not move, so it holds while
    /// the list is still sliding in under a pointer that rests on the edge.
    static func peekedListFrame(shell: CGRect, sidebarWidth: CGFloat, margin: CGFloat) -> CGRect {
        guard !shell.isEmpty else { return .zero }
        let width = SidebarMetrics.clampWidth(sidebarWidth, container: shell.width)
        return CGRect(x: shell.minX, y: shell.minY, width: width + 2 * margin, height: shell.height)
    }

    /// Closes the list that opened from the edge once the pointer is off it. `pointerGone` is for leaving the app: the
    /// pointer may still be over the list then, but nobody is pointing at it any more.
    private func closePeekedTabListUnlessPointerOnIt(pointerGone: Bool = false) {
        guard PeekExit.endsTabListPeek(
            isPeeking: isPeeking && coordinator.isMinimalTabListOpen,
            isPinned: isPinned,
            isProfileSwitcherOpen: coordinator.holdsPeek,
            pointer: pointerGone ? nil : coordinator.pointerInShell,
            frame: Self.peekedListFrame(
                shell: shellFrame, sidebarWidth: coordinator.sidebar.width, margin: settings.chromeShape.pageSpacing
            )
        ) else { return }
        coordinator.isMinimalTabListOpen = false
    }

    /// A click beside the open list closes it, unless it lands on the bar's tab button (which toggles it itself) or the
    /// profile switcher the list opened. `height` is the window's, strip included: the point is a window point.
    private func closeTabList(unlessAt windowPoint: CGPoint, height: CGFloat) {
        guard coordinator.isMinimalTabListOpen, !coordinator.holdsPeek else { return }
        let point = CGPoint(x: windowPoint.x, y: height - windowPoint.y)
        guard !tabListFrame.contains(point), !tabButtonFrame.contains(point) else { return }
        coordinator.isMinimalTabListOpen = false
    }
}

/// Where the page in front says it is scrolled to (`ScrollPositionMonitor`, the page's own script on either engine, so the
/// keyboard, Find, links to a heading and the page's own scrolling count as much as the wheel). In a view of its own, so a
/// page that scrolls redraws nothing else.
private struct PageScrollWatch: View {
    let browser: BrowserModel
    let onScroll: (Bool) -> Void

    private struct Mark: Equatable {
        var tab: UUID?
        var y: Double
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: Mark(tab: browser.activeTab?.id, y: browser.activeTab?.lastReportedScrollY ?? 0)) { old, new in
                // Another tab is not a scroll; a new document starts again at 0, which reads as scrolling up.
                guard old.tab == new.tab, abs(new.y - old.y) > MinimalShellSensor.ScrollTravel.threshold else { return }
                onScroll(new.y < old.y)
            }
    }
}

extension AppCoordinator {
    /// The Minimal bar's reveal: shown at rest, and held by everything that holds the micro bar, the address being edited,
    /// a prompt, a save offer, a question, VoiceOver, a page with no address to show, plus the open tab list and the setting
    /// being off. A window that is gone, or a state that cannot be read, keeps the bar.
    func makeMinimalReveal() -> MicroReveal {
        // The window the page is drawn in, should the window's host not be known (a view hosted on its own).
        let window: () -> NSWindow? = { [weak self] in self?.nativeWindow ?? self?.browser.activeTab?.liveView?.window }
        return MicroReveal(
            restsRevealed: true,
            window: window,
            host: { [weak self] in MicroShell.host(of: self?.browser.activeTab?.urlString) },
            focusToken: { [weak self] in self?.addressBarFocusToken ?? 0 },
            pending: { [weak self] in self?.hasPendingPagePrompt ?? true },
            keeps: { [weak self] in
                guard let self else { return true }
                return !BrowserSettings.application.hidesMinimalBar
                    || isMinimalTabListOpen
                    || MicroShell.keepsBar(
                        browser: browser,
                        coordinator: self,
                        isEditing: MicroShell.isEditing(in: window()),
                        voiceOver: NSWorkspace.shared.isVoiceOverEnabled
                    )
            }
        )
    }
}
