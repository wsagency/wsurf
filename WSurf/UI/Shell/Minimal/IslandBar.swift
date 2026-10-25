// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// The Minimal window's floating bar. Its middle is the same Ask surface as the toolbar's, so it carries the address,
/// asking the assistant and its replies, agent questions, the engine badge, the password and passkey save badge, Input
/// History, Reader, translation and site controls. Around it: the tab list button, Back/Forward/Reload, the AI mark of a
/// tab an app controls, the external-connection badge with Stop, downloads while they run, extensions and the side panel.
struct IslandBar: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator
    let edge: MinimalBarEdge
    var onTabButtonFrame: (CGRect) -> Void = { _ in }

    static let height: CGFloat = 44
    private static let extensionBudget: CGFloat = 3 * 36

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// Wide enough for the address and its badges; wider with the full address on. Never wider than the window allows.
    static func width(fullAddress: Bool, available: CGFloat) -> CGFloat {
        min(fullAddress ? 860 : 720, max(available, 0))
    }

    /// The gap between the bar and the window edge follows the theme's page spacing (14 pt at the default 6 pt).
    static func edgeGap(pageSpacing: CGFloat) -> CGFloat {
        pageSpacing + 8
    }

    /// A capsule at the theme's default corner rounding and above, square at none.
    static func cornerRadius(cornerScale: CGFloat) -> CGFloat {
        height / 2 * min(max(cornerScale, 0), 1)
    }

    /// The window's tabs, without the rows that stand for its pages in micro windows.
    static func tabCount(of browser: BrowserModel) -> Int {
        browser.tabs.count(where: { $0.microTabID == nil })
    }

    static func tabCountSymbol(_ count: Int) -> String {
        (1...50).contains(count) ? "\(count).square" : "square.on.square"
    }

    private var ground: NSColor {
        LoomChrome.sampledColor(
            ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
            scheme: scheme,
            isFloating: true
        )
    }

    private var showsTabList: Bool {
        coordinator.isMinimalTabListOpen || coordinator.keepsMinimalSidebarOpen
    }

    private var tabListLabel: LocalizedStringResource {
        showsTabList ? "Hide Tabs" : "Show Tabs"
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: Self.cornerRadius(cornerScale: BrowserSettings.application.chromeShape.cornerScale),
            style: .continuous
        )
        let isLight = PageInk.isLight(ground, scheme: scheme)

        HStack(spacing: 4) {
            ToolbarButton(
                symbol: Self.tabCountSymbol(Self.tabCount(of: browser)),
                enabled: true,
                isOn: showsTabList,
                help: String(localized: tabListLabel)
            ) {
                coordinator.toggleSidebar()
            }
            .accessibilityLabel(Text(tabListLabel))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onTabButtonFrame($0) }

            ToolbarNavigationControls(browser: browser, coordinator: coordinator)

            AskSurface(placement: .toolbar, browser: browser, coordinator: coordinator, opensUpward: edge == .bottom)
                .holdsWindowStillOnHover()

            if let tab = browser.activeTab {
                ExternalControlMark(tab: tab, coordinator: coordinator)
            }
            ExternalConnectionBadge(server: coordinator.mcpServer, browser: browser)
            if browser.downloads.activeCount > 0 {
                SidebarDownloadsButton(coordinator: coordinator)
            }
            if !coordinator.isShowingSettings {
                StoreInstallButton(manager: coordinator.extensions, browser: browser)
            }
            ExtensionActionsCluster(
                manager: coordinator.extensions,
                browser: browser,
                availableWidth: Self.extensionBudget
            )
            SidePanelToggle(coordinator: coordinator)
        }
        .padding(.horizontal, 4)
        .frame(height: Self.height)
        .background {
            // The theme's floating ground: glass, plain or solid as the theme says, opaque under Reduce Transparency and
            // Increase Contrast. Only the ground is clipped, so the address's results can grow past the bar.
            ZStack {
                LoomFloatingFill(
                    sampledPageColor: ChromeBand.pageColor(browser: browser, coordinator: coordinator),
                    settings: BrowserSettings.application
                )
                WindowDragArea()
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    Theme.chrome(GlassPolicy.borderOpacity(contrast: contrast)),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
            }
            .shadow(color: .black.opacity(isLight ? 0.12 : 0.3), radius: 10, y: 3)
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
