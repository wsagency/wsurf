// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

/// The menu after Help named for the site in front (View › Show Site in Menu Bar, off by default).
extension MainMenu {
    func siteMenu() -> NSMenuItem {
        let menu = NSMenu()
        let address = NSMenuItem(title: "", action: #selector(showSiteAddress), keyEquivalent: "")
        address.target = self
        menu.addItem(address)
        menu.addItem(.separator())
        // No shortcuts here: Edit and File own ⇧⌘C and ⌘L, and one chord must not sit in two menus.
        menu.addItem(command("Copy Link", #selector(copyPageURL)))
        menu.addItem(command("Open Location…", #selector(openLocation)))
        let holder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        holder.submenu = menu
        holder.isHidden = true
        siteMenuItem = holder
        return holder
    }

    /// The coordinator whose site the menu names: the window in front, unless a window that is not a browser window is key.
    private var siteCoordinator: AppCoordinator? {
        if let key = PasswordsWindow.keyWindow() {
            let window = key.sheetParent ?? key
            let windows = application?.windows ?? fallbackCoordinator.map { [$0] } ?? []
            guard windows.contains(where: { $0.nativeWindow === window }) else { return nil }
        }
        return application?.activeCoordinator ?? fallbackCoordinator
    }

    /// Hides the site menu, or names it for the front window's site. The menu bar draws the submenu's title, so both are
    /// written; each only when it changed, since AppKit redraws the menu bar for every write.
    func refreshSiteItem() {
        guard let item = siteMenuItem else { return }
        let host = siteCoordinator?.menuBarHost
        if item.isHidden != (host == nil) {
            item.isHidden = host == nil
        }
        guard let host else { return }
        if item.title != host {
            item.title = host
        }
        if item.submenu?.title != host {
            item.submenu?.title = host
        }
    }

    @objc func someWindowBecameKey(_ notification: Notification) {
        refreshSiteItem()
    }

    @objc func toggleSiteInMenuBar() {
        coordinator.settings.showsSiteInMenuBar.toggle()
        refreshSiteItem()
    }

    /// Only carries the address in the site menu; it has nothing to do.
    @objc func showSiteAddress() {}

    /// The answer for the two items of this menu's own making, nil for any other. The address row is the page's whole address
    /// as the address bar draws it (`AddressText`), cut in the middle when long; it is set when the menu opens, not on every
    /// navigation, and is always disabled: a label.
    func validateSiteItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(toggleSiteInMenuBar):
            menuItem.state = coordinator.settings.showsSiteInMenuBar ? .on : .off
            return true
        case #selector(showSiteAddress):
            let text = coordinator.menuBarAddress?.text ?? ""
            menuItem.title = text.count > 80 ? String(text.prefix(40)) + "…" + String(text.suffix(39)) : text
            return false
        default:
            return nil
        }
    }
}
