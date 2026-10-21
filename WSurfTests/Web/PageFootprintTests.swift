// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What a page, and a frame from another website inside it, can see of WSurf on either engine. Challenge pages compare
/// built-ins with `[native code]` and look for globals and `window.webkit`; a frame sees nothing of WSurf at all, and the
/// main frame only the features that have no other way in.
@MainActor
@Suite(.serialized, .boundedWebViews)
final class PageFootprintTests {
    private struct Report: Decodable, Equatable {
        var wrapped: [String]
        var keys: [String]
        var webkit: String
        var navigator: [String]
    }

    /// Every built-in WSurf has ever replaced, checked by `[native code]`, plus the page's view of WSurf's channels.
    private static let probe = """
        (() => {
          const native = f => Function.prototype.toString.call(f).includes('[native code]');
          const credential = window.PublicKeyCredential || {};
          const checks = {
            'Function.prototype.toString': Function.prototype.toString,
            'window.open': window.open,
            'HTMLMediaElement.prototype.play': HTMLMediaElement.prototype.play,
            'MediaDevices.getDisplayMedia': navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia,
            'Document.currentScript': (Object.getOwnPropertyDescriptor(Document.prototype, 'currentScript') || {}).get,
            'navigator.credentials.get': navigator.credentials && navigator.credentials.get,
            'navigator.credentials.create': navigator.credentials && navigator.credentials.create,
            'PublicKeyCredential.isConditionalMediationAvailable': credential.isConditionalMediationAvailable,
            'PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable': credential.isUserVerifyingPlatformAuthenticatorAvailable,
            'PublicKeyCredential.getClientCapabilities': credential.getClientCapabilities,
            'PublicKeyCredential.signalUnknownCredential': credential.signalUnknownCredential,
            'PublicKeyCredential.signalAllAcceptedCredentials': credential.signalAllAcceptedCredentials,
            'PublicKeyCredential.signalCurrentUserDetails': credential.signalCurrentUserDetails,
            'Notification': window.Notification,
            'navigator.geolocation.getCurrentPosition': navigator.geolocation && navigator.geolocation.getCurrentPosition,
          };
          return JSON.stringify({
            wrapped: Object.keys(checks).filter(name => typeof checks[name] === 'function' && !native(checks[name])),
            keys: Object.getOwnPropertyNames(window).filter(key => /wsurf/i.test(key)),
            webkit: typeof window.webkit,
            navigator: Object.getOwnPropertyNames(navigator),
          });
        })()
        """

    /// Vault passkeys (until the owner's entitlement decision): the main frame on both engines, and on Chromium, whose vault
    /// serves a verified frame, every frame.
    private static let passkeyExceptions: Set<String> = [
        "navigator.credentials.get", "navigator.credentials.create",
        "PublicKeyCredential.isConditionalMediationAvailable",
        "PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable",
        "PublicKeyCredential.getClientCapabilities", "PublicKeyCredential.signalUnknownCredential",
        "PublicKeyCredential.signalAllAcceptedCredentials", "PublicKeyCredential.signalCurrentUserDetails",
    ]

    /// The main frame's documented exceptions: vault passkeys, and the notification and location stand-ins for APIs WebKit
    /// gives an embedding app no other way to provide.
    private static let mainFrameExceptions = passkeyExceptions.union(["Notification", "navigator.geolocation.getCurrentPosition"])

    private var window: NSWindow?

    deinit {
        let window = window
        Task { @MainActor in window?.close() }
    }

    private func report(_ page: BrowserPage, in frame: BrowserFrame?) async throws -> Report {
        let json = try #require(try await page.evaluateJavaScript(Self.probe, in: frame, contentWorld: .page) as? String)
        return try JSONDecoder().decode(Report.self, from: Data(json.utf8))
    }

    /// The tab the app makes on `engine` for `site`: the window's own page scripts (media, location, notifications) and the
    /// tab's, through the production adoption path.
    private func tab(_ engine: BrowserEngine, for site: URL, in context: BrowserProfileContext) throws -> BrowserTab {
        let media = MediaCenter()
        context.webViewPool.configurePage = { page in
            media.install(in: page)
            GeolocationBridge.shared.install(in: page)
            NotificationBridge.shared.install(in: page)
        }
        // The tab sends a site to the engine it is set to.
        context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: site))
        let tab = BrowserTab(opensBlank: false, privately: true, context: context)
        switch engine {
        case .webKit:
            tab.adopt(BrowserPage(webKit: context.webViewPool.acquire(), context: context))
        case .chromium:
            try ChromiumRuntime.shared.ensureInitialized()
            tab.adopt(BrowserPage(chromium: ChromiumPage(context: context)))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderBack(nil)
        self.window = window
        return tab
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPageAndAnotherWebsitesFrameSeeNoTraceOfWSurf(_ engine: BrowserEngine) async throws {
        let framed = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Challenge</title><video></video><script>void 0</script>"),
        ])
        defer { withExtendedLifetime(framed) {} }
        var components = try #require(URLComponents(url: try framed.url(), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let childURL = try #require(components.url)
        let childPort = try #require(childURL.port)
        let top = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <!doctype html><title>Site</title><video></video>
                <iframe src="\(childURL.absoluteString)"></iframe>
                """),
        ])
        defer { withExtendedLifetime(top) {} }

        // Another origin on the same site: Chromium keeps it in the page's own renderer, where the engine's frame list
        // (and so this probe) reaches it. A frame from another site gets its own process.
        var topComponents = try #require(URLComponents(url: try top.url(), resolvingAgainstBaseURL: false))
        topComponents.host = "localhost"
        let site = try #require(topComponents.url)
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let tab = try tab(engine, for: site, in: context)
        defer {
            context.webViewPool.configurePage = nil
            tab.detach()
        }
        _ = tab.load(site)
        try #require(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        try #require(await waitUntil {
            await PageFrameRegistry.shared.targets(in: tab.page).contains { $0.url.port == childPort }
        })
        let child = try #require(await PageFrameRegistry.shared.targets(in: tab.page).first { $0.url.port == childPort })

        let frame = try await report(tab.page, in: child.frame)
        #expect(Set(frame.wrapped).isSubset(of: engine == .chromium ? Self.passkeyExceptions : []), "\(frame.wrapped)")
        // Chromium: also needs ChromiumDevTools to expose `__wsurfSend` only to worlds with a message handler (the
        // Chromium branch's isolated bindings); a page-world script must not bring it into every frame.
        #expect(frame.keys.isEmpty, "\(engine): \(frame.keys)")
        #expect(frame.webkit == "undefined" && frame.navigator.isEmpty, "\(engine)")

        let main = try await report(tab.page, in: nil)
        #expect(Set(main.wrapped).isSubset(of: Self.mainFrameExceptions), "\(main.wrapped)")
        // The features are installed, so the probe would see any other replacement too.
        #expect(main.wrapped.contains("Notification") && main.wrapped.contains("navigator.credentials.get"))
        #expect(main.keys.isEmpty, "\(main.keys)")
        #expect(main.webkit == "undefined")
        #expect(main.navigator == ["geolocation"], "only the location stand-in")
    }

    /// WSurf's own script call is no click on either engine: a `window.open` it runs is the pop-up the Block policy stops,
    /// and only a person's action replayed (`userGesture`) opens one. The gesture-less call goes first, so by the time the
    /// replayed one has opened its tab the first has been decided.
    @Test(arguments: BrowserEngine.allCases)
    func aWSurfEvaluationIsStillABlockedPopUp(_ engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Site</title>"),
            "/popup": .html("<!doctype html><title>Popup</title>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let site = try server.url()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        context.settings.blocksPopups = true
        let tab = try tab(engine, for: site, in: context)
        defer {
            context.webViewPool.configurePage = nil
            tab.detach()
        }
        var opened = 0
        tab.onNewWindow = { _, _ in opened += 1 }
        tab.onOpenInNewTab = { _, _ in opened += 1 }
        _ = tab.load(site)
        try #require(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))

        _ = try await tab.page.evaluateJavaScript("window.open('/popup'); true", in: nil, contentWorld: .page)
        _ = try await tab.page.evaluateJavaScript(
            "window.open('/popup'); true", in: nil, contentWorld: .page, userGesture: true)
        #expect(await waitUntil { opened == 1 }, "\(engine): the replayed action opens its pop-up")
        #expect(opened == 1, "\(engine): WSurf's own call opened one too")
        // CEF blocks a gesture-less `window.open` before `on_before_popup`, so WSurf has no notice to show there: only WebKit asks.
        if engine == .webKit {
            #expect(tab.popups.blocked == (try server.url("/popup")), "\(engine)")
        }
    }
}
