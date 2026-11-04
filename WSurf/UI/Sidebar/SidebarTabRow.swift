// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

func pinnedPageName(of tab: BrowserTab) -> String {
    if !tab.pinnedTitle.isEmpty {
        return tab.pinnedTitle
    }
    return tab.pinnedURL?.host() ?? String(localized: "the pinned page")
}

struct SidebarTabRow: View {
    let tab: BrowserTab
    let depth: Int
    let context: SidebarRowContext

    private var browser: BrowserModel {
        context.browser
    }
    private var coordinator: AppCoordinator {
        context.coordinator
    }
    private var item: SidebarItem {
        .tab(tab.id)
    }
    private var isLifted: Bool {
        context.isLifted(item)
    }
    private var isSelected: Bool {
        context.isSelected(item)
    }
    private var isActive: Bool {
        tab.isSidebarActive
    }
    private var windowAnchor: CGRect {
        context.windowFrame(of: item)
    }
    private var style: SidebarRowStyle {
        browser.rowStyle(
            of: tab,
            isMarked: isSelected,
            paletteOpen: coordinator.isNewTabPaletteOpen,
            increasedContrast: inkSource.increasedContrast
        )
    }

    @Environment(\.sidebarStyle) private var sidebarStyle
    @Environment(\.sidebarIconTint) private var folderIconTint
    @Environment(\.sidebarKeepsHiddenControls) private var keepsHiddenControls
    private var inkSource = SidebarRowInkSource()
    @State private var hovering = false
    @State private var returnHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool
    @State private var rowFrame = SidebarRowFrame()
    @State private var markWidth: CGFloat = 0

    private var showsTrailingControls: Bool {
        hovering && !isRenaming
    }

    private var showsPinSegment: Bool {
        sidebarStyle == .full && tab.isAwayFromPin
    }

    private var showsSpeaker: Bool {
        sidebarStyle == .full && (tab.isPlayingAudio || tab.isMuted)
    }

    private var ink: SidebarRowInk {
        inkSource.ink(for: style, isDeferred: tab.isDeferred)
    }

    private var textColor: Color {
        ink.text
    }

    private var radius: CGFloat {
        depth == 0 ? Theme.Radius.row : FolderSection.rowRadius(depth: depth - 1)
    }

    private var returnHelp: String {
        String(localized: "Back to \(pinnedPageName(of: tab))")
    }

    private func tapped() {
        guard !isRenaming else { return }
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) {
            context.selection.hold(context.activeItem)
            context.selection.extend(to: item, in: browser.sidebarTree) {
                browser.folder(id: $0)?.isExpanded ?? false
            }
        } else if modifiers.contains(.command) {
            context.selection.hold(context.activeItem)
            context.selection.toggle(item)
        } else {
            context.selection.anchor(on: item)
            activate()
        }
        context.selection.excludeFavorites(browser.favorites)
    }

    private func beginRename() {
        coordinator.tabPreview.dismiss()
        context.selection.clear()
        draftTitle = tab.title
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        renameFocused = false
        browser.renameTab(tab, to: draftTitle)
    }

    private func activate() {
        coordinator.tabPreview.dismiss()
        if isActive, tab.isAwayFromPin {
            browser.returnToPin(tab)
        } else {
            coordinator.openTab(tab)
        }
    }

    private var selected: [SidebarItem] {
        guard context.selection.count > 1, isSelected else { return [] }
        return Array(context.selection.items)
    }

    /// Built only while it shows (it fades in and out with the hover), unless something that walks every row needs to reach it.
    /// A hidden button in every drawn row made each row cost more to build while the list scrolls.
    @ViewBuilder private var trailingControls: some View {
        if showsTrailingControls || keepsHiddenControls {
            SidebarTabActionButton(tab: tab, coordinator: coordinator, followsCommandKey: showsTrailingControls)
                .opacity(showsTrailingControls ? 1 : 0)
                .allowsHitTesting(showsTrailingControls)
                .transition(.opacity)
        }
    }

    private var peekedTab: BrowserTab? {
        guard coordinator.peek.belongs(to: tab.id) else { return nil }
        return coordinator.peek.tab
    }

    private var titleMask: some View {
        let badge = (peekedTab == nil ? 0 : PeekRowBadge.extent + 4) + (tab.microTabID == nil ? 0 : MicroRowBadge.extent + 4)
        let mark = tab.processState.externalControllers.isEmpty ? 0 : markWidth + 4
        // The action button is a row control, so its width is known without measuring it.
        let covered = (showsTrailingControls ? SidebarMetrics.rowControlExtent : 0) + badge + mark
        return HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: covered > 0 ? 18 : 0)
            Color.clear
                .frame(width: covered)
        }
    }

    @ViewBuilder private var leadingIcon: some View {
        let icon = ink.iconStyle(
            folderTint: folderIconTint,
            colorsFavicon: BrowserSettings.application.chromeShape.colorsFavicons,
            isDeferred: tab.isDeferred
        )
        if sidebarStyle == .full {
            TabIcon(tab: tab, tint: icon.tint, colorsFavicon: icon.colorsFavicon)
                .frame(width: SidebarMetrics.rowIconSize)
                .sidebarNewMark(ink)
        } else {
            TabIcon(tab: tab, tint: icon.tint, colorsFavicon: icon.colorsFavicon)
                .sidebarNewMark(ink)
        }
    }

    /// `color` is the row's text color. The rename popover of the icons-only sidebar sits outside the row, so it
    /// takes the sidebar's own text color rather than the one on an inverse fill.
    @ViewBuilder private func titleColumn(color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isRenaming {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(BrowserSettings.application.sidebarFont)
                    .foregroundStyle(color)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onAppear { renameFocused = true }
                    .onKeyPress(.escape) {
                        isRenaming = false
                        renameFocused = false
                        return .handled
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused {
                            commitRename()
                        }
                    }
                    .onChange(of: isActive) { _, active in
                        if !active {
                            commitRename()
                        }
                    }
            } else {
                HStack(spacing: 0) {
                    Text(verbatim: tab.title)
                        .font(ink.titleFont)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .sidebarRowAccessibility(style)
                    Spacer(minLength: 0)
                }
            }

            if returnHovering {
                Text("Back to Pinned Page")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(alignment: .leading) { titleMask }
        .sidebarTitleCentered(!returnHovering)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsPinSegment {
                PinReturnSegment(tab: tab, help: returnHelp, tint: textColor, isHovering: $returnHovering) {
                    coordinator.tabPreview.dismiss()
                    browser.returnToPin(tab)
                }
                Rectangle()
                    .fill(Theme.Wash.strong)
                    .frame(width: 1, height: 14)
            }

            HStack(spacing: SidebarMetrics.rowIconSpacing) {
                leadingIcon
                    .sidebarRowName(tab.title, style: style, isIconOnly: sidebarStyle == .icons)
                    .overlay(alignment: .bottomTrailing) {
                        if sidebarStyle == .icons {
                            ExternalControlMark(tab: tab, coordinator: coordinator, isCompact: true)
                        }
                    }

                if showsSpeaker {
                    SidebarTabMuteButton(isMuted: tab.isMuted) {
                        coordinator.toggleMute(tab: tab)
                    }
                    .frame(width: SidebarMetrics.rowIconSize)
                }

                if sidebarStyle == .full {
                    titleColumn(color: textColor)
                }
            }
            .overlay(alignment: .trailing) {
                if sidebarStyle == .full {
                    HStack(spacing: 4) {
                        trailingControls
                        // Measured only while there is a mark, so a plain row has one geometry callback: its frame.
                        if !tab.processState.externalControllers.isEmpty {
                            ExternalControlMark(tab: tab, coordinator: coordinator)
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { markWidth = $0 }
                        }
                        if let peekedTab {
                            PeekRowBadge(tab: peekedTab, coordinator: coordinator)
                        }
                        MicroRowBadge(tab: tab)
                    }
                    .padding(.trailing, SidebarMetrics.rowControlEdgeOffset(
                        style: sidebarStyle,
                        settings: BrowserSettings.application
                    ))
                }
            }
            .padding(.horizontal, SidebarMetrics.rowContentPadding(style: sidebarStyle))
            .frame(maxWidth: .infinity)
        }
        .frame(height: SidebarMetrics.rowHeight(settings: BrowserSettings.application))
        .environment(\.chromeIconExtent, SidebarMetrics.rowControlExtent)
        .sidebarInverse(ink, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .sidebarRowSelectionEffect(
            isSelected: style.emphasis == .lit,
            isHovering: hovering && style.emphasis != .current,
            glassTint: context.refractsTabColor
                ? FaviconTint.of(tab.favicon, heldBy: tab.id)
                : nil,
            radius: radius
        )
        .overlay { SidebarRevealPulse(browser: browser, tabID: tab.id, radius: radius) }
        .opacity(isLifted ? 0 : 1)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(context.space)) } action: {
            rowFrame.measure(item, at: $0, in: context.frames)
            context.followPreview(of: item, id: tab.id)
        }
        .onAppear { rowFrame.appear(item, in: context.frames) }
        // The list holds still while a title is being edited, so it needs to know.
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                browser.tabRenameID = tab.id
            } else if browser.tabRenameID == tab.id {
                browser.tabRenameID = nil
            }
        }
        .onTapGesture { tapped() }
        // A middle click unloads the tab: the list catches it for every row (`WorkspaceList`), so a row has no view of its own for it.
        .onHover { over in
            withAnimation(Theme.Motion.quick) { hovering = over }
            if over, !isRenaming {
                coordinator.tabPreview.hover(tab, anchor: windowAnchor)
            } else {
                coordinator.tabPreview.unhover(tab.id)
            }
        }
        .onDisappear {
            coordinator.tabPreview.unhover(tab.id)
            rowFrame.forget(item, in: context.frames)
            if browser.tabRenameID == tab.id {
                browser.tabRenameID = nil
            }
        }
        .help(sidebarStyle == .icons ? Text(verbatim: tab.title) : Text(verbatim: ""))
        .popover(isPresented: Binding(
            get: { isRenaming && sidebarStyle == .icons },
            set: { if !$0 { commitRename() } }
        )) {
            titleColumn(color: ink.resting)
                .frame(width: 220, height: 24)
                .padding(12)
        }
        .contextMenu {
            if selected.isEmpty {
                menu
            } else {
                SidebarSelectionMenuItems(items: selected, browser: browser, coordinator: coordinator)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        ExternalControlMenuItems(tabs: [tab], coordinator: coordinator)
        SidebarLinkMenuItems(tabs: [tab], coordinator: coordinator)

        Button {
            beginRename()
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            browser.duplicate(tab)
        } label: {
            Label("Duplicate Tab", systemImage: "plus.square.on.square")
        }
        OpenBesideCurrentPageItem(tab: tab, browser: browser, coordinator: coordinator)
        ExitSplitItem(tab: tab, browser: browser)
        MoveToMicroWindowItem(tab: tab, coordinator: coordinator)
        MicroRowMenuItems(tab: tab, coordinator: coordinator)
        Divider()

        SidebarPinMenuItems(tab: tab, browser: browser)
        SidebarFavoriteMenuItems(tabs: [tab], browser: browser)
        SidebarAudioMenuItems(tab: tab, coordinator: coordinator)
        SidebarFolderMenuItems(items: [item], browser: browser)

        if tab.isPinnedForProfile {
            SidebarUnpinButton(tab: tab, browser: browser)
        }
        if !tab.isDeferred {
            Button {
                coordinator.tabPreview.dismiss()
                coordinator.unloadTab(tab)
            } label: {
                Label("Unload Tab", systemImage: "arrow.uturn.down")
            }
        }
        Button(role: .destructive) {
            browser.close([.tab(tab.id)])
        } label: {
            Label("Remove Tab", systemImage: "xmark")
        }
        RemoveOtherTabsItem(tab: tab, browser: browser)
    }
}

/// Open Beside Current Page, in a view of its own: a row builds its context menu with its body, so a menu item that read which
/// tab is current there would draw every row again on each tab switch.
private struct OpenBesideCurrentPageItem: View {
    let tab: BrowserTab
    let browser: BrowserModel
    let coordinator: AppCoordinator

    var body: some View {
        if let anchor = browser.activeTab, anchor !== tab {
            Button {
                coordinator.split(anchor, with: tab, axis: .sideBySide)
            } label: {
                Label("Open Beside Current Page", systemImage: "rectangle.split.2x1")
            }
        }
    }
}

/// Remove Other Tabs, Exit Split and Move to Micro Window, in views of their own for the reason above: read in the row, the
/// tabs, the splits and the window would make every drawn row draw again whenever a tab opens, closes or is pinned.
private struct RemoveOtherTabsItem: View {
    let tab: BrowserTab
    let browser: BrowserModel

    var body: some View {
        if !tab.isPinnedForProfile {
            let others = browser.tabs.filter { $0 !== tab && !$0.isPinnedForProfile && browser.isShown($0) }
            if !others.isEmpty {
                Button(role: .destructive) {
                    let count = others.count
                    Task {
                        guard await ConfirmAlert.destructive(
                            "Remove \(count) tabs?",
                            verb: "Remove Tabs"
                        ) else { return }
                        browser.closeOthers(tab)
                    }
                } label: {
                    Label("Remove Other Tabs", systemImage: "trash")
                }
            }
        }
    }
}

private struct ExitSplitItem: View {
    let tab: BrowserTab
    let browser: BrowserModel

    var body: some View {
        if browser.splits.contains(tab.id) {
            Button {
                browser.dissolveSplit(containing: tab)
            } label: {
                Label("Exit Split", systemImage: "rectangle")
            }
        }
    }
}

private struct MoveToMicroWindowItem: View {
    let tab: BrowserTab
    let coordinator: AppCoordinator

    var body: some View {
        if coordinator.canMoveToMicroWindow(tab) {
            Button {
                coordinator.moveToMicroWindow(tab)
            } label: {
                Label("Move to Micro Window", systemImage: "arrow.up.forward.square")
            }
        }
    }
}

struct PinReturnSegment: View {
    let tab: BrowserTab
    let help: String
    let tint: Color
    @Binding var isHovering: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pinnedFavicon: NSImage?

    private var isSameSite: Bool {
        guard let pinnedHost = tab.pinnedURL?.host()?.lowercased() else { return false }
        return URL(string: tab.urlString)?.host()?.lowercased() == pinnedHost
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if let pinnedFavicon, !isSameSite {
                    FaviconImage(image: pinnedFavicon, tint: tint)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tight, style: .continuous))
                        .opacity(hovering ? 0 : 1)
                }
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering || isSameSite || pinnedFavicon == nil ? 1 : 0)
            }
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHoverFill(
            isHovering: hovering,
            in: UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.row,
                bottomLeadingRadius: Theme.Radius.row
            )
        )
        .onHover { over in
            withAnimation(Theme.Motion.quick) {
                hovering = over
                isHovering = over
            }
        }
        .help(Text(verbatim: help))
        .task(id: tab.pinnedURL) {
            pinnedFavicon = nil
            guard let pageURL = tab.pinnedURL, let host = pageURL.host() else { return }
            if let cached = tab.context.favicons.cached(for: host) {
                pinnedFavicon = cached
            } else {
                pinnedFavicon = await tab.context.favicons.load(forPageURL: pageURL)
            }
        }
    }
}

nonisolated enum SidebarTabAction: Equatable {
    case close
    case unload
    case load

    static func resolve(isPinned: Bool, isDeferred: Bool, command: Bool) -> Self {
        if isPinned {
            return command ? .close : (isDeferred ? .load : .unload)
        }
        return command ? .unload : .close
    }

    var symbol: String {
        switch self {
        case .close:
            "xmark"
        case .unload:
            "arrow.uturn.down"
        case .load:
            "play.fill"
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .close:
            "Remove Tab"
        case .unload:
            "Unload Tab"
        case .load:
            "Load Tab"
        }
    }
}

struct SidebarTabActionButton: View {
    let tab: BrowserTab
    let coordinator: AppCoordinator
    /// False for a button that is not shown. It stays in the row but does not read the Command key, so a press draws the one
    /// row under the pointer and not every row that is drawn.
    var followsCommandKey = true

    var body: some View {
        let action = SidebarTabAction.resolve(
            isPinned: tab.isPinnedForProfile,
            isDeferred: tab.isDeferred,
            command: followsCommandKey && coordinator.linkModifiers.contains(.command)
        )
        ChromeIcon.rowControl(symbol: action.symbol, help: String(localized: action.label)) {
            coordinator.tabPreview.dismiss()
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            switch SidebarTabAction.resolve(
                isPinned: tab.isPinnedForProfile,
                isDeferred: tab.isDeferred,
                command: modifiers.contains(.command)
            ) {
            case .close:
                coordinator.browser.close([.tab(tab.id)])
            case .unload:
                if !tab.isDeferred {
                    coordinator.unloadTab(tab)
                }
            case .load:
                coordinator.openTab(tab)
            }
        }
        .disabled(action == .unload && tab.isDeferred)
        .accessibilityLabel(Text(action.label))
    }
}

struct SidebarTabMuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    private var help: LocalizedStringResource {
        isMuted ? "Unmute Tab" : "Mute Tab"
    }

    var body: some View {
        ChromeIcon(
            symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            isSubdued: isMuted,
            help: String(localized: help),
            action: action
        )
    }
}

struct PinBadge: View {
    let browser: BrowserModel

    @State private var hovering = false

    private var tab: BrowserTab? {
        browser.activeTab
    }
    private var hasPage: Bool {
        !(tab?.urlString.isEmpty ?? true)
    }

    var body: some View {
        if let tab, hasPage {
            ChromeIcon(
                symbol: symbol(for: tab),
                weight: .semibold,
                help: helpText(for: tab)
            ) {
                if tab.isAwayFromPin {
                    browser.returnToPin(tab)
                } else if tab.isShowingPin {
                    browser.unpin(tab)
                } else {
                    browser.pin(tab)
                }
            }
            .animation(.snappy(duration: 0.2), value: tab.pinnedURL)
        }
    }

    private func symbol(for tab: BrowserTab) -> String {
        if tab.isAwayFromPin {
            return "arrow.uturn.backward"
        }
        return tab.isShowingPin ? "pin.fill" : "pin"
    }

    private func helpText(for tab: BrowserTab) -> String {
        if tab.isAwayFromPin {
            return String(localized: "Back to \(pinnedPageName(of: tab))")
        }
        let help: LocalizedStringResource = tab.isShowingPin
            ? "Unpin Tab"
            : "Pin This Page"
        return String(localized: help)
    }
}

struct TabIcon: View {
    let tab: BrowserTab
    var size: CGFloat = SidebarMetrics.rowIconSize
    var tint: Color?
    var loadingColor: Color = .secondary
    /// A loaded tab shows its favicon's own colors instead of `tint`. Unloaded tabs and symbols keep the tint, so
    /// loaded and unloaded tabs stay apart.
    var colorsFavicon = false

    /// nil draws the favicon in its own colors.
    var faviconTint: Color? {
        if colorsFavicon, !tab.isDeferred {
            return nil
        }
        return tint ?? (tab.isDeferred ? .secondary : nil)
    }

    var body: some View {
        Group {
            if let internalPage = tab.internalPage {
                SidebarSymbol(internalPage.symbol, size: size * 0.72, weight: .medium, box: size)
                    .foregroundStyle(tint ?? .secondary)
            } else if tab.isLoading, !tab.isRestoring {
                Spinner(size: size * 0.8)
                    .foregroundStyle(tint ?? loadingColor)
            } else if SystemPages.showsStartFace(tab) {
                SidebarSymbol(SystemPages.startSymbol, size: size * 0.66, weight: .medium, box: size)
                    .foregroundStyle(tint ?? .secondary)
            } else if let favicon = tab.favicon {
                FaviconImage(image: favicon, tint: faviconTint)
                    .frame(width: size - 1, height: size - 1)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tight, style: .continuous))
            } else {
                SidebarSymbol("globe", size: size * 0.69, box: size)
                    .foregroundStyle(tint ?? .secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
