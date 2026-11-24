// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit
import WSurfVault

@testable import WSurf

/// Website Settings → Cookies: which cookies belong to a website, and listing and deleting them in WebKit and Chromium. Fresh
/// profiles only; Chromium uses the test runtime's temporary root and mock key.
@MainActor
@Suite(.serialized)
struct SiteCookiesTests {
    private let runtime = ChromiumRuntime.shared

    // MARK: Matching

    @Test(arguments: [
        // A domain cookie: its domain and every name under it.
        (".example.com", "example.com", true),
        (".example.com", "app.example.com", true),
        (".example.com", "a.b.example.com", true),
        (".Example.COM.", "APP.example.com.", true),
        (".example.co.uk", "www.example.co.uk", true),
        // A host-only cookie: its own host only.
        ("example.com", "example.com", true),
        ("example.com", "app.example.com", false),
        ("app.example.com", "example.com", false),
        (".app.example.com", "example.com", false),
        // A name that only ends in the same letters.
        ("notexample.com", "example.com", false),
        (".example.com", "notexample.com", false),
        (".example.com", "example.com.evil.test", false),
        // A public suffix: no site can set it, so it matches nothing under it.
        (".com", "example.com", false),
        (".co.uk", "example.co.uk", false),
        (".github.io", "someone.github.io", false),
        // Addresses and loopback names: the exact address only.
        ("127.0.0.1", "127.0.0.1", true),
        (".0.0.1", "127.0.0.1", false),
        (".1", "127.0.0.1", false),
        ("127.0.0.1", "127.0.0.2", false),
        ("[::1]", "::1", true),
        ("::1", "[::1]", true),
        ("0:0:0:0:0:0:0:1", "[::1]", true),
        ("::2", "::1", false),
        ("localhost", "localhost", true),
        ("localhost", "app.localhost", false),
        ("", "example.com", false),
        (".", "example.com", false),
    ])
    func whichCookiesApplyToAHost(domain: String, host: String, applies: Bool) throws {
        // Every public-suffix case above would pass with no list at all; this one cannot.
        try #require(RelyingPartyPolicy.registrableDomain(of: "www.example.co.uk") == "example.co.uk")
        #expect(SiteCookies.applies(domain: domain, to: host) == applies)
    }

    @Test func aPagesHostIsComparedWithoutCaseTrailingDotOrBrackets() throws {
        #expect(SiteCookies.host(of: try #require(URL(string: "https://App.Example.com./path"))) == "app.example.com")
        #expect(SiteCookies.host(of: try #require(URL(string: "http://[::1]:8080/"))) == "::1")
        #expect(SiteCookies.host(of: try #require(URL(string: "about:blank"))) == nil)
    }

    // MARK: Chromium's answer

    @Test func aChromiumCookieIsReadAndNamedExactlyForDeletion() throws {
        let partitioned = try #require(SiteCookies.chromiumCookie([
            "name": "sid", "value": "secret", "domain": ".example.com", "path": "/app", "expires": 1_900_000_000.0,
            "session": false, "secure": true, "httpOnly": true, "sameSite": "None",
            "partitionKey": ["topLevelSite": "https://top.test", "hasCrossSiteAncestor": false],
        ]))
        #expect(partitioned.engine == .chromium)
        #expect(partitioned.expiresDate == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(partitioned.isSecure && partitioned.isHTTPOnly && partitioned.sameSite == "None")
        #expect(partitioned.partitionKey == "https://top.test")
        let params = SiteCookies.deleteParameters(for: partitioned)
        #expect(params["name"] as? String == "sid" && params["domain"] as? String == ".example.com")
        #expect(params["path"] as? String == "/app")
        let key = try #require(params["partitionKey"] as? [String: Any])
        #expect(key["topLevelSite"] as? String == "https://top.test" && key["hasCrossSiteAncestor"] as? Bool == false)

        let session = try #require(SiteCookies.chromiumCookie([
            "name": "s", "value": "v", "domain": "host.test", "path": "/", "expires": -1, "session": true,
        ]))
        #expect(session.expiresDate == nil && session.partitionKey == nil)
        #expect(SiteCookies.deleteParameters(for: session)["partitionKey"] == nil)
    }

    /// The value is for the inspector and Copy Value: a cookie written into a log or an error leaves it out.
    @Test func aCookiesDescriptionLeavesItsValueOut() {
        let cookie = SiteCookie(
            name: "sid", value: "top-secret-value", domain: ".example.com", path: "/", expiresDate: nil,
            isSecure: true, isHTTPOnly: true, sameSite: nil, engine: .webKit
        )
        #expect(!String(describing: cookie).contains("top-secret-value"))
        #expect(!String(reflecting: cookie).contains("top-secret-value"))
        #expect(!"\(cookie)".contains("top-secret-value"))
    }

    // MARK: WebKit

    private func cookie(_ name: String, domain: String, path: String = "/") throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name, .value: "value-\(name)", .domain: domain, .path: path,
            .expires: Date().addingTimeInterval(3600),
        ]))
    }

    private func set(_ cookies: [HTTPCookie], in context: BrowserProfileContext) async {
        for cookie in cookies {
            await context.dataStore.httpCookieStore.setCookie(cookie)
        }
    }

    private func names(_ host: String, in context: BrowserProfileContext) async -> [String] {
        await SiteCookies.list(host: host, context: context).cookies.map(\.name).sorted()
    }

    @Test(arguments: [false, true])
    func webKitCookiesAreListedAndDeletedForTheSiteOnly(isPrivate: Bool) async throws {
        let profile = isPrivate ? Profile.privateBrowsing() : Profile(id: UUID(), name: "Cookies", symbol: "person", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        await set([
            try cookie("host", domain: "app.example.com"),
            try cookie("parent", domain: ".example.com"),
            try cookie("sibling", domain: "other.example.com"),
            try cookie("lookalike", domain: ".notexample.com"),
        ], in: context)

        let listing = await SiteCookies.list(host: "app.example.com", context: context)
        #expect(listing.cookies.map(\.name).sorted() == ["host", "parent"])
        #expect(listing.cookies.allSatisfy { $0.engine == .webKit })
        #expect(!listing.chromiumUnavailable)

        let host = try #require(listing.cookies.first { $0.name == "host" })
        try await SiteCookies.delete(host, context: context)
        #expect(await names("app.example.com", in: context) == ["parent"])

        await set([try cookie("again", domain: "app.example.com")], in: context)
        #expect(try await SiteCookies.deleteAll(host: "app.example.com", context: context) == 2)
        #expect(await names("app.example.com", in: context).isEmpty)
        let left = await context.dataStore.httpCookieStore.allCookies().map(\.name).sorted()
        #expect(left == ["lookalike", "sibling"])

        if isPrivate {
            await context.endPrivateSession()
        } else {
            await Profile.erase(profile)
        }
    }

    /// A private window has its own cookie jar: what it sets is not in the regular profile's list, nor the other way round.
    @Test func privateAndRegularCookiesStayApart() async throws {
        let profile = Profile(id: UUID(), name: "Cookies", symbol: "person", color: .gray)
        let regular = BrowserProfileContext(profile: profile)
        let privateContext = BrowserProfileContext(profile: .privateBrowsing())
        await set([try cookie("regular", domain: "example.com")], in: regular)
        await set([try cookie("private", domain: "example.com")], in: privateContext)

        #expect(await names("example.com", in: regular) == ["regular"])
        #expect(await names("example.com", in: privateContext) == ["private"])
        try await SiteCookies.deleteAll(host: "example.com", context: privateContext)
        #expect(await names("example.com", in: regular) == ["regular"])

        await privateContext.endPrivateSession()
        await Profile.erase(profile)
    }

    // MARK: Chromium

    /// A profile that never used Chromium is answered from WebKit alone: Chromium is not started and no context is made for it.
    @Test func aProfileWithoutChromiumDataDoesNotStartChromium() async throws {
        let profile = Profile(id: UUID(), name: "Cookies", symbol: "person", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let calls = runtime.ensureInitializedCalls

        let listing = await SiteCookies.list(host: "example.com", context: context)
        #expect(try await SiteCookies.deleteAll(host: "example.com", context: context) == 0)

        #expect(listing.cookies.isEmpty && !listing.chromiumUnavailable)
        #expect(runtime.ensureInitializedCalls == calls)
        #expect(!runtime.hasContext(contextID: context.contextID))
        await Profile.erase(profile)
    }

    /// Opening Website Settings lists without starting Chromium: starting it blocks the main thread while CEF loads. Only an
    /// open tab, a running Chromium, or an explicit Load or Delete reaches its cookies.
    @Test func whenChromiumIsAskedForItsCookies() {
        func access(live: Bool = false, holds: Bool = true, oop: Bool = false, started: Bool = false, allow: Bool = false)
            -> SiteCookies.ChromiumAccess {
            SiteCookies.chromiumAccess(
                hasLivePage: live, mayHoldCookies: holds, isOutOfProcess: oop, hasStarted: started, allowStartup: allow)
        }
        #expect(access() == .notLoaded)
        #expect(access(allow: true) == .available)
        #expect(access(started: true) == .available)
        #expect(access(live: true) == .available)
        #expect(access(live: true, oop: true) == .available)
        #expect(access(holds: false) == .none)
        #expect(access(holds: false, allow: true) == .none)
        #expect(access(oop: true, allow: true) == .unreachable)
        #expect(access(oop: true, started: true) == .unreachable)
    }

    /// A profile with a Chromium disk profile: the passive listing reports Chromium as not loaded instead of starting it, and an
    /// explicit load or Delete Cookies reaches it.
    @Test(.boundedWebViews)
    func aChromiumDiskProfileIsListedPassivelyWithoutStartingChromium() async throws {
        let profile = Profile(id: UUID(), name: "Cookies", symbol: "person", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        try FileManager.default.createDirectory(at: runtime.cacheDirectory(profileID: profile.id), withIntermediateDirectories: true)
        let wasStarted = runtime.hasStartedChromium
        let calls = runtime.ensureInitializedCalls

        let passive = await SiteCookies.list(host: "example.test", context: context)

        if wasStarted {
            #expect(!passive.chromiumNotLoaded, "a running Chromium is asked")
        } else {
            #expect(passive.chromiumNotLoaded)
            #expect(runtime.ensureInitializedCalls == calls)
            #expect(!runtime.hasContext(contextID: context.contextID))
        }
        let loaded = await SiteCookies.list(host: "example.test", context: context, allowChromiumStartup: true)
        #expect(!loaded.chromiumNotLoaded && !loaded.chromiumUnavailable)
        #expect(runtime.hasContext(contextID: context.contextID))
        #expect(try await SiteCookies.deleteAll(host: "example.test", context: context) == 0)

        await runtime.releaseContext(contextID: context.contextID)
        try await runtime.erase(profile: profile)
        await Profile.erase(profile)
    }

    @Test(.boundedWebViews)
    func chromiumCookiesAreListedAndDeletedForTheSiteOnly() async throws {
        let profile = Profile(id: UUID(), name: "Cookies", symbol: "person", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        try runtime.ensureInitialized()
        let expires = Date().timeIntervalSince1970 + 3600
        for (name, target) in [
            ("host", ["url": "https://app.example.test/"]),
            ("parent", ["domain": ".example.test", "path": "/"]),
            ("lookalike", ["url": "https://notexample.test/"]),
            ("other", ["url": "https://other.test/"]),
        ] {
            var params: [String: Any] = ["name": name, "value": "value-\(name)", "expires": expires, "secure": true]
            params.merge(target) { $1 }
            _ = try await runtime.command(context: context, method: "Network.setCookie", params: params)
        }
        // A WebKit cookie of the same site is listed beside them.
        await set([try cookie("webkit", domain: "app.example.test")], in: context)

        let listing = await SiteCookies.list(host: "app.example.test", context: context)
        #expect(listing.cookies.map(\.name).sorted() == ["host", "parent", "webkit"])
        let chromium = listing.cookies.filter { $0.engine == .chromium }
        #expect(chromium.count == 2 && chromium.allSatisfy(\.isSecure))
        #expect(chromium.first { $0.name == "host" }?.domain == "app.example.test")
        #expect(chromium.first { $0.name == "parent" }?.domain == ".example.test")

        try await SiteCookies.delete(try #require(chromium.first { $0.name == "host" }), context: context)
        #expect(await names("app.example.test", in: context) == ["parent", "webkit"])

        #expect(try await SiteCookies.deleteAll(host: "app.example.test", context: context) == 2)
        #expect(await names("app.example.test", in: context).isEmpty)
        let all = try await runtime.command(context: context, method: "Network.getAllCookies")
        let left = ((all["cookies"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
        #expect(left == ["lookalike", "other"])

        await runtime.releaseContext(contextID: context.contextID)
        try await runtime.erase(profile: profile)
        await Profile.erase(profile)
    }

    // MARK: Favicons

    /// Deleting a website's cookies clears its icon from the open tabs on that host at once; a tab of another host keeps its own.
    @Test func clearingAHostsFaviconClearsItsOpenTabs() async throws {
        let profile = Profile(id: UUID(), name: "Cookies", symbol: "person", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let browser = BrowserModel(context: context, database: .temporary())
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let onSite = BrowserTab(restoring: true, context: context)
        onSite.urlString = "https://Example.com/inbox"
        onSite.favicon = icon
        let elsewhere = BrowserTab(restoring: true, context: context)
        elsewhere.urlString = "https://other.com/"
        elsewhere.favicon = icon
        let trailingDot = BrowserTab(restoring: true, context: context)
        trailingDot.urlString = "https://example.com./"
        trailingDot.favicon = icon
        browser.tabs = [onSite, elsewhere, trailingDot]

        try await SiteCookies.deleteAll(host: "example.com", context: context)

        #expect(onSite.favicon == nil)
        #expect(trailingDot.favicon == nil)
        #expect(elsewhere.favicon === icon)
        browser.tabs = []
        await Profile.erase(profile)
    }
}
