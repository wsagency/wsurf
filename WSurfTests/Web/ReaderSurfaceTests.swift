// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import WSurf

/// Waits until a web view has loaded a document of its own.
@MainActor
private final class ReaderLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL?) async {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish()
    }
}

/// Reader on a tab of either engine, in the view that shows the article, and in the commands around it.
@MainActor
@Suite(.serialized)
struct ReaderSurfaceTests {
    private static let story = URL(string: "https://example.test/story")!

    private var articleRoutes: [String: HTTPFixtureServer.Response] {
        ["/news/tide": .html(ReaderFixtures.article()), "/news/next": .html(ReaderFixtures.article())]
    }

    // MARK: The view

    @Test(.boundedWebViews) func theViewThatShowsTheArticleRunsNoJavaScriptAndPlaysNothing() {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = ReaderPageController.makeWebView(dataStore: store).configuration

        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(configuration.websiteDataStore === store)
    }

    /// A script that runs while the document loads would change its title before the load finishes.
    private var scripted: ReaderArticle {
        ReaderArticle(
            url: Self.story, title: "Safe", content: "<p>Body</p><script>document.title = 'ran'</script>", blocks: ["Body"]
        )
    }

    @Test(.boundedWebViews) func aScriptInTheArticleDoesNotRun() async throws {
        let view = ReaderPageController.makeWebView(dataStore: .nonPersistent())
        let controller = ReaderPageController()
        controller.webView = view
        view.navigationDelegate = controller

        controller.show(scripted, appearance: .init(typeface: .system, palette: .automatic, textSize: 19))
        try #require(await waitUntil { controller.isLoaded })

        #expect(await documentTitle(of: view) == "Safe", "the article's script changed the document")
    }

    /// The view's JavaScript setting and the page's policy each stop the script alone. The same document in a view with neither
    /// shows that the script would have run.
    @Test(.boundedWebViews) func eachBarrierAloneKeepsAScriptFromRunning() async throws {
        let html = ReaderPage.html(for: scripted, typeface: .system, palette: .automatic, textSize: 19)
        let policy = #"<meta http-equiv="Content-Security-Policy" content="\#(ReaderPage.contentSecurityPolicy)">"#
        let withoutPolicy = html.replacingOccurrences(of: policy, with: "")
        try #require(withoutPolicy != html)

        let open = pageView(javaScript: true)
        await load(withoutPolicy, in: open)
        #expect(await waitUntil { await documentTitle(of: open) == "ran" }, "the script is live without either barrier")

        let policyOnly = pageView(javaScript: true)
        await load(html, in: policyOnly)
        #expect(await documentTitle(of: policyOnly) == "Safe", "the page's policy alone")

        let readerView = ReaderPageController.makeWebView(dataStore: .nonPersistent())
        await load(withoutPolicy, in: readerView)
        #expect(await documentTitle(of: readerView) == "Safe", "the view's JavaScript setting alone")
    }

    private func pageView(javaScript: Bool) -> WKWebView {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    }

    private func load(_ html: String, in view: WKWebView) async {
        let waiter = ReaderLoadWaiter()
        await waiter.load(html, in: view, baseURL: URL(string: "https://example.test/story"))
    }

    /// The title the document itself holds. `WKWebView.title` reaches the app over IPC and can still show an earlier value, or
    /// none, when the load finishes, so it is read from the DOM. The article's script is inline and synchronous: it runs while
    /// the document is parsed, before the load finishes, so a title still "Safe" after the load means it never ran. An app's
    /// own evaluation runs even with the page's JavaScript off.
    private func documentTitle(of view: WKWebView) async -> String? {
        try? await view.evaluateJavaScript("document.title", in: nil, contentWorld: .defaultClient) as? String
    }

    // MARK: Either engine

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theArticleOfEitherEngineIsShownInWebKit(engine: BrowserEngine) async throws {
        try await withTab(engine: engine, routes: articleRoutes, start: "/news/tide") { tab, _ in
            tab.isFrontTab = { true }
            tab.probeReader()
            #expect(await waitUntil { tab.reader.availability == .available }, "engine \(engine)")

            #expect(await tab.reader.open(), "engine \(engine)")
            let article = try #require(tab.reader.article)
            #expect(article.title.hasPrefix("How the harbour learned to read the tide"), "\(article.title)")
            #expect(tab.reader.isActive)

            let window = host(tab, showing: article)
            defer {
                window.contentView = nil
                window.close()
            }
            try #require(await waitUntil { tab.reader.presentedPage?.title == article.title }, "the article was not loaded")
            let page = try #require(tab.reader.presentedPage)
            let view = try #require(page.webKit)
            #expect(page.engine == .webKit, "the article is shown by WebKit whichever engine the tab uses")
            #expect(tab.page.engine == engine)
            #expect(tab.shownPage === page)
            #expect(!view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
            #expect(tab.isPrivate)
            #expect(view.configuration.websiteDataStore === tab.context.dataStore, "a private tab's article uses the private store")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aNavigationEndsReader(engine: BrowserEngine) async throws {
        try await withTab(engine: engine, routes: articleRoutes, start: "/news/tide") { tab, server in
            tab.reader.driver = StubReader().driver
            #expect(await tab.reader.open())

            let next = try server.url("/news/next")
            tab.load(next)

            #expect(await waitUntil { !tab.reader.isActive }, "engine \(engine)")
            #expect(tab.reader.article == nil)
        }
    }

    @Test(.boundedWebViews)
    func aMoveWithinThePageEndsReaderOnlyWhenTheAddressChangesBeyondItsFragment() async throws {
        try await withTab(engine: .webKit, routes: articleRoutes, start: "/news/tide") { tab, _ in
            tab.reader.driver = StubReader().driver
            #expect(await tab.reader.open())

            _ = try await tab.page.evaluateJavaScript("location.hash = 'part-2'; 1")
            #expect(await waitUntil { tab.urlString.hasSuffix("#part-2") })
            #expect(tab.reader.isActive, "a fragment is the same page")

            _ = try await tab.page.evaluateJavaScript("history.pushState({}, '', '/news/other'); 1")
            #expect(await waitUntil { !tab.reader.isActive })
        }
    }

    @Test(.boundedWebViews)
    func onlyTheTabInFrontAsksItsPageForAnArticle() async throws {
        try await withTab(engine: .webKit, routes: articleRoutes, start: "/news/tide") { tab, _ in
            let stub = StubReader()
            tab.reader.driver = stub.driver
            tab.probeReader()
            for _ in 0..<50 {
                await Task.yield()
            }
            #expect(stub.probes == 0, "a tab that is not in front is left alone")
            #expect(tab.reader.availability == .unknown)

            tab.isFrontTab = { true }
            tab.probeReader()

            #expect(await waitUntil { tab.reader.availability == .available })
            #expect(stub.probes == 1)
        }
    }

    @Test(.boundedWebViews) func aTabIsAskedWhenItIsBroughtToTheFront() async throws {
        let server = try await HTTPFixtureServer.start(routes: articleRoutes)
        defer { withExtendedLifetime(server) {} }
        let browser = BrowserModel(context: BrowserProfileContext(profile: .privateBrowsing()), windowID: UUID())
        defer { browser.closeAllTabs(saving: false) }
        let frontURL = try server.url("/news/tide")
        let behindURL = try server.url("/news/next")
        let front = browser.newTab(url: frontURL)
        let behind = browser.newTab(url: behindURL, activate: false)
        #expect(await settled(front, at: frontURL))
        #expect(await settled(behind, at: behindURL))
        let frontStub = StubReader()
        let behindStub = StubReader()
        front.reader.driver = frontStub.driver
        behind.reader.driver = behindStub.driver
        #expect(browser.activeTab === front)

        browser.activate(behind)

        #expect(await waitUntil { behindStub.probes == 1 })
        #expect(behind.reader.availability == .available)
        #expect(frontStub.probes == 0)
    }

    // MARK: What ends Reader

    @Test(.boundedWebViews) func closingATabEndsItsReader() async {
        let browser = BrowserModel(context: BrowserProfileContext(profile: .privateBrowsing()), windowID: UUID())
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.newTab()
        browser.newTab()
        tab.reader.driver = StubReader().driver
        #expect(await tab.reader.open())

        browser.close(tab)

        #expect(tab.isClosed)
        #expect(!tab.reader.isActive)
        #expect(tab.reader.article == nil)
    }

    /// A profile switch closes the window's tabs this way.
    @Test(.boundedWebViews) func leavingAProfileEndsReaderInEveryTab() async {
        let browser = BrowserModel(context: BrowserProfileContext(profile: .privateBrowsing()), windowID: UUID())
        let tabs = [browser.newTab(), browser.newTab()]
        for tab in tabs {
            tab.reader.driver = StubReader().driver
            #expect(await tab.reader.open())
        }

        browser.closeAllTabs(saving: false)

        for tab in tabs {
            #expect(!tab.reader.isActive)
            #expect(tab.reader.article == nil)
        }
    }

    @Test(.boundedWebViews) func endingAPrivateSessionEndsReader() async {
        let browser = BrowserModel(context: .shared(for: .privateBrowsing()), windowID: UUID())
        let window = AppCoordinator(browser: browser)
        let tab = browser.newTab()
        tab.reader.driver = StubReader().driver
        #expect(await tab.reader.open())

        window.closeWindow()

        #expect(tab.isClosed)
        #expect(!tab.reader.isActive)
        #expect(tab.reader.article == nil)
    }

    // MARK: Links

    @Test(.boundedWebViews) func aLinkInTheArticleOpensATabLikeAnyOtherLink() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/linked": .html("<title>Linked</title><p>Linked</p>")])
        defer { withExtendedLifetime(server) {} }
        let linked = try server.url("/linked")
        let browser = BrowserModel(context: BrowserProfileContext(profile: .privateBrowsing()), windowID: UUID())
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.newTab()
        let decision = ReaderNavigation.decision(
            for: linked, type: .linkActivated, inSubframe: false, article: Self.story, acceptsFirstLoad: false,
            modifiers: [], buttonNumber: 0
        )
        guard case .open(let url, let activate) = decision else {
            Issue.record("the link was not handed to the browser: \(decision)")
            return
        }

        tab.onOpenInNewTab?(url, activate)

        let opened = try #require(browser.activeTab)
        #expect(opened !== tab)
        #expect(browser.tabs.count == 2)
        #expect(opened.urlString == linked.absoluteString)
    }

    // MARK: Commands

    @Test(.boundedWebViews) func theZoomCommandsSetTheTextSizeWhileReaderShowsTheArticle() async {
        let tab = BrowserTab(context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        let settings = tab.context.settings
        let saved = settings.readerTextSize
        defer { settings.readerTextSize = saved }
        settings.readerTextSize = ReaderAppearance.defaultTextSize
        let zoom = tab.page.pageZoom
        tab.reader.driver = StubReader().driver
        #expect(await tab.reader.open())

        #expect(!tab.isZoomed)
        tab.zoomIn()
        #expect(settings.readerTextSize == 21)
        #expect(tab.isZoomed)
        tab.zoomOut()
        tab.zoomOut()
        #expect(settings.readerTextSize == 17)
        tab.resetZoom()
        #expect(settings.readerTextSize == ReaderAppearance.defaultTextSize)
        #expect(!tab.isZoomed)
        #expect(tab.page.pageZoom == zoom, "the website's zoom was left alone")
    }

    @Test(.boundedWebViews) func printAndFindActOnTheArticleWhileReaderShowsIt() async {
        let tab = BrowserTab(context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        let articlePage = BrowserPage(
            webKit: ReaderPageController.makeWebView(dataStore: tab.context.dataStore), context: tab.context
        )
        tab.reader.presentedPage = articlePage
        #expect(tab.shownPage === tab.page, "the website, while Reader is not showing")

        tab.reader.driver = StubReader().driver
        #expect(await tab.reader.open())
        #expect(tab.shownPage === articlePage)

        tab.reader.close()
        #expect(tab.shownPage === tab.page)
    }

    @Test(.boundedWebViews) func showReaderIsEnabledOnlyWhereThereIsAnArticle() async throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let items = root.items.compactMap(\.submenu).flatMap(\.items)
        let item = try #require(items.first { $0.title == String(localized: "Show Reader") })
        let tab = coordinator.browser.newTab()
        defer { coordinator.browser.closeAllTabs(saving: false) }

        #expect(item.keyEquivalent == "r")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        #expect(items.filter { $0.keyEquivalent == "r" && $0.keyEquivalentModifierMask == [.command, .option] }.count == 1)
        #expect(!menu.validateMenuItem(item), "nothing is known about the page yet")

        let stub = StubReader()
        tab.reader.driver = stub.driver
        await tab.reader.probe()
        #expect(menu.validateMenuItem(item), "the page holds an article")
        #expect(item.title == String(localized: "Show Reader"))

        #expect(await tab.reader.open())
        #expect(menu.validateMenuItem(item))
        #expect(item.title == String(localized: "Hide Reader"))

        tab.reader.pageChanged()
        #expect(!menu.validateMenuItem(item), "a new page is not known to hold one")
        #expect(item.title == String(localized: "Show Reader"))
    }

    // MARK: Translate and Find

    private static let english = Locale.Language(identifier: "en")

    /// A stand-in for the language model, so the suite needs no language pack.
    private static func germanised(_ segments: [PageTranslationSegment]) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: segments.map { ($0.node, $0.text.replacingOccurrences(of: "harbour", with: "Hafen")) })
    }

    /// The text the article's view shows. Its page's JavaScript is off, so it is read in the app's own world.
    private func shownText(of article: BrowserPage) async -> String {
        (try? await article.evaluateJavaScript("document.body.innerText", in: nil, contentWorld: .defaultClient)) as? String ?? ""
    }

    private func pageText(of tab: BrowserTab) async throws -> String {
        try #require(try await tab.page.evaluateJavaScript("document.body.innerText") as? String)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.lowercased().components(separatedBy: needle).count - 1
    }

    /// Translate Page translates the article and Show Original brings its text back, with the page behind it left alone. The
    /// article's view runs no JavaScript of the page's; the translation runs in its own world.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func translatePageAndShowOriginalActOnTheArticleWhileReaderShowsIt(engine: BrowserEngine) async throws {
        try await withTab(engine: engine, routes: articleRoutes, start: "/news/tide") { tab, _ in
            try await withReader(on: tab) { article in
                let translation = tab.shownTranslation
                #expect(translation === tab.reader.translation, "engine \(engine)")
                #expect(tab.translatedPage === article)
                #expect(tab.canTranslateShown)
                #expect(tab.canToggleTranslation)

                let request = translation.begin(to: Self.english)
                translation.translate(request, in: article) { Self.germanised($0) }

                #expect(await waitUntil { await shownText(of: article).contains("Hafen") }, "engine \(engine)")
                #expect(await waitUntil { translation.phase == .translated })
                let hidden = try await pageText(of: tab)
                #expect(hidden.contains("harbour") && !hidden.contains("Hafen"), "the page behind Reader was translated")
                #expect(tab.translation.phase == .original)

                AppCoordinator().showOriginal(tab)

                #expect(await waitUntil { !(await shownText(of: article)).contains("Hafen") }, "engine \(engine)")
                #expect(await shownText(of: article).contains("harbour"))
                #expect(!translation.isActive)

                tab.reader.close()
                #expect(tab.shownTranslation === tab.translation, "leaving Reader returns to the page")
                #expect(tab.translatedPage === tab.liveView)
                #expect(!tab.reader.translation.isActive)
            }
        }
    }

    /// Asking for a translation reads the language of what is shown: the article, not the page behind it.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func askingForATranslationReadsTheArticleAndNotThePage(engine: BrowserEngine) async throws {
        try await withTab(engine: engine, routes: articleRoutes, start: "/news/tide") { tab, _ in
            try await withReader(on: tab) { _ in
                #expect(!tab.translation.hasDetected)

                // The article is already English, so this ends before any model is needed, but only after reading it.
                #expect(await tab.translate(to: Self.english, downloading: nil) == false)

                #expect(tab.reader.translation.detectedLanguage.map(TranslationLanguage.key) == "en", "engine \(engine)")
                #expect(!tab.translation.hasDetected, "the page behind Reader was read")
            }
        }
    }

    /// Find counts the matches in the article, whose JavaScript is off, and clears its highlight; once Reader is left, Find
    /// searches the page again.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func findCountsInTheArticleAndReturnsToThePageWhenReaderEnds(engine: BrowserEngine) async throws {
        try await withTab(engine: engine, routes: articleRoutes, start: "/news/tide") { tab, _ in
            try await withReader(on: tab) { article in
                let expected = occurrences(of: "tide clock", in: await shownText(of: article))
                try #require(expected > 1)

                tab.find.open()
                tab.find.query = "Tide Clock"
                tab.find.queryDidChange()
                #expect(await waitUntil { tab.find.totalMatches == expected }, "engine \(engine): \(tab.find.totalMatches) of \(expected)")

                tab.find.query = "newsletter"
                tab.find.queryDidChange()
                #expect(await waitUntil { tab.find.totalMatches == 0 }, "the sidebar is not part of the article")

                _ = try await article.evaluateJavaScript(
                    "getSelection().selectAllChildren(document.body); 1", in: nil, contentWorld: .defaultClient
                )
                tab.find.driver?.clearHighlight()
                #expect(await waitUntil {
                    (try? await article.evaluateJavaScript("getSelection().toString()", in: nil, contentWorld: .defaultClient)) as? String == ""
                }, "the highlight stayed")

                tab.find.close()
                tab.reader.close()
            }

            #expect(tab.shownPage === tab.page)
            tab.find.open()
            tab.find.query = "newsletter"
            tab.find.queryDidChange()
            #expect(await waitUntil { tab.find.totalMatches == 1 }, "engine \(engine): \(tab.find.totalMatches)")
            tab.find.close()
        }
    }

    /// The Translate Page command follows what is shown: the page's translation, then the article's while Reader has a view.
    @Test(.boundedWebViews) func theTranslateCommandFollowsWhatIsShown() async throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.title == String(localized: "Translate Page") })
        let tab = coordinator.browser.newTab()
        defer { coordinator.browser.closeAllTabs(saving: false) }
        let articlePage = BrowserPage(
            webKit: ReaderPageController.makeWebView(dataStore: tab.context.dataStore), context: tab.context
        )
        tab.reader.driver = StubReader().driver

        #expect(!menu.validateMenuItem(item), "a new tab holds no web page")
        _ = tab.translation.begin(to: Self.english)
        #expect(menu.validateMenuItem(item))
        #expect(item.title == String(localized: "Show Original"), "the page is translated")

        #expect(await tab.reader.open())
        #expect(!menu.validateMenuItem(item), "Reader has no view yet")
        #expect(item.title == String(localized: "Translate Page"), "what is shown is not translated")

        tab.reader.presentedPage = articlePage
        #expect(menu.validateMenuItem(item), "the article can be translated though the page behind it is")
        #expect(item.title == String(localized: "Translate Page"))
        _ = tab.reader.translation.begin(to: Self.english)
        #expect(menu.validateMenuItem(item))
        #expect(item.title == String(localized: "Show Original"))

        tab.reader.close()
        #expect(menu.validateMenuItem(item))
        #expect(item.title == String(localized: "Show Original"), "the page is still translated")
        #expect(!tab.reader.translation.isActive, "the article's translation ended with Reader")
        await articlePage.close()
    }

    /// A new view of the article, as when the tab is brought back to the front, starts from the original text.
    @Test(.boundedWebViews) func aNewArticleViewForgetsWhatWasTranslatedInTheOldOne() async {
        let tab = BrowserTab(context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        let first = BrowserPage(webKit: ReaderPageController.makeWebView(dataStore: tab.context.dataStore), context: tab.context)
        let second = BrowserPage(webKit: ReaderPageController.makeWebView(dataStore: tab.context.dataStore), context: tab.context)
        tab.reader.driver = StubReader().driver
        #expect(await tab.reader.open())
        tab.reader.presentedPage = first
        _ = tab.shownTranslation.begin(to: Self.english)
        #expect(tab.shownTranslation.isActive)

        tab.reader.presentedPage = second
        #expect(!tab.shownTranslation.isActive)

        _ = tab.shownTranslation.begin(to: Self.english)
        tab.reader.presentedPage = second
        #expect(tab.shownTranslation.isActive, "the same view is the same text")

        tab.reader.pageChanged()
        #expect(!tab.reader.translation.isActive)
        await first.close()
        await second.close()
    }

    // MARK: Hosting

    private func host(_ tab: BrowserTab, showing article: ReaderArticle) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReaderSurface(tab: tab, article: article))
        window.orderBack(nil)
        return window
    }

    /// Opens Reader on `tab`, shows its view in a window and runs `body` with the page that shows the article.
    private func withReader(on tab: BrowserTab, body: (BrowserPage) async throws -> Void) async throws {
        tab.isFrontTab = { true }
        tab.probeReader()
        try #require(await waitUntil { tab.reader.availability == .available })
        try #require(await tab.reader.open())
        let article = try #require(tab.reader.article)
        let window = host(tab, showing: article)
        defer {
            window.contentView = nil
            window.close()
        }
        try #require(await waitUntil { tab.reader.presentedPage?.title == article.title }, "the article was not loaded")
        try await body(try #require(tab.reader.presentedPage))
    }

    /// A private tab of either engine showing a fixture page, in a window so Chromium loads it.
    private func withTab(
        engine: BrowserEngine,
        routes: [String: HTTPFixtureServer.Response],
        start: String,
        body: (BrowserTab, HTTPFixtureServer) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: routes)
        defer { withExtendedLifetime(server) {} }
        let url = try server.url(start)
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
        }
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let tab = BrowserTab(opensBlank: false, privately: true, context: context)
        tab.engineOverride = engine
        tab.load(url)
        let page = tab.page
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        do {
            #expect(page.engine == engine)
            try #require(await waitUntil { page.url == url && !page.isLoading && !tab.isLoading })
            try await body(tab, server)
        } catch {
            tab.detach()
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        tab.detach()
        await page.close()
        await context.endPrivateSession()
    }
}
