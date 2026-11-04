// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore

/// What another device has open, read-only. A row opens its link in a new tab here and copies nothing else.
///
/// It does not reuse `SidebarTabRow` or `FolderSection`: both need a live `BrowserTab` or `TabFolder` and the window's drag,
/// selection and undo context. It shares the metrics, the hover effect, the favicon cache and the section seam.
struct RemoteSessionList<TopBar: View, BottomBar: View>: View {
    let session: RemoteDeviceSession
    let coordinator: AppCoordinator
    let bottomClearance: CGFloat
    let topBar: TopBar
    let bottomBar: BottomBar
    let contentInsets: EdgeInsets
    /// Called after a row opened a tab, so the sidebar can go back to This Mac and show it.
    let onOpen: () -> Void

    @State private var collapsed: Set<UUID> = []

    private var payload: DeviceSessionPayload {
        session.payload
    }

    /// A window without loose tabs has nothing to list.
    private var windows: [SessionWindow] {
        payload.windows.filter { !$0.nodes.isEmpty }
    }

    private var keptNodes: [SessionNode] {
        payload.favorites + payload.pins
    }

    var body: some View {
        ScrollView {
            TimelineView(.everyMinute) { timeline in
                content(now: timeline.date)
            }
            .padding(.leading, contentInsets.leading)
            .padding(.trailing, contentInsets.trailing)
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .mask {
            WorkspaceListFadeMask()
        }
        .safeAreaBar(edge: .top, spacing: 6) {
            topBar
                .padding(.leading, contentInsets.leading)
                .padding(.trailing, contentInsets.trailing)
        }
        .safeAreaBar(edge: .bottom, spacing: 6) {
            bottomBar
                .padding(.leading, contentInsets.leading)
                .padding(.trailing, contentInsets.trailing)
                .zIndex(1)
        }
    }

    private func content(now: Date) -> some View {
        let presence = Presence.of(lastSeen: session.lastSeen, running: payload.running, now: now)
        return VStack(spacing: SidebarMetrics.rowVerticalSpacing(settings: coordinator.context.settings)) {
            if case .lastSeen(let date) = presence {
                Text("Last seen \(date.formatted(.relative(presentation: .named)))")
                    .font(Theme.Font.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SidebarMetrics.rowContentPadding(style: .full))
            }
            rows(keptNodes)
            if !keptNodes.isEmpty, !windows.isEmpty {
                SidebarSectionSeam()
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if windows.count > 1 {
                    Text("Window \(index + 1)")
                        .font(Theme.Font.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SidebarMetrics.rowContentPadding(style: .full))
                }
                rows(window.nodes)
            }
            if payload.omittedTabs > 0 {
                Text("\(payload.omittedTabs) more tabs not shown")
                    .font(Theme.Font.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SidebarMetrics.rowContentPadding(style: .full))
            }
            if keptNodes.isEmpty, windows.isEmpty {
                Text("No open tabs")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            Color.clear
                .frame(height: 26 + bottomClearance)
        }
        // The grey state: the whole list reads as the last thing the device said.
        .foregroundStyle(presence == .current ? .primary : .secondary)
    }

    private func rows(_ nodes: [SessionNode]) -> some View {
        ForEach(nodes) { node in
            RemoteNodeRow(node: node, depth: 0, coordinator: coordinator, collapsed: $collapsed, onOpen: open)
        }
    }

    private func open(_ node: SessionNode) {
        guard CloudTabs.shared?.open(node, in: coordinator.browser) == true else { return }
        onOpen()
    }
}

private struct RemoteNodeRow: View {
    let node: SessionNode
    let depth: Int
    let coordinator: AppCoordinator
    @Binding var collapsed: Set<UUID>
    let onOpen: (SessionNode) -> Void

    @State private var hovering = false

    private static let indent: CGFloat = 12

    private var isCollapsed: Bool {
        collapsed.contains(node.id)
    }

    /// A tab saved without a title shows its host.
    private var title: String {
        guard node.title.isEmpty else { return node.title }
        return node.webURL?.host() ?? node.url ?? ""
    }

    var body: some View {
        if let children = node.children {
            folder(children)
        } else {
            tab
        }
    }

    private var tab: some View {
        Button {
            onOpen(node)
        } label: {
            label(title: title) {
                tabIcon
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens in a new tab"))
    }

    @ViewBuilder
    private func folder(_ children: [SessionNode]) -> some View {
        Button {
            if isCollapsed {
                collapsed.remove(node.id)
            } else {
                collapsed.insert(node.id)
            }
        } label: {
            label(title: node.title) {
                HStack(spacing: 2) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 8)
                    Image(systemName: "folder")
                        .font(.system(size: SidebarMetrics.rowIconSize * 0.69))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isCollapsed ? Text("Collapsed") : Text("Expanded"))
        if !isCollapsed {
            ForEach(children) { child in
                RemoteNodeRow(node: child, depth: depth + 1, coordinator: coordinator, collapsed: $collapsed, onOpen: onOpen)
            }
        }
    }

    /// The cached icon of the host if this Mac already has one. It never fetches an icon for a remote tab: that would contact a
    /// site this Mac has not opened.
    @ViewBuilder private var tabIcon: some View {
        let size = SidebarMetrics.rowIconSize
        if let host = node.webURL?.host(), let favicon = coordinator.context.favicons.cached(for: host) {
            FaviconImage(image: favicon)
                .frame(width: size - 1, height: size - 1)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tight, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.69))
                .foregroundStyle(.secondary)
        }
    }

    private func label(title: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: SidebarMetrics.rowIconSpacing) {
            icon()
                .frame(minWidth: SidebarMetrics.rowIconSize, minHeight: SidebarMetrics.rowIconSize)
            Text(verbatim: title)
                .font(BrowserSettings.application.sidebarFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * Self.indent)
        .padding(.horizontal, SidebarMetrics.rowContentPadding(style: .full))
        .frame(height: SidebarMetrics.rowHeight(settings: BrowserSettings.application))
        .sidebarRowSelectionEffect(isSelected: false, isHovering: hovering)
        .contentShape(Rectangle())
        .onHover { over in
            withAnimation(Theme.Motion.quick) { hovering = over }
        }
    }
}
