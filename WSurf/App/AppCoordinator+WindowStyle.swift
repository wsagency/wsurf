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
        isMinimal && settings.keepsMinimalSidebarOpen
    }

    /// View › Hide Sidebar (⌃⌘S). In the Minimal window it shows and hides the tab list, and leaves the Standard
    /// sidebar's own state alone. Hiding a list that was kept open lets go of the pin, so it hides.
    func toggleSidebar() {
        if !browserVisible {
            showBrowser()
        }
        if isMinimal {
            if keepsMinimalSidebarOpen {
                settings.keepsMinimalSidebarOpen = false
                isMinimalTabListOpen = false
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
        isMinimalTabListOpen = false
    }

    /// View › Use Minimal / Standard Window Style (⇧⌘M). The choice is app-wide, so every window follows.
    func toggleWindowStyle() {
        if !browserVisible {
            showBrowser()
        }
        isMinimalTabListOpen = false
        settings.windowStyle = isMinimal ? .standard : .minimal
    }

    /// View › Move Bar to Top / Bottom, in the Minimal window.
    func moveMinimalBar() {
        settings.minimalBarEdge = settings.minimalBarEdge == .top ? .bottom : .top
    }
}
