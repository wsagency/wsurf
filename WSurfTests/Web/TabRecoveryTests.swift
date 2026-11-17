// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

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

        let tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .privateBrowsing()))
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
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = context.webViewPool.makeView(configuration: configuration)
        let tab = BrowserTab(adopting: page, opensBlank: false, context: context)
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
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webKit = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let tab = BrowserTab(adopting: webKit, opensBlank: false, sitePermissions: permissions, context: context)
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
        let contexts = profiles.map { BrowserProfileContext.shared(for: $0) }
        var privateContext = BrowserProfileContext(profile: .privateBrowsing())
        let runtime = ChromiumRuntime.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        var activePage: BrowserPage?

        func inspect(_ context: BrowserProfileContext, expected: String, write: String? = nil) async throws {
            let page = BrowserPage(chromium: ChromiumPage(context: context))
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
            try await inspect(contexts[0], expected: "|", write: "first")
            try await inspect(contexts[1], expected: "|", write: "second")
            try await inspect(contexts[0], expected: "first|profileToken=first")
            try await inspect(privateContext, expected: "|", write: "private")
            try await inspect(privateContext, expected: "private|profileToken=private")
            await privateContext.endPrivateSession()
            privateContext = BrowserProfileContext(profile: .privateBrowsing())
            try await inspect(privateContext, expected: "|")
            try await inspect(contexts[0], expected: "first|profileToken=first")
            try await inspect(contexts[1], expected: "second|profileToken=second")
        } catch {
            failure = error
        }
        await activePage?.close()
        await privateContext.endPrivateSession()
        window.close()
        for (profile, context) in zip(profiles, contexts) {
            await runtime.releaseContext(contextID: context.contextID)
            try? FileManager.default.removeItem(at: runtime.cacheDirectory(profileID: profile.id))
            BrowserProfileContext.forget(profile.id)
        }
        if let failure {
            throw failure
        }
    }

    @Test func htmlLoadDuringRetirementReplacesTheRetiredDocument() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/retired": .html("<title>Retired</title><p>Original document</p>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/retired")
        let tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .original()))
        defer { tab.detach() }
        tab.load(url)
        try #require(await waitUntil {
            tab.committedURL == url && tab.page.title == "Retired" && !tab.page.isLoading
        })

        let retired = tab.page
        #expect(tab.canDiscardWebContent)
        tab.discardWebContent()
        #expect(!tab.isMaterialised)

        tab.loadHTML("<!doctype html><title>Replacement</title><p>New document</p>", baseURL: nil)
        _ = await tab.waitForPendingNavigation()

        #expect(await waitUntil { tab.page.title == "Replacement" })
        #expect(tab.page !== retired)
        #expect(retired.isClosed)
    }

    // MARK: Stop, then Reload keeps the page and its Back/Forward list

    /// `BrowserTab.reload` takes "stopped, yet the page still loading" for a hung page and restarts it, which builds a new page with an
    /// empty history. A Chromium load that WSurf started and Chromium had not begun used to stay loading after Stop, so that Reload
    /// restarted a healthy page.
    private static let stopReloadPages: [String: HTTPFixtureServer.Response] = [
        "/a": .html("<title>A</title><p>A</p>"),
        "/b": .html("<title>B</title><p>B</p>"),
        "/c": .html("<title>C</title><p>C</p>"),
    ]

    /// Opens `/a`, then `/b`, and returns the page both are in.
    private func openAThenBForStop(_ rig: LiveWindowRig) async throws -> (tab: BrowserTab, page: BrowserPage) {
        let tab = try await rig.open("/a")
        let b = try rig.server.url("/b")
        tab.load(b)
        try #require(await waitUntil { tab.page.url == b && !tab.page.isLoading })
        return (tab, tab.page)
    }

    /// Reload after Stop, then the checks both tests share: the same page (no restart) and a history that still starts `/a`, `/b`. The
    /// current entry may end as B (reloaded in place) or C (the stopped address, loaded again): neither is asserted.
    private func reloadAndExpectHistoryKept(_ tab: BrowserTab, _ before: BrowserPage, _ engine: BrowserEngine) async throws {
        tab.reload(byPerson: true)
        #expect(tab.page === before, "\(engine): Reload after Stop restarted the page")
        _ = await tab.waitForPendingNavigation()
        try #require(await waitUntil { tab.page.url != nil && !tab.page.isLoading })
        #expect(tab.page === before, "\(engine): the page was replaced while it reloaded")
        let list = tab.page.backForwardList
        let paths = list.backList.map(\.url.path) + [list.currentItem?.url.path].compactMap { $0 }
        #expect(paths.starts(with: ["/a", "/b"]), "\(engine): Back and Forward are \(paths)")
    }

    /// The window in which Chromium has not begun a load WSurf started: Stop lands in the same turn as the load.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func reloadAfterStoppingALoadTheEngineHasNotBegunKeepsTheHistory(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine, routes: Self.stopReloadPages) { rig in
            let (tab, before) = try await openAThenBForStop(rig)
            tab.load(try rig.server.url("/c"), byPerson: true)
            tab.stopLoading()
            let ended = await waitUntil(timeout: .seconds(3)) { !tab.page.isLoading }
            #expect(ended, "\(engine): the page still reports loading after Stop")
            try await reloadAndExpectHistoryKept(tab, before, engine)
        }
    }

    /// The usual case, which already held: the server has the request when Stop comes.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func reloadAfterStoppingALoadTheServerIsAnsweringKeepsTheHistory(engine: BrowserEngine) async throws {
        let gate = ResponseGate()
        defer { gate.open() }
        var routes = Self.stopReloadPages
        routes["/slow"] = .html("<title>Slow</title><p>Slow</p>", gate: gate)
        try await LiveWindowRig.with(engine: engine, routes: routes) { rig in
            let (tab, before) = try await openAThenBForStop(rig)
            tab.load(try rig.server.url("/slow"), byPerson: true)
            try #require(await waitUntil(timeout: .seconds(30)) { gate.requestCount > 0 }, "\(engine): the server never saw the request")
            tab.stopLoading()
            let ended = await waitUntil(timeout: .seconds(3)) { !tab.page.isLoading }
            #expect(ended, "\(engine): the page still reports loading after Stop")
            // The stopped address may load again on Reload; it must not wait for an answer that was held back.
            gate.open()
            try await reloadAndExpectHistoryKept(tab, before, engine)
        }
    }
}
