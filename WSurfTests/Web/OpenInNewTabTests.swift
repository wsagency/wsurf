// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Every way a person or a page opens a link in a new tab, driven by real input on a real page in both engines and read at
/// the model: the tab that came out of it. WebKit gets AppKit events through its window and its real context menu is chosen
/// from while it tracks; Chromium gets DevTools input (a trusted gesture the renderer cannot tell from a person's).
///
/// The fixture is one loopback server: the opener on 127.0.0.1 and, in an iframe, a page of another site on `localhost`
/// (an out-of-process frame in Chromium). Every link carries `via=`, so a tab says which way it was opened.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct OpenInNewTabTests {
    // MARK: - Fixture

    private static let opener = """
        <!doctype html><title>Opener</title>
        <style>
          body { margin: 0 }
          .box { position: absolute; left: 20px; width: 240px; height: 30px; display: block; background: #cde }
        </style>
        <a id="plain" class="box" style="top: 10px" href="/target?via=plain">plain</a>
        <a id="blank" class="box" style="top: 50px" href="/target?via=blank" target="_blank">blank</a>
        <a id="open" class="box" style="top: 90px" href="#" onclick="window.open('/target?via=open'); return false">open</a>
        <form action="/target" target="_blank" style="position: absolute; left: 20px; top: 130px; margin: 0">
          <input type="hidden" name="via" value="form"><button id="submit" style="width: 240px; height: 30px">form</button>
        </form>
        <a id="oauth" class="box" style="top: 170px" href="#"
           onclick="window.__popup = window.open('/popup', 'oauth', 'width=400,height=300'); return false">oauth</a>
        <a id="crossOauth" class="box" style="top: 210px" href="#"
           onclick="window.__popup = window.open('http://localhost:' + location.port + '/popup', 'cross', 'width=400,height=300');
                    return false">cross-site oauth</a>
        <script>
          window.__messages = [];
          window.addEventListener('message', event => window.__messages.push(JSON.stringify(event.data)));
          const frame = document.createElement('iframe');
          frame.src = 'http://localhost:' + location.port + '/frame';
          frame.style = 'position: absolute; left: 300px; top: 10px; width: 300px; height: 200px; border: 0';
          document.body.append(frame);
        </script>
        """

    private static let frame = """
        <!doctype html><title>Frame</title>
        <style>
          body { margin: 0 }
          .box { position: absolute; left: 10px; width: 200px; height: 30px; display: block; background: #edc }
        </style>
        <a id="fblank" class="box" style="top: 10px" href="/target?via=frame-blank" target="_blank">frame blank</a>
        <a id="fplain" class="box" style="top: 60px" href="/target?via=frame-plain">frame plain</a>
        <script>parent.postMessage('frame-ready', '*');</script>
        """

    private static let popup = """
        <!doctype html><title>Popup</title>
        <script>
          document.title = 'popup:' + (window.opener ? 'opener' : 'none');
          if (window.opener) { window.opener.postMessage({ from: 'popup' }, '*'); }
        </script>
        """

    /// The modes of `/verify`: what each button awaits between the click and `window.open`.
    nonisolated static let verifyModes = ["direct", "timer", "late", "chain", "fetch", "slow"]

    /// A "Verify" step: each button opens a pop-up that talks back to its opener and then closes itself, either at once or after
    /// what payment and sign-in pages await first. `timer` waits 300 ms, `late` 1.5 s, `chain` two nested 300 ms timers, `fetch` a
    /// request the server answers at once, `slow` one it holds for 2.5 s (`slowGate`).
    private static let verify = """
        <!doctype html><title>Verify</title>
        <style>
          body { margin: 0 }
          .box { position: absolute; left: 20px; width: 240px; height: 30px; display: block; background: #cde }
        </style>
        \(verifyModes.enumerated().map { ##"<a id="v-\##($1)" class="box" style="top: \##(10 + 40 * $0)px" href="#">\##($1)</a>"## }.joined(separator: "\n"))
        <script>
          window.__verify = [];
          window.__popups = {};
          addEventListener('message', event => {
            if (event.data?.from === 'verify-popup') __verify.push({ message: event.data.mode });
          });
          const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
          const steps = {
            direct: async () => {}, timer: () => wait(300), late: () => wait(1500),
            chain: () => new Promise(resolve => setTimeout(() => setTimeout(resolve, 300), 300)),
            fetch: () => fetch('/ping').then(response => response.text()), slow: () => fetch('/slow').then(response => response.text()),
          };
          for (const [mode, step] of Object.entries(steps)) {
            document.getElementById('v-' + mode).addEventListener('click', async event => {
              event.preventDefault();
              await step();
              const popup = window.open('/verify-popup?via=popup-' + mode + '&mode=' + mode, 'verify-' + mode, 'width=400,height=300');
              __verify.push({ mode, opened: popup !== null });
              if (popup) __popups[mode] = popup;
            });
          }
        </script>
        """

    private static let verifyPopup = """
        <!doctype html><title>Verify pop-up</title>
        <script>
          const mode = new URLSearchParams(location.search).get('mode');
          // Whether WSurf's document-start scripts reached this first document: its passkey script replaces this function.
          const scripts = String(window.PublicKeyCredential?.isConditionalMediationAvailable).includes('[native code]') ? 'engine' : 'wsurf';
          document.title = 'popup:' + mode + ':' + (window.opener ? 'opener' : 'none') + ':' + scripts;
          if (window.opener) window.opener.postMessage({ from: 'verify-popup', mode }, '*');
          setTimeout(() => window.close(), 300);
        </script>
        """

    /// Holds `/slow` until a test opens it.
    private static let slowGate = ResponseGate()

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/verify": .html(verify),
        "/verify-popup": .html(verifyPopup),
        "/ping": .html("ok"),
        "/slow": .html("ok", gate: slowGate),
        "/": .html(opener),
        "/frame": .html(frame),
        "/popup": .html(popup),
        "/auto": .html("<!doctype html><title>Auto</title><script>setTimeout(() => window.open('/target?via=auto'), 300);</script>"),
        "/target": .html("<!doctype html><title>Target</title><p>Target</p>"),
        // A page that opens a pop-up every few milliseconds once it is told to, from a timer: no gesture started any of them.
        "/menu-race": .html("""
            <!doctype html><title>Race</title><style>body { margin: 0 }</style>
            <a id="plain" href="/target?via=plain"
               style="position: absolute; left: 20px; top: 10px; width: 240px; height: 30px; display: block">plain</a>
            <script>
              window.__spam = false;
              setInterval(() => { if (window.__spam) { window.open('/target?via=spam'); } }, 5);
            </script>
            """),
    ]

    /// The centre of each element of the fixture in the opener's viewport, in points.
    private static let centers: [String: CGPoint] = [
        "plain": CGPoint(x: 140, y: 25),
        "blank": CGPoint(x: 140, y: 65),
        "open": CGPoint(x: 140, y: 105),
        "submit": CGPoint(x: 140, y: 145),
        "oauth": CGPoint(x: 140, y: 185),
        "crossOauth": CGPoint(x: 140, y: 225),
        "fblank": CGPoint(x: 300 + 10 + 100, y: 10 + 10 + 15),
        "fplain": CGPoint(x: 300 + 10 + 100, y: 10 + 60 + 15),
    ].merging(verifyModes.enumerated().map { ("v-" + $1, CGPoint(x: 140, y: 25 + 40 * $0)) }) { first, _ in first }

    private enum Button {
        case left, middle
    }

    /// What WebKit's hit test reports for the element under the pointer (`absoluteLinkURL`).
    private final class HoverHit: NSObject {
        @objc var absoluteLinkURL: URL?

        init(_ url: URL?) {
            absoluteLinkURL = url
        }
    }

    /// What a person's pin does to the opener before the link is opened.
    enum Opener {
        case plain, pinned, inPinnedFolder
    }

    // MARK: - Rig

    @MainActor
    private final class Rig {
        let engine: BrowserEngine
        let server: HTTPFixtureServer
        let permissions: SitePermissions
        let browser: BrowserModel
        let tab: BrowserTab
        let window: NSWindow
        let url: URL
        private var menuObserver: NSObjectProtocol?
        /// What the last context menu offered, by title.
        private(set) var offered: [String] = []
        private(set) var offeredIdentifiers: [String] = []
        /// Whether the last context menu had an item the caller chose.
        private(set) var chosen = false
        private var seenMenu = false

        init(engine: BrowserEngine, server: HTTPFixtureServer, permissions: SitePermissions, browser: BrowserModel, tab: BrowserTab, window: NSWindow, url: URL) {
            self.engine = engine
            self.server = server
            self.permissions = permissions
            self.browser = browser
            self.tab = tab
            self.window = window
            self.url = url
        }

        var page: BrowserPage {
            tab.page
        }

        /// The tabs the opener's page made.
        var opened: [BrowserTab] {
            browser.tabs.filter { $0 !== tab }
        }

        func close() {
            if let menuObserver {
                NotificationCenter.default.removeObserver(menuObserver)
            }
            for shown in [window] + tabWindows {
                shown.contentView = nil
                shown.close()
            }
        }

        /// Windows that show the tabs the page opened (`showOpenedTabs`).
        private var tabWindows: [NSWindow] = []
        /// Every tab the page opened, in order, closed or not (`showOpenedTabs`).
        private(set) var openedEver: [BrowserTab] = []

        /// Shows each tab the page opens in a window of its own, as the browser window shows a tab a page opened: a Chromium page
        /// starts loading only once it is shown.
        func showOpenedTabs() {
            browser.onTabOpened = { [weak self] tab in
                guard let self else { return }
                openedEver.append(tab)
                let shown = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                shown.isReleasedWhenClosed = false
                shown.contentView = WebViewContainer(page: tab.page)
                shown.orderBack(nil)
                tabWindows.append(shown)
            }
        }

        // MARK: Input

        func isOn(_ id: String) async throws -> Bool {
            let point = try #require(OpenInNewTabTests.centers[id])
            let hit = try await page.evaluateJavaScript("document.elementFromPoint(\(point.x), \(point.y))?.id ?? ''")
            return (hit as? String) == id || id.hasPrefix("f")
        }

        func click(_ id: String, button: Button = .left, modifiers: NSEvent.ModifierFlags = []) async throws {
            let point = try #require(OpenInNewTabTests.centers[id])
            try #require(await isOn(id), "\(id) is where the fixture put it")
            if let chromium = page.chromium {
                var mask = 0
                for (flag, bit) in [(NSEvent.ModifierFlags.option, 1), (.control, 2), (.command, 4), (.shift, 8)] where modifiers.contains(flag) {
                    mask |= bit
                }
                let name = button == .left ? "left" : "middle"
                let held = button == .left ? 1 : 4
                for (type, buttons) in [("mousePressed", held), ("mouseReleased", 0)] {
                    _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                        "type": type, "x": Double(point.x), "y": Double(point.y), "button": name, "buttons": buttons,
                        "clickCount": 1, "modifiers": mask,
                    ])
                }
                return
            }
            let native = try #require(page.webKit)
            let location = native.convert(point, to: nil)
            if button == .middle {
                native.otherMouseDown(with: try #require(middleEvent(.otherMouseDown, at: location), "a middle button event"))
                native.otherMouseUp(with: try #require(middleEvent(.otherMouseUp, at: location), "a middle button event"))
                return
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )))
            }
        }

        /// The address of link `id`, as WebKit reports it under the pointer.
        private func address(of id: String) -> URL? {
            let port = url.port ?? 0
            switch id {
            case "plain", "blank":
                return URL(string: "http://127.0.0.1:\(port)/target?via=\(id)")
            case "fplain":
                return URL(string: "http://localhost:\(port)/target?via=frame-plain")
            case "fblank":
                return URL(string: "http://localhost:\(port)/target?via=frame-blank")
            default:
                return nil
            }
        }

        /// WebKit tells the tab which link the pointer is over, in any frame, when the pointer moves onto it. A hosted test cannot
        /// make WebKit see a pointer move, so the report is made as WebKit makes it.
        private func reportHover(over link: URL?) {
            guard let native = page.webKit else { return }
            TabNavigationDelegate(tab: tab).webView(native, mouseDidMoveOverElement: HoverHit(link), withFlags: [], userInfo: nil)
        }

        /// A middle-button event, as the system makes one: `NSEvent.mouseEvent` gives every other button number 0. It is only converted
        /// from a `CGEvent`, never posted, and carries no window, so its location is the one in the window.
        private func middleEvent(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent? {
            let primary = NSScreen.screens.first?.frame.height ?? 0
            guard let made = CGEvent(
                mouseEventSource: nil, mouseType: type == .otherMouseDown ? .otherMouseDown : .otherMouseUp,
                mouseCursorPosition: CGPoint(x: location.x, y: primary - location.y), mouseButton: .center
            ) else { return nil }
            made.setIntegerValueField(.mouseEventClickState, value: 1)
            return NSEvent(cgEvent: made)
        }

        /// Right-clicks `id` and chooses the first item of the menu that `choose` accepts. The menu is the real one, read a moment
        /// after it began to track (a view may still change it as it opens): WebKit's as `TabWebView.willOpenMenu` left it,
        /// Chromium's as CEF shows it. Returns whether an item was chosen.
        @discardableResult
        func rightClick(_ id: String, choosing choose: @escaping @MainActor (String) -> Bool) async throws -> Bool {
            let point = try #require(OpenInNewTabTests.centers[id])
            try #require(await isOn(id), "\(id) is where the fixture put it")
            try await Task.sleep(for: .milliseconds(300))
            offered = []
            offeredIdentifiers = []
            chosen = false
            seenMenu = false
            if let menuObserver {
                NotificationCenter.default.removeObserver(menuObserver)
            }
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                // Posted on the main thread, while the menu tracks; the test touches the menu only there.
                nonisolated(unsafe) let tracked = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let self, let menu = tracked, !self.seenMenu else { return }
                    self.seenMenu = true
                    // Whatever the test does, the menu does not stay: a menu that stays holds the whole test run.
                    let watchdog = Timer(timeInterval: 8, repeats: false) { _ in menu.cancelTracking() }
                    RunLoop.main.add(watchdog, forMode: .common)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        self.offered = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                        self.offeredIdentifiers = menu.items.map { $0.identifier?.rawValue ?? "-" }
                        let index = menu.items.firstIndex { !$0.isSeparatorItem && choose($0.title) }
                        self.chosen = index != nil
                        if let index {
                            menu.performActionForItem(at: index)
                        }
                        menu.cancelTracking()
                        watchdog.invalidate()
                    }
                }
            }
            if let chromium = page.chromium {
                for (type, buttons) in [("mousePressed", 2), ("mouseReleased", 0)] {
                    _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                        "type": type, "x": Double(point.x), "y": Double(point.y), "button": "right", "buttons": buttons, "clickCount": 1,
                    ])
                }
            } else {
                reportHover(over: address(of: id))
                let native = try #require(page.webKit)
                let location = native.convert(point, to: nil)
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    window.sendEvent(try #require(NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0
                    )))
                }
            }
            _ = await waitUntil(timeout: .seconds(10)) { !self.offered.isEmpty }
            // The chosen action runs in the turn after the menu was read.
            try await Task.sleep(for: .milliseconds(100))
            return chosen
        }

        func evaluate(_ script: String) async throws -> Any {
            try await page.evaluateJavaScript(script)
        }

        // MARK: Outcomes

        /// The one tab whose address says it came `via` that way.
        func tab(via: String, timeout: Duration = .seconds(15)) async -> BrowserTab? {
            _ = await waitUntil(timeout: timeout) { self.opened.contains { $0.urlString.contains("via=\(via)") } }
            return opened.first { $0.urlString.contains("via=\(via)") }
        }

        /// Gives anything that would open a second tab for the same link the time to do it.
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(500))
        }

        func verifyReports() async throws -> [[String: Any]] {
            let json = try await evaluate("JSON.stringify(window.__verify ?? [])") as? String ?? "[]"
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        }

        func messages() async throws -> [String] {
            let json = try await evaluate("JSON.stringify(window.__messages)") as? String ?? "[]"
            return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        }
    }

    private func withRig(
        _ engine: BrowserEngine, path: String = "/", opener: Opener = .plain, popups: PopupPolicy? = nil, privately: Bool = false,
        body: (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let url = try server.url(path)
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("OpenInNewTab-\(UUID().uuidString).json"))
        let origin = SitePermissions.origin(for: url)
        let frameOrigin = SitePermissions.origin(for: URL(string: "http://localhost:\(url.port ?? 0)/"))
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
            permissions.setEngine(.chromium, for: origin)
            permissions.setEngine(.chromium, for: frameOrigin)
        }
        if let popups {
            permissions.setPopups(popups, for: origin)
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        if privately {
            browser.adopt(database: .temporary(), sitePermissions: permissions, privately: true)
        }
        let tab = browser.newTab(url: url)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        let rig = Rig(engine: engine, server: server, permissions: permissions, browser: browser, tab: tab, window: window, url: url)
        defer { rig.close() }
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })
        #expect((tab.page.chromium != nil) == (engine == .chromium), "the opener runs on \(engine)")
        // The frame has loaded and been drawn once its page said so.
        if path == "/" {
            try #require(await waitUntil { try await rig.messages().contains("\"frame-ready\"") })
            try await Task.sleep(for: .milliseconds(300))
        }
        switch opener {
        case .plain:
            break
        case .pinned:
            browser.pin(tab)
            try #require(browser.isPinned(.tab(tab.id)), "the opener is pinned")
        case .inPinnedFolder:
            let folder = browser.createFolder(named: "Work", containing: [tab])
            browser.pin(folder)
            try #require(browser.isPinned(.tab(tab.id)) && browser.sidebarTree.parent(of: .tab(tab.id)) == folder.id, "the opener is in a pinned folder")
        }
        try await body(rig)
        withExtendedLifetime(server) {}
    }

    /// A new tab is a tab of its own, shown, and the opener's page opened it.
    private func expectOpened(_ landed: BrowserTab?, by rig: Rig, _ path: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> BrowserTab {
        let landed = try #require(landed, "a new tab came out of \(path)", sourceLocation: sourceLocation)
        #expect(rig.browser.openerByTab[landed.id] == rig.tab.id, "\(path): the opener's page is the tab's opener", sourceLocation: sourceLocation)
        #expect(rig.browser.isShown(.tab(landed.id)), "\(path): the tab is in the sidebar", sourceLocation: sourceLocation)
        #expect(landed.pinID == nil && landed.pinnedURL == nil, "\(path): it is not pinned", sourceLocation: sourceLocation)
        return landed
    }

    // MARK: - The context menu

    @Test(arguments: BrowserEngine.allCases)
    func theContextMenuOpensALinkInANewTab(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            let chosen = try await rig.rightClick("plain") { $0.lowercased().contains("open link in new tab") }
            try #require(chosen, "the menu offers Open Link in New Tab; it offered \(rig.offered) \(rig.offeredIdentifiers)")
            let landed = try expectOpened(
                await rig.tab(via: "plain"), by: rig, "the context menu (a pop-up was refused: \(String(describing: rig.tab.popups.blocked)))")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
        }
    }

    /// The same, where the site may open pop-ups: what the menu does cannot depend on that answer.
    @Test(arguments: BrowserEngine.allCases)
    func theContextMenuOpensALinkInANewTabWherePopupsAreAllowed(engine: BrowserEngine) async throws {
        try await withRig(engine, popups: .allow) { rig in
            let chosen = try await rig.rightClick("plain") { $0.lowercased().contains("open link in new tab") }
            try #require(chosen, "the menu offers Open Link in New Tab; it offered \(rig.offered) \(rig.offeredIdentifiers)")
            _ = try expectOpened(await rig.tab(via: "plain"), by: rig, "the context menu where pop-ups are allowed")
        }
    }

    @Test
    func theContextMenuOpensALinkInTheSameTabInWebKit() async throws {
        try await withRig(.webKit) { rig in
            let chosen = try await rig.rightClick("plain") { $0 == "Open Link" }
            try #require(chosen, "the menu offers Open Link; it offered \(rig.offered) \(rig.offeredIdentifiers)")
            try #require(await waitUntil { rig.page.url?.query == "via=plain" }, "the opener moved to the link")
            #expect(rig.opened.isEmpty)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func theContextMenuOpensALinkInANewWindowAndAPrivateOne(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            var asked: [(URL, Bool)] = []
            rig.browser.onOpenInNewWindow = { _, url, isPrivate in asked.append((url, isPrivate)) }
            let window = try await rig.rightClick("plain") { $0 == "Open Link in New Window" }
            try #require(window, "the menu offers Open Link in New Window; it offered \(rig.offered) \(rig.offeredIdentifiers)")
            let privateWindow = try await rig.rightClick("plain") { $0 == "Open Link in New Private Window" }
            try #require(privateWindow, "the menu offers Open Link in New Private Window; it offered \(rig.offered) \(rig.offeredIdentifiers)")
            #expect(asked.map { $0.0.absoluteString.hasSuffix("/target?via=plain") } == [true, true])
            #expect(asked.map(\.1) == [false, true])
            #expect(rig.opened.isEmpty, "a window is not a tab")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func theContextMenuOfALinkInACrossSiteFrameOpensItInANewTab(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            let chosen = try await rig.rightClick("fplain") { $0.lowercased().contains("open link in new tab") }
            try #require(chosen, "the menu offers Open Link in New Tab in the frame; it offered \(rig.offered) \(rig.offeredIdentifiers)")
            _ = try expectOpened(await rig.tab(via: "frame-plain"), by: rig, "the context menu in a frame")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func theContextMenuOfALinkInACrossSiteFrameOpensItInANewWindow(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            var asked: [URL] = []
            rig.browser.onOpenInNewWindow = { _, url, _ in asked.append(url) }
            let chosen = try await rig.rightClick("fplain") { $0 == "Open Link in New Window" }
            try #require(chosen, "the menu offers Open Link in New Window in the frame; it offered \(rig.offered)")
            try #require(await waitUntil { !asked.isEmpty }, "a window was asked for")
            #expect(asked.map(\.path) == ["/target"] && asked.first?.query == "via=frame-plain")
        }
    }

    @Test func theContextMenuOfALinkInACrossSiteFrameOpensItInPeekInWebKit() async throws {
        try await withRig(.webKit) { rig in
            var peeked: [URL] = []
            rig.browser.onOpenInPeek = { _, url, _ in peeked.append(url) }
            let chosen = try await rig.rightClick("fplain") { $0 == "Open Link in Peek" }
            try #require(chosen, "the menu offers Open Link in Peek in the frame; it offered \(rig.offered)")
            try #require(await waitUntil { !peeked.isEmpty }, "a peek was asked for")
            #expect(peeked.first?.query == "via=frame-plain")
        }
    }

    /// A page that keeps opening pop-ups from a timer, with no gesture, while the person chooses a New Tab item: the window the
    /// person chose opens, and none of the page's own does, whatever moment it asks in.
    @Test func aPagesOwnPopupsWhileTheMenuOpensItsWindowStayBlockedInWebKit() async throws {
        try await withRig(.webKit, path: "/menu-race", popups: .blockAndNotify) { rig in
            _ = try await rig.evaluate("window.__spam = true; 0")
            let chosen = try await rig.rightClick("plain") { $0.lowercased().contains("open link in new tab") }
            try #require(chosen, "the menu offers Open Link in New Tab; it offered \(rig.offered)")
            let landed = try expectOpened(await rig.tab(via: "plain"), by: rig, "the context menu while the page opens pop-ups")
            _ = try await rig.evaluate("window.__spam = false; 0")
            try await rig.settle()
            #expect(rig.opened == [landed], "the page's own windows stayed blocked: \(rig.opened.map(\.urlString))")
            #expect(rig.tab.popups.blocked?.absoluteString.contains("via=spam") == true, "and were refused, not lost")
        }
    }

    // MARK: - The keyboard and the mouse

    @Test(arguments: BrowserEngine.allCases)
    func aCommandClickOpensALinkInTheBackground(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try await rig.click("plain", modifiers: .command)
            let landed = try expectOpened(await rig.tab(via: "plain"), by: rig, "a Command-click")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
            #expect(rig.page.url == rig.url, "the opener's page did not move")
            // A Chromium tab opens it in front: the engine's disposition (background) is not read.
            if engine == .webKit {
                #expect(rig.browser.activeTab === rig.tab, "the opener stays in front")
                #expect(landed.isUnseen)
            }
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aCommandShiftClickOpensALinkInFront(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try await rig.click("plain", modifiers: [.command, .shift])
            let landed = try expectOpened(await rig.tab(via: "plain"), by: rig, "a Command-Shift-click")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
            #expect(rig.browser.activeTab === landed, "the new tab is in front")
            #expect(rig.page.url == rig.url, "the opener's page did not move")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aMiddleClickOpensALinkInTheBackground(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try await rig.click("plain", button: .middle)
            let landed = try expectOpened(await rig.tab(via: "plain"), by: rig, "a middle-click")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
            #expect(rig.page.url == rig.url, "the opener's page did not move")
            if engine == .webKit {
                #expect(rig.browser.activeTab === rig.tab, "the opener stays in front")
            }
        }
    }

    // MARK: - What a page asks for

    @Test(arguments: BrowserEngine.allCases)
    func aTargetBlankLinkOpensANewTabInFront(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try await rig.click("blank")
            let landed = try expectOpened(await rig.tab(via: "blank"), by: rig, "a target=_blank link")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
            #expect(rig.browser.activeTab === landed)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aTargetBlankLinkInACrossSiteFrameOpensANewTab(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try await rig.click("fblank")
            let landed = try expectOpened(await rig.tab(via: "frame-blank"), by: rig, "a target=_blank link in a frame")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aFormWithTargetBlankOpensANewTab(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try await rig.click("submit")
            let landed = try expectOpened(await rig.tab(via: "form"), by: rig, "a form with target=_blank")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func windowOpenFromAClickOpensANewTab(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try await rig.click("open")
            let landed = try expectOpened(await rig.tab(via: "open"), by: rig, "window.open from a click")
            try await rig.settle()
            #expect(rig.opened == [landed], "one tab, not two")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func windowOpenWithoutAGestureIsBlockedWhereBlockingIsOn(engine: BrowserEngine) async throws {
        try await withRig(engine, popups: .blockAndNotify) { rig in
            _ = try await rig.evaluate("setTimeout(() => window.open('/target?via=script'), 0); 0")
            try await rig.settle()
            await Self.expectNothingOpened(in: rig)
        }
    }

    /// A Chromium tab opens the pop-up: CEF tells the tab the pop-up of a script that no gesture started was one a gesture started
    /// (`user_gesture`), so the tab's blocker never refuses it. Not changed by the context menu and not part of the Open Link
    /// paths; it is recorded as a known issue, which fails this test the day it is fixed.
    private static func expectNothingOpened(in rig: Rig, sourceLocation: SourceLocation = #_sourceLocation) async {
        if rig.engine == .chromium {
            withKnownIssue("CEF reports a script's pop-up as started by a gesture", sourceLocation: sourceLocation) {
                #expect(rig.opened.isEmpty, "nothing opened", sourceLocation: sourceLocation)
            }
        } else {
            #expect(rig.opened.isEmpty, "nothing opened: \(rig.opened.map(\.urlString))", sourceLocation: sourceLocation)
        }
    }

    /// A page that opens a pop-up by itself, with no script of ours in between.
    @Test(arguments: BrowserEngine.allCases)
    func aPageThatOpensAPopupByItselfIsBlockedWhereBlockingIsOn(engine: BrowserEngine) async throws {
        try await withRig(engine, path: "/auto", popups: .blockAndNotify) { rig in
            try await Task.sleep(for: .seconds(1.5))
            await Self.expectNothingOpened(in: rig)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func windowOpenWithoutAGestureOpensATabWhereTheSiteMayOpenPopups(engine: BrowserEngine) async throws {
        try await withRig(engine, popups: .allow) { rig in
            _ = try await rig.evaluate("setTimeout(() => window.open('/target?via=script'), 0); 0")
            _ = try expectOpened(await rig.tab(via: "script"), by: rig, "window.open without a gesture where it is allowed")
            try await rig.settle()
            #expect(rig.opened.count == 1, "one tab, not two")
        }
    }

    // MARK: - History and the Start page

    /// A middle-click on a row of History or of the Start page asks the model for this: a background tab next to the page in front.
    /// The views' catchers read the event the window is handling, which a test cannot post, so this is the call they make.
    @Test func aBackgroundTabFromHistoryOrTheStartPageOpensNextToThePageInFront() async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        defer { withExtendedLifetime(server) {} }
        let browser = BrowserModel(database: .temporary())
        let first = browser.addPage("https://one.example/")
        let second = browser.addPage("https://two.example/")
        browser.activate(first)

        let opened = browser.newTab(url: try server.url("/target?via=history"), activate: false, after: browser.activeTab)

        #expect(browser.activeTab === first && opened.isUnseen, "in the background")
        let order = browser.tabs.map(\.id)
        #expect(order.firstIndex(of: opened.id) == order.firstIndex(of: first.id).map { $0 + 1 }, "next to the page in front, not at the end")
        #expect(order.contains(second.id))
        #expect(opened.urlString.contains("via=history"))
    }

    // MARK: - A page that is pinned

    @Test(arguments: BrowserEngine.allCases, [Opener.pinned, .inPinnedFolder])
    func aLinkOpenedFromAPinnedPageLandsUnderThePinLine(engine: BrowserEngine, opener: Opener) async throws {
        try await withRig(engine, opener: opener) { rig in
            let kept = rig.browser.keptRunAtTop().count
            try await rig.click("blank")
            let landed = try expectOpened(await rig.tab(via: "blank"), by: rig, "a link from \(opener)")
            let root = rig.browser.sidebarTree.rows(in: nil)
            #expect(root.firstIndex(of: .tab(landed.id)) == kept, "just under the pin line")
            #expect(rig.browser.sidebarTree.parent(of: .tab(landed.id)) == nil, "not in the pinned folder")
            #expect(rig.browser.activeTab === landed)
        }
    }

    @Test(arguments: BrowserEngine.allCases, [Opener.pinned, .inPinnedFolder])
    func theContextMenuOfAPinnedPageOpensALinkUnderThePinLine(engine: BrowserEngine, opener: Opener) async throws {
        try await withRig(engine, opener: opener) { rig in
            let kept = rig.browser.keptRunAtTop().count
            let chosen = try await rig.rightClick("plain") { $0.lowercased().contains("open link in new tab") }
            try #require(chosen, "the menu offers Open Link in New Tab; it offered \(rig.offered) \(rig.offeredIdentifiers)")
            let landed = try expectOpened(await rig.tab(via: "plain"), by: rig, "the context menu of \(opener)")
            let root = rig.browser.sidebarTree.rows(in: nil)
            #expect(root.firstIndex(of: .tab(landed.id)) == kept, "just under the pin line")
        }
    }
}

/// Pop-ups that talk to their opener, kept apart so the suite's body stays readable.
extension OpenInNewTabTests {
    // MARK: - A pop-up that talks to its opener

    /// A sign-in pop-up reaches `window.opener`, in both engines: a Chromium tab's pop-up is the browser CEF made for it, hosted in
    /// the new tab.
    @Test(arguments: BrowserEngine.allCases)
    func aSignInPopupKeepsItsOpener(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            rig.showOpenedTabs()
            try await rig.click("oauth")
            let landed = try expectOpened(await waitForAnyTab(in: rig), by: rig, "a sign-in pop-up")
            try #require(await waitUntil { try await rig.messages().contains("{\"from\":\"popup\"}") }, "the pop-up reached window.opener")
            #expect(landed.liveView?.engine == engine, "the pop-up stays in its opener's engine")
            #expect(try await rig.evaluate("window.__popup !== null && !window.__popup.closed") as? Bool == true, "window.open returned the window")
            try await rig.settle()
            #expect(rig.opened.count == 1)
        }
    }

    /// What a "Verify" button that opens a pop-up gets in each mode: what `window.open` returned, the tab that opened, whether the
    /// pop-up reached its opener and could close itself, and whether the tab's pop-up badge took it instead.
    @Test(arguments: BrowserEngine.allCases, verifyModes)
    func aVerifyButtonOpensAPopupThatTalksToItsOpener(engine: BrowserEngine, mode: String) async throws {
        try await withRig(engine, path: "/verify", popups: .blockAndNotify) { rig in
            rig.showOpenedTabs()
            if mode == "slow" {
                Self.slowGate.close()
            }
            try await rig.click("v-" + mode)
            if mode == "slow" {
                _ = await Self.slowGate.waitForRequest()
                try await Task.sleep(for: .seconds(2.5))
                Self.slowGate.open()
            }
            let reported = await waitUntil(timeout: .seconds(10)) {
                (try? await rig.verifyReports())?.contains { $0["mode"] as? String == mode } == true
            }
            let opened = rig.openedEver
            var title = ""
            if let popup = opened.first {
                _ = await waitUntil(timeout: .seconds(5)) { popup.liveView?.title?.hasPrefix("popup:") == true || popup.isClosed }
                title = popup.liveView?.title ?? ""
            }
            try await Task.sleep(for: .seconds(1.5))
            let reports = try await rig.verifyReports()
            let windowOpen = reports.first { $0["mode"] as? String == mode }?["opened"] as? Bool
            let message = reports.contains { $0["message"] as? String == mode }
            let closed = opened.first.map { !rig.browser.tabs.contains($0) }
            print("""
                VERIFY popup engine=\(engine) mode=\(mode) reported=\(reported) windowOpen=\(windowOpen.map(String.init) ?? "nil") \
                tabs=\(opened.count) title=\(title) message=\(message) closedItself=\(closed.map(String.init) ?? "-") \
                badge=\(rig.tab.popups.blocked?.query ?? "none")
                """)
            if engine == .webKit, mode == "late" {
                // WebKit's own rule, the one Safari applies, lets a timer carry the click for a second, not 1.5 (`webKitsOwnRule…`).
                #expect(windowOpen == false && opened.isEmpty, "blocked, as in Safari")
                #expect(rig.tab.popups.blocked?.query?.contains("mode=late") == true, "the pop-up badge holds it")
            } else {
                #expect(windowOpen == true && message, "window.open returned the pop-up, and it reached its opener")
                #expect(opened.count == 1 && closed == true, "one tab, which the pop-up's window.close() closed")
                // The marker after it says whether WSurf's document-start scripts reached the pop-up's first page: in Chromium they do not
                // yet (the page is CEF's before its scripts are registered), in WebKit they do.
                #expect(title.contains(":opener:"), "the pop-up saw its opener: \(title)")
                #expect(rig.tab.popups.blocked == nil)
            }
        }
    }

    /// Asks for no decision of its own: every window WebKit asks for is made, so what opens is what WebKit's own rule allowed.
    private final class WindowMaker: NSObject, WKUIDelegate {
        var asked: [String] = []
        var views: [WKWebView] = []

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            asked.append(navigationAction.request.url?.query ?? "")
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            views.append(view)
            return view
        }
    }

    /// WebKit's own pop-up rule, the one Safari's blocker applies: a plain view that keeps WebKit's blocker on
    /// (`javaScriptCanOpenWindowsAutomatically` off), so WebKit asks for a window only for a pop-up its rule allows. The same
    /// `/verify` buttons, clicked through the window.
    @Test(arguments: verifyModes)
    func webKitsOwnRuleForAVerifyPopup(mode: String) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let configuration = WebViewPool.makeConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
        let maker = WindowMaker()
        view.uiDelegate = maker
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        let url = try server.url("/verify")
        view.load(URLRequest(url: url))
        try #require(await waitUntil { view.url == url && !view.isLoading })
        try await Task.sleep(for: .milliseconds(300))
        // Read without a gesture: WebKit's public script calls would grant one.
        func reports() async -> String {
            (try? await view.evaluate("JSON.stringify(window.__verify ?? [])", asFunction: false, in: nil, in: .page)) as? String ?? ""
        }
        if mode == "slow" {
            Self.slowGate.close()
        }
        let location = view.convert(try #require(Self.centers["v-" + mode]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )))
        }
        if mode == "slow" {
            _ = await Self.slowGate.waitForRequest()
            try await Task.sleep(for: .seconds(2.5))
            Self.slowGate.open()
        }
        let reported = await waitUntil(timeout: .seconds(10)) { await reports().contains("\"mode\":\"\(mode)\"") }
        try await Task.sleep(for: .seconds(1))
        print("VERIFY webkit-own-rule mode=\(mode) reported=\(reported) windowsAsked=\(maker.asked.count) \(await reports())")
        // The rule WSurf's tab applies (`aVerifyButtonOpensAPopupThatTalksToItsOpener`): only the 1.5 s timer loses the click.
        #expect(reported && maker.asked.count == (mode == "late" ? 0 : 1))
        withExtendedLifetime(server) {}
    }

    /// The site's engine setting wins over the opener: a Chromium page's pop-up of a site set to WebKit (as Google sign-in is) opens
    /// as a plain WebKit tab, and the page gets no window, as before the pop-up kept its opener. One of a site set to Chromium keeps it.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aChromiumPopupFollowsItsSitesEngine(site: BrowserEngine) async throws {
        try await withRig(.chromium) { rig in
            rig.permissions.setEngine(site, for: SitePermissions.origin(for: URL(string: "http://localhost:\(rig.url.port ?? 0)/")))
            rig.showOpenedTabs()
            try await rig.click("crossOauth")
            let landed = try expectOpened(await waitForAnyTab(in: rig), by: rig, "a cross-site pop-up")
            try #require(await waitUntil { landed.liveView?.engine == site && landed.urlString.hasSuffix("/popup") }, "\(landed.urlString)")
            if site == .chromium {
                try #require(await waitUntil { try await rig.messages().contains("{\"from\":\"popup\"}") }, "the pop-up reached window.opener")
                #expect(try await rig.evaluate("window.__popup !== null") as? Bool == true)
            } else {
                try await rig.settle()
                #expect(try await rig.evaluate("window.__popup === null") as? Bool == true, "the page got no window")
                #expect(try await !rig.messages().contains("{\"from\":\"popup\"}"), "no opener")
            }
        }
    }

    /// The first page of a Chromium pop-up starts before WSurf attaches to its browser, so WSurf's scripts run there late, once:
    /// password autofill is in and can talk to the app, and a passkey request reaches WSurf (the answer here is a refusal) instead
    /// of CEF's own WebAuthn, which shows nothing and does not end. Running them a second time installs nothing again. Both in a
    /// pop-up tab that is shown, which is answered at once, and in one that never is, whose request WSurf holds until the tab is
    /// shown and so ends at its deadline.
    @Test(arguments: [true, false])
    func aChromiumPopupsFirstPageGetsWSurfsScripts(shown: Bool) async throws {
        try await withRig(.chromium) { rig in
            let profileID = rig.browser.context.profile.id
            WebAuthnAdapter.interactionForTesting[profileID] = { Declining() }
            defer { WebAuthnAdapter.interactionForTesting[profileID] = nil }
            if shown {
                rig.showOpenedTabs()
            }
            // The pop-up of the other site, on `localhost`: a relying party, where 127.0.0.1 (an IP address) is not one.
            try await rig.click("crossOauth")
            let landed = try #require(await waitForAnyTab(in: rig), "a tab opened for the pop-up")
            let popup = landed.page
            try #require(await waitUntil { popup.url?.path == "/popup" && !popup.isLoading }, "the pop-up's first page loaded")
            try #require(await waitUntil { try await rig.messages().contains("{\"from\":\"popup\"}") }, "it is the opener's pop-up")
            let world = PasswordAutofill.world
            #expect(try await popup.evaluateJavaScript("typeof globalThis.__wsurfPasswords?.pickFill", in: nil, contentWorld: world) as? String
                == "function", "password autofill is in the first page")
            var pings = 0
            popup.addScriptMessageHandler(name: "wsurfTestPing", in: world) { _ in pings += 1 }
            _ = try await popup.evaluateJavaScript("globalThis.__wsurfSend('wsurfTestPing', 1); true", in: nil, contentWorld: world)
            #expect(await waitUntil { pings == 1 }, "and reaches the app")

            // The page asks for 1 s, which WSurf raises to its 10 s minimum (`WebAuthnWire.minimumTimeout`).
            let started = ContinuousClock.now
            _ = try await popup.evaluateJavaScript("""
                navigator.credentials.get({ publicKey: { challenge: new Uint8Array(16), timeout: 1000 } })
                  .then(() => { window.__outcome = 'resolved'; }, error => { window.__outcome = error.name; }); true
                """, in: nil, contentWorld: .page)
            if !shown {
                // Not on screen, the tab holds the request in its queue until it is shown, where CEF's own WebAuthn never puts it.
                #expect(await waitUntil(timeout: .seconds(5)) { landed.dialogs.waitsToBeShown }, "WSurf holds the request for its tab")
            }
            let outcome = { try await popup.evaluateJavaScript("window.__outcome", in: nil, contentWorld: .page) as? String }
            try #require(await waitUntil(timeout: .seconds(20)) { try await outcome() != nil }, "the passkey request ended")
            let elapsed = started.duration(to: .now)
            #expect(try await outcome() == "NotAllowedError", "WSurf answered the passkey request")
            #expect(shown ? elapsed < .seconds(3) : elapsed > .seconds(9) && elapsed < .seconds(15), "at once, or at its deadline: \(elapsed)")
            #expect(await waitUntil { !landed.dialogs.waitsToBeShown }, "and the tab no longer holds it")

            // A second run installs nothing again: the same objects, one listener.
            _ = try await popup.evaluateJavaScript("globalThis.__before = globalThis.__wsurfPasswords; true", in: nil, contentWorld: world)
            _ = try await popup.evaluateJavaScript("window.__before = navigator.credentials.get; true", in: nil, contentWorld: .page)
            let chromium = try #require(popup.chromium)
            await chromium.devTools.runScriptsInEarlierDocuments()
            #expect(try await popup.evaluateJavaScript("globalThis.__before === globalThis.__wsurfPasswords", in: nil, contentWorld: world)
                as? Bool == true)
            #expect(try await popup.evaluateJavaScript("window.__before === navigator.credentials.get", in: nil, contentWorld: .page) as? Bool == true)
            _ = try await popup.evaluateJavaScript("globalThis.__wsurfSend('wsurfTestPing', 2); true", in: nil, contentWorld: world)
            #expect(await waitUntil { pings == 2 })
            try await Task.sleep(for: .milliseconds(300))
            #expect(pings == 2, "one listener")
        }
    }

    /// A person who declines every passkey step.
    @MainActor private struct Declining: WebAuthnCeremonyInteraction {
        var canVerifyUser: Bool {
            true
        }

        func decide(_ prompt: WebAuthnPrompt, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
            .declined
        }

        func offerStart(
            operation: WebAuthnPrompt.Operation, origin: String, locked: Bool, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?
        ) async -> WebAuthnDecision {
            .declined
        }

        func verifyUser(reason: String, until deadline: ContinuousClock.Instant?) async throws {
            throw WebsiteAuthenticatorError.notAllowed
        }

        func reportUnconfirmedRegistration(rpID: String, userName: String, in anchor: ASPresentationAnchor) {}
    }

    /// A private window's pop-up is private too and reads its opener's storage: CEF gives a pop-up its opener's request context.
    @Test func aChromiumPopupOfAPrivateWindowIsPrivate() async throws {
        try await withRig(.chromium, privately: true) { rig in
            let mark = "private\(UInt32.random(in: 1...UInt32.max))"
            _ = try await rig.evaluate("document.cookie = '\(mark)=1'; 0")
            rig.showOpenedTabs()
            try await rig.click("oauth")
            let landed = try #require(await waitForAnyTab(in: rig), "a tab opened for the pop-up")
            #expect(landed.isPrivate && rig.tab.isPrivate)
            try #require(await waitUntil { try await rig.messages().contains("{\"from\":\"popup\"}") }, "the pop-up reached window.opener")
            let cookie = try await landed.page.evaluateJavaScript("document.cookie") as? String
            #expect(cookie?.contains("\(mark)=1") == true, "the pop-up reads its opener's cookie: \(cookie ?? "nil")")
        }
    }

    private func waitForAnyTab(in rig: Rig) async -> BrowserTab? {
        _ = await waitUntil(timeout: .seconds(15)) { !rig.opened.isEmpty }
        return rig.opened.first
    }
}
