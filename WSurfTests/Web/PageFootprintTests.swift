// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What a WebKit page, and a frame from another website inside it, can see of WSurf. Challenge pages compare built-ins
/// with `[native code]` and look for globals and `window.webkit`; a frame sees nothing of WSurf at all, and the main frame
/// only the features that have no other way in.
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

    /// The main frame's documented exceptions: vault passkeys (until the owner's entitlement decision), and the
    /// notification and location stand-ins for APIs WebKit gives an embedding app no other way to provide.
    private static let mainFrameExceptions: Set<String> = [
        "navigator.credentials.get", "navigator.credentials.create",
        "PublicKeyCredential.isConditionalMediationAvailable",
        "PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable",
        "PublicKeyCredential.getClientCapabilities", "PublicKeyCredential.signalUnknownCredential",
        "PublicKeyCredential.signalAllAcceptedCredentials", "PublicKeyCredential.signalCurrentUserDetails",
        "Notification", "navigator.geolocation.getCurrentPosition",
    ]

    private var window: NSWindow?

    deinit {
        let window = window
        Task { @MainActor in window?.close() }
    }

    private func report(_ page: BrowserPage, in frame: BrowserFrame?) async throws -> Report {
        let json = try #require(try await page.evaluateJavaScript(Self.probe, in: frame, contentWorld: .page) as? String)
        return try JSONDecoder().decode(Report.self, from: Data(json.utf8))
    }

    /// The tab the app makes: the window's own page scripts (media, location, notifications) and the tab's.
    private func tab(_ context: BrowserProfileContext) -> BrowserTab {
        let media = MediaCenter()
        context.webViewPool.configurePage = { page in
            media.install(in: page)
            GeolocationBridge.shared.install(in: page)
            NotificationBridge.shared.install(in: page)
        }
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        context.settings.apply(to: configuration)
        let webView = TabWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let tab = BrowserTab(adopting: webView, opensBlank: false, privately: true, context: context)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderBack(nil)
        self.window = window
        return tab
    }

    @Test func aPageAndAnotherWebsitesFrameSeeNoTraceOfWSurf() async throws {
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

        let context = BrowserProfileContext(profile: .privateBrowsing())
        let tab = tab(context)
        defer { context.webViewPool.configurePage = nil }
        _ = tab.load(try top.url())
        try #require(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        try #require(await waitUntil {
            await PageFrameRegistry.shared.targets(in: tab.page).contains { $0.url.port == childPort }
        })
        let child = try #require(await PageFrameRegistry.shared.targets(in: tab.page).first { $0.url.port == childPort })

        let frame = try await report(tab.page, in: child.frame)
        #expect(frame == Report(wrapped: [], keys: [], webkit: "undefined", navigator: []))

        let main = try await report(tab.page, in: nil)
        #expect(Set(main.wrapped).isSubset(of: Self.mainFrameExceptions), "\(main.wrapped)")
        // The features are installed, so the probe would see any other replacement too.
        #expect(main.wrapped.contains("Notification") && main.wrapped.contains("navigator.credentials.get"))
        #expect(main.keys.isEmpty, "\(main.keys)")
        #expect(main.webkit == "undefined")
        #expect(main.navigator == ["geolocation"], "only the location stand-in")
    }
}
