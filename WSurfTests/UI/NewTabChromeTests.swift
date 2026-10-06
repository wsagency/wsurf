// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// What a brand-new tab reports about itself while it has nothing in it.
///
/// The toolbar appears from `hasNoPageYet`, so anything making an empty tab
/// claim to be loading shows as the bar flashing on and off. It did: a pooled
/// view arrives with the warm-up page still in flight, and the tab's own
/// navigation delegate reported the pool's navigation as its own.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct NewTabChromeTests {
    /// The regression, stated as the thing the user saw: an empty tab must
    /// never pass through a loading state, at any point after it is made.
    @Test func anEmptyTabNeverReportsItselfLoading() async {
        let tab = BrowserTab()

        let finished = await waitUntil {
            #expect(!tab.isLoading, "the warm-up page must not report a page load")
            #expect(tab.hasNoPageYet, "the start page must stay visible during warm-up")
            return tab.page.url == SystemPages.start && !tab.page.isLoading
        }
        #expect(finished)
        #expect(tab.urlString.isEmpty)
    }

    /// Several tabs at once is the launch case: the pool only holds a couple
    /// of warm views, so the third onward is built and handed over with its
    /// warm-up load definitely still running.
    @Test func aWholeSessionOfNewTabsStaysQuiet() async {
        let tabs = (0..<5).map { _ in BrowserTab() }

        let finished = await waitUntil {
            #expect(tabs.allSatisfy { $0.hasNoPageYet })
            return tabs.allSatisfy { $0.page.url == SystemPages.start && !$0.page.isLoading }
        }
        #expect(finished)
    }

    /// The warm-up page is painted `#101014` so WebKit has something to
    /// rasterize. That colour must never reach the toolbar's tint - the bar
    /// takes its wash from the *site*, and an empty tab has no site.
    @Test func theWarmUpPageNeverTintsTheToolbar() async {
        let tab = BrowserTab()
        let finished = await waitUntil {
            #expect(tab.pageColor == nil, "the pool's blank page washed the toolbar in its own backdrop")
            return tab.page.url == SystemPages.start && !tab.page.isLoading
        }
        #expect(finished)
    }

    // MARK: - …without disabling the flag entirely

    /// The fix narrows what counts as loading; it must not narrow it to
    /// nothing. A real page still moves the tab out of the start-page state
    /// and leaves its address behind.
    @Test func arealPageStillEndsTheStartPageState() async {
        let tab = BrowserTab()
        tab.loadHTML(
            "<!doctype html><html><body><h1>Arrived</h1></body></html>",
            baseURL: URL(string: "https://example.test/page")
        )

        #expect(await waitUntil { !tab.hasNoPageYet }, "a real page must take the tab off the start page")

        // And it settles: the address is kept, and loading ends.
        #expect(await waitUntil { !tab.isLoading })
        #expect(tab.urlString.contains("example.test"))
    }

    /// Loading `about:blank` - which is how a closing tab is silenced - is
    /// not a page either, and must not light the chrome up on the way out.
    @Test func blankingATabIsNotAPageLoad() async {
        let tab = BrowserTab()
        tab.load(URL(string: "about:blank")!)

        let finished = await waitUntil {
            #expect(!tab.isLoading)
            return tab.page.url?.absoluteString == "about:blank" && !tab.page.isLoading
        }
        #expect(finished)
        #expect(tab.hasNoPageYet)
    }

    // MARK: - The warm-up page's colour

    /// The warm-up page is what the view *displays* between the start page
    /// leaving and the site's first paint, so it has to follow the appearance
    /// it is shown in. Hardcoding the dark window background was invisible in
    /// dark mode and a black flash across every page opened in light.
    @Test func theWarmUpPageFollowsTheAppearanceItIsShownIn() async throws {
        func renderedBackground(_ appearance: NSAppearance.Name) async throws -> (r: Double, g: Double, b: Double) {
            let configuration = WebViewPool.makeConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 200, height: 200),
                configuration: configuration
            )
            webView.appearance = NSAppearance(named: appearance)
            webView.loadHTMLString(WebViewPool.warmUpHTML, baseURL: nil)
            #expect(await PageSettle.untilIdle(BrowserPage(webKit: webView), timeout: .seconds(30)))

            let css = try #require(
                (try? await webView.evaluateJavaScript(
                    "getComputedStyle(document.documentElement).backgroundColor"
                )) as? String
            )
            let numbers = css
                .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap(Double.init)
            try #require(numbers.count >= 3)
            return (numbers[0], numbers[1], numbers[2])
        }

        let light = try await renderedBackground(.aqua)
        #expect(light.r > 180, "light appearance must render a light warm-up, got rgb(\(light))")

        let dark = try await renderedBackground(.darkAqua)
        #expect(dark.r < 120, "dark appearance must render a dark warm-up, got rgb(\(dark))")
    }

    /// The backdrop SwiftUI paints behind the web view follows the same
    /// rule as every other piece of page-derived chrome: no real page, no
    /// claim. While the warm-up page holds the view, the backdrop is the
    /// window's own background, never the warm-up's.
    @Test func theBackdropClaimsNothingBeforeARealPage() async {
        let tab = BrowserTab()
        let finished = await waitUntil {
            #expect(tab.canvasColor == nil, "the warm-up page's backdrop leaked into the canvas colour")
            return tab.page.url == SystemPages.start && !tab.page.isLoading
        }
        #expect(finished)
    }

    /// …and takes the site's colour once there is a site, which is what
    /// keeps a resize gap beside a dark page from flashing white.
    @Test func theBackdropTakesTheSitesColourOnceItArrives() async throws {
        let tab = BrowserTab()
        tab.loadHTML(
            "<!doctype html><html><body style=\"background:#123456\"><p>Here</p></body></html>",
            baseURL: URL(string: "https://example.test/dark")
        )

        #expect(await waitUntil { tab.canvasColor != nil }, "a loaded site must supply the backdrop")
    }

    // MARK: - Getting back to it

    /// The bug, stated as the user saw it: open a new tab, go somewhere, and
    /// Back is dead. The start page is a real `wsurf://start` navigation now,
    /// so it is the first entry in WebKit's own back list.
    @Test func backReturnsToTheStartPageATabBeganOn() async throws {
        let tab = BrowserTab()
        #expect(await settled(tab, at: SystemPages.start))

        tab.load(BrowserTab.InternalPage.history.url)
        #expect(await settled(tab, at: BrowserTab.InternalPage.history.url))

        #expect(tab.canGoBack)
        tab.goBack()
        #expect(await settled(tab, at: SystemPages.start))

        // And it is the oldest thing there is: nothing behind the start page.
        #expect(!tab.canGoBack)
        #expect(tab.canGoForward)

        tab.goForward()
        #expect(await settled(tab, at: BrowserTab.InternalPage.history.url))
    }

    /// The start page covers the row's name and icon while it is on screen.
    @Test func theStartPageTakesTheRowBackFromThePageItCovers() async {
        let tab = BrowserTab()
        #expect(await settled(tab, at: SystemPages.start))

        tab.load(BrowserTab.InternalPage.releaseNotes.url)
        #expect(await settled(tab, at: BrowserTab.InternalPage.releaseNotes.url))

        tab.goBack()
        #expect(await settled(tab, at: SystemPages.start))
        #expect(tab.title == BrowserTab.placeholderTitle)
        #expect(tab.favicon == nil)
    }

    @Test func goingForwardGivesThePageItsNameBack() async {
        let tab = BrowserTab()
        #expect(await settled(tab, at: SystemPages.start))

        tab.load(BrowserTab.InternalPage.downloads.url)
        #expect(await settled(tab, at: BrowserTab.InternalPage.downloads.url))

        tab.goBack()
        #expect(await settled(tab, at: SystemPages.start))

        tab.goForward()
        #expect(await settled(tab, at: BrowserTab.InternalPage.downloads.url))
        #expect(tab.internalPage == .downloads)
    }

    /// The failure that started the rewrite: one remembered page is not a
    /// stack. Two system pages deep, Back must walk both of them.
    @Test func backWalksEverySystemPageInTheTab() async {
        let tab = BrowserTab()
        #expect(await settled(tab, at: SystemPages.start))

        tab.load(BrowserTab.InternalPage.history.url)
        #expect(await settled(tab, at: BrowserTab.InternalPage.history.url))

        tab.load(BrowserTab.InternalPage.settings.url)
        #expect(await settled(tab, at: BrowserTab.InternalPage.settings.url))

        tab.goBack()
        #expect(await settled(tab, at: BrowserTab.InternalPage.history.url))

        tab.goBack()
        #expect(await settled(tab, at: SystemPages.start))
        #expect(!tab.canGoBack)
    }

    @Test func aTabOpenedStraightOntoALinkHasNoStartPageBehindIt() async {
        let tab = BrowserTab(opensBlank: false)

        #expect(!tab.canGoBack)
        tab.goBack()
        #expect(await waitUntil { !tab.isShowingStartPage })
    }
    @Test func typingAnAddressLeavesTheStartPageAgain() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><html><body>Real page</body></html>")
        ])
        defer { withExtendedLifetime(server) {} }
        let tab = BrowserTab()
        #expect(await settled(tab, at: SystemPages.start))

        let address = try server.url()
        tab.load(address)
        #expect(await waitUntil { tab.page.url == address && !tab.isShowingStartPage })
    }
}
