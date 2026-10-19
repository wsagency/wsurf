// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A page and whether Reader should be offered on it.
nonisolated struct ReaderDetectionCase: Sendable, CustomTestStringConvertible {
    let name: String
    let path: String
    let html: String
    let readerable: Bool

    var testDescription: String {
        name
    }
}

/// Pages for Reader tests, served by `HTTPFixtureServer`.
nonisolated enum ReaderFixtures {
    /// A paragraph of about 330 characters, numbered so a test can tell which survived.
    static func paragraph(_ number: Int) -> String {
        "Paragraph \(number) of the harbour survey records how the old tide clock kept every ferry on time for nine decades, with crews "
            + "reading the brass dial each morning before the first crossing of the day; engineers later measured the drift of the "
            + "mechanism at under four seconds a year, which surprised everyone who had assumed that the salt air would ruin it."
    }

    /// The six paragraphs as a JavaScript string literal, for a page that adds them later.
    static var scriptedParagraphs: String {
        let html = (1...6).map { "<p>\(paragraph($0))</p>" }.joined()
        return "'" + html.replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A news article with a byline, navigation, a sidebar and a footer around it, and a few things Reader must not pass on. The
    /// page runs its own script and its image fails to load once, each counted in the page; Reader must not run either again.
    static func article(head: String = "") -> String {
        let paragraphs = (1...6).map { "<p>\(paragraph($0))</p>" }.joined(separator: "\n")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <title>How the harbour learned to read the tide - Harbor Gazette</title>
        <meta property="og:type" content="article"><meta property="og:site_name" content="Harbor Gazette">
        \(head)
        </head><body>
        <header><nav><a href="/">Home</a> <a href="/world">World</a> <a href="/sport">Sport</a></nav></header>
        <div class="ad" id="banner">Buy now! Limited offer!</div>
        <article>
        <h1>How the harbour learned to read the tide</h1>
        <p class="byline">By <a rel="author" href="/people/ana">Ana Marek</a></p>
        \(paragraphs)
        <p onclick="window.clicks = (window.clicks || 0) + 1">\(paragraph(7))</p>
        <p><a href="javascript:window.clicks = (window.clicks || 0) + 1">\(paragraph(8))</a></p>
        <img src="/tide.png" alt="The clock" onerror="window.imageErrors = (window.imageErrors || 0) + 1">
        <script>window.pageScriptRuns = (window.pageScriptRuns || 0) + 1</script>
        <form action="/pay"><input name="card"><button>Pay</button></form>
        </article>
        <aside class="sidebar"><p>Subscribe to the newsletter and never miss a story from the harbour.</p></aside>
        <footer><p>Copyright Harbor Gazette</p></footer>
        </body></html>
        """
    }

    /// A sign-in page: links and a form around a few words.
    static let signIn = """
    <!doctype html><html><head><title>Sign in</title></head><body>
    <nav><a href="/">Home</a></nav>
    <form><label>Email <input type="email"></label><button>Next</button></form>
    <p>Forgot your password?</p>
    </body></html>
    """

    private static let river = String(
        repeating: "The river kept its slow pace through the valley while the town woke around it. ", count: 6
    )
    private static let longBody = String(repeating: "<p>\(river)</p>", count: 4)
    private static let thinBody = "<p>\(river.prefix(250))</p>"
    private static let articleMetadata = #"<meta property="og:type" content="article">"#
    private static let newsArticle = #"<script type="application/ld+json">{"@graph":[{"@type":["NewsArticle"]}]}</script>"#

    private static func page(head: String = "", body: String) -> String {
        #"<!doctype html><html lang="en"><head><title>Page</title>\#(head)</head><body>\#(body)</body></html>"#
    }

    /// What decides whether a page is an article: the text that is on screen, metadata for a short story or a site's home page,
    /// and a list of articles, which is not one.
    static let detection: [ReaderDetectionCase] = [
        ReaderDetectionCase(name: "a home page without article metadata", path: "/", html: page(body: longBody), readerable: false),
        ReaderDetectionCase(
            name: "a home page that says it is an article", path: "/", html: page(head: articleMetadata, body: longBody), readerable: true),
        ReaderDetectionCase(name: "a short story without metadata", path: "/story", html: page(body: thinBody), readerable: false),
        ReaderDetectionCase(
            name: "a short story with article metadata", path: "/story", html: page(head: newsArticle, body: thinBody), readerable: true),
        ReaderDetectionCase(
            name: "text that is not on screen", path: "/login",
            html: page(body: """
            <style>.consent { display: none; } .drawer { width: 0; overflow: hidden; }</style>
            <div class="consent">\(longBody)</div>
            <div class="drawer">\(longBody)</div>
            <p style="opacity: 0">\(river)</p>
            <form><p>Sign in</p></form>
            """),
            readerable: false),
        ReaderDetectionCase(
            name: "a list of articles", path: "/results",
            html: page(body: String(repeating: "<article><a href=\"https://example.org\">Result</a> \(river)</article>", count: 10)),
            readerable: false),
        ReaderDetectionCase(
            name: "a story with related cards", path: "/story",
            html: page(body: "<article>\(longBody)</article><aside>\(String(repeating: "<article><a href=\"/other\">\(river)</a></article>", count: 2))</aside>"),
            readerable: true),
    ]

    /// An article of at least `bytes` bytes, in sections.
    static func longArticle(bytes: Int) -> String {
        var body = ""
        var number = 0
        while body.utf8.count < bytes {
            number += 1
            if number % 25 == 1 {
                body += "<h2>Chapter \(number / 25 + 1)</h2>\n"
            }
            body += "<p>\(paragraph(number)) Entry \(number * 7919 % 10_007) closes the page.</p>\n"
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <title>The complete record of the tide clock - Harbor Gazette</title>
        <meta property="og:type" content="article"><meta property="og:site_name" content="Harbor Gazette">
        </head><body><article><h1>The complete record of the tide clock</h1>
        <p class="byline">By <a rel="author" href="/people/ana">Ana Marek</a></p>
        \(body)</article></body></html>
        """
    }
}

/// Reader finds the article on a page through `BrowserPage`, in a content world of its own, in WebKit and Chromium alike.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ReaderExtractorTests {
    // MARK: Scripts

    /// `Tools/vendored/readability/SHA256SUMS`, by file name.
    private func recordedSums() throws -> [String: String] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "Tools/vendored/readability/SHA256SUMS"), encoding: .utf8)
        var sums: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            sums[URL(filePath: path).lastPathComponent] = String(parts[0])
        }
        return sums
    }

    @Test func bothScriptsLoadFromTheMainBundleAndAreTheRecordedRelease() throws {
        let sums = try recordedSums()
        #expect(sums["LICENSE.md"] != nil)
        for name in ["Readability", "Readability-readerable"] {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "js"), "\(name).js is not in the app bundle")
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == sums["\(name).js"], "\(name).js is not the recorded Readability 0.6.0")
        }
    }

    @Test func onlyWebPagesAreEligible() throws {
        #expect(ReaderExtractor.isEligible(try #require(URL(string: "https://example.test/a"))))
        #expect(ReaderExtractor.isEligible(try #require(URL(string: "HTTP://example.test/a"))))
        #expect(!ReaderExtractor.isEligible(try #require(URL(string: "file:///tmp/a.html"))))
        #expect(!ReaderExtractor.isEligible(try #require(URL(string: "about:blank"))))
        #expect(!ReaderExtractor.isEligible(try #require(URL(string: "wsurf://start"))))
    }

    @Test func theCeilingsAreFiveSecondsToAnswerAndTenToWatch() {
        #expect(ReaderExtractor.replyCeiling == .seconds(5))
        #expect(ReaderExtractor.watchWindow == .seconds(10))
    }

    // MARK: The article

    @Test func anArticleIsDecodedFromTheScriptsAnswer() throws {
        let json = #"{"url":"https://example.test/a","title":" T ","byline":"B","content":"<p>One</p>","blocks":["One","Two three"],"dir":"RTL","lang":"hr"}"#
        let article = try #require(ReaderArticle(json: json))
        #expect(article.title == "T")
        #expect(article.language == "hr")
        #expect(article.isRightToLeft)
        #expect(article.text == "One\n\nTwo three")
        #expect(article.wordCount == 3)
        #expect(ReaderArticle(json: #"{"url":"https://example.test/a","content":"<p></p>","blocks":[]}"#) == nil)
        #expect(ReaderArticle(json: "") == nil)
    }

    @Test func aDriverWithoutAPageAnswersNothing() async {
        let driver = ReaderDriver.page { nil }

        #expect(!(await driver.probe()))
        #expect(!(await driver.watch()))
        #expect(await driver.extract() == nil)
    }

    @Test(arguments: BrowserEngine.allCases)
    func anArticleIsFoundAndExtractedInEitherEngine(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/news/tide": .html(ReaderFixtures.article())])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/news/tide")
        try await withPage(engine: engine, url: url) { page in
            let driver = ReaderDriver.page { page }
            #expect(page.isPrivate)
            let countersScript = "[window.pageScriptRuns ?? 0, window.imageErrors ?? 0, window.clicks ?? 0].join()"
            let before = try await page.evaluateJavaScript(countersScript) as? String
            #expect(before == "1,1,0", "the page ran its own script and handler once, \(before ?? "nothing")")
            #expect(await driver.probe(), "engine \(engine)")

            let article = try #require(await driver.extract(), "engine \(engine)")

            #expect(article.url.absoluteString == url.absoluteString)
            #expect(article.title.hasPrefix("How the harbour learned to read the tide"), "\(article.title)")
            #expect(article.byline.contains("Ana Marek"), "\(article.byline)")
            #expect(article.siteName == "Harbor Gazette")
            #expect(article.language == "en")
            #expect(!article.isRightToLeft)
            #expect(article.blocks.count >= 8, "\(article.blocks.count) blocks")
            for number in [1, 6, 7, 8] {
                #expect(article.blocks.contains { $0.hasPrefix("Paragraph \(number) ") }, "paragraph \(number)")
            }
            #expect(!article.text.contains("Subscribe"))
            #expect(!article.text.contains("Buy now"))
            #expect(!article.text.contains("Copyright"))
            #expect(article.content.contains(#"data-reader-block="0""#))
            for unsafe in ["onclick", "onerror", "javascript:", "<script", "<form", "<input", "<button"] {
                #expect(!article.content.contains(unsafe), "\(unsafe) reached the article")
            }
            // Reader worked on a copy: the article's script and handlers did not run again, and what it left out is still on the page.
            let after = try await page.evaluateJavaScript(countersScript) as? String
            let banner = try await page.evaluateJavaScript("document.getElementById('banner') !== null") as? Bool
            #expect(after == "1,1,0", "probe and extraction ran the article's script or handlers, \(after ?? "nothing")")
            #expect(banner == true)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPageThatIsNotAnArticleIsNotOfferedToReader(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/login": .html(ReaderFixtures.signIn),
            "/blank": .html("<!doctype html><title>Blank</title><body></body>"),
        ])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url("/login")) { page in
            #expect(!(await ReaderExtractor.isReaderable(page)), "engine \(engine)")
            #expect(!(await ReaderExtractor.becomesReaderable(page, within: .seconds(1))), "engine \(engine)")
        }
        try await withPage(engine: engine, url: server.url("/blank")) { page in
            #expect(await ReaderExtractor.article(in: page) == nil, "engine \(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases, ReaderFixtures.detection)
    func aPageIsOfferedToReaderOnlyWhenItHoldsAnArticle(engine: BrowserEngine, fixture: ReaderDetectionCase) async throws {
        let server = try await HTTPFixtureServer.start(routes: [fixture.path: .html(fixture.html)])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url(fixture.path)) { page in
            #expect(await ReaderExtractor.isReaderable(page) == fixture.readerable, "\(fixture.name) in \(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPageThatBecomesAnArticleIsNoticedWhileWatching(engine: BrowserEngine) async throws {
        let late = """
        <!doctype html><html lang="en"><head><title>Loading the tide report</title>
        <meta property="og:type" content="article"></head><body><article id="story"><p>Loading.</p></article>
        <script>
        function appendStory() {
          document.getElementById('story').insertAdjacentHTML('beforeend', \(ReaderFixtures.scriptedParagraphs));
        }
        </script></body></html>
        """
        let server = try await HTTPFixtureServer.start(routes: ["/news/late": .html(late)])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url("/news/late")) { page in
            #expect(!(await ReaderExtractor.isReaderable(page)), "engine \(engine)")
            let watching = Task { @MainActor in await ReaderExtractor.becomesReaderable(page, within: .seconds(8)) }

            _ = try await page.evaluateJavaScript("appendStory(); 1")

            #expect(await watching.value, "engine \(engine)")
        }
    }

    // MARK: The world

    @Test(arguments: BrowserEngine.allCases)
    func thePageCannotSeeReadability(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/news/tide": .html(ReaderFixtures.article())])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url("/news/tide")) { page in
            #expect(await ReaderExtractor.isReaderable(page))
            #expect(await ReaderExtractor.article(in: page) != nil)

            let seen = try await page.evaluateJavaScript(
                "[typeof Readability, typeof isProbablyReaderable, typeof isNodeVisible, typeof readerIsReaderable, typeof REGEXPS].join()"
            )

            #expect(seen as? String == "undefined,undefined,undefined,undefined,undefined", "engine \(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPageCannotChangeWhatReaderRuns(engine: BrowserEngine) async throws {
        let hostile = """
        <script>
        window.fakeCalls = 0;
        window.Readability = class { parse() { window.fakeCalls += 1; return { title: 'HIJACKED', content: '<p>HIJACKED</p>', textContent: 'HIJACKED' }; } };
        window.isProbablyReaderable = () => { window.fakeCalls += 1; return false; };
        JSON.stringify = () => { window.fakeCalls += 1; return '{"url":"x","content":"<p>HIJACKED</p>","blocks":["HIJACKED"]}'; };
        Array.prototype.some = function () { window.fakeCalls += 1; return false; };
        </script>
        """
        let server = try await HTTPFixtureServer.start(routes: ["/news/tide": .html(ReaderFixtures.article(head: hostile))])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url("/news/tide")) { page in
            #expect(await ReaderExtractor.isReaderable(page), "engine \(engine)")
            let article = try #require(await ReaderExtractor.article(in: page), "engine \(engine)")

            #expect(article.title.hasPrefix("How the harbour learned to read the tide"))
            #expect(!article.text.contains("HIJACKED"))
            let fakeCalls = try await page.evaluateJavaScript("window.fakeCalls") as? Int
            #expect(fakeCalls == 0, "the page's replacements ran")
        }
    }

    // MARK: A page that does not answer

    /// The document stays in `loading` because a script it waits for never arrives, so the probe, which waits for the
    /// document to load, never answers.
    @Test(arguments: BrowserEngine.allCases)
    func aProbeThatIsNeverAnsweredGivesUpAtTheCeiling(engine: BrowserEngine) async throws {
        let gate = ResponseGate()
        let server = try await HTTPFixtureServer.start(routes: [
            "/news/stuck": .html(ReaderFixtures.article(head: #"<script src="/never.js"></script>"#)),
            "/never.js": .html("", gate: gate),
        ])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url("/news/stuck"), waitsForLoad: false) { page in
            #expect(await gate.waitForRequest())
            let state = try await page.evaluateJavaScript("document.readyState") as? String
            #expect(state == "loading", "the page finished loading")

            let began = ContinuousClock.now
            let readerable = await ReaderExtractor.isReaderable(page, within: .milliseconds(500))

            #expect(!readerable, "engine \(engine)")
            #expect(began.duration(to: .now) < .seconds(4), "the caller waited for the page, not the ceiling")
        }
    }

    /// A script that never returns keeps the web-content process busy for good. The caller must still be released, and the
    /// page must not be held by the call that is still waiting.
    @Test func anArticleThatIsNeverAnsweredIsNilAtTheCeilingAndDoesNotHoldThePage() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/news/tide": .html(ReaderFixtures.article())])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/news/tide")
        weak var releasedPage: BrowserPage?
        weak var releasedView: WKWebView?
        var article: ReaderArticle? = ReaderArticle(url: url, title: "unset", content: "", blocks: ["unset"])
        var waited = Duration.zero
        do {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration),
                context: BrowserProfileContext(profile: .privateBrowsing())
            )
            releasedPage = page
            releasedView = page.webKit
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            _ = try await page.evaluateJavaScript("setTimeout(() => { while (true) {} }, 0); 1")
            let began = ContinuousClock.now

            article = await ReaderExtractor.article(in: page, within: .milliseconds(300))

            waited = began.duration(to: .now)
        }

        #expect(article == nil)
        #expect(waited < .seconds(3), "the caller waited for the page, not the ceiling")
        #expect(await waitUntil { releasedPage == nil && releasedView == nil }, "the pending call kept the page")
    }

    // MARK: Pages

    private func withPage(
        engine: BrowserEngine, url: URL, waitsForLoad: Bool = true, body: (BrowserPage) async throws -> Void
    ) async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration),
                context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && (!waitsForLoad || !page.isLoading) })
            try await body(page)
        } catch {
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        await page.close()
        await context.endPrivateSession()
    }
}
