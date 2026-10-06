// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews, .exclusiveExternalApp)
struct TabRecoveryTests {
    @Test func reloadStartsAnAddressThatHasNotCommitted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSurfUncommitted-\(UUID().uuidString).html")
        try Data("<title>Loaded</title>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tab = BrowserTab(opensBlank: false)
        tab.urlString = url.absoluteString
        let webKit = try #require(tab.page.webKit)
        #expect(webKit.backForwardList.currentItem == nil)

        tab.reload()

        let deadline = ContinuousClock.now + .seconds(3)
        while tab.page.url != url && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(tab.page.url == url)
    }

    @Test func restartReplacesOnlyThePageViewAndKeepsItsDataStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSurfRecovery-\(UUID().uuidString).html")
        try Data("<title>Recovered</title>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WebViewPool.shared.makeView(configuration: configuration)
        let tab = BrowserTab(
            adopting: page,
            opensBlank: false,
            privately: true
        )
        let oldPage = tab.page
        let oldView = try #require(oldPage.webKit)
        tab.urlString = url.absoluteString

        tab.restartPage()
        _ = await tab.waitForPendingNavigation()

        #expect(tab.page !== oldPage)
        let newView = try #require(tab.page.webKit)
        #expect(newView.configuration.websiteDataStore === oldView.configuration.websiteDataStore)
        #expect(oldView.navigationDelegate == nil)
        #expect(oldPage.superview == nil)
        #expect(tab.urlString == url.absoluteString)
        #expect(!tab.isClosed)
    }

    @Test func engineRoundTripRetiresChromiumWithoutSharingWebsiteData() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Engine round trip</title><iframe src='/frame'></iframe>"),
            "/frame": .html("<p>Subresource loaded</p>"),
        ])
        let url = try server.url("/")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EngineRoundTrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let permissions = SitePermissions(storageURL: file)
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webKit = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let tab = BrowserTab(adopting: webKit, opensBlank: false, privately: true, sitePermissions: permissions)
        let window = NSWindow(contentRect: webKit.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)
        defer { window.close() }
        tab.load(url)
        try #require(await waitUntil { tab.page.url == url && tab.page.title == "Engine round trip" && !tab.page.isLoading })
        _ = try await tab.page.evaluateJavaScript("localStorage.setItem('engineToken', 'webkit'); true")

        let origin = SitePermissions.origin(for: url)
        permissions.setEngine(.chromium, for: origin)
        try #require(await tab.switchEngine(to: .chromium))
        window.contentView = tab.page
        let native = try #require(tab.page.chromium)
        try #require(await waitUntil { tab.page.url == url && tab.page.title == "Engine round trip" && !tab.page.isLoading })
        let userAgent = try await tab.page.evaluateJavaScript("navigator.userAgent") as? String
        #expect(userAgent?.contains("Chrome/") == true)
        #expect(try await tab.page.evaluateJavaScript("localStorage.getItem('engineToken') === null") as? Bool == true)
        _ = try await tab.page.evaluateJavaScript("localStorage.setItem('engineToken', 'chromium'); true")
        let frames = try await native.frames()
        #expect(frames.contains { !$0.isMainFrame && $0.request.url?.path == "/frame" })

        permissions.setEngine(.webKit, for: origin)
        try #require(await tab.switchEngine(to: .webKit))
        window.contentView = tab.page
        try #require(await waitUntil { tab.page.url == url && tab.page.title == "Engine round trip" && !tab.page.isLoading })
        #expect(try await tab.page.evaluateJavaScript("localStorage.getItem('engineToken')") as? String == "webkit")
        #expect(native.isClosed)
        #expect(window.isVisible)
        #expect(!tab.isClosed)
        tab.detach()
        await tab.waitForRetirement()
    }

    @Test func chromiumProfilesAndPrivateSessionsKeepTheirCookiesAndStorageSeparate() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Profile isolation</title>"),
        ])
        let url = try server.url("/")
        let profiles = [
            Profile(id: UUID(), name: "First", symbol: "person", color: .gray),
            Profile(id: UUID(), name: "Second", symbol: "person", color: .gray),
        ]
        let runtime = ChromiumRuntime.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        var activePage: BrowserPage?

        func inspect(_ profile: Profile, expected: String, write: String? = nil) async throws {
            let page = BrowserPage(chromium: ChromiumPage(profile: profile))
            activePage = page
            window.contentView = page
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && page.title == "Profile isolation" && !page.isLoading })
            let state = try await page.evaluateJavaScript(
                "(localStorage.getItem('profileToken') || '') + '|' + document.cookie") as? String
            #expect(state == expected)
            if let write {
                _ = try await page.evaluateJavaScript(
                    "localStorage.setItem('profileToken', '\(write)'); document.cookie = 'profileToken=\(write); Path=/; SameSite=Lax'; true")
            }
            await page.close()
            activePage = nil
        }

        var failure: (any Error)?
        do {
            try await inspect(profiles[0], expected: "|", write: "first")
            try await inspect(profiles[1], expected: "|", write: "second")
            try await inspect(profiles[0], expected: "first|profileToken=first")
            try await inspect(.privateBrowsing(), expected: "|", write: "private")
            try await inspect(.privateBrowsing(), expected: "private|profileToken=private")
            runtime.endPrivateSession()
            try await inspect(.privateBrowsing(), expected: "|")
            try await inspect(profiles[0], expected: "first|profileToken=first")
            try await inspect(profiles[1], expected: "second|profileToken=second")
        } catch {
            failure = error
        }
        await activePage?.close()
        runtime.endPrivateSession()
        window.close()
        for profile in profiles {
            await runtime.releaseContext(profileID: profile.id)
            try? FileManager.default.removeItem(at: runtime.cacheDirectory(profileID: profile.id))
        }
        if let failure {
            throw failure
        }
    }

    @Test func htmlLoadDuringRetirementReplacesTheRetiredDocument() async throws {
        let tab = BrowserTab(opensBlank: false)
        tab.urlString = "https://retired.invalid/"
        let retired = tab.page
        tab.discardWebContent()

        tab.loadHTML("<!doctype html><title>Replacement</title><p>New document</p>", baseURL: nil)
        _ = await tab.waitForPendingNavigation()

        #expect(await waitUntil { tab.page.title == "Replacement" })
        #expect(tab.page !== retired)
        #expect(retired.isClosed)
    }
}
