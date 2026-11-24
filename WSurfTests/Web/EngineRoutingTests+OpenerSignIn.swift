// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

extension EngineRoutingTests {
    private func openSignedInCalendar(in browser: BrowserModel) throws -> BrowserTab {
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/week?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        let calendarTab = browser.newTab()
        calendarTab.urlString = calendar.absoluteString
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(calendarTab.permitsEngineNavigation(URLRequest(url: calendar), isMainFrame: true))
        try #require(calendarTab.signInEngine == .webKit)
        return calendarTab
    }

    private func openFromCalendar(
        _ calendarTab: BrowserTab,
        in browser: BrowserModel,
        to url: URL,
        via: String
    ) throws -> BrowserTab {
        switch via {
        case "newWindow":
            return try openPopup(from: calendarTab, to: url)
        case "peek":
            return browser.makePeekTab(url, from: calendarTab)
        default:
            calendarTab.onOpenInNewTab?(url, true)
            return try #require(browser.tabs.first { $0 !== calendarTab && $0.urlString == url.absoluteString })
        }
    }

    private func closeOpenedTab(_ tab: BrowserTab, in browser: BrowserModel, via: String) {
        if via == "peek" {
            browser.dismissPeekTab(tab)
        } else {
            browser.close(tab)
        }
    }

    @Test(.boundedWebViews) func agentMicroDefaultChromiumEngineComposesWithSignedInSameSiteTabs() async throws {
        let permissions = temporaryPermissions()
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1"))
        let external = try #require(URL(string: "https://example.com/article"))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        browser.windowKind = .micro
        browser.isEphemeralAgentWindow = true
        defer { browser.closeAllTabs(saving: false) }

        let calendarTab = try openSignedInCalendar(in: browser)
        try #require(calendarTab.defaultEngineOverride == .chromium)

        calendarTab.onOpenInNewTab?(meet, true)
        let meetTab = try #require(browser.tabs.first { $0.urlString == meet.absoluteString })
        #expect(meetTab.defaultEngineOverride == .chromium)
        #expect(meetTab.signInEngine == .webKit)
        #expect(meetTab.inheritedSignInOrigin == "https://meet.google.com")
        #expect(meetTab.loadedEngine == .webKit)

        calendarTab.onOpenInNewTab?(external, false)
        let externalTab = try #require(browser.tabs.first { $0.urlString == external.absoluteString })
        _ = await externalTab.waitForPendingNavigation()
        #expect(externalTab.defaultEngineOverride == .chromium)
        #expect(externalTab.signInEngine == nil)
        #expect(externalTab.inheritedSignInOrigin == nil)
        #expect(externalTab.loadedEngine == .chromium)

        let meetPeek = browser.makePeekTab(meet, from: calendarTab)
        defer { browser.dismissPeekTab(meetPeek) }
        #expect(meetPeek.defaultEngineOverride == .chromium)
        #expect(meetPeek.signInEngine == .webKit)
        #expect(meetPeek.inheritedSignInOrigin == "https://meet.google.com")
        #expect(meetPeek.loadedEngine == .webKit)

        let externalPeek = browser.makePeekTab(external, from: calendarTab)
        defer { browser.dismissPeekTab(externalPeek) }
        _ = await externalPeek.waitForPendingNavigation()
        #expect(externalPeek.defaultEngineOverride == .chromium)
        #expect(externalPeek.signInEngine == nil)
        #expect(externalPeek.inheritedSignInOrigin == nil)
        #expect(externalPeek.loadedEngine == .chromium)
    }

    @Test(.boundedWebViews, arguments: ["newWindow", "openInNewTab", "peek"])
    func chromiumDefaultRedirectorDoesNotLeakWebKitSignInInAgentMicroWindow(via: String) async throws {
        let permissions = temporaryPermissions()
        let redirector = try #require(URL(string: "https://www.google.com/url?q=https://example.com/"))
        let external = try #require(URL(string: "https://example.com/"))
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1"))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        browser.windowKind = .micro
        browser.isEphemeralAgentWindow = true
        defer { browser.closeAllTabs(saving: false) }

        let calendarTab = try openSignedInCalendar(in: browser)

        for isRedirect in [true, false] {
            let externalTab = try openFromCalendar(calendarTab, in: browser, to: redirector, via: via)
            #expect(externalTab.defaultEngineOverride == .chromium)
            #expect(externalTab.permitsEngineNavigation(URLRequest(url: redirector), isMainFrame: true))
            #expect(externalTab.signInEngine == .webKit)
            #expect(externalTab.inheritedSignInOrigin == "https://www.google.com")
            if !isRedirect {
                externalTab.committedURL = redirector
            }
            #expect(!externalTab.permitsEngineNavigation(URLRequest(url: external), isMainFrame: true, isRedirect: isRedirect))
            _ = await externalTab.waitForPendingNavigation()
            #expect(externalTab.signInEngine == nil)
            #expect(externalTab.inheritedSignInOrigin == nil)
            #expect(externalTab.pendingOpenerSignIn == nil)
            #expect(externalTab.loadedEngine == .chromium)
            closeOpenedTab(externalTab, in: browser, via: via)

            let meetTab = try openFromCalendar(calendarTab, in: browser, to: redirector, via: via)
            #expect(meetTab.permitsEngineNavigation(URLRequest(url: redirector), isMainFrame: true))
            if !isRedirect {
                meetTab.committedURL = redirector
            }
            #expect(meetTab.permitsEngineNavigation(URLRequest(url: meet), isMainFrame: true, isRedirect: isRedirect))
            #expect(meetTab.signInEngine == .webKit)
            #expect(meetTab.inheritedSignInOrigin == "https://www.google.com")
            #expect(meetTab.loadedEngine == .webKit)
            closeOpenedTab(meetTab, in: browser, via: via)
        }
    }

    @Test(.boundedWebViews, arguments: ["newWindow", "openInNewTab", "peek"])
    func chromiumConfiguredRedirectorInStandardWindowDoesNotLeakWebKitSignIn(via: String) async throws {
        let permissions = temporaryPermissions()
        let redirector = try #require(URL(string: "https://www.google.com/url?q=https://example.com/"))
        let externalChromium = try #require(URL(string: "https://example.com/"))
        let externalWebKit = try #require(URL(string: "https://webkit-only.example/"))
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1"))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: redirector))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: externalChromium))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: meet))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        defer { browser.closeAllTabs(saving: false) }

        let calendarTab = try openSignedInCalendar(in: browser)

        for isRedirect in [true, false] {
            let chromiumTab = try openFromCalendar(calendarTab, in: browser, to: redirector, via: via)
            #expect(chromiumTab.permitsEngineNavigation(URLRequest(url: redirector), isMainFrame: true))
            #expect(chromiumTab.signInEngine == .webKit)
            #expect(chromiumTab.inheritedSignInOrigin == "https://www.google.com")
            if !isRedirect {
                chromiumTab.committedURL = redirector
            }
            #expect(!chromiumTab.permitsEngineNavigation(URLRequest(url: externalChromium), isMainFrame: true, isRedirect: isRedirect))
            _ = await chromiumTab.waitForPendingNavigation()
            #expect(chromiumTab.signInEngine == nil)
            #expect(chromiumTab.inheritedSignInOrigin == nil)
            #expect(chromiumTab.loadedEngine == .chromium)
            closeOpenedTab(chromiumTab, in: browser, via: via)

            // Same-site Meet stays in WebKit even when www.google.com and meet.google.com are set to Chromium.
            let meetTab = try openFromCalendar(calendarTab, in: browser, to: redirector, via: via)
            #expect(meetTab.permitsEngineNavigation(URLRequest(url: redirector), isMainFrame: true))
            if !isRedirect {
                meetTab.committedURL = redirector
            }
            #expect(meetTab.permitsEngineNavigation(URLRequest(url: meet), isMainFrame: true, isRedirect: isRedirect))
            #expect(meetTab.signInEngine == .webKit)
            #expect(meetTab.loadedEngine == .webKit)
            closeOpenedTab(meetTab, in: browser, via: via)
        }

        // An HTTP 302 redirect from Chromium-configured www.google.com to a WebKit external site clears sign-in on commit.
        let webKitTab = try openFromCalendar(calendarTab, in: browser, to: redirector, via: via)
        let nav = PageNavigation()
        #expect(webKitTab.permitsEngineNavigation(URLRequest(url: redirector), isMainFrame: true))
        webKitTab.navigationStarted(nav, url: redirector)
        #expect(webKitTab.permitsEngineNavigation(URLRequest(url: externalWebKit), isMainFrame: true, navigation: nav, isRedirect: true))
        #expect(webKitTab.signInEngine == .webKit, "sign-in remains until the external document commits")
        webKitTab.navigationCommitted(nav)
        #expect(webKitTab.signInEngine == nil)
        #expect(webKitTab.inheritedSignInOrigin == nil)
        closeOpenedTab(webKitTab, in: browser, via: via)
    }

    @Test(.boundedWebViews) func agentMicroWindowOnOpenInNewWindowRoutesThroughOpenTabWithAgentTransition() async throws {
        let app = BrowserApplication()
        let profile = Profile(id: UUID(), name: "Agent micro opener test", symbol: "person", color: .gray)
        Profile.dataStoreForTesting[profile.id] = .nonPersistent()
        let context = BrowserProfileContext.shared(for: profile)
        var failure: Error?
        do {
            let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1"))
            let redirector = try #require(URL(string: "https://www.google.com/url?q=https://example.com/"))
            let external = try #require(URL(string: "https://example.com/"))
            let companion = AgentCompanionInfo(hostName: "T3 Code", threadId: "thread-signin", threadTitle: "Sign-in")
            let agentWindow = app.openAgentMicroWindow(
                profile: profile,
                companion: companion,
                url: nil,
                engine: .chromium,
                floatOnTop: false,
                open: false
            )
            let calendarTab = try openSignedInCalendar(in: agentWindow.browser)

            agentWindow.browser.onOpenInNewWindow?(calendarTab, meet, false)
            let meetTab = try #require(agentWindow.browser.tabs.first { $0.urlString == meet.absoluteString })
            #expect(app.windows.count == 1, "links opened from an Agent Micro Window stay inside it")
            #expect(meetTab.pendingTransition == .agent)
            #expect(meetTab.defaultEngineOverride == .chromium)
            #expect(meetTab.signInEngine == .webKit)
            #expect(meetTab.inheritedSignInOrigin == "https://meet.google.com")
            #expect(meetTab.loadedEngine == .webKit)

            agentWindow.browser.onOpenInNewWindow?(calendarTab, redirector, false)
            let redirectTab = try #require(agentWindow.browser.tabs.first { $0.urlString == redirector.absoluteString })
            #expect(redirectTab.pendingTransition == .agent)
            #expect(redirectTab.signInEngine == .webKit)
            #expect(redirectTab.inheritedSignInOrigin == "https://www.google.com")
            #expect(!redirectTab.permitsEngineNavigation(URLRequest(url: external), isMainFrame: true, isRedirect: true))
            _ = await redirectTab.waitForPendingNavigation()
            #expect(redirectTab.signInEngine == nil)
            #expect(redirectTab.inheritedSignInOrigin == nil)
            #expect(redirectTab.loadedEngine == .chromium)

            agentWindow.browser.onOpenInNewWindow?(calendarTab, meet, true)
            let privateRequestTab = try #require(agentWindow.browser.tabs.first {
                $0 !== meetTab && $0.urlString == meet.absoluteString
            })
            _ = await privateRequestTab.waitForPendingNavigation()
            #expect(privateRequestTab.pendingTransition == .agent)
            #expect(privateRequestTab.signInEngine == nil)
            #expect(privateRequestTab.inheritedSignInOrigin == nil)
            #expect(privateRequestTab.loadedEngine == .chromium)
        } catch {
            failure = error
        }
        app.windows.forEach { $0.closeWindow() }
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        try? await app.clearDataOnQuitIfNeeded()
        BrowserProfileContext.forget(profile.id)
        try? await Profile.eraseLocalData(profile)
        Profile.dataStoreForTesting[profile.id] = nil
        if let failure {
            throw failure
        }
    }

    @Test(.boundedWebViews) func agentMicroWindowWithWebKitDefaultComposesWithOpenerSignIn() throws {
        let permissions = temporaryPermissions()
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1"))
        let redirector = try #require(URL(string: "https://www.google.com/url?q=https://example.com/"))
        let external = try #require(URL(string: "https://example.com/article"))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: meet))
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: external))

        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        browser.windowKind = .micro
        browser.isEphemeralAgentWindow = true
        browser.agentCompanion = AgentCompanionInfo(
            hostName: "T3 Code",
            threadId: "thread-webkit-default",
            threadTitle: "WebKit Preview",
            defaultEngine: .webKit
        )
        defer { browser.closeAllTabs(saving: false) }

        let calendarTab = try openSignedInCalendar(in: browser)
        #expect(calendarTab.defaultEngineOverride == .webKit)

        calendarTab.onOpenInNewTab?(meet, true)
        let meetTab = try #require(browser.tabs.first { $0.urlString == meet.absoluteString })
        #expect(meetTab.defaultEngineOverride == .webKit)
        #expect(meetTab.signInEngine == nil)
        #expect(meetTab.inheritedSignInOrigin == nil)
        #expect(meetTab.pendingOpenerSignIn == BrowserTab.OpenerSignIn(engine: .webKit, origin: "https://meet.google.com"))
        #expect(meetTab.loadedEngine == .webKit)

        calendarTab.onOpenInNewTab?(redirector, false)
        let redirectTab = try #require(browser.tabs.first { $0.urlString == redirector.absoluteString })
        #expect(redirectTab.defaultEngineOverride == .webKit)
        #expect(redirectTab.permitsEngineNavigation(URLRequest(url: redirector), isMainFrame: true))
        #expect(redirectTab.permitsEngineNavigation(URLRequest(url: external), isMainFrame: true, isRedirect: true))
        #expect(redirectTab.signInEngine == nil)
        #expect(redirectTab.inheritedSignInOrigin == nil)
        #expect(redirectTab.pendingOpenerSignIn == nil)
        #expect(redirectTab.loadedEngine == .webKit)

        let peekTab = browser.makePeekTab(meet, from: calendarTab)
        defer { browser.dismissPeekTab(peekTab) }
        #expect(peekTab.defaultEngineOverride == .webKit)
        #expect(peekTab.loadedEngine == .webKit)
    }

    @Test(.boundedWebViews) func oauthProviderHopClearsInheritedOriginSoThirdPartyCallbackStaysInWebKit() throws {
        let permissions = temporaryPermissions()
        let meet = try #require(URL(string: "https://meet.google.com/uag-ohsc-hbw?authuser=1"))
        let accounts = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth"))
        let callback = try #require(URL(string: "https://app.example/oauth/callback?code=fixture"))
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        browser.windowKind = .micro
        browser.isEphemeralAgentWindow = true
        defer { browser.closeAllTabs(saving: false) }

        let calendarTab = try openSignedInCalendar(in: browser)
        calendarTab.onOpenInNewTab?(meet, true)
        let meetTab = try #require(browser.tabs.first { $0.urlString == meet.absoluteString })
        try #require(meetTab.signInEngine == .webKit)
        try #require(meetTab.inheritedSignInOrigin == "https://meet.google.com")

        // Entering a genuine sign-in provider flow lifts the inherited same-site restriction.
        #expect(meetTab.permitsEngineNavigation(URLRequest(url: accounts), isMainFrame: true))
        #expect(meetTab.signInEngine == .webKit)
        #expect(meetTab.inheritedSignInOrigin == nil)

        // The OAuth provider's return redirect to a third-party app stays in WebKit.
        #expect(meetTab.permitsEngineNavigation(URLRequest(url: callback), isMainFrame: true, isRedirect: true))
        #expect(meetTab.signInEngine == .webKit)
        #expect(meetTab.inheritedSignInOrigin == nil)
        #expect(meetTab.loadedEngine == .webKit)
    }
}
