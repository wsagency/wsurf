// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// A back within one site is answered by WebKit's page cache; a back across
/// sites swaps WebContent processes and used to come back at the top. The tab
/// remembers where each page was left and puts it back. Both paths are pinned
/// here.
@MainActor
@Suite(.serialized)
struct BackForwardScrollTests {

    private func scrollY(_ page: BrowserPage) async -> Double {
        (try? await page.evaluateJavaScript("window.scrollY")) as? Double ?? -1
    }

    private func window(hosting page: BrowserPage) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        page.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.addSubview(page)
        window.orderBack(nil)
        return window
    }

    /// crossHost is the case WebKit does not cover: the process swap drops the
    /// page cache, and without the tab's own memory the page lands at the top.
    @Test(.boundedWebViews, arguments: [false, true])
    func goingBackReturnsToTheSpotThePageWasLeftAt(crossHost: Bool) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/tall": .html("""
                <title>Tall</title>
                <div style="height: 8000px">tall page</div>
                <a id="next" href="/other">next</a>
                """),
            "/other": .html("<title>Other</title><h1>Other</h1>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let tall = try server.url("/tall")
        var other = try server.url("/other")
        if crossHost {
            var components = try #require(URLComponents(url: other, resolvingAgainstBaseURL: false))
            components.host = "localhost"
            other = try #require(components.url)
        }
        let permissions = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("BackForwardScroll-\(UUID().uuidString).json")
        )
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let tab = browser.newTab(url: tall)
        let host = window(hosting: tab.page)
        defer {
            host.orderOut(nil)
            browser.close(tab, recordForReopening: false)
        }

        try #require(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        try #require(await waitUntil { tab.urlString == tall.absoluteString })

        _ = try await tab.page.evaluateJavaScript("window.scrollTo(0, 1500)")
        let before = await scrollY(tab.page)
        try #require(before == 1500)
        // The scroll monitor reports on a short throttle; leaving the page
        // before it fires is not the gesture under test.
        try #require(await waitUntil { tab.lastReportedScrollY == before })

        _ = try await tab.page.evaluateJavaScript(
            "document.getElementById('next').href = '\(other.absoluteString)'; document.getElementById('next').click()"
        )
        try #require(await waitUntil { tab.urlString == other.absoluteString && tab.canGoBack })
        try #require(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))

        tab.goBack()
        try #require(await waitUntil { tab.urlString == tall.absoluteString })
        try #require(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))

        let restored = await waitUntil { await scrollY(tab.page) == before }
        // Check after the bounded watcher, not a transient restoration.
        let actual = try await tab.page.callAsyncJavaScript(
            "await new Promise(resolve => setTimeout(resolve, 1400)); return window.scrollY;",
            in: nil, contentWorld: .page
        ) as? Double
        #expect(restored && actual == before)
    }

    @Test(.boundedWebViews, arguments: [false, true])
    func restorationSurvivesALateNativeReset(alreadyRestored: Bool) async throws {
        let tab = BrowserTab(opensBlank: false)
        let host = window(hosting: tab.page)
        defer { host.orderOut(nil) }
        tab.loadHTML("<div style='height: 8000px'>Tall</div>", baseURL: nil)
        try #require(await waitUntil { !tab.page.isLoading })
        let initial = alreadyRestored ? "window.scrollTo(0, 1500);" : ""
        _ = try await tab.page.evaluateJavaScript(
            initial + BrowserTab.restoreScrollScript(to: 1500) + "; window.scrollTo(0, 0);"
        )
        #expect(await waitUntil { await scrollY(tab.page) == 1500 })
    }

    @Test(.boundedWebViews, arguments: ["wheel", "keydown", "pointerdown", "touchstart", "pagehide", "page-scroll"])
    func restorationRespectsSubsequentInput(event: String) async throws {
        let tab = BrowserTab(opensBlank: false)
        let host = window(hosting: tab.page)
        defer { host.orderOut(nil) }
        tab.loadHTML("<div style='height: 8000px'>Tall</div>", baseURL: nil)
        try #require(await waitUntil { !tab.page.isLoading })
        let target = event == "page-scroll" ? 700 : 0
        let input = event == "page-scroll" ? "" : "window.dispatchEvent(new Event('\(event)'));"
        let position = try await tab.page.callAsyncJavaScript(
            BrowserTab.restoreScrollScript(to: 1500) + """
                \(input)
                window.scrollTo(0, \(target));
                await new Promise(resolve => setTimeout(resolve, 1400));
                return window.scrollY;
                """,
            in: nil, contentWorld: .page
        )
        #expect((position as? Double) == Double(target))
    }

    // MARK: - The memory itself

    @Test func memoryReturnsWhatWasLeftAndOnlyThat() {
        var memory = ScrollReturnMemory()
        memory.remember(1500, leaving: "https://a.example/page")

        #expect(memory.offset(returningTo: "https://a.example/page") == 1500)
        #expect(memory.offset(returningTo: "https://b.example/") == nil)
        #expect(memory.offset(returningTo: nil) == nil)
    }

    /// A page left at the top has nothing to restore; handing back a zero
    /// would still run a script against pages that place themselves.
    @Test func memoryTreatsTheTopAsNothingToRestore() {
        var memory = ScrollReturnMemory()
        memory.remember(0, leaving: "https://a.example/")
        memory.remember(0.5, leaving: "https://b.example/")

        #expect(memory.offset(returningTo: "https://a.example/") == nil)
        #expect(memory.offset(returningTo: "https://b.example/") == nil)
    }

    /// Leaving the same page twice keeps the newer offset - the user may have
    /// scrolled somewhere else on the return visit.
    @Test func memoryKeepsTheLatestOffsetPerAddress() {
        var memory = ScrollReturnMemory()
        memory.remember(1500, leaving: "https://a.example/")
        memory.remember(320, leaving: "https://a.example/")

        #expect(memory.offset(returningTo: "https://a.example/") == 320)
    }

    @Test func memoryStaysBounded() {
        var memory = ScrollReturnMemory(capacity: 3)
        memory.remember(10, leaving: "https://one.example/")
        memory.remember(20, leaving: "https://two.example/")
        memory.remember(30, leaving: "https://three.example/")
        memory.remember(40, leaving: "https://four.example/")

        #expect(memory.offset(returningTo: "https://four.example/") == 40)
        #expect(memory.offset(returningTo: "https://one.example/") == nil)
    }
}
