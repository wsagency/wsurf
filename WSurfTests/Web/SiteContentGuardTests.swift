// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
/// The auto-play answer as Chromium keeps it, with a script in WSurf's isolated world; its JavaScript is engine-neutral, so
/// these cases drive it on WebKit, in that world. On WebKit itself both answers are WebKit's own (`WebKitSiteContentTests`).
@Suite(.serialized, .boundedWebViews)
final class SiteContentGuardTests {
    private let defaultsName = AppDatabase.defaultsSuite("SiteContentGuardTests-" + UUID().uuidString)
    private let settings: BrowserSettings

    init() {
        settings = BrowserSettings(defaults: UserDefaults(suiteName: defaultsName)!)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }

    private func temporaryPermissions() -> SitePermissions {
        SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appending(path: "SiteContentGuardTests-\(UUID().uuidString).json")
        )
    }

    private static let markup = """
        <!doctype html><html><body style="margin:0">
        <video style="width:640px;height:360px"></video>
        </body></html>
        """

    private func page(permissions: SitePermissions, at address: URL? = nil) async -> BrowserPage {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = BrowserPage(webKit: TabWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        ), context: BrowserProfileContext(profile: .privateBrowsing()))
        SiteContentGuard.shared.installScript(in: view, permissions: permissions, settings: settings)
        if let address {
            view.load(URLRequest(url: address))
        } else {
            view.loadHTMLString(Self.markup, baseURL: nil)
        }
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(30)))
        #expect(
            await waitUntil {
                let settled = try? await self.run(
                    "!!(window.__wsurfSiteGuard && window.__wsurfSiteGuard.autoplay)", in: view
                )
                return (settled as? NSNumber)?.boolValue == true
            },
            "the page never heard back which policy it is under"
        )
        return view
    }

    /// Runs `script` in the guard's own world: it sees the page's DOM, and the guard sees what is replaced there.
    private func run(_ script: String, in view: BrowserPage) async throws -> Any {
        try await view.evaluateJavaScript(script, in: nil, contentWorld: BrowserPage.servicesWorld)
    }

    /// `pause` is replaced rather than watched: a player with no source throws
    /// on the real call, and the count is what the test is asking about.
    private func play(in view: BrowserPage, startedByHand: Bool = false) async {
        _ = try? await run(
            """
            (() => {
              Object.defineProperty(navigator, 'userActivation', {
                configurable: true,
                get() { return { hasBeenActive: \(startedByHand), isActive: \(startedByHand) }; }
              });
              const video = document.querySelector('video');
              window.__pauses = 0;
              video.pause = () => { window.__pauses += 1; };
              video.dispatchEvent(new Event('play'));
              return true;
            })()
            """, in: view
        )
    }

    private func pauses(in view: BrowserPage) async -> Int {
        let count = try? await run("window.__pauses", in: view)
        return (count as? NSNumber)?.intValue ?? -1
    }

    private func isMuted(in view: BrowserPage) async -> Bool {
        let muted = try? await view.evaluateJavaScript("document.querySelector('video').muted")
        return (muted as? NSNumber)?.boolValue ?? false
    }

    /// What Chromium leaves behind when an autoplay element was ready before the website's answer came: paused, ready, never
    /// played. `play` is counted, not called (a player with no source throws on it). The answer is then handed to the guard
    /// the way the reply is, and the count of `play` calls it made comes back.
    private func startsAfterAnswer(
        _ policy: AutoplayPolicy, in view: BrowserPage, autoplay: Bool = true, readyState: Int = 4,
        played: Bool = false, pausedByHand: Bool = false
    ) async -> Int {
        let started = try? await run(
            """
            (() => {
              const video = document.querySelector('video');
              const fixed = (key, value) => Object.defineProperty(video, key, { configurable: true, get() { return value; } });
              \(autoplay ? "video.setAttribute('autoplay', '');" : "")
              fixed('paused', true);
              fixed('readyState', \(readyState));
              fixed('played', { length: \(played ? 1 : 0) });
              window.__plays = 0;
              video.play = () => { window.__plays += 1; return Promise.resolve(); };
              \(pausedByHand ? "video.dispatchEvent(new Event('pause'));" : "")
              window.__wsurfSiteGuard.applyPolicy({ autoplay: '\(policy.rawValue)' });
              return window.__plays;
            })()
            """, in: view
        )
        return (started as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Auto-play

    @Test func aWebsiteToldNeverIsStopped() async {
        settings.autoplay = .block

        let view = await page(permissions: temporaryPermissions())
        await play(in: view)

        #expect(await pauses(in: view) == 1)
        #expect(await isMuted(in: view) == false, "stopping a player is not muting it")
    }

    @Test func aWebsiteToldMutedPlaysWithoutSound() async {
        settings.autoplay = .silent

        let view = await page(permissions: temporaryPermissions())
        await play(in: view)

        #expect(await pauses(in: view) == 0, "a muted player is still a playing one")
        #expect(await isMuted(in: view))
    }

    @Test func aWebsiteToldAllowIsLeftAlone() async {
        settings.autoplay = .allow

        let view = await page(permissions: temporaryPermissions())
        await play(in: view)

        #expect(await pauses(in: view) == 0)
        #expect(await isMuted(in: view) == false)
    }

    /// The answer is about what a website starts by itself. A video the person
    /// pressed play on is theirs, whatever the website was told.
    @Test func aPlayerThePersonStartedIsNeverStopped() async {
        settings.autoplay = .block

        let view = await page(permissions: temporaryPermissions())
        await play(in: view, startedByHand: true)

        #expect(await pauses(in: view) == 0)
    }

    /// Chromium tries an autoplay element once, when it is ready, and refuses it before the answer's activation has come; the
    /// answer under Allow starts what is still waiting for it.
    @Test func allowStartsAnAutoplayPlayerThatWasReadyBeforeTheAnswer() async {
        settings.autoplay = .allow

        let view = await page(permissions: temporaryPermissions())

        #expect(await startsAfterAnswer(.allow, in: view) == 1)
    }

    /// What is not waiting is left alone: a player that has played, one that was paused, one that is not ready yet, and one
    /// the website never asked to autoplay.
    @Test func allowNeverStartsAPlayerThePersonOrThePageStoppedOrNeverAskedToAutoplay() async {
        settings.autoplay = .allow

        // A page of its own for each: a pause is remembered for the life of the page.
        let cases: [(String, (BrowserPage) async -> Int)] = [
            ("paused before the answer", { await self.startsAfterAnswer(.allow, in: $0, pausedByHand: true) }),
            ("it has played, so it was stopped, not refused", { await self.startsAfterAnswer(.allow, in: $0, played: true) }),
            ("not ready: its own attempt is still to come", { await self.startsAfterAnswer(.allow, in: $0, readyState: 2) }),
            ("the website never asked it to start", { await self.startsAfterAnswer(.allow, in: $0, autoplay: false) }),
        ]
        for (what, answer) in cases {
            let view = await page(permissions: temporaryPermissions())

            #expect(await answer(view) == 0, "\(what)")
        }
    }

    /// Muted and Never are what they were: nothing is started where the answer forbids sound or any start.
    @Test func neitherMutedNorNeverStartsAPlayerTheEngineRefused() async {
        for policy in [AutoplayPolicy.silent, .block] {
            settings.autoplay = policy

            let view = await page(permissions: temporaryPermissions())

            #expect(await startsAfterAnswer(policy, in: view) == 0, "\(policy.rawValue) starts nothing")
        }
    }

    /// A website's own answer outranks the setting every other website is under.
    @Test func aWebsiteWithItsOwnAnswerIsNotUnderTheSetting() async throws {
        settings.autoplay = .allow

        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.markup)])
        let address = try server.url()
        let permissions = temporaryPermissions()
        permissions.setAutoplay(.block, for: SitePermissions.origin(for: address))

        let view = await page(permissions: permissions, at: address)
        await play(in: view)

        #expect(await pauses(in: view) == 1)
    }

    // MARK: - User activation

    private static let bare = "<!doctype html><title>Bare</title><p>Nothing to play here.</p>"

    private func hasBeenActive(_ view: BrowserPage) async -> Bool? {
        (try? await view.evaluateJavaScript("navigator.userActivation.hasBeenActive")) as? Bool
    }

    /// Hearing WSurf's answer is no click, Allow included: no page is given the activation that would let its script open a
    /// pop-up or the colour chooser by itself, whether it has nothing to play, has a player, or makes one by script.
    @Test func anAllowAnswerGivesNoPageActivation() async throws {
        settings.autoplay = .allow
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.bare), "/player": .html(Self.markup)])

        for path in ["/", "/player"] {
            let view = await page(permissions: temporaryPermissions(), at: try server.url(path))
            try await Task.sleep(for: .milliseconds(500))
            #expect(await hasBeenActive(view) == false, "\(path)")
            if path == "/" {
                _ = try await view.evaluateJavaScript("""
                    const player = document.createElement('video'); player.src = '/missing.mp4'; document.body.append(player); true
                    """)
                try await Task.sleep(for: .milliseconds(500))
                #expect(await hasBeenActive(view) == false, "a player made by script")
            }
        }
        withExtendedLifetime(server) {}
    }
}

/// The colour chooser opens for the person's own click on a colour field, and never because a page asked for it by itself:
/// a page that has just loaded, under the default Allow, asks a moment later, once WSurf's answers to it are in, and opens a
/// pop-up too. One page first makes a player by script, the way a website could to be answered as one with media. On each
/// engine, in the window the app builds.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageColorChooserTests {
    private static let page = """
        <!doctype html><title>Colour</title><input type="color" id="field">
        <script>
        window.__marker = 'loaded';
        addEventListener('load', () => {
          if (location.pathname === '/player') {
            const player = document.createElement('video'); player.src = '/missing.mp4'; document.body.append(player);
          }
          setTimeout(() => {
            let chooser;
            try { document.getElementById('field').showPicker(); chooser = 'opened'; } catch (error) { chooser = error.name; }
            document.title = chooser + ' ' + (window.open('/still') ? 'opened' : 'blocked');
          }, 1000);
        });
        </script>
        """

    private func title(of tab: BrowserTab) async -> String? {
        (try? await tab.page.evaluateJavaScript("document.title")) as? String
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium], ["/colour", "/player"])
    func onlyThePersonsClickOpensTheColourChooser(engine: BrowserEngine, path: String) async throws {
        try await LiveWindowRig.with(engine: engine, routes: ["/colour": .html(Self.page), "/player": .html(Self.page)]) { rig in
            let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            let added = { NSApp.windows.filter { $0.isVisible && !shown.contains(ObjectIdentifier($0)) } }
            defer {
                added().forEach { $0.orderOut(nil) }
            }
            let tabs = rig.browser.tabs.count
            let tab = try await rig.open(path)
            #expect(await waitUntil { await title(of: tab) != "Colour" }, "\(engine) \(path): the page asked")
            #expect(await title(of: tab) == "NotAllowedError blocked", "\(engine) \(path): the page was refused both")
            #expect(added().isEmpty, "\(engine) \(path): no chooser opened: \(added())")
            #expect(rig.browser.tabs.count == tabs + 1, "\(engine) \(path): no pop-up tab opened")

            _ = try await tab.page.evaluateJavaScript(
                "document.getElementById('field').click(); true", in: nil, contentWorld: .page, userGesture: true
            )
            #expect(await waitUntil { !added().isEmpty }, "\(engine) \(path): the person's click opens it")
        }
    }
}

/// Under Allow a Chromium website starts sound by itself, as on WebKit, and is not given the person's activation for it;
/// under Never sound waits for the person. Chromium applies its allowlist when a navigation finishes, so the page starts its
/// player once it has loaded. The player's source never arrives, so nothing is heard: a refused start fails at once, an
/// allowed one waits for its data.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ChromiumAutoplayAllowlistTests {
    private static let page = """
        <!doctype html><title>Sound</title>
        <script>
        window.__marker = 'loaded';
        addEventListener('load', () => setTimeout(() => {
          let settled = false;
          new Audio('/never').play().then(
            () => { settled = true; document.title = 'played'; },
            (error) => { settled = true; document.title = error.name; }
          );
          setTimeout(() => { if (!settled) document.title = 'waiting'; }, 1000);
        }, 300));
        </script>
        """

    private func title(of tab: BrowserTab) async -> String? {
        (try? await tab.page.evaluateJavaScript("document.title")) as? String
    }

    /// An entry names one exact origin, its port written out, or there is none: a host that would read as a wildcard to
    /// Chromium, or is not a plain host, is left out.
    @Test func anEntryIsOneExactOriginOrNone() {
        let kept = [
            "https://example.com": "https://example.com:443",
            "http://127.0.0.1:8080": "http://127.0.0.1:8080",
            "http://[::1]": "http://[::1]:80",
            "https://[2001:db8::1]:8443": "https://[2001:db8::1]:8443",
            "https://xn--bcher-kva.example": "https://xn--bcher-kva.example:443",
        ]
        for (origin, entry) in kept {
            #expect(ChromiumRuntime.autoplayPattern(for: origin) == entry, "\(origin)")
        }
        let dropped = [
            "https://*.example.com", "https://*", "https://[*.]example.com", "http://[example.com]", "http://[::1",
            "https://ex%2Aample.com", "https://-example.com", "https://Example.com", "file:///tmp/page.html", "chrome://settings",
        ]
        for origin in dropped {
            #expect(ChromiumRuntime.autoplayPattern(for: origin) == nil, "\(origin)")
        }
    }

    @Test(arguments: [(AutoplayPolicy.allow, "waiting"), (.block, "NotAllowedError")])
    func onlyAnAllowedWebsiteStartsSoundByItself(policy: AutoplayPolicy, outcome: String) async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: ["/sound": .html(Self.page)]) { rig in
            rig.browser.sitePermissions.setAutoplay(policy, for: SitePermissions.origin(for: try rig.server.url("/sound")))
            let tab = try await rig.open("/sound")
            #expect(await waitUntil { await title(of: tab) != "Sound" }, "\(policy): the page started its player")
            #expect(await title(of: tab) == outcome, "\(policy)")
            #expect(
                try await tab.page.evaluateJavaScript("navigator.userActivation.hasBeenActive") as? Bool == false,
                "\(policy): the page was activated"
            )
        }
    }

    /// The allowlist names the allowed origin and nothing more: a subdomain of its host and the same host on another port,
    /// both answered Never, are refused while the allowed origin's page is open, and the allowed origin itself plays.
    @Test func onlyTheAllowedOriginItselfStartsSoundByItself() async throws {
        let elsewhere = try await HTTPFixtureServer.start(routes: ["/sound": .html(Self.page)])
        try await LiveWindowRig.with(engine: .chromium, routes: ["/sound": .html(Self.page)]) { rig in
            let port = try #require(try rig.server.url().port)
            let another = try #require(try elsewhere.url().port)
            let allowed = try #require(URL(string: "http://localhost:\(port)/sound"))
            let subdomain = try #require(URL(string: "http://sub.localhost:\(port)/sound"))
            let otherPort = try #require(URL(string: "http://localhost:\(another)/sound"))
            let cases = [(allowed, AutoplayPolicy.allow, "waiting"), (subdomain, .block, "NotAllowedError"), (otherPort, .block, "NotAllowedError")]
            for (url, policy, _) in cases {
                rig.browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
                rig.browser.sitePermissions.setAutoplay(policy, for: SitePermissions.origin(for: url))
            }
            var tabs: [BrowserTab] = []
            for (url, _, outcome) in cases {
                let tab = rig.browser.newTab(url: url, engine: .chromium)
                tab.page.ignoresWindowOcclusion = true
                tabs.append(tab)
                #expect(await waitUntil(timeout: .seconds(60)) { tab.page.url == url && !tab.page.isLoading }, "\(url) loads")
                #expect(await waitUntil { await title(of: tab) != "Sound" }, "\(url): the page started its player")
                #expect(await title(of: tab) == outcome, "\(url)")
            }
            withExtendedLifetime(tabs) {}
        }
        withExtendedLifetime(elsewhere) {}
    }
}

/// WebKit keeps a website's answers itself: the tab's navigation delegate sets the auto-play policy for each main-frame
/// document and decides each pop-up as WebKit asks for its window. Nothing is installed in the page, so these cases also
/// check that `window.open` and `play` are still WebKit's own.
@MainActor
@Suite(.serialized, .boundedWebViews)
final class WebKitSiteContentTests {
    private let context = BrowserProfileContext(profile: .privateBrowsing())
    private let permissions = SitePermissions(
        storageURL: FileManager.default.temporaryDirectory
            .appending(path: "WebKitSiteContentTests-\(UUID().uuidString).json")
    )
    private var windows: [NSWindow] = []

    deinit {
        let windows = windows
        Task { @MainActor in windows.forEach { $0.close() } }
    }

    /// A tenth of a second of silence: a real track, so WebKit applies its audio rules to it.
    static let wave: Data = {
        let samples = 800
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(8_000))
        append(UInt16(1)); append(UInt16(8))
        data.append(contentsOf: Data("data".utf8))
        append(UInt32(samples))
        data.append(Data(repeating: 128, count: samples))
        return data
    }()

    /// Plays `make` (an expression giving a media element) as the page's own script does, and titles the page with the
    /// outcome. Native never runs script in the page first: WebKit counts that as the person's interaction.
    private static func playing(_ make: String) -> String {
        """
        <!doctype html><title>loading</title><script>
        const report = (outcome) => { if (window.parent !== window) parent.postMessage(outcome, '*'); else document.title = outcome; };
        const native = [window.open, HTMLMediaElement.prototype.play]
          .every(f => Function.prototype.toString.call(f).includes('[native code]'));
        window.start = () => (\(make)).play().then(() => report(native ? 'played' : 'wrapped'),
                                                     e => report(native ? e.name : 'wrapped'));
        </script>
        """
    }

    private func server(_ routes: [String: HTTPFixtureServer.Response]) async throws -> HTTPFixtureServer {
        var all = routes
        all["/tone.wav"] = .bytes(Self.wave, contentType: "audio/wav")
        return try await HTTPFixtureServer.start(routes: all)
    }

    private func tab() -> BrowserTab {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        context.settings.apply(to: configuration)
        let webView = TabWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let tab = BrowserTab(adopting: webView, opensBlank: false, privately: true,
                             sitePermissions: permissions, context: context)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderBack(nil)
        windows.append(window)
        return tab
    }

    private func outcome(of page: String, at path: String = "/", under policy: AutoplayPolicy,
                         siteAnswer: AutoplayPolicy? = nil) async throws -> String? {
        context.settings.autoplay = policy
        let server = try await server([path: .html(page + "<script>start()</script>")])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url(path)
        if let siteAnswer {
            permissions.setAutoplay(siteAnswer, for: SitePermissions.origin(for: url))
        }
        let tab = tab()
        _ = tab.load(url)
        _ = await waitUntil { tab.page.title.map { $0 != "loading" && !$0.isEmpty } == true }
        return tab.page.title
    }

    // MARK: - Auto-play

    @Test func aWebsiteToldNeverStartsNoPlayerKeptOffThePage() async throws {
        #expect(try await outcome(of: Self.playing("new Audio('/tone.wav')"), under: .block) == "NotAllowedError")
    }

    @Test func aWebsiteToldAllowPlaysByItself() async throws {
        #expect(try await outcome(of: Self.playing("new Audio('/tone.wav')"), under: .allow) == "played")
    }

    @Test func aWebsiteToldMutedPlaysOnlyWithoutSound() async throws {
        #expect(try await outcome(of: Self.playing("new Audio('/tone.wav')"), under: .silent) == "NotAllowedError")
        let muted = "Object.assign(document.createElement('video'), {muted: true, src: '/tone.wav'})"
        #expect(try await outcome(of: Self.playing(muted), under: .silent) == "played")
    }

    @Test func aWebsitesOwnNeverOutranksTheSetting() async throws {
        let outcome = try await outcome(of: Self.playing("new Audio('/tone.wav')"), under: .allow, siteAnswer: .block)
        #expect(outcome == "NotAllowedError", "\(outcome ?? "nil")")
    }

    @Test func aWebsitesOwnAllowOutranksTheSetting() async throws {
        let outcome = try await outcome(of: Self.playing("new Audio('/tone.wav')"), under: .block, siteAnswer: .allow)
        #expect(outcome == "played", "\(outcome ?? "nil")")
    }

    /// The answer covers the whole document, a frame from another website included.
    @Test func aWebsiteToldNeverStartsNothingInAnotherWebsitesFrame() async throws {
        context.settings.autoplay = .block
        let framed = try await server(["/": .html(Self.playing("new Audio('/tone.wav')") + "<script>start()</script>")])
        defer { withExtendedLifetime(framed) {} }
        var components = try #require(URLComponents(url: try framed.url(), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let child = try #require(components.url)
        let top = try await server([
            "/": .html("""
                <!doctype html><title>loading</title>
                <script>addEventListener('message', e => { document.title = 'frame:' + e.data; });</script>
                <iframe src="\(child.absoluteString)"></iframe>
                """),
        ])
        defer { withExtendedLifetime(top) {} }
        let tab = tab()
        _ = tab.load(try top.url())
        #expect(await waitUntil { tab.page.title?.hasPrefix("frame:") == true })
        #expect(tab.page.title == "frame:NotAllowedError")
    }

    /// A pop-up its opener writes is never navigated, so no navigation decision gives it an answer: it starts under the
    /// opener's. The player starts outside the gesture that opened the window.
    @Test func aPopUpTheOpenerWritesKeepsTheOpenersAnswer() async throws {
        context.settings.autoplay = .block
        let server = try await server(["/": .html("<!doctype html><title>ready</title>")])
        defer { withExtendedLifetime(server) {} }
        let tab = tab()
        tab.onNewWindow = { _, _ in }
        _ = tab.load(try server.url())
        #expect(await waitUntil { tab.page.title == "ready" })
        // The person's click, replayed, so the window opens.
        _ = try await tab.page.evaluateJavaScript("""
            const popup = window.open('');
            setTimeout(() => new popup.Audio(new URL('/tone.wav', location.href).href).play()
              .then(() => { document.title = 'played'; }, error => { document.title = error.name; }), 1500);
            true
            """, in: nil, contentWorld: .page, userGesture: true)
        #expect(await waitUntil(timeout: .seconds(10)) { tab.page.title != "ready" })
        #expect(tab.page.title == "NotAllowedError")
    }

    /// Once the person has used the page, its players are theirs: a player started well after that interaction plays.
    @Test func aPageThePersonUsedMayPlayLater() async throws {
        context.settings.autoplay = .block
        let server = try await server([
            "/": .html(Self.playing("new Audio('/tone.wav')")
                + "<script>window.later = () => setTimeout(start, 1500); document.title = 'ready';</script>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let tab = tab()
        _ = tab.load(try server.url())
        #expect(await waitUntil { tab.page.title == "ready" })
        // The person's click, replayed; the player starts outside any gesture.
        _ = try await tab.page.evaluateJavaScript("later(); true", in: nil, contentWorld: .page, userGesture: true)
        #expect(await waitUntil(timeout: .seconds(10)) { tab.page.title != "ready" })
        #expect(tab.page.title == "played")
    }

    // MARK: - WSurf's own calls are not the person's

    /// The tab with the window's own page scripts too (media, location, notifications), whose answers reach the page.
    private func tabWithBridges() -> BrowserTab {
        let media = MediaCenter()
        context.webViewPool.configurePage = { page in
            media.install(in: page)
            GeolocationBridge.shared.install(in: page)
            NotificationBridge.shared.install(in: page)
        }
        let tab = tab()
        context.webViewPool.configurePage = nil
        NotificationBridge.shared.tabResolver = { [weak tab] page in tab?.page === page ? tab : nil }
        GeolocationBridge.shared.tabResolver = NotificationBridge.shared.tabResolver
        return tab
    }

    private func resetBridges() {
        NotificationBridge.shared.tabResolver = nil
        GeolocationBridge.shared.tabResolver = nil
    }

    /// The notification stand-in hears from native as each page loads. That answer is WSurf's, not the person's: a player the
    /// website starts after it is still refused.
    @Test(arguments: [AutoplayPolicy.block, .silent])
    func aPlayerStartedAfterWSurfAnsweredThePageIsStillRefused(_ policy: AutoplayPolicy) async throws {
        defer { resetBridges() }
        context.settings.autoplay = policy
        let server = try await server([
            "/": .html(Self.playing("new Audio('/tone.wav')") + """
                <script>
                const answered = setInterval(() => {
                  if (Notification.permission !== 'granted') return;
                  clearInterval(answered);
                  setTimeout(start, 1500);
                }, 20);
                </script>
                """),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        permissions.set(.allow, for: SitePermissions.origin(for: url), .notifications)
        let tab = tabWithBridges()
        _ = tab.load(url)
        #expect(await waitUntil(timeout: .seconds(10)) { tab.page.title.map { $0 != "loading" && !$0.isEmpty } == true })
        #expect(tab.page.title == "NotAllowedError", "\(policy)")
    }

    /// A page can ask the notification stand-in for an answer whenever it likes. Hearing it is no click: a pop-up opened from
    /// the answer is blocked.
    @Test(arguments: [true, false])
    func anAnswerThePageAskedForOpensNoPopUp(notifies: Bool) async throws {
        defer { resetBridges() }
        context.settings.blocksPopups = notifies
        let server = try await server([
            "/": .html("""
                <!doctype html><title>loading</title><script>
                document.addEventListener('wsurfnotify-answer', () => {
                  window.open('/popup');
                  document.title = 'answered';
                });
                setTimeout(() => document.dispatchEvent(new CustomEvent('wsurfnotify',
                  { detail: JSON.stringify({ type: 'hello', id: 0 }) })), 100);
                </script>
                """),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        if !notifies {
            permissions.setPopups(.block, for: SitePermissions.origin(for: url))
        }
        let tab = tabWithBridges()
        var opened = 0
        tab.onNewWindow = { _, _ in opened += 1 }
        _ = tab.load(url)
        #expect(await waitUntil { tab.page.title == "answered" })
        #expect(opened == 0)
        #expect(tab.popups.blocked == (notifies ? try server.url("/popup") : nil))
    }

    /// A page's own Cmd-click is a plain click: it opens no tab of its own accord.
    @Test func aScriptedCommandClickOpensNoTab() async throws {
        let server = try await server([
            "/": .html("""
                <!doctype html><title>start</title><a href="/next">Next</a><script>
                document.querySelector('a').dispatchEvent(
                  new MouseEvent('click', { metaKey: true, bubbles: true, cancelable: true }));
                </script>
                """),
            "/next": .html("<!doctype html><title>next</title>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let tab = tab()
        var newTabs = 0
        tab.onOpenInNewTab = { _, _ in newTabs += 1 }
        _ = tab.load(try server.url())
        #expect(await waitUntil { tab.page.title == "next" })
        #expect(newTabs == 0)
    }

    // MARK: - Pop-ups

    private final class Opened {
        var count = 0
    }

    private func popUpTab(_ html: String, blocksPopups: Bool,
                          siteAnswer: PopupPolicy? = nil) async throws -> (BrowserTab, Opened, HTTPFixtureServer) {
        context.settings.blocksPopups = blocksPopups
        let server = try await server(["/": .html(html)])
        let url = try server.url()
        if let siteAnswer {
            permissions.setPopups(siteAnswer, for: SitePermissions.origin(for: url))
        }
        let tab = tab()
        let opened = Opened()
        tab.onNewWindow = { _, _ in opened.count += 1 }
        _ = tab.load(url)
        #expect(await waitUntil { tab.page.title == "done" })
        return (tab, opened, server)
    }

    private static let openingByItself = """
        <!doctype html><script>
        window.open('/popup');
        document.title = Function.prototype.toString.call(window.open).includes('[native code]') ? 'done' : 'wrapped';
        </script>
        """

    @Test func aPopUpTheWebsiteOpensByItselfIsBlockedAndNoted() async throws {
        let (tab, opened, server) = try await popUpTab(Self.openingByItself, blocksPopups: true)
        defer { withExtendedLifetime(server) {} }
        #expect(opened.count == 0)
        #expect(tab.popups.blocked == (try server.url("/popup")))
    }

    @Test func aWebsiteToldBlockSaysNothing() async throws {
        let (tab, opened, server) = try await popUpTab(Self.openingByItself, blocksPopups: false, siteAnswer: .block)
        defer { withExtendedLifetime(server) {} }
        #expect(opened.count == 0)
        #expect(tab.popups.blocked == nil)
    }

    @Test func aWebsiteAllowedItsPopUpsOpensThem() async throws {
        let (tab, opened, server) = try await popUpTab(Self.openingByItself, blocksPopups: false)
        defer { withExtendedLifetime(server) {} }
        #expect(await waitUntil { opened.count == 1 })
        #expect(tab.popups.blocked == nil)
    }

    /// A pop-up the person started is theirs, whatever the website was told.
    @Test func aPopUpThePersonStartedOpens() async throws {
        let (tab, opened, server) = try await popUpTab("<!doctype html><title>done</title>", blocksPopups: true)
        defer { withExtendedLifetime(server) {} }
        // The person's click, replayed.
        _ = try await tab.page.evaluateJavaScript("window.open('/next'); true", in: nil, contentWorld: .page, userGesture: true)
        #expect(await waitUntil { opened.count == 1 })
        #expect(tab.popups.blocked == nil)
    }
}
