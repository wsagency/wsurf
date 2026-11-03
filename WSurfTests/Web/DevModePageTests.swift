// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Developer mode on real pages. The inspector, the page appearance and "Open In" are WebKit's or the window's; the overlays,
/// the screenshot and Clear Website Data are proved on WebKit and on Chromium through `BrowserPage`.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct DevModePageTests {
    private struct Rig {
        let browser: BrowserModel
        let permissions: SitePermissions
        let profile: Profile
    }

    private func makeRig() -> Rig {
        let profile = Profile(id: UUID(), name: "Dev mode fixture", symbol: "hammer", color: .teal)
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("DevMode-\(UUID().uuidString).json"))
        let browser = BrowserModel(
            context: BrowserProfileContext(profile: profile), windowID: UUID(), database: .temporary(), sitePermissions: permissions)
        return Rig(browser: browser, permissions: permissions, profile: profile)
    }

    private func finish(_ rig: Rig) {
        ProfileSettingsStore.forget(rig.profile.id)
    }

    private func show(_ tab: BrowserTab) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        return window
    }

    private func hide(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// `parkTab` returns as soon as the page reports the address, which a new view does at once, while its web process is
    /// still starting and nothing has committed (and a moment later the view reports no address at all, until the load
    /// begins). The inspector and the page appearance follow the committed document, so these tests wait for that.
    private func park(_ browser: BrowserModel, at url: URL) async throws -> BrowserTab {
        let tab = await parkTab(browser, at: url)
        let view = try #require(tab.page.webKit)
        try #require(await waitUntil { view.url == url && !view.isLoading }, "the document at \(url) committed")
        return tab
    }

    private func server() async throws -> HTTPFixtureServer {
        try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Dev</title><p>Hello</p>")])
    }

    /// The fixture's address under another host name (`app.localhost` resolves to the loopback server).
    private func address(_ server: HTTPFixtureServer, host: String? = nil) throws -> URL {
        let url = try server.url()
        guard let host, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = host
        return try #require(parts.url)
    }

    /// A tab on the fixture in `engine`, shown and loaded.
    private func open(
        _ rig: Rig, _ server: HTTPFixtureServer, host: String? = nil, engine: BrowserEngine
    ) async throws -> (BrowserTab, NSWindow) {
        let url = try address(server, host: host)
        rig.permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let tab = rig.browser.newTab(url: url)
        let window = show(tab)
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })
        #expect(tab.page.engine == engine)
        return (tab, window)
    }

    /// The page's answer, or nil while it cannot give one (a document that is still being replaced).
    private func script(_ tab: BrowserTab, _ source: String) async -> Any? {
        try? await tab.page.evaluateJavaScript(source)
    }

    private func inspectorOn(_ view: WKWebView) -> Bool {
        view.isInspectable && view.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool == true
    }

    private func inspectorOff(_ view: WKWebView) -> Bool {
        !view.isInspectable && view.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool == false
    }

    // MARK: Inspector

    @Test func theInspectorFollowsTheDocumentTheViewCommitted() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        // The person's own switch is off: Developer mode alone turns the inspector on, for that website only.
        let application = BrowserSettings.application
        let before = application.webInspectorEnabled
        application.webInspectorEnabled = false
        defer { application.webInspectorEnabled = before }

        let local = try #require(URL(string: "http://app.localhost:5173/"))
        let remote = try #require(URL(string: "https://shop.invalid/"))
        let tab = try await park(rig.browser, at: local)
        let view = try #require(tab.page.webKit)
        #expect(await waitUntil { inspectorOn(view) }, "a website in Developer mode has the inspector")
        #expect(tab.canShowWebInspector)

        tab.loadHTML("<!doctype html><title>Shop</title><p>Shop</p>", baseURL: remote)
        #expect(await waitUntil { tab.page.url == remote && inspectorOff(view) }, "leaving the website switches it off again")
        #expect(!tab.canShowWebInspector)

        tab.loadHTML("<!doctype html><title>App</title><p>App</p>", baseURL: local)
        #expect(await waitUntil { tab.page.url == local && inspectorOn(view) })
    }

    @Test func turningTheModeOffAtOnceTakesTheInspectorAwayFromEveryTabOfThatWebsite() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let application = BrowserSettings.application
        let before = application.webInspectorEnabled
        application.webInspectorEnabled = false
        defer { application.webInspectorEnabled = before }

        let local = try #require(URL(string: "http://app.localhost:5173/"))
        let remote = try #require(URL(string: "https://shop.invalid/"))
        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let first = try await park(rig.browser, at: local)
        let second = try await park(rig.browser, at: local)
        let other = try await park(rig.browser, at: remote)
        let firstView = try #require(first.page.webKit)
        let secondView = try #require(second.page.webKit)
        let otherView = try #require(other.page.webKit)
        #expect(await waitUntil { inspectorOn(firstView) && inspectorOn(secondView) && inspectorOff(otherView) })

        coordinator.setDevMode(false, for: first)
        #expect(inspectorOff(firstView))
        #expect(inspectorOff(secondView), "another tab of the same website follows at once")
        #expect(inspectorOff(otherView))
        #expect(!first.usesDevMode && !second.usesDevMode)
        #expect(!rig.browser.context.settings.usesDevMode(for: local))

        // A website that is not local can be turned on by hand, and only that one.
        coordinator.setDevMode(true, for: other)
        #expect(inspectorOn(otherView))
        #expect(other.canShowWebInspector)
        #expect(inspectorOff(firstView))
        coordinator.setDevMode(false, for: other)
        coordinator.setDevMode(true, for: first)
        #expect(rig.browser.context.settings.devModeSites == DevModeSites())
    }

    /// A view reports the address of a page it is still loading, and no address at all while its web process starts, so a
    /// website can be turned on before its document exists. The commit then decides, and the inspector arrives with it.
    @Test func aWebsiteTurnedOnWhileItsPageIsStillLoadingGetsTheInspectorWhenItCommits() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let application = BrowserSettings.application
        let before = application.webInspectorEnabled
        application.webInspectorEnabled = false
        defer { application.webInspectorEnabled = before }

        let remote = try #require(URL(string: "https://shop.invalid/"))
        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let tab = rig.browser.newTab()
        let view = try #require(tab.page.webKit)
        tab.loadHTML("<!doctype html><title>Shop</title><p>Shop</p>", baseURL: remote)
        #expect(await waitUntil { tab.urlString == remote.absoluteString })

        coordinator.setDevMode(true, for: tab)
        #expect(tab.usesDevMode)
        #expect(await waitUntil { view.url == remote && !view.isLoading && inspectorOn(view) }, "on once the document committed")
        #expect(tab.canShowWebInspector)

        coordinator.setDevMode(false, for: tab)
        #expect(inspectorOff(view), "and off at once on the committed document")
        #expect(rig.browser.context.settings.devModeSites == DevModeSites())
    }

    @Test func theInspectorCanBeOpenedOnlyThroughWebKitsOwnInterface() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let tab = try await park(rig.browser, at: try #require(URL(string: "http://app.localhost:5173/")))
        let view = try #require(tab.page.webKit)
        // The private interface the command calls. If a WebKit update drops it, the command does nothing instead of crashing.
        #expect(view.responds(to: NSSelectorFromString("_inspector")), "WebKit still has the private inspector the command uses")
    }

    @Test func aChromiumTabOffersDevToolsAndThePageAppearance() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let application = BrowserSettings.application
        let before = application.webInspectorEnabled
        application.webInspectorEnabled = false
        defer { application.webInspectorEnabled = before }
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .chromium)
        defer { hide(window) }
        let chromium = try #require(tab.page.chromium)
        #expect(tab.usesDevMode, "the website uses Developer mode")
        #expect(tab.canShowWebInspector)

        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let menu = DevModeMenu.make(for: tab, coordinator: coordinator)
        let titles = menu.items.map(\.title)
        #expect(titles.contains(String(localized: "Show Web Inspector")))
        #expect(titles.contains(String(localized: "Page Appearance")))
        #expect(titles.contains(String(localized: "Copy Screenshot")))
        #expect(titles.contains(String(localized: "Show Frame Rate")))

        // DevTools open in a window of their own, and close again when the website stops using Developer mode.
        #expect(!chromium.hasDevTools)
        tab.showWebInspector()
        #expect(await waitUntil { chromium.hasDevTools })
        coordinator.setDevMode(false, for: tab)
        #expect(!tab.canShowWebInspector)
        #expect(await waitUntil { !chromium.hasDevTools })
        coordinator.setDevMode(true, for: tab)
        tab.showWebInspector()
        chromium.closeDevTools()
    }

    @Test func aChromiumPagesAppearanceFollowsTheDeveloperToolsChoice() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .chromium)
        defer { hide(window) }
        let dark = "matchMedia('(prefers-color-scheme: dark)').matches"

        tab.updateDevModeTools { $0.appearance = .dark }
        #expect(await waitUntil { await script(tab, dark) as? Bool == true })
        tab.updateDevModeTools { $0.appearance = .light }
        #expect(await waitUntil { await script(tab, dark) as? Bool == false })
        // Quick changes end on the last one.
        tab.updateDevModeTools { $0.appearance = .dark }
        tab.updateDevModeTools { $0.appearance = .system }
        tab.updateDevModeTools { $0.appearance = .dark }
        #expect(await waitUntil { await script(tab, dark) as? Bool == true })

        // An MCP lease that ends puts back the appearance Developer mode asked for, not the page's own.
        let chromium = try #require(tab.page.chromium)
        try await chromium.setEmulatedMedia(DevelopmentMedia(colorScheme: .light))
        #expect(await waitUntil { await script(tab, dark) as? Bool == false })
        await chromium.forceMediaEmulation(DevelopmentMedia())
        #expect(await waitUntil { await script(tab, dark) as? Bool == true })

        tab.updateDevModeTools { $0.appearance = .system }
        let system = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #expect(await waitUntil { await script(tab, dark) as? Bool == system })
    }

    @Test func aWebKitTabsMenuHasTheInspectorAndThePageAppearance() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let tab = try await park(rig.browser, at: try #require(URL(string: "http://app.localhost:5173/")))
        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let titles = DevModeMenu.make(for: tab, coordinator: coordinator).items.map(\.title)
        #expect(titles.contains(String(localized: "Show Web Inspector")))
        #expect(titles.contains(String(localized: "Page Appearance")))
    }

    @Test func theDeveloperMenuNamesTheWebsiteAndOffersTheInspectorForChromium() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let previousMenu = NSApp.mainMenu
        let mainMenu = MainMenu(coordinator: coordinator)
        mainMenu.install()
        defer { NSApp.mainMenu = previousMenu }
        let developer = try #require(
            NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Developer" }?.submenu)
        let inspector = try #require(developer.items.first { $0.title == String(localized: "Show Web Inspector") })
        let toggle = try #require(developer.items.first { $0.title.hasPrefix("Developer Mode for") })
        #expect(inspector.keyEquivalent == "i")
        #expect(inspector.keyEquivalentModifierMask == [.command, .option])

        // A WebKit page on a local website.
        let webKit = try await park(rig.browser, at: try #require(URL(string: "http://app.localhost:5173/")))
        #expect(rig.browser.activeTab === webKit)
        #expect(mainMenu.validateMenuItem(inspector))
        #expect(!inspector.isHidden)
        #expect(mainMenu.validateMenuItem(toggle))
        #expect(toggle.title == String(localized: "Developer Mode for “app.localhost”"))
        #expect(toggle.state == .on)

        // Turned off for the website: the item says so, and the inspector goes with it.
        coordinator.setDevMode(false, for: webKit)
        #expect(mainMenu.validateMenuItem(toggle))
        #expect(toggle.state == .off)
        coordinator.setDevMode(true, for: webKit)
        #expect(toggle.title == String(localized: "Developer Mode for “app.localhost”"))

        // A Chromium page: DevTools open for it, so the item is there as it is for WebKit.
        let server = try await server()
        let (chromium, window) = try await open(rig, server, engine: .chromium)
        defer { hide(window) }
        #expect(rig.browser.activeTab === chromium)
        #expect(mainMenu.validateMenuItem(inspector))
        #expect(!inspector.isHidden)
        #expect(mainMenu.validateMenuItem(toggle))
        #expect(toggle.state == .on)
        #expect(toggle.title == String(localized: "Developer Mode for “127.0.0.1”"))
    }

    // MARK: Open In and private windows

    @Test func aPrivateWindowsMenuNeverOffersOpenIn() async throws {
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("DevMode-\(UUID().uuidString).json"), persists: false)
        let owner = Profile(id: UUID(), name: "Dev mode owner", symbol: "hammer", color: .teal)
        defer { ProfileSettingsStore.forget(owner.id) }
        let context = BrowserProfileContext(profile: .privateBrowsing(), settingsOwner: owner)
        let browser = BrowserModel(context: context, windowID: UUID(), database: .temporary(), sitePermissions: permissions)
        let local = try #require(URL(string: "http://localhost:3000/secret?token=abc"))
        let tab = try await park(browser, at: local)
        #expect(tab.isPrivate)
        #expect(tab.usesDevMode, "Developer mode itself works in a private window")
        let coordinator = AppCoordinator(browser: browser)
        defer { coordinator.closeWindow() }

        let menu = DevModeMenu.make(for: tab, coordinator: coordinator)
        #expect(!menu.items.contains { $0.title == String(localized: "Open In") })
        #expect(menu.items.contains { $0.title == String(localized: "Copy Screenshot") })
        // The address is not shareable from here, whichever browser would have received it.
        #expect(DevModeOpenIn.shareableURL(tab.urlString, isPrivate: tab.isPrivate) == nil)
        await context.endPrivateSession()
    }

    @Test func aRegularWindowsMenuOffersOpenInOnlyWithBrowsersThatAreNotWSurf() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let tab = try await park(rig.browser, at: try #require(URL(string: "http://localhost:3000/")))
        #expect(!tab.isPrivate)
        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let menu = DevModeMenu.make(for: tab, coordinator: coordinator)
        let openIn = menu.items.first { $0.title == String(localized: "Open In") }
        let browsers = DevModeOpenIn.installedBrowsers(isPrivate: false)
        #expect((openIn != nil) == !browsers.isEmpty)
        let names = openIn?.submenu?.items.map(\.title) ?? []
        #expect(names.count == browsers.count)
        #expect(!names.contains { $0.lowercased().contains("wsurf") }, "no WSurf build is offered: \(names)")
    }

    // MARK: Overlays and appearance

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func theOverlaysRunInAWorldOfTheirOwnOnBothEngines(engine: BrowserEngine) async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        let outlined = "getComputedStyle(document.querySelector('p')).outlineStyle"
        let badge = "[...document.documentElement.children].some(e => e.tagName === 'DIV' && e.style.zIndex === '2147483647')"
        #expect(await script(tab, outlined) as? String == "none")

        tab.updateDevModeTools { $0.outlinesElements = true; $0.showsFrameRate = true }
        #expect(await waitUntil { await script(tab, outlined) as? String == "solid" }, "outlines are drawn")
        #expect(await waitUntil { await script(tab, badge) as? Bool == true }, "the frame rate badge is shown")
        #expect(await script(tab, "typeof window.__wsurfDevMode") as? String == "undefined", "the page cannot see the script's state")
        #expect(await script(tab, "typeof window.__linenDeveloper") as? String == "undefined")

        tab.updateDevModeTools { $0.outlinesElements = false }
        #expect(await waitUntil { await script(tab, outlined) as? String == "none" })
        #expect(await script(tab, badge) as? Bool == true, "only the outlines were switched off")
        tab.updateDevModeTools { $0.showsFrameRate = false }
        #expect(await waitUntil { await script(tab, badge) as? Bool == false })
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func theOverlayScriptDrawsOnlyInTheOriginItWasAskedFor(engine: BrowserEngine) async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        let outlined = "getComputedStyle(document.querySelector('p')).outlineStyle"
        func run(for origin: String) async throws {
            _ = try await tab.page.callAsyncJavaScript(
                DevModeOverlay.source, arguments: ["fps": false, "outlines": true, "origin": origin], in: nil,
                contentWorld: DevModeOverlay.world)
        }

        // A document that is not the one the call was made for (the page moved on in between) is left alone.
        try await run(for: "http://elsewhere.test")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await script(tab, outlined) as? String == "none")
        #expect(await script(tab, "typeof window.__wsurfDevMode") as? String == "undefined")

        try await run(for: SitePermissions.origin(for: tab.page.url))
        #expect(await waitUntil { await script(tab, outlined) as? String == "solid" })
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aNewDocumentGetsTheOverlaysAgain(engine: BrowserEngine) async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        let outlined = "getComputedStyle(document.querySelector('p')).outlineStyle"
        tab.updateDevModeTools { $0.outlinesElements = true }
        #expect(await waitUntil { await script(tab, outlined) as? String == "solid" })

        let document = tab.page.mainDocumentID
        tab.page.reload()
        try #require(await waitUntil { tab.page.mainDocumentID != document && !tab.page.isLoading })
        #expect(await waitUntil { await script(tab, outlined) as? String == "solid" }, "\(engine)")
    }

    @Test func turningTheModeOffClearsWhatTheTabHadSwitchedOn() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        let outlined = "getComputedStyle(document.querySelector('p')).outlineStyle"
        tab.updateDevModeTools { $0.outlinesElements = true; $0.appearance = .dark }
        #expect(await waitUntil { await script(tab, outlined) as? String == "solid" })
        #expect(tab.page.webKit?.appearance?.name == .darkAqua)

        tab.setDevMode(false)
        #expect(await waitUntil { await script(tab, outlined) as? String == "none" })
        #expect(tab.page.webKit?.appearance == nil)
        #expect(tab.devModeTools == DevModeTools())
        tab.updateDevModeTools { $0.outlinesElements = true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await script(tab, outlined) as? String == "none", "nothing is drawn on a website that is not in Developer mode")

        tab.setDevMode(true)
        #expect(tab.devModeTools == DevModeTools(outlinesElements: true), "the choice made while it was off comes back with the mode")
        #expect(await waitUntil { await script(tab, outlined) as? String == "solid" })
        #expect(rig.browser.context.settings.devModeSites == DevModeSites())
    }

    @Test func thePageAppearanceNeverUndoesAppearanceSomethingElseSet() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let local = try #require(URL(string: "http://app.localhost:5173/"))
        let remote = try #require(URL(string: "https://shop.invalid/"))
        let tab = try await park(rig.browser, at: local)
        let view = try #require(tab.page.webKit)

        // Nothing chosen: the view's appearance is left to whoever set it (a media emulation, for one).
        view.appearance = NSAppearance(named: .aqua)
        tab.syncDevMode()
        tab.applyDevModeAppearance()
        #expect(view.appearance?.name == .aqua)

        tab.updateDevModeTools { $0.appearance = .dark }
        #expect(view.appearance?.name == .darkAqua)
        // Another writer takes over; choosing Match System then leaves its appearance alone.
        view.appearance = NSAppearance(named: .aqua)
        tab.updateDevModeTools { $0.appearance = .system }
        #expect(view.appearance?.name == .aqua)

        // Leaving the website takes back only what this feature put there.
        tab.updateDevModeTools { $0.appearance = .dark }
        tab.loadHTML("<!doctype html><title>Shop</title><p>Shop</p>", baseURL: remote)
        #expect(await waitUntil { tab.page.url == remote && view.appearance == nil })
        tab.loadHTML("<!doctype html><title>App</title><p>App</p>", baseURL: local)
        #expect(await waitUntil { tab.page.url == local && view.appearance?.name == .darkAqua }, "the choice for the tab is still there")
    }

    // MARK: Screenshot

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func copyScreenshotPutsThePagePictureOnThePasteboardOnBothEngines(engine: BrowserEngine) async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        try await DevModeScreenshot.copy(tab.shownPage, to: pasteboard)
        let image = try #require(pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage)
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(pasteboard.string(forType: .string) == nil, "the picture replaces what was there")
    }

    // MARK: Clear Website Data

    private let seed = """
        localStorage.setItem('k', 'v'); sessionStorage.setItem('s', 'v');
        document.cookie = 'session=devModeSecret; path=/';
        return true;
        """

    private func cookieDomains(_ tab: BrowserTab) async throws -> Set<String> {
        func bare(_ domain: String) -> String {
            domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        }
        if let webKit = tab.page.webKit {
            return Set(await webKit.configuration.websiteDataStore.httpCookieStore.allCookies().map { bare($0.domain) })
        }
        let chromium = try #require(tab.page.chromium)
        let all = try await chromium.command("Network.getAllCookies")
        return Set(((all["cookies"] as? [[String: Any]]) ?? []).compactMap { ($0["domain"] as? String).map(bare) })
    }

    private func plant(_ domain: String, in tab: BrowserTab) async throws {
        if let webKit = tab.page.webKit {
            let cookie = try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "keep", .value: "1"]))
            await webKit.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        } else if let chromium = tab.page.chromium {
            _ = try await chromium.command("Network.setCookie", params: ["name": "keep", "value": "1", "domain": domain, "path": "/"])
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, .chromium])
    func clearWebsiteDataClearsOnlyTheExactAddressOnBothEngines(engine: BrowserEngine) async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, host: "app.localhost", engine: engine)
        defer { hide(window) }
        #expect(tab.usesDevMode)
        let seeded = try await tab.page.callAsyncJavaScript(seed, in: nil, contentWorld: .page)
        #expect(seeded as? Bool == true)
        // The parent domain, a sibling and a subdomain of the website's own host: none of them may lose a cookie.
        let others: Set = ["localhost", "other.localhost", "deep.app.localhost"]
        for domain in others {
            try await plant(domain, in: tab)
        }
        var before = try await cookieDomains(tab)
        #expect(before.contains("app.localhost"), "the page's own cookie is set: \(before)")
        #expect(before.isSuperset(of: others), "the other cookies are in place: \(before)")

        let confirmed = SitePermissions.origin(for: try address(server, host: "app.localhost"))
        let outcome = await tab.clearDevModeSiteData(origin: confirmed)
        guard case .cleared(let report) = outcome else {
            Issue.record("expected the data to be cleared, got \(outcome)")
            return
        }
        #expect(report.failed.isEmpty)
        #expect(report.cookies >= 1)
        let after = try await cookieDomains(tab)
        #expect(!after.contains("app.localhost"), "the website's own cookie is gone: \(after)")
        #expect(after.isSuperset(of: others), "no other address lost a cookie: \(after)")
        before.remove("app.localhost")
        #expect(after == before)

        // The page reloaded from the network and its storage is empty.
        #expect(await waitUntil { await script(tab, "String(localStorage.length + sessionStorage.length)") as? String == "0" })
        #expect(await script(tab, "document.cookie") as? String == "")
    }

    @Test func clearWebsiteDataDoesNothingForATabWithoutAWebPage() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let unloaded = rig.browser.newTab()
        guard case .stale = await unloaded.clearDevModeSiteData(origin: "http://app.localhost:5173") else {
            Issue.record("a tab with no page has nothing to clear")
            return
        }
    }

    /// The question names an origin, and the page can move on while it is open (a redirect, a script, a click). Confirming must
    /// clear what was named, never whatever the tab shows by the time the person answers.
    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, .chromium])
    func aPageThatMovedOnWhileTheQuestionWasOpenIsNeverCleared(engine: BrowserEngine) async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, host: "app.localhost", engine: engine)
        defer { hide(window) }
        let confirmed = SitePermissions.origin(for: try address(server, host: "app.localhost"))
        #expect(try await tab.page.callAsyncJavaScript(seed, in: nil, contentWorld: .page) as? Bool == true)

        // The page moves to another website while the alert is open.
        let other = try address(server, host: "other.localhost")
        rig.permissions.setEngine(engine, for: SitePermissions.origin(for: other))
        let document = tab.page.mainDocumentID
        tab.load(other)
        try #require(await waitUntil {
            tab.page.url == other && !tab.page.isLoading && tab.page.mainDocumentID != nil && tab.page.mainDocumentID != document
        })
        #expect(tab.page.engine == engine)
        #expect(try await tab.page.callAsyncJavaScript(seed, in: nil, contentWorld: .page) as? Bool == true)
        let before = try await cookieDomains(tab)
        #expect(before.isSuperset(of: ["app.localhost", "other.localhost"]), "\(before)")

        guard case .stale = await tab.clearDevModeSiteData(origin: confirmed) else {
            Issue.record("a page that is no longer the confirmed website must report stale")
            return
        }
        #expect(try await cookieDomains(tab) == before, "no cookie of either website was removed")
        #expect(await script(tab, "String(localStorage.length) + String(sessionStorage.length)") as? String == "11", "the page now shown kept its storage")
        #expect(await script(tab, "document.cookie") as? String == "session=devModeSecret")
        #expect(tab.page.url == other, "and it did not reload")
    }

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, .chromium])
    func aWebsiteTurnedOffWhileTheQuestionWasOpenIsNeverCleared(engine: BrowserEngine) async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let server = try await server()
        let (tab, window) = try await open(rig, server, host: "app.localhost", engine: engine)
        defer { hide(window) }
        let confirmed = SitePermissions.origin(for: try address(server, host: "app.localhost"))
        #expect(try await tab.page.callAsyncJavaScript(seed, in: nil, contentWorld: .page) as? Bool == true)
        let before = try await cookieDomains(tab)

        tab.setDevMode(false)
        guard case .stale = await tab.clearDevModeSiteData(origin: confirmed) else {
            Issue.record("a website that is no longer in Developer mode must report stale")
            return
        }
        #expect(try await cookieDomains(tab) == before)
        #expect(await script(tab, "String(localStorage.length)") as? String == "1")

        // Back on, the same confirmed website is cleared.
        tab.setDevMode(true)
        guard case .cleared = await tab.clearDevModeSiteData(origin: confirmed) else {
            Issue.record("the confirmed website in Developer mode is cleared")
            return
        }
        #expect(!(try await cookieDomains(tab)).contains("app.localhost"))
    }

    @Test func aMenuItemActsOnlyOnTheWebsiteItNamed() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let tab = try await park(rig.browser, at: try #require(URL(string: "http://app.localhost:5173/")))

        // The page moved on while a menu named another website: nothing changes.
        for named in ["other.localhost", "shop.invalid", "localhost", ""] {
            #expect(!coordinator.setDevMode(false, for: tab, named: named), "\(named)")
        }
        #expect(tab.usesDevMode)
        #expect(rig.browser.context.settings.devModeSites == DevModeSites())

        #expect(coordinator.setDevMode(false, for: tab, named: "app.localhost"))
        #expect(!tab.usesDevMode)
        #expect(rig.browser.context.settings.devModeSites.disabled == ["app.localhost"])
    }

    @Test func theWebsiteItemOfTheDeveloperMenuActsOnlyOnTheWebsiteItNamed() async throws {
        let rig = makeRig()
        defer { finish(rig) }
        let coordinator = AppCoordinator(browser: rig.browser)
        defer { coordinator.closeWindow() }
        let previousMenu = NSApp.mainMenu
        let mainMenu = MainMenu(coordinator: coordinator)
        mainMenu.install()
        defer { NSApp.mainMenu = previousMenu }
        let developer = try #require(
            NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Developer" }?.submenu)
        let toggle = try #require(developer.items.first { $0.title.hasPrefix("Developer Mode for") })
        let local = try #require(URL(string: "http://app.localhost:5173/"))
        let remote = try #require(URL(string: "https://shop.invalid/"))
        let tab = try await park(rig.browser, at: local)
        let settings = rig.browser.context.settings

        #expect(mainMenu.validateMenuItem(toggle))
        #expect(toggle.title == String(localized: "Developer Mode for “app.localhost”"))
        // The page moves on after the item named app.localhost: choosing it changes nothing, for either website.
        tab.loadHTML("<!doctype html><title>Shop</title><p>Shop</p>", baseURL: remote)
        #expect(await waitUntil { tab.urlString == remote.absoluteString })
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
        #expect(settings.devModeSites == DevModeSites())
        #expect(settings.usesDevMode(for: local) && !settings.usesDevMode(for: remote))

        // Named again for the page that is shown, it acts on that one.
        #expect(mainMenu.validateMenuItem(toggle))
        #expect(toggle.title == String(localized: "Developer Mode for “shop.invalid”"))
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
        #expect(settings.usesDevMode(for: remote))
        #expect(settings.devModeSites.enabled == ["shop.invalid"])
        #expect(settings.usesDevMode(for: local))
    }
}
