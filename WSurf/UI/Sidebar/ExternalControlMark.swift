// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The AI mark of a tab that an external app holds a grant for, in its sidebar row, split cell or Favorites tile. It shows
/// for exactly as long as a connection may use the tab, between its calls too, so a tab worked on in the background is
/// never unmarked. The full form opens Take Over and Stop; every surface also has them in its context menu.
struct ExternalControlMark: View {
    let tab: BrowserTab
    let coordinator: AppCoordinator
    /// The icon-sized form for an icons-only sidebar, a split cell and a Favorites tile: no text and no button.
    var isCompact = false

    var body: some View {
        // The tab's own record is the cheap gate: rows of tabs that no connection holds never read the server.
        if !tab.processState.externalControllers.isEmpty {
            let controllers = coordinator.mcpServer.controllers(of: tab, in: coordinator.browser)
            if !controllers.isEmpty {
                if isCompact {
                    ExternalControlDot(tab: tab, controllers: controllers)
                } else {
                    ExternalControlBadge(tab: tab, controllers: controllers, coordinator: coordinator)
                }
            }
        }
    }

    /// "Codex controls this tab" or "Codex can read this tab"; with several apps, how many. Read-only sharing, control and a
    /// running call each read differently, so the mark never claims more than the grants give.
    static func label(for controllers: [MCPBrowserSession], tab: BrowserTab) -> String {
        guard let first = controllers.first else { return "" }
        let controls = controllers.contains { ($0.grants[tab.id]?.access ?? .readOnly) != .readOnly }
        switch (controllers.count, controls) {
        case (1, true):
            return String(localized: "\(first.displayName) controls this tab")
        case (1, false):
            return String(localized: "\(first.displayName) can read this tab")
        case (_, true):
            return String(localized: "\(controllers.count) apps control this tab")
        default:
            return String(localized: "\(controllers.count) apps can read this tab")
        }
    }

    static func state(of tab: BrowserTab) -> Text {
        tab.processState.isExternalAutomationWorking ? Text("Working") : Text("Idle")
    }
}

/// The full mark: "AI" with the connection glyph, or a spinner while a call works on the tab.
private struct ExternalControlBadge: View {
    let tab: BrowserTab
    let controllers: [MCPBrowserSession]
    let coordinator: AppCoordinator

    @State private var showsPopover = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let label = ExternalControlMark.label(for: controllers, tab: tab)
        let isWorking = tab.processState.isExternalAutomationWorking
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                if isWorking {
                    Spinner(size: 9)
                } else {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text("AI")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Capsule().fill(Theme.warning.opacity(isWorking ? 0.24 : 0.13)))
            .overlay {
                Capsule().strokeBorder(Theme.warning.opacity(contrast == .increased ? 0.95 : 0.45), lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(ExternalControlMark.state(of: tab))
        .accessibilityHint(Text("Lets you take over this tab or stop the app."))
        .popover(isPresented: $showsPopover, arrowEdge: .trailing) {
            ExternalControlPopover(tab: tab, controllers: controllers) {
                showsPopover = false
                coordinator.mcpServer.takeOver(tab, in: coordinator.browser)
            } stop: {
                showsPopover = false
                coordinator.mcpServer.stop(controllersOf: tab, in: coordinator.browser)
            }
        }
    }
}

/// The compact mark: the connection glyph on a small disc at the corner of the tab's icon. It does not take clicks; the
/// tab's context menu has the actions.
private struct ExternalControlDot: View {
    let tab: BrowserTab
    let controllers: [MCPBrowserSession]

    var body: some View {
        let label = ExternalControlMark.label(for: controllers, tab: tab)
        Image(systemName: "cable.connector")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(Theme.warning)
            .frame(width: 11, height: 11)
            .background(Circle().fill(.background))
            .overlay { Circle().strokeBorder(Theme.warning, lineWidth: 1) }
            .offset(x: 3, y: 2)
            .allowsHitTesting(false)
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(ExternalControlMark.state(of: tab))
    }
}

private struct ExternalControlPopover: View {
    let tab: BrowserTab
    let controllers: [MCPBrowserSession]
    let takeOver: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controllers) { session in
                HStack(spacing: 6) {
                    Text(verbatim: session.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let access = session.grants[tab.id]?.access {
                        Text(access.tierTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if tab.processState.isExternalAutomationWorking {
                        Text("Working")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Taking over ends their access to this tab. Stopping ends their access to this window’s tabs, and they need your approval to connect again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: takeOver) {
                    Text("Take Over")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .accessibilityHint(Text("Ends their access to this tab only."))
                Button(action: stop) {
                    Text("Stop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
                .controlSize(.large)
                .accessibilityHint(Text("Disconnects them from every tab in this window."))
            }
        }
        .padding(SiteControlsMetrics.inset)
        .frame(width: 280)
        .background(.ultraThickMaterial)
    }
}

/// Take Over and Stop for tabs that external apps hold, at the top of a tab's or a split's context menu. Nothing when no
/// connection holds them.
struct ExternalControlMenuItems: View {
    let tabs: [BrowserTab]
    let coordinator: AppCoordinator

    var body: some View {
        let server = coordinator.mcpServer
        let held = tabs.filter { !$0.processState.externalControllers.isEmpty }
        let controllers = held.flatMap { server.controllers(of: $0, in: coordinator.browser) }
        let apps = Dictionary(grouping: controllers, by: \.id).compactMap { $0.value.first }
        if let first = apps.first {
            Button {
                for tab in held {
                    server.takeOver(tab, in: coordinator.browser)
                }
            } label: {
                if held.count == 1 {
                    Label("Take Over Tab", systemImage: "hand.raised")
                } else {
                    Label("Take Over Tabs", systemImage: "hand.raised")
                }
            }
            Button(role: .destructive) {
                for tab in held {
                    server.stop(controllersOf: tab, in: coordinator.browser)
                }
            } label: {
                if apps.count == 1 {
                    Label("Stop \(first.displayName)", systemImage: "stop.circle")
                } else {
                    Label("Stop \(apps.count) Apps", systemImage: "stop.circle")
                }
            }
            Divider()
        }
    }
}
