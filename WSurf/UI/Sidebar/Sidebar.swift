// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI
import WSurfCore

struct Sidebar: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    private var sidebar: SidebarLayout {
        coordinator.sidebar
    }

    @Environment(\.windowControlsInset) private var windowControlsInset
    @Environment(\.sidebarStyle) private var sidebarStyle
    /// A peeking sidebar, or the Minimal window's tab list: it draws its own ground over the page.
    @Environment(\.sidebarIsFloating) private var isFloating
    @Environment(\.colorScheme) private var scheme
    @State private var bottomObscuredHeight: CGFloat = 0
    @State private var newFolderDrop = SidebarNewFolderDrop()
    @State private var pinDrop = SidebarPinDrop()
    /// The install ID of the other device whose tabs are shown, or nil for This Mac.
    @State private var shownDevice: String?

    private var selection: SidebarSelection {
        browser.sidebarSelection
    }

    private var frames: SidebarFrames {
        coordinator.sidebarDrag.frames
    }

    private var wearsBand: Bool {
        sidebarStyle == .icons
    }

    private var inkColor: NSColor {
        LoomChrome.sampledColor(
            ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
            scheme: scheme
        )
    }

    /// What the sidebar surface really is: a preset colors a floating sidebar differently from the window.
    private var groundColor: NSColor {
        LoomChrome.sampledColor(
            ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
            scheme: scheme,
            isFloating: isFloating
        )
    }

    private var inkIsLight: Bool {
        if !coordinator.isShowingSettings {
            return PageInk.isLight(
                LoomChrome.sampledColor(
                    ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
                    scheme: scheme
                ),
                scheme: scheme
            )
        }
        guard wearsBand else { return scheme == .light }
        return PageInk.isLight(
            ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
            scheme: scheme
        )
    }

    private var topPadding: CGFloat {
        guard windowControlsInset > 0 else { return 10 }
        return sidebarStyle == .icons ? Theme.topBarHeight : 8
    }

    private var contentInsets: EdgeInsets {
        let shape = BrowserSettings.application.chromeShape
        return SidebarMetrics.contentInsets(
            style: sidebarStyle,
            isFloating: isFloating,
            margin: shape.sidebarMargin,
            pageSpacing: shape.pageSpacing
        )
    }

    private func topBar(remote: [RemoteDeviceSession]) -> SidebarTopChrome {
        SidebarTopChrome(
            browser: browser,
            coordinator: coordinator,
            selection: selection,
            newFolderDrop: newFolderDrop,
            pinDrop: pinDrop,
            remote: remote,
            shownDevice: $shownDevice
        )
    }

    /// The bottom chrome of either list. A remote device's list has no spaces, so its switcher is left out.
    private func bottomBar(showsSpaces: Bool) -> SidebarBottomChrome {
        SidebarBottomChrome(
            coordinator: coordinator,
            obscuredHeight: $bottomObscuredHeight,
            showsSpaceSwitcher: showsSpaces
        )
    }

    var body: some View {
        let remote = CloudTabs.shared?.remoteSessions(for: coordinator.context.profile) ?? []
        let shown = sidebarStyle == .full ? SidebarDeviceFilter.shown(shownDevice, in: remote) : nil
        Group {
            if let shown {
                RemoteSessionList(
                    session: shown,
                    coordinator: coordinator,
                    bottomClearance: bottomObscuredHeight,
                    topBar: topBar(remote: remote),
                    bottomBar: bottomBar(showsSpaces: false),
                    contentInsets: contentInsets,
                    onOpen: { shownDevice = nil }
                )
            } else {
                WorkspaceList(
                    browser: browser,
                    coordinator: coordinator,
                    selection: selection,
                    newFolderDrop: newFolderDrop,
                    pinDrop: pinDrop,
                    frames: frames,
                    bottomClearance: bottomObscuredHeight,
                    topBar: topBar(remote: remote),
                    bottomBar: bottomBar(showsSpaces: coordinator.showsSpaceSwitcher),
                    contentInsets: contentInsets
                )
                .background {
                    if coordinator.showsSpaceSwitcher {
                        SpaceSwipeCatcher { coordinator.switchSpace(by: $0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 12)
        .padding(.top, topPadding)
        .background {
            ZStack {
                if isFloating {
                    LoomFloatingFill(
                        sampledPageColor: ChromeBand.pageColor(
                            browser: browser,
                            coordinator: coordinator
                        ),
                        settings: BrowserSettings.application
                    )
                }
                WindowDragArea()
            }
        }
        .environment(\.chromeIsLight, inkIsLight)
        .environment(\.chromeWash, .of(inkColor, isLight: inkIsLight, ground: groundColor))
        .environment(\.windowColorScheme, scheme)
        .environment(\.colorScheme, inkIsLight ? .light : .dark)
        .animation(nil, value: inkIsLight)
        .animation(Theme.Motion.settle, value: coordinator.media.model.isActive)
        .onChange(of: coordinator.context.profile.id) {
            shownDevice = nil
        }
        // A space chosen by menu, swipe, ⌘K or a link shows this Mac's list of that space.
        .onChange(of: browser.currentSpaceID) {
            shownDevice = nil
        }
        .onChange(of: shownDevice) { _, device in
            if device != nil {
                CloudTabs.shared?.refresh()
            }
        }
    }
}

private struct SidebarTopChrome: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator
    let selection: SidebarSelection
    let newFolderDrop: SidebarNewFolderDrop
    let pinDrop: SidebarPinDrop
    let remote: [RemoteDeviceSession]
    @Binding var shownDevice: String?

    @Environment(\.sidebarStyle) private var sidebarStyle

    private var offersPin: Bool {
        coordinator.sidebarDrag.acceptsPin
    }

    /// Favorites belong to This Mac. Another device's list brings its own.
    private var showsFavorites: Bool {
        sidebarStyle != .full || SidebarDeviceFilter.shown(shownDevice, in: remote) == nil
    }

    var body: some View {
        VStack(spacing: 6) {
            SidebarTopRow(
                browser: browser,
                coordinator: coordinator,
                selection: selection,
                newFolderDrop: newFolderDrop,
                allowsNewFolder: showsFavorites
            )

            if sidebarStyle == .full, !remote.isEmpty {
                SidebarDevicePicker(sessions: remote, shown: $shownDevice)
            }

            if showsFavorites {
                SidebarFavorites(browser: browser, coordinator: coordinator)
                    .opacity(offersPin ? 0 : 1)
                    .overlay {
                        if offersPin {
                            SidebarDropMark(kind: .pin, isArmed: pinDrop.isArmed)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pinDrop.frame = $0 }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SidebarBottomChrome: View {
    let coordinator: AppCoordinator
    @Binding var obscuredHeight: CGFloat
    let showsSpaceSwitcher: Bool

    @Environment(\.sidebarStyle) private var sidebarStyle

    private var expandsProfile: Bool {
        sidebarStyle == .full
    }

    private var downloadsButton: some View {
        SidebarDownloadsButton(coordinator: coordinator)
    }

    var body: some View {
        VStack(spacing: 6) {
            SidebarPinnedCards(
                coordinator: coordinator,
                obscuredHeight: $obscuredHeight
            )

            if sidebarStyle == .icons {
                VStack(spacing: 6) {
                    if showsSpaceSwitcher {
                        SidebarSpaceSwitcher(coordinator: coordinator, axis: .vertical)
                    }
                    AudioIndicatorButton(coordinator: coordinator)
                    SidebarProfileControl(coordinator: coordinator)
                    downloadsButton
                    SidebarSettingsRow(coordinator: coordinator)
                }
            } else {
                HStack(spacing: 6) {
                    SidebarProfileControl(coordinator: coordinator)
                        .padding(.leading, SidebarMetrics.profileLeading)

                    AudioIndicatorButton(coordinator: coordinator)

                    if showsSpaceSwitcher {
                        SidebarSpaceSwitcher(coordinator: coordinator)
                    } else {
                        Spacer(minLength: 0)
                    }

                    downloadsButton
                    SidebarSettingsRow(coordinator: coordinator)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SidebarPinnedCards: View {
    let coordinator: AppCoordinator
    @Binding var obscuredHeight: CGFloat

    @State private var mediaHeight: CGFloat = 0
    @State private var measuredBanner: CGFloat = 0

    private static let spacing: CGFloat = 6

    private var bannerHeight: CGFloat {
        UpdateBanner.isVisible(for: coordinator) ? measuredBanner : 0
    }

    private var stackedHeight: CGFloat {
        let cards = [mediaHeight, bannerHeight].filter { $0 > 0 }
        guard !cards.isEmpty else { return 0 }
        return cards.reduce(0, +) + Self.spacing * CGFloat(cards.count - 1)
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            if coordinator.media.model.isActive {
                MediaSidebarCard(
                    media: coordinator.media,
                    coordinator: coordinator,
                    obscuredHeight: $mediaHeight
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            UpdateBanner(coordinator: coordinator)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredBanner = $0 }
        }
        .glassGroup()
        .frame(maxWidth: .infinity)
        .zIndex(1)
        .onAppear { obscuredHeight = stackedHeight }
        .onChange(of: stackedHeight) { _, height in obscuredHeight = height }
        .onChange(of: coordinator.media.model.isActive) { _, isActive in
            if !isActive {
                mediaHeight = 0
            }
        }
    }
}

struct SidebarTopRow: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator
    let selection: SidebarSelection
    let newFolderDrop: SidebarNewFolderDrop
    /// False while another device's list is shown: a new folder would appear in a list that is not on screen.
    var allowsNewFolder = true

    @Environment(\.sidebarStyle) private var sidebarStyle
    @Environment(\.sidebarIsFloating) private var isFloating

    private var sidebar: SidebarLayout {
        coordinator.sidebar
    }

    var body: some View {
        Group {
            if sidebarStyle == .icons {
                VStack(spacing: 2) {
                    SidebarTopActions(
                        browser: browser,
                        coordinator: coordinator,
                        selection: selection,
                        newFolderDrop: newFolderDrop,
                        allowsNewFolder: allowsNewFolder
                    )
                }
            } else {
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    SidebarTopActions(
                        browser: browser,
                        coordinator: coordinator,
                        selection: selection,
                        newFolderDrop: newFolderDrop,
                        allowsNewFolder: allowsNewFolder
                    )
                }
            }
        }
        .padding(.bottom, 2)
        .opacity(SidebarMetrics.topControlsOpacity(isShowing: sidebar.isShowing || isFloating))
    }
}

struct SidebarVisibilityToggle: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @Environment(\.windowControlsInset) private var windowControlsInset
    @Environment(\.colorScheme) private var scheme

    private var sidebar: SidebarLayout {
        coordinator.sidebar
    }

    private var label: LocalizedStringResource {
        sidebar.isVisible ? "Hide Sidebar" : "Show Sidebar"
    }

    private var barColor: NSColor {
        LoomChrome.sampledColor(
            ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
            scheme: scheme
        )
    }

    private var barIsLight: Bool {
        PageInk.isLight(
            LoomChrome.sampledColor(
                ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
                scheme: scheme
            ),
            scheme: scheme
        )
    }

    var body: some View {
        ToolbarButton(
            symbol: "sidebar.left",
            enabled: true,
            isOn: sidebar.isVisible,
            highlightsWhenOn: false,
            help: String(localized: label)
        ) {
            sidebar.toggleVisible()
        }
        .onHover { if $0, !sidebar.isVisible { sidebar.isPeeking = true } }
        .contextMenu {
            SidebarStyleMenuItems(sidebar: sidebar)
        }
        .accessibilityLabel(Text(label))
        .padding(
            .leading,
            SidebarMetrics.permanentToggleLeading(windowControlsInset: windowControlsInset)
        )
        .frame(height: Theme.topBarHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.chromeIsLight, barIsLight)
        .environment(\.chromeWash, .of(barColor, isLight: barIsLight))
        .environment(\.colorScheme, barIsLight ? .light : .dark)
        .animation(nil, value: barIsLight)
    }
}

private struct SidebarTopActions: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator
    let selection: SidebarSelection
    let newFolderDrop: SidebarNewFolderDrop
    let allowsNewFolder: Bool

    var body: some View {
        Group {
            // The Minimal window's tab list slides away when it is not pointed at; the pin keeps it open.
            if coordinator.isMinimal {
                QuietIconButton(
                    symbol: coordinator.keepsMinimalSidebarOpen ? "pin.fill" : "pin",
                    isOn: coordinator.keepsMinimalSidebarOpen,
                    help: String(localized: "Keep Sidebar Open")
                ) {
                    coordinator.toggleMinimalSidebarPin()
                }
                .accessibilityLabel(Text("Keep Sidebar Open"))
                .accessibilityAddTraits(coordinator.keepsMinimalSidebarOpen ? .isSelected : [])
            }
            QuietIconButton(
                symbol: "magnifyingglass",
                isOn: false,
                help: String(localized: "Search Everything (⌘K)")
            ) {
                coordinator.openPalette()
            }
            QuietIconButton(
                symbol: "folder.badge.plus",
                isOn: newFolderDrop.isArmed,
                help: String(localized: "New Folder")
            ) {
                browser.createFolderForRenaming(containing: selection.items.isEmpty
                    ? []
                    : browser.sidebarTree.normalized(selection.items))
                selection.clear()
            }
            .disabled(!allowsNewFolder)
            .overlay {
                if newFolderDrop.isArmed {
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .frame(width: 28, height: 28)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                newFolderDrop.frame = $0
            }
        }
    }
}

struct SidebarStyleMenuItems: View {
    let sidebar: SidebarLayout

    var body: some View {
        Toggle(isOn: Binding(
            get: { sidebar.isIconsOnly },
            set: { sidebar.setIconsOnly($0) }
        )) {
            Text("Use Icons Only")
        }
    }
}

private struct SidebarFavorites: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 6)], spacing: 6) {
            ForEach(browser.favorites) { tab in
                SidebarFavoriteButton(tab: tab, browser: browser, coordinator: coordinator)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Favorites"))
    }
}

struct SidebarFavoriteButton: View {
    let tab: BrowserTab
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @State private var hovering = false
    private var inkSource = SidebarRowInkSource()

    private var style: SidebarRowStyle {
        browser.rowStyle(
            of: tab,
            isMarked: false,
            paletteOpen: coordinator.isNewTabPaletteOpen,
            increasedContrast: inkSource.increasedContrast
        )
    }

    private var favoriteValue: Text {
        let loaded = tab.isDeferred ? Text("Unloaded") : Text("Loaded")
        guard let status = style.spokenStatus else { return loaded }
        return Text("\(status), \(loaded)")
    }

    var body: some View {
        let ink = inkSource.ink(for: style, isDeferred: tab.isDeferred)
        Button {
            coordinator.tabPreview.dismiss()
            coordinator.openTab(tab)
        } label: {
            TabIcon(tab: tab)
                .sidebarNewMark(ink)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .sidebarInverse(ink, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .sidebarRowSelectionEffect(
                    isSelected: style.emphasis == .lit,
                    isHovering: hovering && style.emphasis != .current
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: tab.title))
        .accessibilityLabel(Text(verbatim: tab.title))
        .accessibilityValue(favoriteValue)
        .accessibilityAddTraits(style.isSelected ? .isSelected : [])
        .overlay {
            ExternalControlMark(tab: tab, coordinator: coordinator, isCompact: true)
                .offset(x: 8, y: 8)
        }
        .contextMenu {
            ExternalControlMenuItems(tabs: [tab], coordinator: coordinator)
            SidebarLinkMenuItems(tabs: [tab], coordinator: coordinator)
            SidebarPinMenuItems(tab: tab, browser: browser)
            if !tab.isDeferred {
                Button {
                    coordinator.tabPreview.dismiss()
                    coordinator.unloadTab(tab)
                } label: {
                    Label("Unload Tab", systemImage: "arrow.uturn.down")
                }
            }
            Button {
                browser.removeFavorite(tab)
            } label: {
                Label("Remove Favorite", systemImage: "star.slash")
            }
            Button(role: .destructive) {
                browser.close([.tab(tab.id)])
            } label: {
                Label("Remove Tab", systemImage: "xmark")
            }
        }
    }
}

/// The Downloads button. Pointing at it lists the newest downloads, each with Open and Show in Finder (`RecentDownloadsList`);
/// pressing it opens the Downloads page, which is also what VoiceOver and the keyboard use.
struct SidebarDownloadsButton: View {
    let coordinator: AppCoordinator
    /// The side of the button the list opens to.
    var listEdge: Edge = .trailing

    @Environment(\.sidebarStyle) private var sidebarStyle
    @State private var hovering = false
    @State private var showsList = false
    @State private var overList = false
    @State private var pending: Task<Void, Never>?

    private static let barWidth: CGFloat = 15
    // The same moments as the speaker's list (`AudioIndicatorButton`).
    private static let openDelay: Duration = .milliseconds(350)
    private static let closeDelay: Duration = .milliseconds(220)

    private var downloads: DownloadManager {
        coordinator.browser.downloads
    }
    private var isRunning: Bool {
        downloads.activeCount > 0
    }

    var body: some View {
        Button {
            pending?.cancel()
            showsList = false
            coordinator.showDownloads()
        } label: {
            VStack(spacing: isRunning ? 3 : 0) {
                Image(systemName: "arrow.down")
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(.secondary)

                Capsule()
                    .fill(Theme.Wash.strong)
                    .frame(width: Self.barWidth, height: 2)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(
                                width: Self.barWidth * max(0.06, min(downloads.activeFraction, 1)),
                                height: 2
                            )
                            .animation(Theme.Motion.drift, value: downloads.activeFraction)
                    }
                    .opacity(isRunning ? 1 : 0)
                    .frame(height: isRunning ? 2 : 0)
            }
            .frame(width: 28, height: 28)
            .hoverBackground(isActive: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGPoint.self) { proxy in
            CGPoint(x: proxy.frame(in: .global).midX, y: proxy.frame(in: .global).midY)
        } action: { point in
            coordinator.downloadFlights.target = point
        }
        .onHover { inside in
            hovering = inside
            settle()
        }
        .animation(Theme.Motion.quick, value: hovering)
        .animation(Theme.Motion.settle, value: isRunning)
        .help(isRunning
              ? Text("Downloads — \(downloads.activeCount) in progress")
              : Text("Downloads"))
        .accessibilityAction(named: Text("Show Recent Downloads")) { showsList = true }
        .popover(isPresented: $showsList, arrowEdge: listEdge) {
            RecentDownloadsList(downloads: downloads, showAll: coordinator.showDownloads) { showsList = false }
                .onHover { inside in
                    overList = inside
                    settle()
                }
                .onExitCommand { showsList = false }
        }
        .onChange(of: showsList) { _, isOpen in
            coordinator.isDownloadsListOpen = isOpen
            // A list closed by a press inside it sends no exit, and the stale "inside" would keep the next one open.
            if !isOpen {
                overList = false
            }
        }
        .onDisappear {
            pending?.cancel()
            showsList = false
            coordinator.isDownloadsListOpen = false
        }
    }

    /// Opens the list a moment after the pointer arrives and closes it a moment after the pointer has left both the button and
    /// the list, so the way from one to the other does not close it.
    private func settle() {
        pending?.cancel()
        let wanted = hovering || overList
        guard wanted != showsList else { return }
        pending = Task {
            try? await Task.sleep(for: wanted ? Self.openDelay : Self.closeDelay)
            guard !Task.isCancelled else { return }
            showsList = wanted
        }
    }
}

struct SidebarSettingsRow: View {
    let coordinator: AppCoordinator

    var body: some View {
        QuietIconButton(
            symbol: "gearshape",
            isOn: false,
            help: String(localized: "Settings")
        ) {
            coordinator.openSettings()
        }
    }
}
