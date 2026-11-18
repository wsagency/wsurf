// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Testing

@testable import WSurf

/// The menu after Help named for the site in front (View › Show Site in Menu Bar). Menu items are plain objects, so nothing here
/// needs the real menu bar. A background test host cannot make a window key, so the key window is the `PasswordsWindow.keyWindow`
/// seam (`Rig.becomeKey` points it at a window and runs the hook a real key change runs), and the notifications a real change
/// posts are posted by hand.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SiteMenuTests {
    /// Runs `body` with Show Site in Menu Bar on, and puts the app-wide setting back after: it must not leak into later suites.
    private func withSiteSetting(_ isOn: Bool = true, _ body: () async throws -> Void) async rethrows {
        let settings = BrowserSettings.application
        let saved = settings.showsSiteInMenuBar
        let savedKeyWindow = PasswordsWindow.keyWindow
        settings.showsSiteInMenuBar = isOn
        PasswordsWindow.keyWindow = { nil }
        defer {
            settings.showsSiteInMenuBar = saved
            PasswordsWindow.keyWindow = savedKeyWindow
        }
        try await body()
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

    @Test func aWebsiteShowsItsNameWithoutWWWPathOrQuery() async {
        await withSiteSetting {
            #expect(host(of: "https://www.example.com/account?token=secret#frag") == "example.com")
            #expect(host(of: "http://docs.example.org:8080/a/b") == "docs.example.org")
        }
    }

    /// The raw address would read `bank.com@evil.com`: the menu bar shows the website the page really is.
    @Test func signInDetailsInTheAddressNeverPoseAsTheWebsite() async {
        await withSiteSetting {
            #expect(host(of: "https://bank.com@evil.com") == "evil.com")
            #expect(host(of: "https://bank.com:pa55@evil.com/login") == "evil.com")
        }
    }

    @Test func aNonASCIIWebsiteShowsAsPunycode() async {
        await withSiteSetting {
            #expect(host(of: "https://\u{0430}pple.com/") == "xn--pple-43d.com", "a Cyrillic “а” must not pass for a Latin “a”")
        }
    }

    /// A long name loses whole labels at the front and keeps the domain that owns the page: a made-up name in front must not pose as it.
    @Test func aLongNameKeepsTheDomainThatOwnsThePage() async throws {
        try await withSiteSetting {
            let long = "accounts.bank.com." + String(repeating: "a", count: 30) + ".evil.example"
            let name = try #require(host(of: "https://\(long)/"))
            #expect(name == "…evil.example", "\(name)")
            #expect(host(of: "https://\(String(repeating: "b", count: 27)).com/")?.count == 31, "short enough stays whole")
        }
    }

    @Test func pagesThatAreNotWebsitesShowNothing() async {
        await withSiteSetting {
            let addresses = [
                "about:blank", "file:///Users/someone/secret.html", "data:text/html,hi", "wsurf://settings",
                "javascript:alert(1)", "not a url", "",
            ]
            for address in addresses {
                #expect(host(of: address) == nil, "\(address)")
            }
            #expect(coordinator(showing: nil).menuBarHost == nil, "no tab")
        }
    }

    @Test func aSettingsPageShowsNothing() async {
        await withSiteSetting {
            let window = coordinator(showing: "https://example.com/")
            defer { window.closeWindow() }
            #expect(window.menuBarHost == "example.com")
            window.browser.showSettings()
            #expect(window.browser.activeTab?.isShowingSystemPage == true)
            #expect(window.menuBarHost == nil)
        }
    }

    @Test func aPrivateWindowShowsNothing() async {
        await withSiteSetting {
            #expect(host(of: "https://example.com/", isPrivate: true) == nil)
        }
    }

    @Test func anExtensionPageShowsNothing() async {
        await withSiteSetting {
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

    @Test func nothingIsComputedWhileTheSettingIsOff() async {
        await withSiteSetting(false) {
            #expect(host(of: "https://example.com/") == nil)
        }
    }

    // MARK: - Shortening a host (the title: 32 characters; the address row: 64)

    private let label20 = String(repeating: "x", count: 20)
    private let label30 = String(repeating: "x", count: 30)
    private let label40 = String(repeating: "a", count: 40)

    private func check(_ table: [(host: String, limit: Int, expected: String)]) {
        for row in table {
            let shown = AddressText.shortened(host: row.host, to: row.limit)
            #expect(shown == row.expected, "\(row.host) to \(row.limit): \(shown)")
        }
    }

    @Test func aHostOfTheLimitStaysWholeAndOneCharacterMoreLosesItsFrontLabels() {
        #expect((label20 + ".example.org").count == 32)
        check([
            (label20 + ".example.org", 32, label20 + ".example.org"),
            (label20 + "x.example.org", 32, "…example.org"),
            ("example.org", 32, "example.org"),
        ])
    }

    @Test func labelsAreKeptFromTheRightAsLongAsTheyFit() {
        check([
            ("bank.com." + label40 + ".evil.net", 32, "…evil.net"),
            ("one.two.three.four.five.six.seven.eight.evil.net", 32, "…five.six.seven.eight.evil.net"),
            ("one.two.three.four.five.six.seven.eight.evil.net", 64, "one.two.three.four.five.six.seven.eight.evil.net"),
        ])
    }

    /// `evil.co.uk` is the registrable domain: it stays whole even when it alone is longer than the limit, and never reads `co.uk`.
    @Test func theRegistrableDomainOfATwoLabelPublicSuffixStaysWhole() {
        check([
            (label40 + ".evil.co.uk", 32, "…evil.co.uk"),
            (label30 + ".co.uk", 32, label30 + ".co.uk"),
            ("www." + label30 + ".co.uk", 32, "…" + label30 + ".co.uk"),
        ])
    }

    @Test func aSingleLongLabelAnAddressAndLocalhostAreNeverCut() {
        check([
            (String(repeating: "x", count: 50), 32, String(repeating: "x", count: 50)),
            ("localhost", 32, "localhost"),
            ("localhost", 4, "localhost"),
            ("192.168.100.200", 8, "192.168.100.200"),
            ("[2001:0db8:85a3:0000:0000:8a2e:0370:7334]", 32, "[2001:0db8:85a3:0000:0000:8a2e:0370:7334]"),
        ])
    }

    @Test func aTrailingDotIsKeptAndPunycodeLabelsGoWhole() {
        let punycode = "xn--80ak6aa92e"
        check([
            (label40 + ".evil.net.", 32, "…evil.net."),
            ([punycode, punycode, punycode, "xn--e1afmkfd", "xn--p1ai"].joined(separator: "."), 32, "…xn--e1afmkfd.xn--p1ai"),
        ])
    }

    /// The port is `rest`, not `host`: it neither counts toward the limit nor is cut with the host.
    @Test func thePortIsNotPartOfTheHost() throws {
        let address = try #require(AddressText(URL(string: "https://" + label40 + ".evil.net:8443/x")))
        #expect(address.host == label40 + ".evil.net" && address.rest == ":8443/x")
        #expect(AddressText.shortened(host: address.host, to: 32) == "…evil.net")
    }

    // MARK: - The menu

    private struct Rig {
        let app: BrowserApplication
        let first: AppCoordinator
        let second: AppCoordinator
        let menu: MainMenu

        /// `coordinator`'s window is key: the seam answers with it, and the hook a real key change runs fires.
        func becomeKey(_ coordinator: AppCoordinator) {
            PasswordsWindow.keyWindow = { [weak coordinator] in coordinator?.nativeWindow }
            coordinator.windowDidBecomeKey()
        }

        /// What AppKit posts when `window` closes or resigns key, and the one run-loop turn the menu waits for.
        func post(_ name: Notification.Name, for coordinator: AppCoordinator) async {
            NotificationCenter.default.post(name: name, object: coordinator.nativeWindow)
            await Self.turn()
        }

        static func turn() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func withMenu(
        firstAddress: String = "https://first.example/page",
        _ body: (Rig, NSMenuItem) async throws -> Void
    ) async throws {
        let saved = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
        NSApp.mainMenu = nil
        NSApp.windowsMenu = nil
        let app = BrowserApplication()
        let first = coordinator(showing: firstAddress)
        let second = coordinator(showing: "https://second.example/")
        app.register(first)
        app.register(second)
        first.showBrowser(activate: false)
        second.showBrowser(activate: false)
        let menu = MainMenu(application: app)
        menu.install()
        app.mainMenu = menu  // what `bootstrap()` does: a window becoming key reaches the menu through it
        defer {
            first.closeWindow()
            second.closeWindow()
            NSApp.mainMenu = saved.0
            NSApp.windowsMenu = saved.1
            NSApp.helpMenu = saved.2
            NSApp.servicesMenu = saved.3
        }
        let item = try #require(NSApp.mainMenu?.items.last)
        try await body(Rig(app: app, first: first, second: second, menu: menu), item)
    }

    @Test func theSiteMenuComesAfterHelpAndIsHiddenByDefault() async throws {
        try await withSiteSetting(false) {
            try await withMenu { _, item in
                let titles = try #require(NSApp.mainMenu).items.map(\.title)
                #expect(titles.suffix(2) == ["Help", ""], "after Help: \(titles)")
                #expect(item.isHidden, "off: no menu")
            }
        }
    }

    @Test func theTitleOfBothTheItemAndTheSubmenuFollowsTheKeyWindowAndNavigation() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
                #expect(!item.isHidden)
                #expect(item.title == "first.example" && item.submenu?.title == "first.example", "the bar draws the submenu's title")

                rig.becomeKey(rig.second)
                #expect(item.title == "second.example" && item.submenu?.title == "second.example")

                rig.second.browser.activeTab?.urlString = "https://moved.example/next"
                rig.menu.refreshSiteItem()
                #expect(item.title == "moved.example" && item.submenu?.title == "moved.example")

                rig.becomeKey(rig.first)
                #expect(item.title == "first.example")
            }
        }
    }

    @Test func theMenuHidesForAPrivateWindowAnInternalPageAndAWindowThatIsNotABrowserWindow() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
                #expect(!item.isHidden)

                rig.first.browser.showSettings()
                rig.menu.refreshSiteItem()
                #expect(item.isHidden, "a Settings page")

                rig.becomeKey(rig.second)
                #expect(!item.isHidden)
                let stranger = NSWindow()
                PasswordsWindow.keyWindow = { stranger }
                rig.menu.refreshSiteItem()
                #expect(item.isHidden, "Passwords, About or the Settings window is key")

                let priv = coordinator(showing: "https://private.example/", isPrivate: true)
                defer { priv.closeWindow() }
                rig.app.register(priv)
                priv.showBrowser(activate: false)
                rig.becomeKey(priv)
                #expect(item.isHidden, "a private window")
            }
        }
    }

    @Test func turningTheSettingOffHidesTheMenu() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
                #expect(!item.isHidden)
                BrowserSettings.application.showsSiteInMenuBar = false
                rig.menu.refreshSiteItem()
                #expect(item.isHidden)
            }
        }
    }

    @Test func theSubmenuHoldsTheAddressCopyLinkAndOpenLocation() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
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
    @Test func theAddressRowNeverShowsSignInDetails() async throws {
        try await withSiteSetting {
            try await withMenu(firstAddress: "https://bank.com@evil.com/login") { rig, item in
                rig.becomeKey(rig.first)
                let address = try #require(item.submenu?.items.first)
                _ = rig.menu.validateMenuItem(address)
                #expect(!address.title.contains("bank.com"), "\(address.title)")
                #expect(address.title.contains("evil.com"))
            }
        }
    }

    /// A long address loses the end of its path and the front labels of its host, never the domain that owns the page: the row does
    /// not rely on AppKit to clip a 253-character host.
    @Test func theAddressRowShortensThePathAndTheHostButNeverTheDomainThatOwnsThePage() async throws {
        let site = "bank.com." + String(repeating: "a", count: 60) + ".evil.example"
        let path = "/" + String(repeating: "x", count: 100)
        try await withSiteSetting {
            try await withMenu(firstAddress: "https://\(site)\(path)") { rig, item in
                rig.becomeKey(rig.first)
                let address = try #require(item.submenu?.items.first)
                _ = rig.menu.validateMenuItem(address)
                #expect(address.title.hasPrefix("https://…evil.example/x"), "\(address.title)")
                #expect(!address.title.contains("bank.com"), "\(address.title)")
                #expect(address.title.hasSuffix("x…") && address.title.count == "https://…evil.example".count + 48, "\(address.title)")
            }
        }
    }

    @Test func viewShowSiteInMenuBarTurnsItOnAndOffWithACheckmark() async throws {
        try await withSiteSetting(false) {
            try await withMenu { rig, item in
                let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
                let toggle = try #require(view.items.first { $0.title == "Show Site in Menu Bar" })
                rig.becomeKey(rig.first)
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

    // MARK: - When the window in front goes away

    /// The front window closes while the only other one is minimised: no window is key, so the menu must not keep naming the closed
    /// window's site, nor fall back to the minimised window's.
    @Test func theTitleGoesWhenTheFrontWindowClosesAndTheOtherIsMinimised() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.second)
                #expect(item.title == "second.example" && !item.isHidden)

                PasswordsWindow.keyWindow = { nil }
                await rig.post(NSWindow.willCloseNotification, for: rig.second)
                #expect(item.isHidden, "no browser window is in front")

                let address = try #require(item.submenu?.items.first)
                #expect(!rig.menu.validateMenuItem(address) && address.title.isEmpty, "the row never shows an address then: \(address.title)")
            }
        }
    }

    @Test func theTitleGoesWhenTheLastWindowCloses() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
                #expect(!item.isHidden)
                PasswordsWindow.keyWindow = { nil }
                await rig.post(NSWindow.willCloseNotification, for: rig.second)
                #expect(item.isHidden)
                await rig.post(NSWindow.willCloseNotification, for: rig.first)
                #expect(item.isHidden)
                let address = try #require(item.submenu?.items.first)
                #expect(!rig.menu.validateMenuItem(address) && address.title.isEmpty, "\(address.title)")
            }
        }
    }

    @Test func theTitleGoesWhenTheWindowResignsKeyToAWindowThatIsNotABrowserWindow() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
                #expect(!item.isHidden)
                let stranger = NSWindow()
                PasswordsWindow.keyWindow = { stranger }
                await rig.post(NSWindow.didResignKeyNotification, for: rig.first)
                #expect(item.isHidden)
                rig.becomeKey(rig.first)
                #expect(!item.isHidden && item.title == "first.example")
            }
        }
    }

    @Test func manyNotificationsInOneTurnMakeOneRefresh() async throws {
        try await withSiteSetting {
            try await withMenu { rig, _ in
                rig.becomeKey(rig.first)
                await Rig.turn()  // what the key change itself queued
                let refreshes = rig.menu.site.refreshCount
                let notifications = rig.menu.site.notificationCount
                for _ in 0..<3 {
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: rig.first.nativeWindow)
                    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: rig.second.nativeWindow)
                }
                await Rig.turn()
                #expect(rig.menu.site.notificationCount - notifications >= 6, "the menu heard them all")
                #expect(rig.menu.site.refreshCount - refreshes == 1, "and refreshed once")
            }
        }
    }

    @Test func installingTwiceLeavesOneObserverAndOneSiteItem() async throws {
        try await withSiteSetting {
            try await withMenu { rig, _ in
                let items = NSApp.mainMenu?.items.count
                rig.menu.install()
                let root = try #require(NSApp.mainMenu)
                #expect(root.items.count == items, "a second install builds the same menus, with one site item")
                #expect(root.items.last === rig.menu.site.item && root.items.filter { $0 === rig.menu.site.item }.count == 1)

                await Rig.turn()
                let notifications = rig.menu.site.notificationCount
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: rig.first.nativeWindow)
                await Rig.turn()
                #expect(rig.menu.site.notificationCount - notifications == 1, "one observer, not two")
            }
        }
    }

    /// A sheet (save panel, print, alert) is key while it is open; the window it hangs from still counts as the window in front.
    @Test func aKeyFloatingToolbarNamesItsBrowserInTheSiteMenu() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                let window = try #require(rig.first.nativeWindow)
                let panel = FloatingBarPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 76))
                window.addChildWindow(panel, ordered: .above)
                defer {
                    window.removeChildWindow(panel)
                    panel.close()
                }
                rig.becomeKey(rig.second)
                PasswordsWindow.keyWindow = { panel }
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
                await Rig.turn()
                #expect(!item.isHidden && item.title == "first.example")
                #expect(item.submenu?.title == "first.example")
                let address = try #require(item.submenu?.items.first)
                #expect(!rig.menu.validateMenuItem(address))
                #expect(address.title == "https://first.example/page")
            }
        }
    }

    @Test func aSheetOnABrowserWindowKeepsTheMenu() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
                let window = try #require(rig.first.nativeWindow)
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
                sheet.isReleasedWhenClosed = false
                window.beginSheet(sheet, completionHandler: nil)
                defer { window.endSheet(sheet) }
                try #require(sheet.sheetParent === window)

                PasswordsWindow.keyWindow = { sheet }
                rig.menu.refreshSiteItem()
                #expect(!item.isHidden && item.title == "first.example", "the sheet is key and the menu stays")
                rig.first.browser.activeTab?.urlString = "https://moved.example/next"
                rig.first.refreshSiteMenu()
                #expect(item.title == "moved.example" && item.submenu?.title == "moved.example")
                let address = try #require(item.submenu?.items.first)
                _ = rig.menu.validateMenuItem(address)
                #expect(address.title == "https://moved.example/next")
            }
        }
    }

    @Test func theTopLevelItemAndTheAddressRowCarryAccessibilityLabels() async throws {
        try await withSiteSetting {
            try await withMenu { rig, item in
                rig.becomeKey(rig.first)
                #expect(item.accessibilityLabel() == "Site: first.example")
                let address = try #require(item.submenu?.items.first)
                _ = rig.menu.validateMenuItem(address)
                #expect(address.accessibilityLabel() == "Address: https://first.example/page")
            }
        }
    }
}
