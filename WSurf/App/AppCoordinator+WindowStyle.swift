// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension AppCoordinator {
    var isMinimal: Bool {
        settings.windowStyle == .minimal
    }

    /// View › Hide Sidebar (⌃⌘S). In the Minimal window it shows and hides the tab list, and leaves the Standard
    /// sidebar's own state alone.
    func toggleSidebar() {
        if !browserVisible {
            showBrowser()
        }
        if isMinimal {
            isMinimalTabListOpen.toggle()
            return
        }
        sidebar.toggleVisible()
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
