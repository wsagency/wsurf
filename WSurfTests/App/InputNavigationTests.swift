// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Back and Forward as a person uses them in a real browser window, in both engines: after a link that moved the tab to the
/// other engine, in a tab a link opened, and from a mouse's side buttons. One loopback server serves two sites, 127.0.0.1 and
/// localhost, so each can have its own engine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct InputNavigationTests {
    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/zero": .html("<!doctype html><title>Zero</title><a id=\"next\" href=\"/one\">one</a>"),
        "/one": .html("""
            <!doctype html><title>One</title>
            <a id="blank" href="/target" target="_blank">blank</a>
            <a id="other" href="#">other site</a>
            <script>document.getElementById('other').href = 'http://localhost:' + location.port + '/two';</script>
            """),
        "/two": .html("<!doctype html><title>Two</title><p>Two</p>"),
        "/target": .html("<!doctype html><title>Target</title><p>Target</p>"),
        "/password": .html("<!doctype html><title>Sign in</title><input id=\"pw\" type=\"password\">"),
    ]

    @MainActor
    private final class Rig {
        let main: AppCoordinator
        let port: Int

        init(main: AppCoordinator, port: Int) {
            self.main = main
            self.port = port
        }

        var browser: BrowserModel {
            main.browser
        }

        /// A page of the first site (127.0.0.1), or of the second (localhost).
        func url(_ path: String, second: Bool = false) -> URL {
            URL(string: "http://\(second ? "localhost" : "127.0.0.1"):\(port)\(path)")!
        }

        /// Whether `tab` shows `url`, loaded, in `engine`.
        func loaded(_ tab: BrowserTab, _ url: URL, in engine: BrowserEngine, timeout: Duration = .seconds(10)) async -> Bool {
            await waitUntil(timeout: timeout) {
                tab.isMaterialised && tab.page.engine == engine && tab.page.url == url && !tab.page.isLoading
            }
        }

        /// Follows link `id` with the person's click replayed in the page, so it carries a user gesture. A link that navigates
        /// can take the document away before the call returns; the wait that follows says where the click led.
        func follow(_ id: String, in tab: BrowserTab) async {
            _ = try? await tab.page.callAsyncJavaScript(
                "document.getElementById(id).click(); return true;", arguments: ["id": id], in: nil, contentWorld: .page,
                userGesture: true
            )
        }

        /// Presses and releases mouse button `number` over the middle of the window, as the system makes the event: only a
        /// `CGEvent` carries another button's number. It is converted, never posted.
        func press(button number: UInt32) throws {
            let window = try #require(main.nativeWindow)
            let point = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
            let primary = NSScreen.screens.first?.frame.height ?? 0
            let button = try #require(CGMouseButton(rawValue: number))
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                let made = try #require(CGEvent(
                    mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: point.x, y: primary - point.y),
                    mouseButton: button
                ))
                made.setIntegerValueField(.mouseEventClickState, value: 1)
                let event = try #require(NSEvent(cgEvent: made))
                try #require(event.buttonNumber == Int(number))
                window.sendEvent(event)
            }
        }
    }

    /// A window of a fresh profile whose first site is in `first` and second in `second`, shown but not in front.
    private func withWindow(
        first: BrowserEngine, second: BrowserEngine = .webKit, _ body: (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let base = try server.url()
        let port = try #require(base.port)
        if first == .chromium || second == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
        }
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Input navigation")
        let context = BrowserProfileContext.shared(for: profile)
        context.sitePermissions.setEngine(first, for: "http://127.0.0.1:\(port)")
        context.sitePermissions.setEngine(second, for: "http://localhost:\(port)")
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let main = app.newWindow(profile: profile, show: false)
        main.showBrowser(activate: false)
        var failure: (any Error)?
        do {
            try await body(Rig(main: main, port: port))
        } catch {
            failure = error
        }
        let tabs = main.browser.tabs
        for window in app.windows {
            window.closeWindow()
        }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        withExtendedLifetime(server) {}
        if let failure {
            throw failure
        }
    }

    // MARK: - Back

    /// A link to a site of the other engine moves the tab to that engine, whose history starts empty. Back from its first page
    /// returns to the page the link left, in that page's engine; a WebKit page comes back with the history it had.
    @Test(arguments: BrowserEngine.allCases)
    func backReturnsToThePageAnEngineSwitchLeft(from engine: BrowserEngine) async throws {
        let other: BrowserEngine = engine == .webKit ? .chromium : .webKit
        try await withWindow(first: engine, second: other) { rig in
            let tab = rig.browser.newTab(url: rig.url("/zero"))
            try #require(await rig.loaded(tab, rig.url("/zero"), in: engine))
            await rig.follow("next", in: tab)
            try #require(await rig.loaded(tab, rig.url("/one"), in: engine))
            await rig.follow("other", in: tab)
            try #require(await rig.loaded(tab, rig.url("/two", second: true), in: other), "the link moved the tab to \(other): \(tab.urlString)")

            #expect(tab.canGoBack, "Back is offered on the first page of the engine the link moved to")
            tab.goBack()
            #expect(await rig.loaded(tab, rig.url("/one"), in: engine), "Back returned to the page the link left: \(tab.urlString)")
            if engine == .webKit {
                #expect(await waitUntil(timeout: .seconds(5)) { tab.canGoBack }, "with WebKit's history from before the switch")
            }
        }
    }

    /// A link that opens a tab: the tab has no history of its own, so Back closes it and shows the page that opened it, as Safari
    /// does.
    @Test(arguments: BrowserEngine.allCases)
    func backFromATabALinkOpenedReturnsToTheOpener(engine: BrowserEngine) async throws {
        try await withWindow(first: engine) { rig in
            let opener = rig.browser.newTab(url: rig.url("/one"))
            try #require(await rig.loaded(opener, rig.url("/one"), in: engine))
            await rig.follow("blank", in: opener)
            let target = rig.url("/target")
            try #require(await waitUntil(timeout: .seconds(10)) { rig.browser.tabs.contains { $0 !== opener && $0.urlString == target.absoluteString } })
            let opened = try #require(rig.browser.tabs.first { $0 !== opener && $0.urlString == target.absoluteString })
            try #require(await rig.loaded(opened, target, in: engine))
            try #require(rig.browser.activeTab === opened, "the link's tab is in front")

            #expect(opened.canGoBack, "Back is offered in a tab a link opened")
            opened.goBack()
            #expect(await waitUntil(timeout: .seconds(5)) { opened.isClosed }, "Back closed the tab")
            #expect(rig.browser.activeTab === opener, "and showed the page that opened it")
        }
    }

    // MARK: - Mouse side buttons

    /// Button 3 goes Back and button 4 Forward, taken by the window before the page under them, in both engines.
    @Test(arguments: BrowserEngine.allCases)
    func sideButtonsGoBackAndForward(engine: BrowserEngine) async throws {
        try await withWindow(first: engine) { rig in
            let tab = rig.browser.newTab(url: rig.url("/zero"))
            try #require(await rig.loaded(tab, rig.url("/zero"), in: engine))
            await rig.follow("next", in: tab)
            try #require(await rig.loaded(tab, rig.url("/one"), in: engine))
            try #require(await waitUntil(timeout: .seconds(10)) { tab.canGoBack })

            try rig.press(button: 3)
            #expect(await rig.loaded(tab, rig.url("/zero"), in: engine), "button 3 went back: \(tab.urlString)")
            try #require(await waitUntil(timeout: .seconds(10)) { tab.canGoForward })
            try rig.press(button: 4)
            #expect(await rig.loaded(tab, rig.url("/one"), in: engine), "button 4 went forward: \(tab.urlString)")
        }
    }

    /// The buttons are one app-wide choice, on unless the person turns it off in General. Off, the window lets them through to
    /// the page and the tab stays where it is.
    @Test(arguments: BrowserEngine.allCases)
    func sideButtonsTurnedOffAreLeftToThePage(engine: BrowserEngine) async throws {
        let name = AppDatabase.defaultsSuite("InputNavigationTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false).sideButtonsNavigate, "on by default")
        #expect(SettingsIndex.search("side buttons").contains { $0.id == "general.mouseSideButtons" })

        try await withWindow(first: engine) { rig in
            let settings = rig.main.context.settings
            defer {
                settings.sideButtonsNavigate = true
                StageMode.defaults.removeObject(forKey: BrowserSettings.Key.mouseSideButtons)
            }
            let tab = rig.browser.newTab(url: rig.url("/zero"))
            try #require(await rig.loaded(tab, rig.url("/zero"), in: engine))
            await rig.follow("next", in: tab)
            try #require(await rig.loaded(tab, rig.url("/one"), in: engine))
            try #require(await waitUntil(timeout: .seconds(10)) { tab.canGoBack })

            settings.sideButtonsNavigate = false
            try rig.press(button: 3)
            try await Task.sleep(for: .seconds(1))
            #expect(tab.page.url == rig.url("/one") && !tab.page.isLoading, "off, button 3 left the tab where it was: \(tab.urlString)")
            settings.sideButtonsNavigate = true
            try rig.press(button: 3)
            #expect(await rig.loaded(tab, rig.url("/zero"), in: engine), "on again, button 3 went back: \(tab.urlString)")
        }
    }

    // MARK: - Keyboard

    /// A tab that is left gives up the keyboard. Otherwise keys typed next go to a page that is off screen, and a focused
    /// password field there keeps macOS secure event input on, which keeps every key from other apps' shortcuts, while this
    /// window is in front.
    @Test(arguments: BrowserEngine.allCases)
    func aTabThatIsLeftGivesUpTheKeyboard(engine: BrowserEngine) async throws {
        try await withWindow(first: engine) { rig in
            let window = try #require(rig.main.nativeWindow)
            let tab = rig.browser.newTab(url: rig.url("/password"))
            try #require(await rig.loaded(tab, rig.url("/password"), in: engine))
            let page = tab.page
            try #require(await waitUntil(timeout: .seconds(5)) { page.window === window }, "the page is on screen")
            window.makeFirstResponder(page)
            _ = try? await page.callAsyncJavaScript(
                "document.getElementById('pw').focus(); return true;", in: nil, contentWorld: .page, userGesture: true
            )
            try #require((window.firstResponder as? NSView)?.isDescendant(of: page) == true, "the page has the keyboard")

            rig.browser.newTab(url: rig.url("/zero"))
            #expect(
                await waitUntil(timeout: .seconds(5)) { (window.firstResponder as? NSView)?.isDescendant(of: page) != true },
                "the left page still has the keyboard: \(String(describing: window.firstResponder))"
            )
        }
    }
}
