// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

extension AppCoordinator {
    var isMinimal: Bool {
        settings.windowStyle == .minimal
    }

    /// The Minimal window's tab list stays docked open: the person pinned it, and the page sits beside it.
    var keepsMinimalSidebarOpen: Bool {
        isMinimal && settings.keepsMinimalSidebarOpen && !hidesPinnedSidebar
    }

    /// View › Hide Sidebar (⌃⌘S). In the Minimal window it shows and hides the tab list, and leaves the Standard
    /// sidebar's own state alone. Showing a pinned list restores its place beside the page.
    func toggleSidebar() {
        if !browserVisible {
            showBrowser()
        }
        if isMinimal {
            if keepsMinimalSidebarOpen {
                hidesPinnedSidebar = true
                isMinimalTabListOpen = false
            } else if settings.keepsMinimalSidebarOpen && !isMinimalTabListOpen {
                hidesPinnedSidebar = false
            } else {
                isMinimalTabListOpen.toggle()
            }
            return
        }
        sidebar.toggleVisible()
    }

    /// View › Keep Sidebar Open, and the pin in the tab list's header, in the Minimal window. Pinned, the list docks and the
    /// page is laid out beside it; unpinned, it goes back to sliding in over the page when pointed at.
    func toggleMinimalSidebarPin() {
        guard isMinimal else { return }
        if !browserVisible {
            showBrowser()
        }
        settings.keepsMinimalSidebarOpen.toggle()
        hidesPinnedSidebar = false
        isMinimalTabListOpen = false
    }

    /// View › Use Minimal / Standard Window Style (⇧⌘M). The choice is app-wide, so every window follows.
    func toggleWindowStyle() {
        if !browserVisible {
            showBrowser()
        }
        isMinimalTabListOpen = false
        hidesPinnedSidebar = false
        settings.windowStyle = isMinimal ? .standard : .minimal
    }

    /// The Minimal bar is a panel of its own over this window: the Minimal window style, a placement of floating, and not
    /// full screen, where the window has room for the bar and docks it for the while. Micro windows keep their own bar. Every
    /// decision about the panel, in the host and in the shell, reads this and never the setting alone.
    var barFloats: Bool {
        isMinimal && !isMicro && settings.minimalBarPlacement == .floating && !windowIsFullScreen
    }

    /// View › Move Bar to Top / Bottom, in the Minimal window. A floating bar docks to the edge it is sent to.
    func moveMinimalBar() {
        settings.minimalBarEdge = settings.minimalBarEdge == .top ? .bottom : .top
        settings.minimalBarPlacement = .window
    }

    /// View › Detach Toolbar / Dock Toolbar, the bar's context menu and the icon in the tab list, in the Minimal window.
    func toggleToolbarDetached() {
        guard isMinimal else { return }
        if !browserVisible {
            showBrowser()
        }
        settings.minimalBarPlacement = settings.minimalBarPlacement == .floating ? .window : .floating
    }

    func dockToolbar() {
        settings.minimalBarPlacement = .window
    }
}
