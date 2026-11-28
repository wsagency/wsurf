// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// The micro window's bar: full width and flush with the top edge, as tall as the band the traffic lights are centred in, so
/// the native window buttons sit on it. The middle is the same Ask surface as the toolbar's, so it carries the address, the
/// assistant, and the badges, among them the one that moves the page back to the main window.
struct MicroBar: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.windowControlsInset) private var windowControlsInset

    private var ground: NSColor {
        LoomChrome.sampledColor(
            ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
            scheme: scheme,
            isFloating: true
        )
    }

    private var floatHelp: LocalizedStringResource {
        coordinator.floatsOnTop ? "Stop Floating on Top" : "Float on Top"
    }

    var body: some View {
        let isLight = PageInk.isLight(ground, scheme: scheme)

        VStack(spacing: 0) {
            HStack(spacing: 4) {
                // The window buttons are drawn by the window, over this space.
                Color.clear.frame(width: windowControlsInset - 4)

                ToolbarNavigationControls(browser: browser, coordinator: coordinator)

                AskSurface(placement: .toolbar, browser: browser, coordinator: coordinator)
                    .holdsWindowStillOnHover()

                if browser.tabs.count > 1 {
                    MicroTabSwitcherPill(browser: browser)
                }

                AudioIndicatorButton(coordinator: coordinator, style: .bar, listEdge: .bottom)

                ToolbarButton(
                    symbol: coordinator.floatsOnTop ? "square.3.layers.3d.top.filled" : "square.3.layers.3d",
                    enabled: true,
                    isOn: coordinator.floatsOnTop,
                    help: String(localized: floatHelp)
                ) {
                    coordinator.floatsOnTop.toggle()
                }
                .accessibilityLabel(Text(floatHelp))
            }
            .padding(.horizontal, 4)
            .frame(height: IslandBar.height)

            if let companion = browser.agentCompanion {
                AgentMicroControlBar(companion: companion, coordinator: coordinator)
            }
        }
        .background {
            // The theme's floating ground, opaque under Reduce Transparency and Increase Contrast. Dragging it moves the window.
            ZStack {
                LoomFloatingFill(
                    sampledPageColor: ChromeBand.pageColor(browser: browser, coordinator: coordinator),
                    settings: BrowserSettings.application
                )
                WindowDragArea()
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.chrome(GlassPolicy.borderOpacity(contrast: contrast)))
                    .frame(height: contrast == .increased ? 1 : 0.5)
            }
        }
        .environment(\.chromeIsLight, isLight)
        .environment(\.chromeWash, .of(ground, isLight: isLight))
        .environment(\.windowColorScheme, scheme)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .animation(nil, value: isLight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Toolbar"))
    }
}

/// Compact tab count/switcher pill shown in `MicroBar` when an Agent Micro Window holds more than one tab.
struct MicroTabSwitcherPill: View {
    let browser: BrowserModel

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Menu {
            ForEach(browser.tabs) { tab in
                Button {
                    browser.activate(tab)
                } label: {
                    if browser.activeTabID == tab.id {
                        Label(tab.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: tab.title)
                    }
                }
            }
            if let active = browser.activeTab {
                AgentTabCleanupMenuItems(tabs: [active], browser: browser)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: "\(browser.tabs.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Theme.chrome(0.10)))
            .overlay {
                Capsule().strokeBorder(Theme.chrome(contrast == .increased ? 0.55 : 0.22), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Switch Tabs"))
        .accessibilityLabel(Text("Switch Tabs"))
        .accessibilityValue(Text("\(browser.tabs.count) tabs"))
    }
}

/// Always-visible status chip and one-click ownership controls (Take Over, Hand Back, Stop) for an Agent Micro Window.
struct AgentMicroControlBar: View {
    static let height: CGFloat = 30

    let companion: AgentCompanionInfo
    let coordinator: AppCoordinator

    @Environment(\.colorSchemeContrast) private var contrast

    static func statusSummary(for companion: AgentCompanionInfo) -> String {
        let host = companion.displayHostName
        switch companion.owner {
        case .agent:
            if let title = companion.displayThreadTitle {
                return "\(host) · \(title) · \(String(localized: "MCP Allowed"))"
            }
            return "\(host) · \(String(localized: "MCP Allowed"))"
        case .human:
            return "\(host) · \(String(localized: "Human Control"))"
        case .unclaimed:
            return "\(host) · \(String(localized: "Unclaimed"))"
        }
    }

    private var accentColor: Color {
        companion.owner == .agent ? Theme.warning : Theme.accentText
    }

    var body: some View {
        let summary = Self.statusSummary(for: companion)
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                if companion.isWorking && companion.owner == .agent {
                    Spinner(size: 10)
                } else {
                    Image(systemName: companion.owner == .human ? "hand.raised.fill" : "cable.connector")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: summary)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(accentColor.opacity(companion.isWorking ? 0.22 : 0.13)))
            .overlay {
                Capsule().strokeBorder(
                    accentColor.opacity(contrast == .increased ? 0.95 : 0.42),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: summary))
            .accessibilityValue(companion.isWorking ? Text("Working") : Text("Idle"))

            Spacer(minLength: 4)

            if companion.owner != .human {
                Button {
                    coordinator.takeOverAgentMicroWindow()
                } label: {
                    Text("Take Over")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "Take over control of this window from the external agent."))
            } else {
                Button {
                    coordinator.handBackAgentMicroWindow()
                } label: {
                    Text("Hand Back")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(String(localized: "Return control of this window to the external agent."))
            }

            Button(role: .destructive) {
                coordinator.stopAgentMicroWindow()
            } label: {
                Text("Stop")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(Theme.danger)
            .controlSize(.small)
            .help(String(localized: "Stop external agent control and disconnect this window’s session."))
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.chrome(GlassPolicy.borderOpacity(contrast: contrast)))
                .frame(height: 0.5)
        }
    }
}
