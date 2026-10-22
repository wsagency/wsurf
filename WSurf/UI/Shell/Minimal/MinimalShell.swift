// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// The chrome of the Minimal window style, drawn over the page `BrowserView` lays out: the floating bar, and the tab list
/// that slides in from the left. The tab list is the real sidebar (Favorites, folders, splits, AI marks, profile, downloads,
/// media), floating. Its open state is `AppCoordinator.isMinimalTabListOpen`; the Standard sidebar's state is never touched.
struct MinimalShell: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @State private var isIslandRaised = true
    /// Opened by pointing at the left edge, so it closes again when the pointer leaves it.
    @State private var isPeeking = false
    @State private var hasEnteredTabList = false
    @State private var tabButtonFrame: CGRect = .zero
    @State private var tabListFrame: CGRect = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.titleStripInset) private var titleStripInset

    private static let edgeSensorWidth: CGFloat = 10

    private var settings: BrowserSettings {
        BrowserSettings.application
    }

    private var motion: Animation? {
        reduceMotion ? nil : Theme.Motion.settle
    }

    /// While the bar says something, it stays: listening, a reply, a notice, a status or a question.
    private var chromeIsBusy: Bool {
        coordinator.state == .listening
            || coordinator.statusMessage != nil
            || coordinator.notice != nil
            || coordinator.agentReply.message(inAnchor: browser.activeAnchorID) != nil
            || coordinator.pendingAgentQuestion(inChrome: true) != nil
    }

    var body: some View {
        let edge = settings.minimalBarEdge
        let spacing = settings.chromeShape.pageSpacing
        let gap = IslandBar.edgeGap(pageSpacing: spacing)

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                MinimalShellSensor(
                    onScroll: { towardTop in
                        guard settings.hidesMinimalBar, !chromeIsBusy, !coordinator.isMinimalTabListOpen else { return }
                        raiseIsland(towardTop)
                    },
                    onEdge: { if $0 == edge { raiseIsland(true) } },
                    onPointerDown: { closeTabList(unlessAt: $0, height: proxy.size.height + titleStripInset) },
                    pinsWindowControls: coordinator.isMinimalTabListOpen
                )
                .allowsHitTesting(false)

                // No toolbar to hold: the gutter above the page moves the window, like the bar's own ground.
                WindowDragArea()
                    .frame(height: max(spacing, 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                IslandBar(browser: browser, coordinator: coordinator, edge: edge) { tabButtonFrame = $0 }
                    .frame(width: IslandBar.width(
                        fullAddress: settings.showsFullAddress,
                        available: proxy.size.width - 2 * gap
                    ))
                    .padding(edge == .top ? .top : .bottom, gap)
                    .offset(y: isIslandRaised ? 0 : (edge == .top ? -1 : 1) * (IslandBar.height + gap + 24))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)

                if coordinator.isMinimalTabListOpen {
                    tabList(width: SidebarMetrics.clampWidth(coordinator.sidebar.width, container: proxy.size.width), inset: spacing)
                        .transition(.move(edge: .leading))
                } else {
                    Color.clear
                        .frame(width: Self.edgeSensorWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            guard inside else { return }
                            isPeeking = true
                            coordinator.isMinimalTabListOpen = true
                        }
                        .accessibilityHidden(true)
                }
            }
        }
        .animation(motion, value: coordinator.isMinimalTabListOpen)
        .animation(motion, value: isIslandRaised)
        .onChange(of: browser.activeTab?.id) { old, _ in
            raiseIsland(true)
            // Picking another tab closes the list; closing the current one leaves it open to pick the next.
            if browser.tabs.contains(where: { $0.id == old }) {
                coordinator.isMinimalTabListOpen = false
            }
        }
        .onChange(of: browser.activeTab?.urlString) { _, _ in raiseIsland(true) }
        .onChange(of: coordinator.isPaletteOpen) { _, isOpen in
            if isOpen {
                coordinator.isMinimalTabListOpen = false
            }
        }
        .onChange(of: coordinator.isMinimalTabListOpen) { _, isOpen in
            if !isOpen {
                isPeeking = false
                hasEnteredTabList = false
            }
        }
        .onChange(of: coordinator.addressBarFocusToken) { _, _ in raiseIsland(true) }
        .onChange(of: chromeIsBusy) { _, busy in
            if busy {
                raiseIsland(true)
            }
        }
        .onChange(of: settings.hidesMinimalBar) { _, hides in
            if !hides {
                raiseIsland(true)
            }
        }
        .onChange(of: edge) { _, _ in raiseIsland(true) }
        .onDisappear { coordinator.isMinimalTabListOpen = false }
    }

    private func tabList(width: CGFloat, inset: CGFloat) -> some View {
        Sidebar(browser: browser, coordinator: coordinator)
            .frame(width: width)
            .environment(\.sidebarStyle, .full)
            .environment(\.sidebarWidth, width)
            .environment(\.sidebarIsFloating, true)
            .clipShape(LoomChrome.canvasShape)
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 22, x: 6)
            .padding(inset)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tabListFrame = $0 }
            .onHover { inside in
                if inside {
                    hasEnteredTabList = true
                } else if isPeeking, hasEnteredTabList, !coordinator.isProfileSwitcherOpen {
                    coordinator.isMinimalTabListOpen = false
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Tabs"))
    }

    /// A click beside the open list closes it, unless it lands on the bar's tab button (which toggles it itself) or the
    /// profile switcher the list opened. `height` is the window's, strip included: the point is a window point.
    private func closeTabList(unlessAt windowPoint: CGPoint, height: CGFloat) {
        guard coordinator.isMinimalTabListOpen, !coordinator.isProfileSwitcherOpen else { return }
        let point = CGPoint(x: windowPoint.x, y: height - windowPoint.y)
        guard !tabListFrame.contains(point), !tabButtonFrame.contains(point) else { return }
        coordinator.isMinimalTabListOpen = false
    }

    private func raiseIsland(_ raised: Bool) {
        guard raised != isIslandRaised else { return }
        isIslandRaised = raised
    }
}
