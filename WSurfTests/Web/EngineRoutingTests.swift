// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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
}
