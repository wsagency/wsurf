// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

struct BrowserView: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @State private var lazySettingsWorkspace = LazySettingsWorkspace()
    /// The window style to draw; nil follows the app-wide setting. Tests pass one so they never write the setting.
    private let style: BrowserWindowStyle?
    /// Whether the Minimal tab list is kept open; nil follows the app-wide setting. Tests pass one for the same reason.
    private let keepsSidebarOpen: Bool?

    init(
        browser: BrowserModel,
        coordinator: AppCoordinator,
        style: BrowserWindowStyle? = nil,
        keepsSidebarOpen: Bool? = nil
    ) {
        self.browser = browser
        self.coordinator = coordinator
        self.style = style
        self.keepsSidebarOpen = keepsSidebarOpen
    }

    private var settingsWorkspace: SettingsWorkspace {
        lazySettingsWorkspace.workspace(for: coordinator)
    }

    private var sidebar: SidebarLayout {
        coordinator.sidebar
    }
    @State private var containerWidth: CGFloat = 0
    @State private var sidebarFrame: CGRect = .zero
    @State private var peekWatch = PeekWatch()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.titleStripInset) private var titleStripInset

    private var isMinimal: Bool {
        (style ?? BrowserSettings.application.windowStyle) == .minimal
    }

    /// The Minimal window docks its tab list beside the page instead of floating it over the page.
    private var pinsTabList: Bool {
        isMinimal && (keepsSidebarOpen ?? BrowserSettings.application.keepsMinimalSidebarOpen)
    }

    private var chromeSitsOnALightPage: Bool {
        PageInk.isLight(
            ChromeBand.pageColor(browser: browser, coordinator: coordinator),
            scheme: scheme
        )
    }

    private var panel: SidePanelModel {
        coordinator.sidePanel
    }
    private var showsPanel: Bool {
        panel.isVisible
    }

    private var chromeMotion: Animation? {
        coordinator.isSwitchingProfile ? nil : Theme.Motion.settle
    }

    var body: some View {
        let isMinimal = self.isMinimal
        // The Minimal window has no toolbar and no Standard sidebar: the page and the side panel take the whole window,
        // beside its tab list while that is kept open.
        let isExpanded = showsPanel && panel.isExpanded
        let spacing = BrowserSettings.application.chromeShape.pageSpacing
        let pinsTabList = self.pinsTabList
        let docksSidebar = isMinimal ? pinsTabList : sidebar.isVisible
        let width = isMinimal
            ? SidebarMetrics.pinnedTabListInset(
                isPinned: pinsTabList, sidebarWidth: sidebar.width, container: containerWidth, pageSpacing: spacing
            )
            : sidebar.openWidth(in: containerWidth)
        let roomBesideSidebar = containerWidth - (docksSidebar ? width : 0)
        let top = isMinimal ? spacing : LoomChrome.canvasTop
        let shell = LoomShellGeometry(
            containerWidth: containerWidth,
            sidebarWidth: width,
            preferredPanelWidth: panel.openWidth(in: roomBesideSidebar),
            isSidebarVisible: docksSidebar,
            isPanelVisible: showsPanel,
            isPanelExpanded: isExpanded,
            pageSpacing: spacing
        )

        ZStack(alignment: .leading) {
            ContentArea(
                browser: browser,
                coordinator: coordinator,
                settingsWorkspace: settingsWorkspace,
                canvasTrailingInset: shell.canvasTrailingInset,
                isFullHeight: isMinimal,
                findBarTop: findBarTop(isMinimal: isMinimal, spacing: spacing)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, docksSidebar ? width : 0)

            SidePanelSurface(
                browser: browser,
                coordinator: coordinator
            )
            .frame(width: shell.panelWidth)
            .padding(.top, top)
            .padding(.trailing, spacing)
            .padding(.bottom, spacing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(x: showsPanel ? 0 : shell.panelWidth + spacing + 24)

            if showsPanel && !isExpanded {
                LoomColumnResizeHandle(
                    grabWidth: LoomChrome.resizeGrabWidth,
                    onLightPage: chromeSitsOnALightPage,
                    isDragging: panel.isDragging,
                    onDragChanged: {
                        panel.dragChanged(translation: $0, available: roomBesideSidebar)
                    },
                    onDragEnded: {
                        panel.dragEnded(translation: $0, available: roomBesideSidebar)
                    },
                    onReset: { panel.resetWidth() }
                )
                .padding(.top, top)
                .padding(.bottom, spacing)
                .offset(x: shell.panelResizeLeading)
            }

            if isMinimal {
                MinimalShell(browser: browser, coordinator: coordinator, pinnedInset: docksSidebar ? width : 0)
                    .transition(.opacity)
            } else {
                standardChrome(width: width, shell: shell, spacing: spacing)
                    .transition(.opacity)
            }

            TabPreviewOverlay(
                browser: browser,
                model: coordinator.tabPreview,
                sidebarEdge: sidebarEdge(width: width, isMinimal: isMinimal, isPinned: pinsTabList)
            )

            SidebarDragOverlay(browser: browser, model: coordinator.sidebarDrag)
                .environment(\.sidebarStyle, isMinimal ? .full : sidebar.style)

            // Flights fly between window points, so the layer is lifted back to the window's top.
            DownloadFlightLayer(flights: coordinator.downloadFlights)
                .environment(\.sidebarStyle, isMinimal ? .full : sidebar.style)
                .offset(y: -titleStripInset)

            PaneDragOverlay(browser: browser, model: coordinator.sidebarDrag)
                .environment(\.sidebarStyle, isMinimal ? .full : sidebar.style)

            if PeekEdge.armsSidebar(isMinimal: isMinimal, isSidebarShowing: sidebar.isShowing) {
                PeekEdgeStrip(coordinator: coordinator) { sidebar.isPeeking = true }
            }

            if coordinator.isPaletteOpen {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.35)
                            .contentShape(Rectangle())
                            .onTapGesture { coordinator.closePalette() }

                        CommandPalette(
                            browser: browser,
                            coordinator: coordinator,
                            containerSize: proxy.size
                        ) {
                            coordinator.closePalette()
                        }
                        .id(coordinator.paletteToken)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }

            if coordinator.isProfileSwitcherOpen, let anchor = coordinator.profileButtonFrame {
                GeometryReader { proxy in
                    ZStack(alignment: .bottomLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { coordinator.isProfileSwitcherOpen = false }

                        ProfileSwitcher(coordinator: coordinator) {
                            coordinator.isProfileSwitcherOpen = false
                        }
                        .padding(.leading, anchor.minX)
                        .padding(.bottom, max(0, proxy.size.height + titleStripInset - anchor.minY + 6))
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }

            if coordinator.onboarding.isPresented {
                OnboardingOverlay(coordinator: coordinator, model: coordinator.onboarding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Full screen: every layout starts below the system's title strip; the backdrop still fills the window.
        .padding(.top, titleStripInset)
        .background {
            LoomAmbientBackdrop(
                sampledPageColor: ChromeBand.pageColor(
                    browser: browser,
                    coordinator: coordinator
                ),
                settings: BrowserSettings.application
            )
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { frame in
            containerWidth = frame.width
            coordinator.noteShellFrame(frame)
        }
        .background(Color.clear)
        .onChange(of: ObjectIdentifier(browser.context)) { _, _ in
            settingsWorkspace.adoptProfile(coordinator: coordinator)
        }
        .modifier(TranslationDownloadHost(downloads: coordinator.translationDownloads))
        // Switches, sliders and progress bars, in the page chrome and in Settings, take the theme's accent. A theme
        // without one keeps the macOS accent color.
        .tint(Theme.systemAccent)
        .environment(\.profileFavicons, coordinator.context.favicons)
        .environment(\.assistantProviderID, coordinator.selectedProvider.id)
        .environment(\.chromeIsLight, scheme == .light)
        .environment(\.chromeWash, .of(nil, isLight: scheme == .light))
        .environment(\.windowColorScheme, scheme)
        .animation(chromeMotion, value: sidebar.isVisible)
        .animation(chromeMotion, value: pinsTabList)
        .animation(
            BrowserSettings.application.skipsTransitions(reduceMotion: reduceMotion) ? nil : chromeMotion, value: isMinimal
        )
        .animation(nil, value: sidebar.isPeeking)
        .animation(chromeMotion, value: showsPanel)
        .animation(chromeMotion, value: panel.isExpanded)
        .animation(
            coordinator.isPaletteOpen ? Theme.Motion.quick : nil, value: coordinator.isPaletteOpen
        )
        .animation(
            coordinator.isProfileSwitcherOpen ? Theme.Motion.quick : nil,
            value: coordinator.isProfileSwitcherOpen
        )

        .animation(nil, value: coordinator.onboarding.isPresented)
    }

    /// The toolbar, the docked or peeking sidebar with its resize handle, and the sidebar toggle.
    private func standardChrome(width: CGFloat, shell: LoomShellGeometry, spacing: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ContentNavBar(browser: browser, coordinator: coordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.leading, sidebar.isVisible ? width : 0)

            Sidebar(
                browser: browser,
                coordinator: coordinator
            )
            .frame(width: width)
            .environment(\.sidebarStyle, sidebar.style)
            .environment(\.sidebarWidth, width)
            .environment(\.sidebarIsFloating, sidebar.isFloating)
            .compositingGroup()
            .shadow(
                color: .black.opacity(sidebar.isFloating ? 0.45 : 0),
                radius: 22,
                x: 6
            )
            // Measured inside the offset, so it is where the sidebar is drawn, not where it is parked.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sidebarFrame = $0 }
            .offset(x: sidebar.isShowing ? 0 : -(width + 24))
            .onHover { inside in
                if !inside {
                    endPeekUnlessPointerOnSidebar()
                }
            }
            .onChange(of: coordinator.holdsPeek) { _, isHeld in
                if !isHeld {
                    endPeekUnlessPointerOnSidebar()
                }
            }
            // A context menu over the peek swallows the pointer; when it closes the pointer may be elsewhere.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                endPeekUnlessPointerOnSidebar()
            }
            .onChange(of: sidebar.isFloating, initial: true) { _, isFloating in
                if isFloating {
                    peekWatch.start(
                        window: coordinator.nativeWindow,
                        check: { endPeekUnlessPointerOnSidebar() },
                        onSwitchAway: { endPeekUnlessPointerOnSidebar(pointerGone: true) }
                    )
                } else {
                    peekWatch.stop()
                }
            }
            .onDisappear { peekWatch.stop() }

            if sidebar.isShowing {
                LoomColumnResizeHandle(
                    grabWidth: LoomChrome.resizeGrabWidth,
                    onLightPage: chromeSitsOnALightPage,
                    isDragging: sidebar.isDragging,
                    onDragChanged: {
                        sidebar.dragChanged(translation: $0, container: containerWidth)
                    },
                    onDragEnded: {
                        sidebar.dragEnded(translation: $0, container: containerWidth)
                    },
                    onReset: { sidebar.resetWidth() }
                )
                .padding(.top, LoomChrome.canvasTop)
                .padding(.bottom, spacing)
                .offset(
                    x: shell.sidebarResizeLeading
                )
            }

            SidebarVisibilityToggle(browser: browser, coordinator: coordinator)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Ends the Standard sidebar's peek once the pointer is off it. `pointerGone` is for leaving the app: the pointer
    /// may still be over the sidebar then, but nobody is pointing at it any more.
    private func endPeekUnlessPointerOnSidebar(pointerGone: Bool = false) {
        guard PeekExit.endsSidebarPeek(
            isPeeking: sidebar.isPeeking,
            isSidebarVisible: sidebar.isVisible,
            isResizing: sidebar.isDragging,
            isProfileSwitcherOpen: coordinator.holdsPeek,
            pointer: pointerGone ? nil : coordinator.pointerInShell,
            frame: sidebarFrame,
            // Read from the coordinator, not the environment: the watch calls this long after the body that made it.
            alsoOn: PeekExit.toggleReach(
                windowControlsInset: coordinator.windowControlsInset, titleStrip: coordinator.titleStripInset
            )
        ) else { return }
        sidebar.isPeeking = false
    }

    /// Where tab previews open: beside the Standard sidebar while it shows, or beside the Minimal tab list while it is open
    /// or kept open.
    private func sidebarEdge(width: CGFloat, isMinimal: Bool, isPinned: Bool) -> CGFloat {
        guard isMinimal else { return sidebar.isShowing ? width : 0 }
        guard isPinned || coordinator.isMinimalTabListOpen else { return 0 }
        let spacing = BrowserSettings.application.chromeShape.pageSpacing
        return SidebarMetrics.clampWidth(sidebar.width, container: containerWidth) + 2 * spacing
    }

    /// The find bar sits 10 pt below the page's top, or below the Minimal bar when it floats at the top.
    private func findBarTop(isMinimal: Bool, spacing: CGFloat) -> CGFloat {
        guard isMinimal, BrowserSettings.application.minimalBarEdge == .top else { return 10 }
        return IslandBar.edgeGap(pageSpacing: spacing) + IslandBar.height + 10 - spacing
    }
}
