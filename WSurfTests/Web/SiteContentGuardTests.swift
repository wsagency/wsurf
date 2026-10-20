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
    private let defaultsName = "SiteContentGuardTests-" + UUID().uuidString
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
    private static let wave: Data = {
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

    @Test func aWebsitesOwnAnswerOutranksTheSetting() async throws {
        #expect(try await outcome(of: Self.playing("new Audio('/tone.wav')"), under: .allow, siteAnswer: .block)
            == "NotAllowedError")
        // The setting is also the view's own fallback; a website's answer still outranks it.
        #expect(try await outcome(of: Self.playing("new Audio('/tone.wav')"), under: .block, siteAnswer: .allow)
            == "played")
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

    /// Nothing WSurf does to a page while it loads counts as the person using it: a player the website starts by itself
    /// two seconds later is still refused.
    @Test func aPlayerTheWebsiteStartsLaterIsStillRefused() async throws {
        context.settings.autoplay = .block
        let server = try await server([
            "/": .html(Self.playing("new Audio('/tone.wav')") + "<script>setTimeout(start, 2000)</script>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let tab = tab()
        _ = tab.load(try server.url())
        #expect(await waitUntil(timeout: .seconds(10)) { tab.page.title.map { $0 != "loading" && !$0.isEmpty } == true })
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
        // Script run by native counts as the person's interaction; the player starts outside any gesture.
        _ = try await tab.page.evaluateJavaScript("later(); true")
        #expect(await waitUntil(timeout: .seconds(10)) { tab.page.title != "ready" })
        #expect(tab.page.title == "played")
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
        // Script run by native counts as the person's click.
        _ = try await tab.page.evaluateJavaScript("window.open('/next'); true")
        #expect(await waitUntil { opened.count == 1 })
        #expect(tab.popups.blocked == nil)
    }
}
