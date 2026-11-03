// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// The address bar's window control, beside Reader and the pin: it moves the page in front into a micro window, or, in a
/// micro window, back to the main window. It is a window action next to the pin action, and the micro bar gets Move Back
/// from it without a control of its own.
struct MicroWindowBadge: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    enum Offer: Equatable {
        case moveOut
        case moveBack
    }

    /// What the badge offers for the page in front: nothing for an internal page, a page that has none yet, or a window that
    /// cannot take it.
    static func offer(for coordinator: AppCoordinator, tab: BrowserTab?) -> Offer? {
        guard let tab else { return nil }
        if coordinator.isMicro {
            return tab.urlString.isEmpty ? nil : .moveBack
        }
        return coordinator.canMoveToMicroWindow(tab) ? .moveOut : nil
    }

    var body: some View {
        let tab = browser.activeTab
        switch Self.offer(for: coordinator, tab: tab) {
        case .moveOut:
            ChromeIcon(
                symbol: "arrow.up.forward.square",
                weight: .semibold,
                help: String(localized: "Move to Micro Window")
            ) {
                if let tab {
                    coordinator.moveToMicroWindow(tab)
                }
            }
            .accessibilityLabel(Text("Move to Micro Window"))
        case .moveBack:
            ChromeIcon(
                symbol: "arrow.down.backward.square",
                weight: .semibold,
                help: String(localized: "Move Back to Main Window")
            ) {
                coordinator.moveBackToMainWindow()
            }
            .accessibilityLabel(Text("Move Back to Main Window"))
        case nil:
            EmptyView()
        }
    }
}

/// The mark on a sidebar row whose page is in a micro window, in the micro window's symbol. The row stays where the page
/// was; clicking it brings the page back, Option-clicking it shows the micro window.
struct MicroRowBadge: View {
    let tab: BrowserTab

    static let extent: CGFloat = 16

    var body: some View {
        if tab.microTabID != nil {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.extent, height: Self.extent)
                .help(Text("In a micro window. Click to move it back here, or Option-click to show the micro window."))
                .accessibilityLabel(Text("In Micro Window"))
        }
    }
}

/// The context menu items of a row whose page is in a micro window: show that window, or move the page back.
struct MicroRowMenuItems: View {
    let tab: BrowserTab
    let coordinator: AppCoordinator

    var body: some View {
        if tab.microTabID != nil {
            Button {
                coordinator.openMicroPlaceholder(tab, showingWindow: true)
            } label: {
                Label("Show Micro Window", systemImage: "arrow.up.forward.square")
            }
            Button {
                coordinator.openMicroPlaceholder(tab)
            } label: {
                Label("Move Back to Main Window", systemImage: "arrow.down.backward.square")
            }
        }
    }
}
