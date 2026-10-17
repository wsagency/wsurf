// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Shown in the toolbar while an external app can act in this window. It is the only way to see that a connection holds a
/// grant, so it stays visible for as long as one does, and its popover holds the Stop button.
struct ExternalConnectionBadge: View {
    let server: BrowserMCPServer
    let browser: BrowserModel

    var body: some View {
        let controllers = server.controllers(in: browser)
        if !controllers.isEmpty {
            ExternalConnectionChip(controllers: controllers) {
                server.stop(window: browser)
            }
        }
    }

    /// Client name and tier, such as "Claude Code · Development". With several apps the widest tier is shown.
    static func label(for controllers: [MCPBrowserSession]) -> String {
        guard let first = controllers.first else { return "" }
        let name = controllers.count == 1 ? first.displayName : String(localized: "\(first.displayName) +\(controllers.count - 1)")
        guard let tier = controllers.compactMap(\.tier).max(by: { $0.rank < $1.rank }) else { return name }
        return "\(name) · \(String(localized: tier.tierTitle))"
    }

    static func help(for controllers: [MCPBrowserSession]) -> String {
        guard let first = controllers.first else { return "" }
        return controllers.count == 1
            ? String(localized: "\(first.displayName) is using this window")
            : String(localized: "\(controllers.count) external apps are using this window")
    }
}

struct ExternalConnectionChip: View {
    let controllers: [MCPBrowserSession]
    let stop: () -> Void

    @State private var showsPopover = false
    @Environment(\.windowColorScheme) private var windowColorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var isWorking: Bool {
        controllers.contains(where: \.isWorking)
    }

    var body: some View {
        let help = ExternalConnectionBadge.help(for: controllers)
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                if isWorking {
                    Spinner(size: 11)
                } else {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: ExternalConnectionBadge.label(for: controllers))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .frame(maxWidth: Self.maximumWidth)
            .background(Capsule().fill(Theme.warning.opacity(isWorking ? 0.24 : 0.13)))
            .overlay {
                Capsule().strokeBorder(Theme.warning.opacity(contrast == .increased ? 0.95 : 0.45), lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
        .accessibilityValue(isWorking ? Text("Working") : Text("Idle"))
        .accessibilityHint(Text("Shows what it can use and lets you stop it."))
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            ExternalConnectionPopover(controllers: controllers) {
                showsPopover = false
                stop()
            }
            .environment(\.colorScheme, windowColorScheme)
        }
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "\(help). Press Option-Command-Period to stop it.")).post()
        }
    }

    /// The toolbar cluster reserves this much room for the badge; see `ContentNavBar`.
    static let maximumWidth: CGFloat = 200
}

private struct ExternalConnectionPopover: View {
    let controllers: [MCPBrowserSession]
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(controllers) { session in
                ExternalConnectionSection(session: session)
            }
            Text("Stopping ends their access to this window’s tabs. They need your approval to connect again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: stop) {
                Text("Stop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text("Disconnects every external app from this window."))
        }
        .padding(SiteControlsMetrics.inset)
        .frame(width: 300)
        .background(.ultraThickMaterial)
    }
}

private struct ExternalConnectionSection: View {
    let session: MCPBrowserSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: session.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let tier = session.tier {
                    Text(tier.tierTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(session.sharedTabs) { tab in
                ExternalConnectionTabRow(tab: tab)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ExternalConnectionTabRow: View {
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: tab.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if tab.processState.isExternalAutomationWorking {
                Text("Working")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
