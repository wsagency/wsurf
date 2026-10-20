// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Page translation reads and replaces text through `BrowserPage`, in a content world of its own, in WebKit and Chromium alike.
/// No test here uses a language model: a stand-in translator rewrites the text, so the suite runs without language packs.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageTranslationScriptTests {
    private static func document(_ body: String, lang: String = "de") -> String {
        "<!doctype html><html lang=\"\(lang)\"><head><meta charset=\"utf-8\"><title>Nachrichten</title></head><body>\(body)</body></html>"
    }

    /// Paragraphs `Absatz 1` to `Absatz count`, each `height` points tall, so a test knows which are on screen.
    private static func paragraphs(_ count: Int, height: Int) -> String {
        (1...count).map { "<p id=\"p\($0)\" style=\"height: \(height)px; margin: 0\">Absatz \($0)</p>" }.joined()
    }

    private func text(_ script: String, in page: BrowserPage) async throws -> String? {
        try await page.evaluateJavaScript(script) as? String
    }

    // MARK: Reading the page

    @Test(arguments: BrowserEngine.allCases)
    func sampleReadsTheDeclaredLanguageAndTheText(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.document("<p>Guten Morgen, liebe Leserinnen und Leser.</p>")) { page in
            let sample = try #require(await PageTranslationScript.sample(in: page), "engine \(engine)")

            #expect(sample.declaredLanguage == "de")
            #expect(sample.text.hasPrefix("Nachrichten\n"), "\(sample.text)")
            #expect(sample.text.contains("Guten Morgen, liebe Leserinnen und Leser."))
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func scriptGroupsInlineTextAndSkipsCodeAndOptOuts(engine: BrowserEngine) async throws {
        let html = Self.document(#"""
        <p id="lead">Klicken Sie <a href="/x">hier</a>, um <b>fortzufahren</b>.</p>
        <p>Erste Zeile<br>Zweite Zeile</p>
        <p>Bitte <a href="/a">hier</a> <b>jetzt</b> klicken</p>
        <pre>let wert = 1</pre><code>wert()</code><p translate="no">WSurf</p><p class="notranslate">WSurf</p>
        <div contenteditable="true">Entwurf</div>
        <script>var text = "nicht übersetzen";</script><p>1234</p>
        """#)
        try await withPage(engine: engine, html: html) { page in
            let token = try #require(await PageTranslationScript.start(in: page), "engine \(engine)")
            let blocks = try #require(await PageTranslationScript.next(limit: 10, token: token, in: page))

            #expect(blocks.texts == [
                "Klicken Sie hier, um fortzufahren.", "Erste Zeile", "Zweite Zeile", "Bitte hier jetzt klicken",
            ], "engine \(engine)")
            #expect(blocks.blocks.first?.count == 5)
        }
    }

    // MARK: Replacing and restoring

    @Test(arguments: BrowserEngine.allCases)
    func applyReplacesTextAndRestoreBringsBackTheOriginal(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.document(#"<p id="lead">Klicken Sie <a href="/x">hier</a>.</p>"#)) { page in
            let token = try #require(await PageTranslationScript.start(in: page))
            let segments = try #require(await PageTranslationScript.next(limit: 4, token: token, in: page)?.blocks.first)
            let nodes = segments.map(\.node)
            try #require(nodes.count == 3)

            await PageTranslationScript.apply([nodes[0]: "Click ", nodes[1]: "here", nodes[2]: "."], in: page)
            #expect(try await text("document.getElementById('lead').textContent", in: page) == "Click here.", "engine \(engine)")
            #expect(try await text("document.querySelector('#lead a').getAttribute('href')", in: page) == "/x")

            await PageTranslationScript.restore(in: page)
            #expect(try await text("document.getElementById('lead').textContent", in: page) == "Klicken Sie hier.", "engine \(engine)")
            #expect(await PageTranslationScript.next(limit: 4, token: token, in: page) == nil)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func restoreLeavesTextThePageChangedItself(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.document(#"<p id="lead">Guten Morgen</p>"#)) { page in
            let token = try #require(await PageTranslationScript.start(in: page))
            let node = try #require(await PageTranslationScript.next(limit: 4, token: token, in: page)?.blocks.first?.first?.node)
            await PageTranslationScript.apply([node: "Good morning"], in: page)
            _ = try await page.evaluateJavaScript("document.getElementById('lead').firstChild.nodeValue = 'Guten Abend'")

            await PageTranslationScript.restore(in: page)

            #expect(try await text("document.getElementById('lead').textContent", in: page) == "Guten Abend", "engine \(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func restartingRetiresTheEarlierRun(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.document("<p>Erster Absatz</p><p>Zweiter Absatz</p>")) { page in
            let first = try #require(await PageTranslationScript.start(in: page))
            let second = try #require(await PageTranslationScript.start(in: page))

            #expect(second != first)
            #expect(await PageTranslationScript.next(limit: 4, token: first, in: page) == nil, "engine \(engine)")
            let blocks = try #require(await PageTranslationScript.next(limit: 4, token: second, in: page))
            #expect(blocks.texts == ["Erster Absatz", "Zweiter Absatz"])
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func contentAddedLaterIsPickedUp(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.document("<p>Erster Absatz</p><div id='feed'></div>")) { page in
            let token = try #require(await PageTranslationScript.start(in: page))
            _ = await PageTranslationScript.next(limit: 4, token: token, in: page)

            let waiting = Task { @MainActor in await PageTranslationScript.next(limit: 4, token: token, in: page) }
            _ = try await page.evaluateJavaScript("document.getElementById('feed').innerHTML = '<p>Neuer <i>Beitrag</i></p>'; 1")

            let blocks = try #require(await waiting.value, "engine \(engine)")
            #expect(blocks.texts == ["Neuer Beitrag"])
        }
    }

    // MARK: The viewport first

    @Test(arguments: BrowserEngine.allCases)
    func visibleBlocksComeFirst(engine: BrowserEngine) async throws {
        let html = Self.document(#"<p style="position: absolute; top: 2500px">Weit unten</p><p>Ganz oben</p>"#)
        try await withPage(engine: engine, html: html) { page in
            let token = try #require(await PageTranslationScript.start(in: page))
            let blocks = try #require(await PageTranslationScript.next(limit: 1, token: token, in: page))

            #expect(blocks.texts == ["Ganz oben"], "engine \(engine)")
        }
    }

    /// The order follows the viewport during a run: after a scroll, the next batch starts where the person is reading, and what
    /// was scrolled past comes after everything below.
    @Test(arguments: BrowserEngine.allCases)
    func scrollingBringsTheNewViewportForward(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.document(Self.paragraphs(40, height: 200))) { page in
            let token = try #require(await PageTranslationScript.start(in: page))
            let top = try #require(await PageTranslationScript.next(limit: 1, token: token, in: page))
            #expect(top.texts == ["Absatz 1"], "engine \(engine)")

            _ = try await page.evaluateJavaScript("document.getElementById('p30').scrollIntoView(); window.scrollY")
            let moved = try #require(await PageTranslationScript.next(limit: 2, token: token, in: page))

            #expect(moved.texts == ["Absatz 30", "Absatz 31"], "engine \(engine)")
        }
    }

    /// A long page is translated a batch at a time, starting on screen, and every block is translated exactly once.
    @Test(arguments: BrowserEngine.allCases)
    func aLongPageIsTranslatedOnceStartingOnScreenAndShowOriginalRestoresIt(engine: BrowserEngine) async throws {
        let count = 120
        try await withPage(engine: engine, html: Self.document(Self.paragraphs(count, height: 100))) { page in
            _ = try await page.evaluateJavaScript("document.getElementById('p60').scrollIntoView(); window.scrollY")
            var translated: [String] = []
            var largestBlock = 0
            let translation = PageTranslation()
            let request = translation.begin(to: Locale.Language(identifier: "en"))

            translation.translate(request, in: page) { segments in
                translated.append(segments.map(\.text).joined())
                largestBlock = max(largestBlock, segments.count)
                return Dictionary(uniqueKeysWithValues: segments.map {
                    ($0.node, $0.text.replacingOccurrences(of: "Absatz", with: "Paragraph"))
                })
            }

            let untranslated = "Array.from(document.querySelectorAll('p')).filter(p => !p.textContent.startsWith('Paragraph')).length"
            #expect(await waitUntil { (try? await page.evaluateJavaScript(untranslated) as? Int) == 0 }, "engine \(engine)")
            #expect(translation.phase == .translated)
            #expect(translated.count == count, "\(translated.count) blocks translated")
            #expect(Set(translated).count == count, "a block was translated twice")
            #expect(largestBlock == 1)
            #expect(translated.first == "Absatz 60", "the first block was \(translated.first ?? "none")")
            #expect(translated.prefix(PageTranslation.batchSize).allSatisfy { ($0.split(separator: " ").last.flatMap { Int($0) } ?? 0) >= 60 })

            translation.showOriginal(in: page)

            let original = "Array.from(document.querySelectorAll('p')).filter(p => !p.textContent.startsWith('Absatz')).length"
            #expect(await waitUntil { (try? await page.evaluateJavaScript(original) as? Int) == 0 }, "engine \(engine)")
            #expect(translation.phase == .original)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aRunWhoseBlocksAllFailShowsTheOriginal(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.document("<p>Erster Absatz</p><p>Zweiter Absatz</p>")) { page in
            let translation = PageTranslation()
            let request = translation.begin(to: Locale.Language(identifier: "en"))

            translation.translate(request, in: page) { _ in nil }

            #expect(await waitUntil { translation.phase == .original }, "engine \(engine)")
            #expect(try await text("document.body.textContent", in: page) == "Erster AbsatzZweiter Absatz")
        }
    }

    // MARK: The world

    @Test(arguments: BrowserEngine.allCases)
    func thePageCannotSeeOrChangeTheTranslator(engine: BrowserEngine) async throws {
        let hostile = #"""
        <script>
        window.fakeCalls = 0;
        Array.prototype.some = function () { window.fakeCalls += 1; return false; };
        String.prototype.replace = function () { window.fakeCalls += 1; return 'HIJACKED'; };
        JSON.stringify = () => { window.fakeCalls += 1; return '{"done":true}'; };
        </script><p id="lead">Guten Morgen</p>
        """#
        try await withPage(engine: engine, html: Self.document(hostile)) { page in
            let token = try #require(await PageTranslationScript.start(in: page), "engine \(engine)")
            let blocks = try #require(await PageTranslationScript.next(limit: 4, token: token, in: page))
            #expect(blocks.texts == ["Guten Morgen"])

            let seen = try await page.evaluateJavaScript("[typeof __wsurfTranslate, window.fakeCalls].join()") as? String
            #expect(seen == "undefined,0", "engine \(engine): \(seen ?? "nothing")")
        }
    }

    // MARK: Pages

    private func withPage(engine: BrowserEngine, html: String, body: (BrowserPage) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/news": .html(html)])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/news")
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
        defer {
            window.contentView = nil
            window.close()
        }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
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
