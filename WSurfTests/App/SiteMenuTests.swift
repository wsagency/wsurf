// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Testing

@testable import WSurf

/// The menu after Help named for the site in front (View › Show Site in Menu Bar). Menu items are plain objects, so nothing here
/// needs the real menu bar; a background test host cannot make a window key, so the key window is the `PasswordsWindow.keyWindow`
/// seam and `windowDidBecomeKey()` is called directly.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SiteMenuTests {
    /// Runs `body` with Show Site in Menu Bar on, and puts the app-wide setting back after: it must not leak into later suites.
    private func withSiteSetting(_ isOn: Bool = true, _ body: () throws -> Void) rethrows {
        let settings = BrowserSettings.application
        let saved = settings.showsSiteInMenuBar
        let savedKeyWindow = PasswordsWindow.keyWindow
        settings.showsSiteInMenuBar = isOn
        PasswordsWindow.keyWindow = { nil }
        defer {
            settings.showsSiteInMenuBar = saved
            PasswordsWindow.keyWindow = savedKeyWindow
        }
        try body()
    }

    private func coordinator(showing address: String?, isPrivate: Bool = false) -> AppCoordinator {
        let context = BrowserProfileContext.shared(for: isPrivate ? .privateBrowsing() : .original())
        let coordinator = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        if let address {
            coordinator.browser.activate(coordinator.browser.addPage(address))
        }
        return coordinator
    }

    private func host(of address: String, isPrivate: Bool = false) -> String? {
        let window = coordinator(showing: address, isPrivate: isPrivate)
        defer { window.closeWindow() }
        return window.menuBarHost
    }

    // MARK: - What the title says

    @Test func aWebsiteShowsItsNameWithoutWWWPathOrQuery() {
        withSiteSetting {
            #expect(host(of: "https://www.example.com/account?token=secret#frag") == "example.com")
            #expect(host(of: "http://docs.example.org:8080/a/b") == "docs.example.org")
        }
    }

    /// The raw address would read `bank.com@evil.com`: the menu bar shows the website the page really is.
    @Test func signInDetailsInTheAddressNeverPoseAsTheWebsite() {
        withSiteSetting {
            #expect(host(of: "https://bank.com@evil.com") == "evil.com")
            #expect(host(of: "https://bank.com:pa55@evil.com/login") == "evil.com")
        }
    }

    @Test func aNonASCIIWebsiteShowsAsPunycode() {
        withSiteSetting {
            #expect(host(of: "https://\u{0430}pple.com/") == "xn--pple-43d.com", "a Cyrillic “а” must not pass for a Latin “a”")
        }
    }

    @Test func aLongNameIsCutAtThirtyTwoCharacters() throws {
        try withSiteSetting {
            let long = String(repeating: "a", count: 40) + ".example"
            let name = try #require(host(of: "https://\(long)/"))
            #expect(name.count == 32 && name.hasSuffix("…"))
            #expect(host(of: "https://\(String(repeating: "b", count: 27)).com/")?.count == 31, "short enough stays whole")
        }
    }

    @Test func pagesThatAreNotWebsitesShowNothing() {
        withSiteSetting {
            for address in ["about:blank", "file:///Users/someone/secret.html", "data:text/html,hi", "wsurf://settings",
                            "javascript:alert(1)", "not a url", ""] {
                #expect(host(of: address) == nil, "\(address)")
            }
            #expect(coordinator(showing: nil).menuBarHost == nil, "no tab")
        }
    }

    @Test func aSettingsPageShowsNothing() {
        withSiteSetting {
            let window = coordinator(showing: "https://example.com/")
            defer { window.closeWindow() }
            #expect(window.menuBarHost == "example.com")
            window.browser.showSettings()
            #expect(window.browser.activeTab?.isShowingSystemPage == true)
            #expect(window.menuBarHost == nil)
        }
    }

    @Test func aPrivateWindowShowsNothing() {
        withSiteSetting {
            #expect(host(of: "https://example.com/", isPrivate: true) == nil)
        }
    }

    @Test func anExtensionPageShowsNothing() {
        withSiteSetting {
            let window = coordinator(showing: nil)
            defer { window.closeWindow() }
            window.browser.extensionPageHost = { url in
                ExtensionPageHost(configuration: WebViewPool.makeConfiguration(), baseURL: url, name: "Stub", icon: nil)
            }
            window.browser.activate(window.browser.addPage("https://extension.example/popup.html"))
            #expect(window.browser.activeTab?.extensionBaseURL != nil)
            #expect(window.menuBarHost == nil, "an extension page's address is not a website")
        }
    }

    @Test func nothingIsComputedWhileTheSettingIsOff() {
        withSiteSetting(false) {
            #expect(host(of: "https://example.com/") == nil)
        }
    }

    // MARK: - The menu

    private struct Rig {
        let app: BrowserApplication
        let first: AppCoordinator
        let second: AppCoordinator
        let menu: MainMenu
    }

    private func withMenu(_ body: (Rig, NSMenuItem) throws -> Void) throws {
        let saved = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
        NSApp.mainMenu = nil
        NSApp.windowsMenu = nil
        let app = BrowserApplication()
        let first = coordinator(showing: "https://first.example/page")
        let second = coordinator(showing: "https://second.example/")
        app.register(first)
        app.register(second)
        let menu = MainMenu(application: app)
        menu.install()
        defer {
            first.closeWindow()
            second.closeWindow()
            NSApp.mainMenu = saved.0
            NSApp.windowsMenu = saved.1
            NSApp.helpMenu = saved.2
            NSApp.servicesMenu = saved.3
        }
        let item = try #require(NSApp.mainMenu?.items.last)
        try body(Rig(app: app, first: first, second: second, menu: menu), item)
    }

    @Test func theSiteMenuComesAfterHelpAndIsHiddenByDefault() throws {
        try withSiteSetting(false) {
            try withMenu { _, item in
                let titles = try #require(NSApp.mainMenu).items.map(\.title)
                #expect(titles.suffix(2) == ["Help", ""], "after Help: \(titles)")
                #expect(item.isHidden, "off: no menu")
            }
        }
    }

    @Test func theTitleOfBothTheItemAndTheSubmenuFollowsTheKeyWindowAndNavigation() throws {
        try withSiteSetting {
            try withMenu { rig, item in
                rig.first.windowDidBecomeKey()
                #expect(!item.isHidden)
                #expect(item.title == "first.example" && item.submenu?.title == "first.example", "the bar draws the submenu's title")

                rig.second.windowDidBecomeKey()
                #expect(item.title == "second.example" && item.submenu?.title == "second.example")

                rig.second.browser.activeTab?.urlString = "https://moved.example/next"
                rig.menu.refreshSiteItem()
                #expect(item.title == "moved.example" && item.submenu?.title == "moved.example")

                rig.first.windowDidBecomeKey()
                #expect(item.title == "first.example")
            }
        }
    }

    @Test func theMenuHidesForAPrivateWindowAnInternalPageAndAWindowThatIsNotABrowserWindow() throws {
        try withSiteSetting {
            try withMenu { rig, item in
                rig.first.windowDidBecomeKey()
                #expect(!item.isHidden)

                rig.first.browser.showSettings()
                rig.menu.refreshSiteItem()
                #expect(item.isHidden, "a Settings page")

                rig.second.windowDidBecomeKey()
                #expect(!item.isHidden)
                PasswordsWindow.keyWindow = { NSWindow() }
                rig.menu.refreshSiteItem()
                #expect(item.isHidden, "Passwords, About or the Settings window is key")
                PasswordsWindow.keyWindow = { nil }

                let priv = coordinator(showing: "https://private.example/", isPrivate: true)
                defer { priv.closeWindow() }
                rig.app.register(priv)
                priv.windowDidBecomeKey()
                #expect(item.isHidden, "a private window")
            }
        }
    }

    @Test func turningTheSettingOffHidesTheMenu() throws {
        try withSiteSetting {
            try withMenu { rig, item in
                rig.first.windowDidBecomeKey()
                #expect(!item.isHidden)
                BrowserSettings.application.showsSiteInMenuBar = false
                rig.menu.refreshSiteItem()
                #expect(item.isHidden)
            }
        }
    }

    @Test func theSubmenuHoldsTheAddressCopyLinkAndOpenLocation() throws {
        try withSiteSetting {
            try withMenu { rig, item in
                rig.first.windowDidBecomeKey()
                let items = try #require(item.submenu).items
                let address = try #require(items.first)
                #expect(!rig.menu.validateMenuItem(address), "the address row is only a label")
                #expect(address.title == "https://first.example/page", "the address bar's own rebuilt text")
                let copy = try #require(items.first { $0.title == "Copy Link" })
                let open = try #require(items.first { $0.title == "Open Location…" })
                #expect(rig.menu.validateMenuItem(copy) && rig.menu.validateMenuItem(open))
                #expect(items.allSatisfy { $0.keyEquivalent.isEmpty }, "⇧⌘C and ⌘L stay on one item each")
            }
        }
    }

    /// The row names the address as `AddressText` rebuilds it: no sign-in details in front of the host.
    @Test func theAddressRowNeverShowsSignInDetails() throws {
        try withSiteSetting {
            try withMenu { rig, item in
                rig.first.browser.activeTab?.urlString = "https://bank.com@evil.com/login"
                rig.first.windowDidBecomeKey()
                let address = try #require(item.submenu?.items.first)
                _ = rig.menu.validateMenuItem(address)
                #expect(!address.title.contains("bank.com"), address.title)
                #expect(address.title.contains("evil.com"))
            }
        }
    }

    @Test func viewShowSiteInMenuBarTurnsItOnAndOffWithACheckmark() throws {
        try withSiteSetting(false) {
            try withMenu { rig, item in
                let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
                let toggle = try #require(view.items.first { $0.title == "Show Site in Menu Bar" })
                rig.first.windowDidBecomeKey()
                #expect(rig.menu.validateMenuItem(toggle) && toggle.state == .off)
                let action = try #require(toggle.action)
                _ = NSApp.sendAction(action, to: toggle.target, from: toggle)
                #expect(BrowserSettings.application.showsSiteInMenuBar)
                #expect(rig.menu.validateMenuItem(toggle) && toggle.state == .on)
                #expect(!item.isHidden && item.title == "first.example")
                _ = NSApp.sendAction(action, to: toggle.target, from: toggle)
                #expect(!BrowserSettings.application.showsSiteInMenuBar && item.isHidden)
            }
        }
    }
}
