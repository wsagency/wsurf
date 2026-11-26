// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The whole flow on loopback servers: an app and its SSO service in Chromium set their state cookies, a provider that only WebKit
/// may load sends the callback back, and each callback accepts it only if its cookie arrives. Cookies ignore ports, so the three
/// roles are three hosts of one server: the app `localhost`, the SSO service `127.0.0.1`, the provider `[::1]`.
/// In the OOP lane (`Tools/run-chromium-oop-tests.sh SignInHandoffLiveTests`) the Chromium half runs in the service, whose
/// cookies are read the same way.
@MainActor
@Suite(.serialized)
struct SignInHandoffLiveTests {
    private typealias Response = HTTPFixtureServer.Response

    init() {
        #if DEBUG
        // As `ChromiumOOPPageTests`: before any Chromium start of this host. Without the service the override changes nothing.
        ChromiumOOP.testOverride = true
        #endif
    }

    nonisolated final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        func record(_ request: HTTPFixtureServer.Request) {
            guard !request.method.isEmpty, request.path != "/favicon.ico" else { return }
            lock.withLock { seen.append(request.path) }
        }

        var paths: [String] {
            lock.withLock { seen }
        }
    }

    private nonisolated static func redirect(_ location: String, setting cookie: String? = nil) -> Response {
        var headers = ["Location": location, "Cache-Control": "no-store"]
        headers["Set-Cookie"] = cookie
        return Response(status: "302 Found", headers: headers, body: Data())
    }

    private nonisolated static func page(_ title: String) -> Response {
        .html("<!doctype html><title>\(title)</title><p>\(title)</p>", headers: ["Cache-Control": "no-store"])
    }

    private nonisolated static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private nonisolated static func respond(_ log: Log) -> @Sendable (HTTPFixtureServer.Request) -> Response? {
        { request in
            log.record(request)
            let port = request.headers["host"]?.split(separator: ":").last.map(String.init) ?? ""
            let app = "http://localhost:\(port)"
            let sso = "http://127.0.0.1:\(port)"
            let provider = "http://[::1]:\(port)"
            let cookies = request.headers["cookie"] ?? ""
            switch request.path {
            case "/app/home":
                return page("App")
            case "/app/start":
                return redirect("\(sso)/sso/authorize", setting: "oauth_csrf=csrf-1; Path=/; HttpOnly; SameSite=Lax")
            case "/app/direct":
                return redirect("\(provider)/provider/to-app?redirect_uri=\(encoded("\(app)/app/callback"))",
                                setting: "oauth_csrf=csrf-1; Path=/; HttpOnly; SameSite=Lax")
            case "/sso/authorize":
                return redirect("\(provider)/provider/to-sso?redirect_uri=\(encoded("\(sso)/sso/callback"))&state=s",
                                setting: "authentik_session=sso-1; Path=/; HttpOnly")
            case "/provider/to-sso":
                return redirect("\(sso)/sso/callback?state=s&code=p")
            case "/provider/to-app":
                return redirect("\(app)/app/callback?code=p")
            case "/sso/callback":
                return cookies.contains("authentik_session=sso-1") ? redirect("\(app)/app/callback?code=s") : page("SSO rejected")
            case "/app/callback":
                return page(cookies.contains("oauth_csrf=csrf-1") ? "Signed in" : "CSRF rejected")
            default:
                return nil
            }
        }
    }

    @Test(.boundedWebViews, arguments: [true, false])
    func aChromiumSignInCompletesThroughTheWebKitProvider(throughSSO: Bool) async throws {
        let log = Log()
        try await LiveWindowRig.with(engine: .chromium, respond: Self.respond(log)) { rig in
            let port = try #require(rig.server.port).rawValue
            let app = "http://localhost:\(port)"
            let provider = "http://[::1]:\(port)"
            rig.browser.sitePermissions.setEngine(.chromium, for: app)
            try await SitePermissions.withWebKitOnlyOriginForTesting(provider) {
                let home = try #require(URL(string: "\(app)/app/home"))
                let tab = rig.browser.newTab(url: home)
                tab.page.ignoresWindowOcclusion = true
                try #require(await waitUntil(timeout: .seconds(60)) { tab.page.url == home && !tab.page.isLoading })
                let chromium = try #require(tab.page.chromium)
                if ChromiumOOP.latch.mode == .outOfProcess {
                    #expect(chromium.remote != nil, "the OOP lane reads the service's cookies")
                }
                // The attributes a plain HTTP fixture cannot set, and cookies that must stay in Chromium.
                let expires = (Date().timeIntervalSince1970 + 3600).rounded()
                for params: [String: Any] in [
                    ["name": "__Host-flow", "value": "h", "url": "https://localhost/", "secure": true],
                    ["name": "sso_none", "value": "n", "url": "https://127.0.0.1/", "secure": true, "httpOnly": true, "sameSite": "None", "expires": expires],
                    ["name": "sso_strict", "value": "s", "url": "https://127.0.0.1/", "sameSite": "Strict"],
                    ["name": "elsewhere", "value": "e", "url": "https://elsewhere.test/"],
                    ["name": "provider_own", "value": "p", "url": "https://[::1]/"],
                ] {
                    _ = try await chromium.command("Network.setCookie", params: params)
                }

                let start = try #require(URL(string: "\(app)/app/\(throughSSO ? "start" : "direct")"))
                let done = try #require(URL(string: "\(app)/app/callback?code=\(throughSSO ? "s" : "p")"))
                tab.load(start)
                let finished = await waitUntil(timeout: .seconds(60)) {
                    tab.loadedEngine == .webKit && tab.page.url == done && !tab.page.isLoading
                }
                try #require(finished, "requests: \(log.paths)")
                #expect(try await tab.page.evaluateJavaScript("document.title") as? String == "Signed in", "requests: \(log.paths)")
                #expect(tab.signInEngine == .webKit)
                #expect(log.paths.filter { $0.hasPrefix("/provider/") }.count == 1, "the provider is asked once, by WebKit")

                let stored = Dictionary(await tab.dataStore.httpCookieStore.allCookies().map { ($0.name, $0) }) { first, _ in first }
                let csrf = try #require(stored["oauth_csrf"])
                #expect(csrf.domain == "localhost" && csrf.isHTTPOnly && csrf.sameSitePolicy == .sameSiteLax)
                let host = try #require(stored["__Host-flow"])
                #expect(host.domain == "localhost" && host.path == "/" && host.isSecure)
                #expect(stored["elsewhere"] == nil && stored["provider_own"] == nil)
                if throughSSO {
                    #expect(try #require(stored["authentik_session"]).isHTTPOnly)
                    let none = try #require(stored["sso_none"])
                    #expect(none.isSecure && none.isHTTPOnly && none.sameSitePolicy == nil)
                    #expect(none.expiresDate?.timeIntervalSince1970.rounded() == expires)
                    let strict = try #require(stored["sso_strict"])
                    #expect(strict.isSessionOnly && strict.sameSitePolicy == .sameSiteStrict)
                } else {
                    // The SSO host was not part of this flow: its Chromium cookies stay there.
                    #expect(stored["sso_none"] == nil && stored["sso_strict"] == nil)
                }
            }
        }
    }
}
