// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WebKit

@testable import WSurf

/// A sign-in that starts in Chromium and reaches a WebKit-only provider: the tab remembers the sites the flow came from, keeps
/// them in the sign-in until the person leaves it, and hands their Chromium cookies to WebKit within the same profile only.
@MainActor
@Suite(.serialized)
struct SignInHandoffTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryPermissions() -> SitePermissions {
        SitePermissions(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SignInHandoff-\(UUID().uuidString).json"))
    }

    // MARK: Chain

    @Test func theChainKeepsTheLastSixDistinctOriginsOfTheLastTwoMinutes() throws {
        let provider = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth"))
        var chain = SignInChain()
        for index in 0..<8 {
            chain.note("https://site\(index).example", engine: .chromium, now: start.addingTimeInterval(Double(index)))
        }
        // A site visited again moves to the end instead of taking a second place.
        chain.note("https://site3.example", engine: .chromium, now: start.addingTimeInterval(8))
        chain.note("https://accounts.google.com", engine: .webKit, now: start.addingTimeInterval(9))
        let now = start.addingTimeInterval(10)
        #expect(chain.origins(leadingTo: provider, now: now) == Set((2..<8).map { "https://site\($0).example" }))
        // Past the lifetime of each visit, it no longer belongs to the hop.
        let later = start.addingTimeInterval(SignInChain.lifetime + 7.5)
        #expect(chain.origins(leadingTo: provider, now: later) == ["https://site3.example"])
        #expect(chain.origins(leadingTo: provider, now: start.addingTimeInterval(SignInChain.lifetime + 9)).isEmpty)
    }

    @Test func onlyTheVisitsChromiumServedMoveTheirCookies() throws {
        let provider = try #require(URL(string:
            "https://accounts.google.com/o/oauth2/auth?redirect_uri=https%3A%2F%2Fsso.company.io%2Fcallback&state=x"))
        var chain = SignInChain()
        chain.note("https://app.example.com", engine: .webKit, now: start)
        chain.note("https://sso.company.io", engine: .chromium, now: start)
        #expect(chain.origins(leadingTo: provider, now: start) == ["https://app.example.com", "https://sso.company.io"])
        #expect(chain.origins(leadingTo: provider, servedBy: .chromium, now: start) == ["https://sso.company.io"])
        // A callback the chain saw served by WebKit keeps its WebKit cookies.
        var webKitCallback = SignInChain()
        webKitCallback.note("https://sso.company.io", engine: .webKit, now: start)
        #expect(webKitCallback.origins(leadingTo: provider, servedBy: .chromium, now: start).isEmpty)
        // The page names `redirect_uri`: it keeps the sign-in going, but a site Chromium never served moves no cookies.
        let named = try #require(URL(string: "https://accounts.google.com/auth?redirect_uri=https%3A%2F%2Fbank.example%2Fcb"))
        #expect(SignInChain().origins(leadingTo: named, now: start) == ["https://bank.example"])
        #expect(SignInChain().origins(leadingTo: named, servedBy: .chromium, now: start).isEmpty)
    }

    @Test(arguments: [
        ("https://accounts.google.com/o/oauth2/auth?redirect_uri=https%3A%2F%2Fauth.wsagency.io%2Fsource%2Foauth%2Fcallback%2Fgoogle%2F",
         "https://auth.wsagency.io"),
        ("https://accounts.google.com/auth?redirect_uri=https://Auth.Example.com:8443/cb&state=1", "https://auth.example.com:8443"),
        ("https://accounts.google.com/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A9000%2Fcb", "http://127.0.0.1:9000"),
        ("https://accounts.google.com/auth?redirect_uri=com.example.app%3A%2Fcb", nil),
        ("https://accounts.google.com/auth?redirect_uri=javascript%3Aalert(1)", nil),
        ("https://accounts.google.com/auth?redirect_uri=", nil),
        ("https://accounts.google.com/auth?continue=https%3A%2F%2Fmail.google.com", nil),
    ] as [(String, String?)])
    func theRedirectURIOriginIsTakenOnlyFromAWebAddress(url: String, origin: String?) throws {
        #expect(SignInChain.redirectOrigin(in: try #require(URL(string: url))) == origin)
    }

    @Test func theProviderItselfIsNeverPartOfTheChain() throws {
        let provider = try #require(URL(string: "https://auth.openai.com/authorize?redirect_uri=https%3A%2F%2Faccounts.google.com%2Fx"))
        var chain = SignInChain()
        chain.note("https://accounts.google.com", engine: .chromium, now: start)
        chain.note("https://auth.openai.com", engine: .chromium, now: start)
        chain.note("", engine: .chromium, now: start)
        #expect(chain.isEmpty)
        #expect(chain.origins(leadingTo: provider, now: start).isEmpty)
    }

    // MARK: Continuity

    /// app.example.com -> sso.company.io -> provider -> sso.company.io -> app.example.com stays in WebKit, including the person's
    /// own link from the SSO page back to the app, and a link to an unrelated website still leaves the sign-in when it commits.
    @Test func aCrossDomainSSOReturnStaysInTheSignInUntilThePersonLeavesIt() throws {
        let app = try #require(URL(string: "https://app.example.com/auth/oidc"))
        let sso = try #require(URL(string: "https://sso.company.io/authorize"))
        let provider = try #require(URL(string:
            "https://accounts.google.com/o/oauth2/auth?redirect_uri=https%3A%2F%2Fsso.company.io%2Fcallback%2F&state=s"))
        let ssoCallback = try #require(URL(string: "https://sso.company.io/callback/?state=s&code=c"))
        let appCallback = try #require(URL(string: "https://app.example.com/auth/oidc.callback?code=d"))
        let outside = try #require(URL(string: "https://outside.example/article"))
        let permissions = temporaryPermissions()
        for site in [app, sso] {
            permissions.setEngine(.chromium, for: SitePermissions.origin(for: site))
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.makeTab(for: provider)
        tab.signInChain.note(SitePermissions.origin(for: app), engine: .chromium)
        tab.signInChain.note(SitePermissions.origin(for: sso), engine: .chromium)

        try #require(tab.permitsEngineNavigation(URLRequest(url: provider), isMainFrame: true))
        #expect(tab.signInEngine == .webKit)
        #expect(tab.signInChainOrigins == ["https://app.example.com", "https://sso.company.io"])
        #expect(tab.permitsEngineNavigation(URLRequest(url: ssoCallback), isMainFrame: true, isRedirect: true))
        #expect(tab.permitsEngineNavigation(
            URLRequest(url: appCallback), isMainFrame: true, userLinkFrom: SitePermissions.origin(for: ssoCallback)))
        #expect(tab.signInEngine == .webKit)
        #expect(tab.preferredEngine(for: appCallback) == .webKit)

        let departure = PageNavigation()
        #expect(tab.permitsEngineNavigation(URLRequest(url: outside), isMainFrame: true, userLinkFrom: SitePermissions.origin(for: app)))
        tab.navigationStarted(departure, url: outside)
        tab.navigationCommitted(departure)
        #expect(tab.signInEngine == nil)
        #expect(tab.signInChainOrigins.isEmpty)
    }

    /// Without the chain the same return link is a departure: the chain is what keeps it.
    @Test func withoutAChainTheSSOReturnLinkLeavesTheSignIn() throws {
        let provider = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth"))
        let appCallback = try #require(URL(string: "https://app.example.com/auth/oidc.callback"))
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.makeTab(for: provider)
        try #require(tab.permitsEngineNavigation(URLRequest(url: provider), isMainFrame: true))
        try #require(tab.signInChainOrigins.isEmpty)
        let departure = PageNavigation()
        #expect(tab.permitsEngineNavigation(URLRequest(url: appCallback), isMainFrame: true, userLinkFrom: "https://sso.company.io"))
        tab.navigationStarted(departure, url: appCallback)
        tab.navigationCommitted(departure)
        #expect(tab.signInEngine == nil)
    }

    @Test func anAddressThePersonOpensEndsTheChain() throws {
        let provider = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth"))
        let typed = try #require(URL(string: "https://elsewhere.example/"))
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.makeTab(for: provider)
        tab.signInChain.note("https://app.example.com", engine: .chromium)
        try #require(tab.permitsEngineNavigation(URLRequest(url: provider), isMainFrame: true))
        try #require(tab.signInChainOrigins == ["https://app.example.com"])
        tab.noteNavigation(to: typed, startedByUser: true)
        #expect(tab.signInEngine == nil)
        #expect(tab.signInChainOrigins.isEmpty)
        #expect(tab.signInChain.isEmpty)
        // Typing the provider's own address starts no flow from the earlier sites.
        tab.signInChain.note("https://app.example.com", engine: .chromium)
        let pasted = try #require(URL(string: "https://accounts.google.com/auth?redirect_uri=https%3A%2F%2Fapp.example.com%2Fcb"))
        tab.noteNavigation(to: pasted, startedByUser: true)
        #expect(tab.signInEngine == .webKit && tab.signInChainOrigins.isEmpty && tab.signInChain.isEmpty)
        #expect(tab.chromiumSignInHandoff(to: pasted, engine: .webKit) == nil)
    }

    // MARK: Cookies

    private func chromium(_ name: String, domain: String, extra: [String: Any] = [:]) throws -> SiteCookie {
        var object: [String: Any] = ["name": name, "value": "v-\(name)", "domain": domain, "path": "/", "expires": -1, "session": true]
        object.merge(extra) { $1 }
        return try #require(SiteCookies.chromiumCookie(object))
    }

    @Test func onlyTheFlowsOwnUnpartitionedCookiesAreHandedOff() throws {
        let cookies = [
            try chromium("csrf", domain: "docs.wsagency.io"),
            try chromium("session", domain: "auth.wsagency.io"),
            try chromium("parent", domain: ".wsagency.io"),
            try chromium("sibling", domain: "mail.wsagency.io"),
            try chromium("partitioned", domain: "auth.wsagency.io", extra: ["partitionKey": "https://docs.wsagency.io"]),
            try chromium("google", domain: ".google.com"),
            try chromium("gmail", domain: "mail.google.com"),
            try chromium("unrelated", domain: "news.example"),
        ]
        let origins: Set<String> = ["https://docs.wsagency.io", "https://auth.wsagency.io", "https://mail.google.com"]
        let names = SignInCookieHandoff.cookies(cookies, for: origins).map(\.name).sorted()
        // WebKit owns the sessions of the WebKit-only sites; Chromium's stale copy must not replace them.
        #expect(names == ["csrf", "parent", "session"])
    }

    /// Each attribute survives a real WebKit cookie store, from the DevTools `Network.Cookie` shape Chromium reports.
    @Test func everyAttributeSurvivesTheWebKitStore() async throws {
        let expires = (Date().timeIntervalSince1970 + 3600).rounded()
        let cookies = [
            try chromium("oauth_csrf", domain: "docs.wsagency.io", extra: ["httpOnly": true, "secure": true, "sameSite": "Lax"]),
            try chromium("authentik_session", domain: "auth.wsagency.io",
                         extra: ["httpOnly": true, "secure": true, "sameSite": "None", "path": "/flow", "expires": expires, "session": false]),
            try chromium("__Host-flow", domain: "auth.wsagency.io", extra: ["secure": true, "sameSite": "Strict"]),
            try chromium("unspecified", domain: ".wsagency.io"),
        ]
        // The cookie store does not keep its data store alive.
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        for cookie in cookies.compactMap(SignInCookieHandoff.httpCookie) {
            await store.setCookie(cookie)
        }
        let stored = Dictionary(uniqueKeysWithValues: await store.allCookies().map { ($0.name, $0) })
        let csrf = try #require(stored["oauth_csrf"])
        #expect(csrf.domain == "docs.wsagency.io" && csrf.path == "/" && csrf.value == "v-oauth_csrf")
        #expect(csrf.isHTTPOnly && csrf.isSecure && csrf.isSessionOnly && csrf.expiresDate == nil)
        #expect(csrf.sameSitePolicy == .sameSiteLax)
        let session = try #require(stored["authentik_session"])
        #expect(session.isHTTPOnly && session.isSecure && !session.isSessionOnly && session.path == "/flow")
        #expect(session.expiresDate?.timeIntervalSince1970.rounded() == expires)
        #expect(session.sameSitePolicy == nil, "SameSite=None is WebKit's unspecified policy")
        let host = try #require(stored["__Host-flow"])
        #expect(host.domain == "auth.wsagency.io" && host.path == "/" && host.isSecure && !host.isHTTPOnly)
        #expect(host.sameSitePolicy == .sameSiteStrict)
        let unspecified = try #require(stored["unspecified"])
        #expect(unspecified.domain == ".wsagency.io" && unspecified.sameSitePolicy == nil && !unspecified.isSecure)
        withExtendedLifetime(dataStore) {}
    }

    // MARK: Profiles

    /// A pop-up continues its opener's chain only in the opener's own profile, and only from a Chromium page.
    @Test(.boundedWebViews) func aPopupContinuesTheOpenersChainOnlyInItsProfile() async throws {
        let app = try #require(URL(string: "https://app.example.com/login"))
        let provider = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth"))
        let permissions = temporaryPermissions()
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: app))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let opener = browser.makeTab(for: app)
        browser.tabs.append(opener)
        opener.urlString = app.absoluteString
        try #require(opener.page.engine == .chromium)

        let sameProfile = browser.makeTab(for: provider)
        sameProfile.seedSignInChain(from: opener, for: provider)
        #expect(sameProfile.signInChain.origins(leadingTo: provider, servedBy: .chromium) == ["https://app.example.com"])

        let notProvider = browser.makeTab(for: app)
        notProvider.seedSignInChain(from: opener, for: app)
        #expect(notProvider.signInChain.isEmpty)

        let privateContext = BrowserProfileContext(profile: .privateBrowsing())
        let privateTab = BrowserTab(restoring: true, context: privateContext)
        privateTab.seedSignInChain(from: opener, for: provider)
        #expect(privateTab.signInChain.isEmpty)
        privateTab.detach()
        await privateContext.endPrivateSession()

        let webKitOpener = browser.makeTab(for: provider)
        webKitOpener.urlString = "https://webkit.example/"
        try #require(webKitOpener.page.engine == .webKit)
        let fromWebKit = browser.makeTab(for: provider)
        fromWebKit.seedSignInChain(from: webKitOpener, for: provider)
        #expect(fromWebKit.signInChain.isEmpty)
    }

    /// The real pop-up path: a Chromium page's `window.open` to the provider opens a WebKit tab that holds the opener's site in
    /// its sign-in, so the provider's callback to it stays there.
    @Test(.boundedWebViews) func aChromiumPopupToTheProviderContinuesTheOpenersFlow() async throws {
        let app = try #require(URL(string: "https://app.example.com/login"))
        let provider = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?state=1"))
        let permissions = temporaryPermissions()
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: app))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let opener = browser.makeTab(for: app)
        browser.tabs.append(opener)
        opener.urlString = app.absoluteString
        try #require(opener.page.engine == .chromium)

        #expect(opener.openChromiumPopup(provider, userGesture: true, sourceURL: app, sourceFrame: nil, click: .other) == nil)
        let popup = try #require(browser.tabs.first { $0 !== opener })
        _ = await popup.waitForPendingNavigation()
        #expect(popup.loadedEngine == .webKit)
        #expect(popup.signInEngine == .webKit)
        #expect(popup.signInChainOrigins == ["https://app.example.com"])
        #expect(popup.preferredEngine(for: app) == .webKit, "the callback to the opener's site stays in the sign-in")
    }

    /// The handoff reads only a Chromium page of the tab's own profile: a page of another profile, or of the regular profile for a
    /// private tab, hands nothing over, while the same page hands its cookie to its own profile.
    @Test(.boundedWebViews) func cookiesNeverCrossProfiles() async throws {
        // A hidden page needs in-process Chromium; the live handoff test covers the service.
        guard ChromiumOOP.latch.mode != .outOfProcess else { return }
        let runtime = ChromiumRuntime.shared
        try runtime.ensureInitialized()
        let source = Profile(id: UUID(), name: "Source", symbol: "person", color: .gray)
        let other = Profile(id: UUID(), name: "Other", symbol: "person", color: .gray)
        let sourceContext = BrowserProfileContext(profile: source)
        let otherContext = BrowserProfileContext(profile: other)
        let privateContext = BrowserProfileContext(profile: .privateBrowsing())
        let origins: Set<String> = ["https://app.example.test"]
        _ = try await runtime.command(context: sourceContext, method: "Network.setCookie", params: [
            "name": "flow", "value": "secret", "url": "https://app.example.test/", "httpOnly": true,
        ])
        try await runtime.withHiddenPage(context: sourceContext) { page in
            for target in [otherContext, privateContext] {
                #expect(await SignInCookieHandoff.copy(
                    origins: origins, context: target, preferring: page, into: target.dataStore.httpCookieStore) == 0)
                #expect(await target.dataStore.httpCookieStore.allCookies().isEmpty)
            }
            #expect(await SignInCookieHandoff.copy(
                origins: origins, context: sourceContext, preferring: page, into: sourceContext.dataStore.httpCookieStore) == 1)
        }
        let copied = await sourceContext.dataStore.httpCookieStore.allCookies()
        #expect(copied.map(\.name) == ["flow"] && copied.first?.isHTTPOnly == true)

        await privateContext.endPrivateSession()
        for (profile, context) in [(source, sourceContext), (other, otherContext)] {
            await runtime.releaseContext(contextID: context.contextID)
            try await runtime.erase(profile: profile)
            await Profile.erase(profile)
        }
    }
}
