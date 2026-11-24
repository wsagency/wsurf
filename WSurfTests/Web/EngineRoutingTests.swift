// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Google refuses sign-in from embedded Chromium, so its sign-in runs in WebKit, and the redirect chain after it stays
/// there instead of bouncing between engines.
@MainActor
struct EngineRoutingTests {
    private func temporaryPermissions() -> SitePermissions {
        SitePermissions(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineRouting-\(UUID().uuidString).json"))
    }

    @Test func googleSignInKeepsTheRedirectBackInWebKit() throws {
        let permissions = temporaryPermissions()
        permissions.setEngine(.chromium, for: "https://mail.google.com")
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let mail = try #require(URL(string: "https://mail.google.com/mail/u/0/"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmail.google.com%2Fmail%2F"))
        let tab = browser.makeTab(for: signIn)
        #expect(tab.preferredEngine(for: mail) == .chromium)
        #expect(tab.preferredEngine(for: signIn) == .webKit)
        // The sign-in page is WebKit's own, so the tab stays where it is.
        #expect(tab.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        // The redirect back to the service is not reissued in Chromium, which has no sign-in and would send it back.
        #expect(tab.permitsEngineNavigation(URLRequest(url: mail), isMainFrame: true))
        #expect(tab.preferredEngine(for: mail) == .webKit)
        // A navigation the user starts follows the website's setting again.
        tab.noteNavigation(to: mail, startedByUser: true)
        #expect(tab.preferredEngine(for: mail) == .chromium)
    }

    @Test(.boundedWebViews, arguments: ["POST", "GET with body", "GET with stream"])
    func aSubmittedSignInKeepsEveryAutomaticCallbackInChromium(kind: String) throws {
        let first = try #require(URL(string: "https://source.example"))
        let google = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let callback = try #require(URL(string: "https://auth.openai.com/api/accounts/callback/google"))
        let service = try #require(URL(string: "https://service.example/signed-in"))
        let permissions = temporaryPermissions()
        permissions.setEngine(.chromium, for: first.absoluteString)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.makeTab(for: first)
        browser.tabs.append(tab)
        tab.urlString = first.absoluteString
        try #require(tab.page.engine == .chromium)
        var request = URLRequest(url: google)
        request.httpMethod = kind == "POST" ? "POST" : "GET"
        if kind == "GET with body" {
            request.httpBody = Data("fixture".utf8)
        } else if kind == "GET with stream" {
            request.httpBodyStream = InputStream(data: Data("fixture".utf8))
        }
        try #require(tab.permitsEngineNavigation(request, isMainFrame: true))
        #expect(tab.permitsEngineNavigation(URLRequest(url: callback), isMainFrame: true))
        #expect(tab.permitsEngineNavigation(URLRequest(url: service), isMainFrame: true))
        // The person may choose a provider or its return link while completing this same sign-in.
        #expect(tab.permitsEngineNavigation(URLRequest(url: callback), isMainFrame: true, userLinkFrom: SitePermissions.origin(for: google)))
        #expect(tab.permitsEngineNavigation(URLRequest(url: service), isMainFrame: true, userLinkFrom: SitePermissions.origin(for: callback)))
        #expect(tab.preferredEngine(for: service) == .chromium)
        tab.noteNavigation(to: google, startedByUser: true)
        #expect(tab.preferredEngine(for: google) == .webKit)
    }

    @Test func sameWebsiteLinksSubframesAndSubmittedRequestsKeepTheSignIn() throws {
        let permissions = temporaryPermissions()
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let google = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let calendar = try #require(URL(string: "https://calendar.google.com/day"))
        let elsewhere = try #require(URL(string: "https://elsewhere.example/confirm"))
        let source = "https://mail.google.com"
        let tab = browser.makeTab(for: google)
        try #require(tab.permitsEngineNavigation(URLRequest(url: google), isMainFrame: true))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: calendar))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: elsewhere))
        #expect(tab.permitsEngineNavigation(URLRequest(url: calendar), isMainFrame: true, userLinkFrom: source))
        #expect(tab.permitsEngineNavigation(URLRequest(url: elsewhere), isMainFrame: false, userLinkFrom: source))
        var submission = URLRequest(url: elsewhere)
        submission.httpMethod = "POST"
        submission.httpBody = Data("confirm=1".utf8)
        #expect(tab.permitsEngineNavigation(submission, isMainFrame: true, userLinkFrom: source))
        #expect(tab.signInEngine == .webKit)
    }

    @Test(arguments: ["regular commit", "superseded", "provider redirect"])
    func publicNavigationCallbacksBindTheDepartureWhenTheActionHasNoNavigation(_ next: String) throws {
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.newTab()
        let home = try #require(URL(string: "https://mail.google.com/inbox"))
        let outside = try #require(URL(string: "https://outside.example/article"))
        let provider = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        try #require(tab.permitsEngineNavigation(URLRequest(url: provider), isMainFrame: true))
        let first = PageNavigation()
        try #require(tab.permitsEngineNavigation(URLRequest(url: outside), isMainFrame: true, userLinkFrom: SitePermissions.origin(for: home)))
        tab.navigationStarted(first, url: outside)
        if next == "provider redirect" {
            try #require(tab.permitsEngineNavigation(URLRequest(url: provider), isMainFrame: true, isRedirect: true))
        } else if next == "superseded" {
            let newer = PageNavigation()
            try #require(tab.permitsEngineNavigation(URLRequest(url: provider), isMainFrame: true, navigation: newer))
            tab.navigationStarted(newer, url: provider)
            tab.navigationFailed(first, error: URLError(.cancelled))
        }
        tab.navigationCommitted(first)
        #expect(tab.signInEngine == (next == "regular commit" ? nil : .webKit))
    }

    @Test(.boundedWebViews) func reopeningAnUnloadedFavoriteAtItsPinUsesThePinnedWebsitesEngine() async throws {
        let origin = "http://127.0.0.1:1"
        let pinned = try #require(URL(string: origin + "/calendar/u/0/r/week"))
        let returned = try #require(URL(string: pinned.absoluteString + "?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let permissions = temporaryPermissions()
        permissions.setEngine(.chromium, for: origin)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let favorite = browser.newTab()
        favorite.urlString = pinned.absoluteString
        browser.addFavorite(favorite)

        try #require(favorite.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(favorite.permitsEngineNavigation(URLRequest(url: returned), isMainFrame: true))
        favorite.urlString = returned.absoluteString
        try #require(favorite.loadedEngine == .webKit)
        try #require(browser.unload(favorite))
        try #require(favorite.isDeferred && favorite.urlString == pinned.absoluteString)

        browser.activate(favorite)
        _ = await favorite.waitForPendingNavigation()
        #expect(favorite.loadedEngine == .chromium, "the fresh load of the pinned address has its own engine choice")
    }

    @Test(.boundedWebViews, arguments: ["no state", "Chromium", "invalid WebKit"])
    func reopeningTheExactFavoriteWithoutNativeWebKitHistoryMakesAFreshVisit(saved: String) async throws {
        let origin = "http://127.0.0.1:1"
        let pinned = try #require(URL(string: origin + "/calendar/u/0/r/week?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let permissions = temporaryPermissions()
        permissions.setEngine(.chromium, for: origin)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let favorite = browser.newTab()
        favorite.urlString = pinned.absoluteString
        browser.addFavorite(favorite)
        try #require(favorite.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(favorite.permitsEngineNavigation(URLRequest(url: pinned), isMainFrame: true))
        try #require(browser.unload(favorite))
        let state: Data? = switch saved {
        case "Chromium":
            Data(#"{"engine":"chromium","chromium":{"back":[],"forward":[]}}"#.utf8)
        case "invalid WebKit":
            Data(#"{"engine":"webkit","webKit":"AAECAw=="}"#.utf8)
        default:
            nil
        }
        favorite.deferRestore(state: state, url: pinned)
        try #require(favorite.isShowingPin)

        browser.activate(favorite)
        _ = await favorite.waitForPendingNavigation()
        #expect(favorite.loadedEngine == .chromium)
    }

    @Test(.boundedWebViews) func aFavoriteRestoredAtLaunchUsesTheSavedWebsiteEngine() throws {
        let origin = "http://127.0.0.1:1"
        let database = AppDatabase.temporary()
        let permissions = temporaryPermissions()
        let first = BrowserModel(database: database, sitePermissions: permissions)
        let favorite = first.newTab()
        favorite.urlString = origin + "/calendar/u/0/r/week?pli=1"
        first.addFavorite(favorite)
        first.closeAllTabs()
        permissions.setEngine(.chromium, for: origin)

        let reopened = BrowserModel(database: database, sitePermissions: permissions)
        defer { reopened.closeAllTabs(saving: false) }
        reopened.restoreSession()
        let restored = try #require(reopened.favorites.first)
        #expect(restored.id == favorite.id)
        #expect(restored.loadedEngine == .chromium)
    }

    @Test(arguments: ["https://accounts.google.com", "https://auth.openai.com"])
    func websiteSettingsKeepSignInInWebKit(signIn: String) async {
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        #expect(await browser.setEngine(.chromium, for: signIn) == false)
        #expect(await browser.setEngine(.webKit, for: signIn))
        #expect(browser.sitePermissions.engine(for: signIn) == .webKit)
        #expect(!browser.sitePermissions.engineOrigins.contains(signIn))
    }

    @Test func openAISignInStartsInWebKitWithAStoredChromiumChoice() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAISignIn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("""
            {"engines":{"https://auth.openai.com":"chromium","https://chatgpt.com":"chromium"}}
            """.utf8).write(to: file)
        let permissions = SitePermissions(storageURL: file)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let start = try #require(URL(string: "https://auth.openai.com/authorize?state=fixture"))
        let google = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth"))
        let callback = try #require(URL(string: "https://auth.openai.com/api/accounts/callback/google?code=fixture"))
        let chatGPT = try #require(URL(string: "https://chatgpt.com/"))
        let tab = browser.makeTab(for: start)
        #expect(permissions.engine(for: "https://auth.openai.com") == .webKit)
        #expect(tab.preferredEngine(for: chatGPT) == .chromium)

        tab.noteNavigation(to: start, startedByUser: true)
        try #require(tab.preferredEngine(for: start) == .webKit, "Keep the session set before going to Google in WebKit")
        #expect(tab.permitsEngineNavigation(URLRequest(url: google), isMainFrame: true))
        #expect(tab.permitsEngineNavigation(URLRequest(url: callback), isMainFrame: true))
        #expect(tab.permitsEngineNavigation(URLRequest(url: chatGPT), isMainFrame: true))
        #expect(tab.preferredEngine(for: chatGPT) == .webKit)

        tab.noteNavigation(to: chatGPT, startedByUser: true)
        #expect(tab.preferredEngine(for: chatGPT) == .chromium)
    }

    /// Tabs that only hold an address, so a switch changes what each is set to run without loading a page.
    /// Each test has a website of its own: tabs of every window in the profile's shared context count as its tabs.
    private func browserWithTwoTabs(site: String) throws -> (BrowserModel, BrowserTab, BrowserTab) {
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        let a = browser.makeTab(for: nil)
        let b = browser.makeTab(for: nil)
        for tab in [a, b] {
            tab.urlString = "\(site)/page"
            browser.tabs.append(tab)
        }
        return (browser, a, b)
    }

    @Test func switchingOneTabLeavesTheOtherTabOfTheSiteOnItsEngine() async throws {
        let site = "https://switch-\(UUID().uuidString.prefix(8).lowercased()).example"
        let (browser, a, b) = try browserWithTwoTabs(site: site)
        let inSite = try #require(URL(string: "\(site)/other"))
        #expect(await browser.setEngine(.chromium, for: a))
        #expect(browser.sitePermissions.engine(for: site) == .webKit, "switching this tab does not choose a website default")
        #expect(browser.engine(for: a) == .chromium)
        #expect(browser.engine(for: b) == .webKit)
        #expect(b.preferredEngine(for: inSite) == .webKit, "and it keeps it when it navigates within the site")
        await browser.applyStoredEngine(to: site)
        #expect(b.preferredEngine(for: inSite) == .webKit)
        // A tab opened afterwards follows the setting.
        let c = browser.makeTab(for: nil)
        #expect(c.preferredEngine(for: inSite) == .webKit)
        // The pin is for this website; another one follows its own setting.
        #expect(a.preferredEngine(for: try #require(URL(string: "https://other.example/"))) == .webKit)
        // Choosing the engine on the pinned tab moves it and no one else.
        #expect(await browser.setEngine(.chromium, for: b))
        #expect(b.preferredEngine(for: inSite) == .chromium)
    }

    @Test func aNewAddressInAnotherEngineDoesNotAskToSwitch() async throws {
        let site = "https://typed-\(UUID().uuidString.prefix(8).lowercased()).example"
        let (browser, a, _) = try browserWithTwoTabs(site: site)
        #expect(await browser.setEngine(.chromium, for: a))
        // A prompt would block on a modal alert here; the load must go straight through.
        a.isPlayingAudio = true
        let elsewhere = try #require(URL(string: "https://other-\(UUID().uuidString.prefix(8).lowercased()).example/search?q=x"))
        a.load(elsewhere)
        _ = await a.waitForPendingNavigation()
        #expect(browser.engine(for: a) == .webKit)
    }

    @Test(arguments: [false, true])
    func backAcrossEnginesDoesNotAskToSwitch(signInInProgress: Bool) async throws {
        let site = "https://back-\(UUID().uuidString.prefix(8).lowercased()).example"
        let (browser, a, _) = try browserWithTwoTabs(site: site)
        #expect(await browser.setEngine(.chromium, for: a))
        let elsewhere = try #require(URL(string: "https://other-\(UUID().uuidString.prefix(8).lowercased()).example/"))
        a.load(elsewhere)
        _ = await a.waitForPendingNavigation()
        #expect(browser.engine(for: a) == .webKit)
        // Nothing commits in a test, so name the page the load left, as a committed one would be.
        a.pageBeforeEngineSwitch = (url: try #require(URL(string: site)), state: nil)
        if signInInProgress {
            let signIn = try #require(URL(string: "https://auth.openai.com/authorize"))
            a.noteNavigation(to: signIn, startedByUser: false)
        }
        // A prompt would block on a modal alert here; Back must go straight to the page it left.
        a.isPlayingAudio = true
        a.goBack()
        _ = await a.waitForPendingNavigation()
        #expect(a.engine == .chromium)
        #expect(a.signInEngine == nil)
    }

    @Test func aComparisonTabSwitchesOnlyItself() async throws {
        let site = "https://compare-\(UUID().uuidString.prefix(8).lowercased()).example"
        let (browser, origin, comparison) = try browserWithTwoTabs(site: site)
        comparison.engineOverride = .chromium
        #expect(await browser.setEngine(.webKit, for: comparison))
        #expect(comparison.engineOverride == .webKit)
        #expect(browser.sitePermissions.engine(for: site) == .webKit, "the setting is not written")
        #expect(origin.pinnedEngine == nil && origin.engineOverride == nil)
        let inSite = try #require(URL(string: "\(site)/other"))
        browser.sitePermissions.setEngine(.chromium, for: site)
        #expect(comparison.preferredEngine(for: inSite) == .webKit)
        #expect(origin.preferredEngine(for: inSite) == .chromium, "the origin tab was never touched")
    }

    @Test func savingADefaultOnlyClearsPinsForThatOriginEvenWhileAnotherSiteIsShowing() async throws {
        let original = "https://one.example"
        let other = "https://two.example"
        let (browser, tab, _) = try browserWithTwoTabs(site: original)
        #expect(await browser.setEngine(.chromium, for: tab))
        tab.urlString = other + "/article"
        #expect(await browser.setEngine(.webKit, for: other))
        #expect(tab.preferredEngine(for: URL(string: original)) == .chromium)
        #expect(await browser.setEngine(.chromium, for: tab))
        tab.urlString = original
        #expect(await browser.setEngine(.webKit, for: other))
        #expect(tab.preferredEngine(for: URL(string: other)) == .webKit)
    }

    @Test func savingTheWebsiteDefaultLeavesAnotherTabsSignInReturnInWebKit() async throws {
        let site = "http://127.0.0.1:1"
        let (browser, tab, _) = try browserWithTwoTabs(site: site)
        defer { browser.closeAllTabs(saving: false) }
        let heldPage = tab.page
        browser.sitePermissions.setEngine(.chromium, for: site)
        tab.noteNavigation(to: try #require(URL(string: "https://accounts.google.com/")), startedByUser: false)
        tab.noteNavigation(to: try #require(URL(string: tab.urlString)), startedByUser: false)
        #expect(await browser.setEngine(.chromium, for: site))
        #expect(tab.liveView === heldPage)
        #expect(tab.loadedEngine == .webKit)
    }

    @Test func websiteSettingsStillMoveEveryTabOfTheSite() async throws {
        let site = "https://default-\(UUID().uuidString.prefix(8).lowercased()).example"
        let (browser, a, b) = try browserWithTwoTabs(site: site)
        #expect(await browser.setEngine(.chromium, for: a))
        #expect(a.preferredEngine(for: URL(string: site)) == .chromium)
        // Explicitly choosing the existing default must also clear local tab choices.
        #expect(await browser.setEngine(.webKit, for: site))
        #expect(a.pinnedEngine == nil && b.pinnedEngine == nil)
        #expect(a.preferredEngine(for: try #require(URL(string: site))) == .webKit)
        #expect(await browser.setEngine(.chromium, for: site))
        #expect(b.preferredEngine(for: URL(string: site)) == .chromium)
        let fresh = browser.makeTab(for: nil)
        #expect(fresh.preferredEngine(for: URL(string: site + "/org/repo/issues?q=open")) == .chromium)
        #expect(fresh.preferredEngine(for: URL(string: "https://other.example/org/repo/issues?q=open")) == .webKit)
    }

    private final class StubNewWindowAction: WKNavigationAction {
        nonisolated(unsafe) var stubbedRequest = URLRequest(url: URL(string: "about:blank")!)

        override var request: URLRequest {
            stubbedRequest
        }

        override var modifierFlags: NSEvent.ModifierFlags {
            []
        }

        override nonisolated func value(forKey key: String) -> Any? {
            key == "_isUserInitiated" ? true : super.value(forKey: key)
        }
    }

    private func openPopup(from tab: BrowserTab, to url: URL) throws -> BrowserTab {
        let webView = try #require(tab.page.webKit)
        let delegate = try #require(tab.navigationDelegate)
        let action = StubNewWindowAction()
        action.stubbedRequest = URLRequest(url: url)
        let created = try #require(delegate.webView(
            webView, createWebViewWith: WebViewPool.makeConfiguration(), for: action, windowFeatures: WKWindowFeatures()
        ))
        return try #require((created.navigationDelegate as? TabNavigationDelegate)?.tab)
    }

    @Test(.boundedWebViews, arguments: ["newWindow", "openInNewTab"])
    func openingGoogleMeetFromSignedInCalendarKeepsWebKit(via: String) throws {
        let permissions = temporaryPermissions()
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/week?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1&hs=122&ijlm=1795513003548"))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: calendar))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: meet))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let calendarTab = browser.newTab()
        calendarTab.urlString = calendar.absoluteString
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: calendar), isMainFrame: true))
        try #require(calendarTab.signInEngine == .webKit && calendarTab.loadedEngine == .webKit)

        let opened: BrowserTab
        if via == "newWindow" {
            opened = try openPopup(from: calendarTab, to: meet)
            #expect(opened.permitsEngineNavigation(URLRequest(url: meet), isMainFrame: true))
        } else {
            calendarTab.onOpenInNewTab?(meet, true)
            opened = try #require(browser.tabs.first { $0 !== calendarTab })
            #expect(opened.permitsEngineNavigation(URLRequest(url: meet), isMainFrame: true))
        }
        #expect(opened.signInEngine == .webKit)
        #expect(opened.loadedEngine == .webKit)
        #expect(opened.preferredEngine(for: meet) == .webKit)
    }

    @Test(.boundedWebViews, arguments: ["newWindow", "openInNewTab"])
    func openingAnExternalLinkInANewTabFromSignedInCalendarUsesItsChromiumSetting(via: String) async throws {
        let permissions = temporaryPermissions()
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/week?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let external = try #require(URL(string: "https://example.com/article"))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: external))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let calendarTab = browser.newTab()
        calendarTab.urlString = calendar.absoluteString
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: calendar), isMainFrame: true))
        try #require(calendarTab.signInEngine == .webKit)

        let opened: BrowserTab
        if via == "newWindow" {
            opened = try openPopup(from: calendarTab, to: external)
            #expect(opened.signInEngine == nil)
            #expect(opened.pendingOpenerSignIn == nil)
            #expect(opened.preferredEngine(for: external) == .chromium)
            #expect(!opened.permitsEngineNavigation(URLRequest(url: external), isMainFrame: true))
            _ = await opened.waitForPendingNavigation()
        } else {
            calendarTab.onOpenInNewTab?(external, true)
            opened = try #require(browser.tabs.first { $0 !== calendarTab })
            _ = await opened.waitForPendingNavigation()
        }
        #expect(opened.signInEngine == nil)
        #expect(opened.loadedEngine == .chromium)
    }

    @Test(.boundedWebViews, arguments: ["sameSite", "externalChromium", "externalWebKit"])
    func aboutBlankPopupFromSignedInCalendarResolvesOnItsFirstHTTPDestination(destination: String) async throws {
        let permissions = temporaryPermissions()
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/week?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let aboutBlank = try #require(URL(string: "about:blank"))
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1&hs=122&ijlm=1795513003548"))
        let external = try #require(URL(string: "https://example.com/article"))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: meet))
        if destination == "externalChromium" {
            permissions.setEngine(.chromium, for: SitePermissions.origin(for: external))
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }
        let calendarTab = browser.newTab()
        calendarTab.urlString = calendar.absoluteString
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: calendar), isMainFrame: true))

        let opened = try openPopup(from: calendarTab, to: aboutBlank)
        #expect(opened.signInEngine == nil)
        #expect(opened.pendingOpenerSignIn != nil)
        #expect(opened.permitsEngineNavigation(URLRequest(url: aboutBlank), isMainFrame: true))
        #expect(opened.permitsEngineNavigation(URLRequest(url: external), isMainFrame: false))
        #expect(opened.pendingOpenerSignIn != nil, "about:blank and subframes do not consume the deferred opener sign-in")

        switch destination {
        case "sameSite":
            #expect(opened.permitsEngineNavigation(URLRequest(url: meet), isMainFrame: true))
            #expect(opened.signInEngine == .webKit)
            #expect(opened.pendingOpenerSignIn == nil)
            #expect(opened.loadedEngine == .webKit)
        case "externalChromium":
            #expect(!opened.permitsEngineNavigation(URLRequest(url: external), isMainFrame: true))
            _ = await opened.waitForPendingNavigation()
            #expect(opened.signInEngine == nil)
            #expect(opened.pendingOpenerSignIn == nil)
            #expect(opened.loadedEngine == .chromium)
        default:
            #expect(opened.permitsEngineNavigation(URLRequest(url: external), isMainFrame: true))
            #expect(opened.signInEngine == nil)
            #expect(opened.pendingOpenerSignIn == nil)
            #expect(opened.loadedEngine == .webKit)
        }
    }

    @Test(.boundedWebViews, arguments: ["newWindow", "openInNewTab", "peek"])
    func openingGoogleMeetFromWebKitCalendarWithoutActiveSignInChainKeepsWebKit(via: String) async throws {
        let permissions = temporaryPermissions()
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/week?pli=1"))
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1&hs=122&ijlm=1795513003548"))
        let external = try #require(URL(string: "https://example.com/article"))
        let appExample = try #require(URL(string: "https://app.example/calendar"))
        let meetExample = try #require(URL(string: "https://meet.example/room"))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: meet))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: external))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: meetExample))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }

        let calendarTab = browser.newTab()
        calendarTab.urlString = calendar.absoluteString
        try #require(calendarTab.signInEngine == nil && calendarTab.loadedEngine == .webKit)

        let opened: BrowserTab
        switch via {
        case "newWindow":
            opened = try openPopup(from: calendarTab, to: meet)
            #expect(opened.permitsEngineNavigation(URLRequest(url: meet), isMainFrame: true))
        case "peek":
            opened = browser.makePeekTab(meet, from: calendarTab)
        default:
            calendarTab.onOpenInNewTab?(meet, true)
            opened = try #require(browser.tabs.first { $0 !== calendarTab })
        }
        defer {
            if via == "peek" {
                opened.detach()
            }
        }
        #expect(opened.signInEngine == .webKit)
        #expect(opened.loadedEngine == .webKit)

        calendarTab.onOpenInNewTab?(external, false)
        let externalTab = try #require(browser.tabs.first { $0.urlString == external.absoluteString })
        _ = await externalTab.waitForPendingNavigation()
        #expect(externalTab.signInEngine == nil)
        #expect(externalTab.loadedEngine == .chromium)

        // Ordinary websites without WebKit-only sign-in continue to respect per-origin Chromium settings.
        let ordinaryTab = browser.newTab()
        ordinaryTab.urlString = appExample.absoluteString
        try #require(ordinaryTab.signInEngine == nil && ordinaryTab.loadedEngine == .webKit)
        ordinaryTab.onOpenInNewTab?(meetExample, false)
        let ordinaryOpened = try #require(browser.tabs.first { $0.urlString == meetExample.absoluteString })
        _ = await ordinaryOpened.waitForPendingNavigation()
        #expect(ordinaryOpened.signInEngine == nil)
        #expect(ordinaryOpened.loadedEngine == .chromium)
    }

    @Test(.boundedWebViews) func leavingAnInheritedGoogleMeetTabToAnExternalSiteClearsSignInOnCommit() throws {
        let permissions = temporaryPermissions()
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/week?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1&hs=122&ijlm=1795513003548"))
        let outside = try #require(URL(string: "https://outside.example/article"))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: meet))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }

        let calendarTab = browser.newTab()
        calendarTab.urlString = calendar.absoluteString
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: calendar), isMainFrame: true))
        calendarTab.onOpenInNewTab?(meet, true)
        let meetTab = try #require(browser.tabs.first { $0 !== calendarTab })
        try #require(meetTab.signInEngine == .webKit && meetTab.loadedEngine == .webKit)

        let departure = PageNavigation()
        try #require(meetTab.permitsEngineNavigation(URLRequest(url: outside), isMainFrame: true, userLinkFrom: SitePermissions.origin(for: meet)))
        meetTab.navigationStarted(departure, url: outside)
        #expect(meetTab.signInEngine == .webKit, "the sign-in stays active until the external document commits")
        meetTab.navigationCommitted(departure)
        #expect(meetTab.signInEngine == nil)
    }
}
