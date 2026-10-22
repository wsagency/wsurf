// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct BrowserView: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @State private var settingsWorkspace: SettingsWorkspace
    /// The window style to draw; nil follows the app-wide setting. Tests pass one so they never write the setting.
    private let style: BrowserWindowStyle?

    init(browser: BrowserModel, coordinator: AppCoordinator, style: BrowserWindowStyle? = nil) {
        self.browser = browser
        self.coordinator = coordinator
        self.style = style
        let workspace = SettingsWorkspace(coordinator: coordinator)
        workspace.onRoute = { [weak coordinator] category in
            coordinator?.routeSettings(to: category)
        }
        _settingsWorkspace = State(initialValue: workspace)
    }

    private var sidebar: SidebarLayout {
        coordinator.sidebar
    }
    @State private var containerWidth: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMinimal: Bool {
        (style ?? BrowserSettings.application.windowStyle) == .minimal
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
        // The Minimal window has no docked sidebar and no toolbar: the page and the side panel take the whole window.
        let docksSidebar = sidebar.isVisible && !isMinimal
        let width = sidebar.openWidth(in: containerWidth)
        let roomBesideSidebar = containerWidth - (docksSidebar ? width : 0)
        let isExpanded = showsPanel && panel.isExpanded
        let spacing = BrowserSettings.application.chromeShape.pageSpacing
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
            LoomAmbientBackdrop(
                sampledPageColor: ChromeBand.pageColor(
                    browser: browser,
                    coordinator: coordinator
                ),
                settings: BrowserSettings.application
            )

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
                MinimalShell(browser: browser, coordinator: coordinator)
                    .transition(.opacity)
            } else {
                standardChrome(width: width, shell: shell, spacing: spacing)
                    .transition(.opacity)
            }

            TabPreviewOverlay(
                browser: browser,
                model: coordinator.tabPreview,
                sidebarEdge: sidebarEdge(width: width, isMinimal: isMinimal)
            )

            SidebarDragOverlay(browser: browser, model: coordinator.sidebarDrag)
                .environment(\.sidebarStyle, isMinimal ? .full : sidebar.style)

            DownloadFlightLayer(flights: coordinator.downloadFlights)
                .environment(\.sidebarStyle, isMinimal ? .full : sidebar.style)

            PaneDragOverlay(browser: browser, model: coordinator.sidebarDrag)
                .environment(\.sidebarStyle, isMinimal ? .full : sidebar.style)

            if !isMinimal && !sidebar.isShowing {
                Color.clear
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { if $0 { sidebar.isPeeking = true } }
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
                        .padding(.bottom, max(0, proxy.size.height - anchor.minY + 6))
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
        .environment(\.profileFavicons, coordinator.context.favicons)
        .environment(\.assistantProviderID, coordinator.selectedProvider.id)
        .environment(\.chromeIsLight, scheme == .light)
        .environment(\.chromeWash, .of(nil, isLight: scheme == .light))
        .environment(\.windowColorScheme, scheme)
        .animation(chromeMotion, value: sidebar.isVisible)
        .animation(reduceMotion ? nil : chromeMotion, value: isMinimal)
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
            .offset(x: sidebar.isShowing ? 0 : -(width + 24))
            .onHover { inside in
                if !sidebar.isVisible, !inside {
                    sidebar.isPeeking = false
                }
            }

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

    /// Where tab previews open: beside the Standard sidebar while it shows, or beside the Minimal tab list while it is open.
    private func sidebarEdge(width: CGFloat, isMinimal: Bool) -> CGFloat {
        guard isMinimal else { return sidebar.isShowing ? width : 0 }
        guard coordinator.isMinimalTabListOpen else { return 0 }
        let spacing = BrowserSettings.application.chromeShape.pageSpacing
        return SidebarMetrics.clampWidth(sidebar.width, container: containerWidth) + 2 * spacing
    }

    /// The find bar sits 10 pt below the page's top, or below the Minimal bar when it floats at the top.
    private func findBarTop(isMinimal: Bool, spacing: CGFloat) -> CGFloat {
        guard isMinimal, BrowserSettings.application.minimalBarEdge == .top else { return 10 }
        return IslandBar.edgeGap(pageSpacing: spacing) + IslandBar.height + 10 - spacing
    }
}
