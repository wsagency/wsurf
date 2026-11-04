// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

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

    @Test func websiteSettingsKeepGoogleSignInInWebKit() async {
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        let signIn = "https://accounts.google.com"
        #expect(await browser.setEngine(.chromium, for: signIn) == false)
        #expect(await browser.setEngine(.webKit, for: signIn))
        #expect(browser.sitePermissions.engine(for: signIn) == .webKit)
        #expect(!browser.sitePermissions.engineOrigins.contains(signIn))
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
        #expect(browser.sitePermissions.engine(for: site) == .chromium, "the website's setting is saved")
        #expect(browser.engine(for: a) == .chromium)
        #expect(browser.engine(for: b) == .webKit)
        #expect(b.preferredEngine(for: inSite) == .webKit, "and it keeps it when it navigates within the site")
        await browser.applyStoredEngine(to: site)
        #expect(b.preferredEngine(for: inSite) == .webKit)
        // A tab opened afterwards follows the setting.
        let c = browser.makeTab(for: nil)
        #expect(c.preferredEngine(for: inSite) == .chromium)
        // The pin is for this website; another one follows its own setting.
        #expect(b.preferredEngine(for: try #require(URL(string: "https://other.example/"))) == .webKit)
        // Choosing the engine on the pinned tab moves it and no one else.
        #expect(await browser.setEngine(.chromium, for: b))
        #expect(b.preferredEngine(for: inSite) == .chromium)
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

    @Test func websiteSettingsStillMoveEveryTabOfTheSite() async throws {
        let site = "https://default-\(UUID().uuidString.prefix(8).lowercased()).example"
        let (browser, a, b) = try browserWithTwoTabs(site: site)
        #expect(await browser.setEngine(.chromium, for: a))
        #expect(b.pinnedEngine != nil)
        // The setting says Chromium now; choosing WebKit as the default reaches every tab.
        #expect(await browser.setEngine(.webKit, for: site))
        #expect(a.pinnedEngine == nil && b.pinnedEngine == nil)
        #expect(a.preferredEngine(for: try #require(URL(string: site))) == .webKit)
    }
}
