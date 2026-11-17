// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

/// What `MainMenu` keeps for the menu after Help named for the site in front (View › Show Site in Menu Bar, off by default).
struct SiteMenuState {
    /// The top-level item, built once per `install()`.
    var item: NSMenuItem?
    /// A refresh is queued for the next run-loop turn; every window notification of the turn shares it.
    var refreshPending = false
    /// How many times the menu was brought up to date, and how many window notifications reached it (for tests).
    var refreshCount = 0
    var notificationCount = 0
}

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
        site.item = holder
        return holder
    }

    /// The menu follows the key window, so it is brought up to date when a window gains or loses key (a window that is not a
    /// browser window, Passwords or About, takes the menu away; a minimised or closed window leaves no key window) and when one
    /// closes. Installing again replaces the observers instead of adding a second set; an observer that is not removed goes with
    /// the menu when it is deallocated.
    func watchSiteWindows() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(siteWindowChanged), name: name, object: nil)
        }
    }

    /// One refresh a turn, however many notifications. It runs on the next turn, so a window that closes or minimises has left
    /// the window list, and a successor has become key, by the time the menu looks.
    @objc func siteWindowChanged(_ notification: Notification) {
        site.notificationCount += 1
        guard !site.refreshPending else { return }
        site.refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.site.refreshPending = false
            self?.refreshSiteItem()
        }
    }

    /// The browser window the menu names: the key window, a sheet on it counting as the window it hangs from. Nil when no window
    /// is key (every window is minimised or closed) and when the key window is not a browser window, so the menu never names a
    /// site for a window that is not in front. It is not `activeCoordinator`, which falls back to the window used last.
    private var siteCoordinator: AppCoordinator? {
        guard let key = PasswordsWindow.keyWindow() else { return nil }
        let window = key.sheetParent ?? key
        let windows = application?.windows ?? fallbackCoordinator.map { [$0] } ?? []
        return windows.first { !$0.isClosed && $0.nativeWindow === window }
    }

    /// Hides the site menu, or names it for the front window's site. The menu bar draws the submenu's title, so both are
    /// written; each only when it changed, since AppKit redraws the menu bar for every write.
    func refreshSiteItem() {
        site.refreshCount += 1
        guard let item = site.item else { return }
        let host = siteCoordinator?.menuBarHost
        if item.isHidden != (host == nil) {
            item.isHidden = host == nil
        }
        guard let host else { return }
        if item.title != host {
            item.title = host
            item.setAccessibilityLabel(String(localized: "Site: \(host)"))
        }
        if item.submenu?.title != host {
            item.submenu?.title = host
        }
    }

    @objc func toggleSiteInMenuBar() {
        coordinator.settings.showsSiteInMenuBar.toggle()
        refreshSiteItem()
    }

    /// Only carries the address in the site menu; it has nothing to do.
    @objc func showSiteAddress() {}

    /// The answer for the two items of this menu's own making, nil for any other. The address row is the address of the page in
    /// front as the address bar draws it (`AddressText`), blank unless a browser window is key. Like the bar, it shortens what
    /// follows the website and the website's own leading labels, never the domain that owns the page: a cut through a long name
    /// would hide who owns it. It is set when the menu opens, not on every navigation, and is always disabled: a label.
    func validateSiteItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(toggleSiteInMenuBar):
            guard let front = application?.activeCoordinator ?? fallbackCoordinator else { return false }
            menuItem.state = front.settings.showsSiteInMenuBar ? .on : .off
            return true
        case #selector(showSiteAddress):
            let address = siteCoordinator?.menuBarAddress
            let rest = address?.rest ?? ""
            let text = address.map { $0.scheme + AddressText.shortened(host: $0.host, to: 64) } ?? ""
            menuItem.title = text + (rest.count > 48 ? String(rest.prefix(47)) + "…" : rest)
            menuItem.setAccessibilityLabel(address == nil ? nil : String(localized: "Address: \(menuItem.title)"))
            return false
        default:
            return nil
        }
    }
}
