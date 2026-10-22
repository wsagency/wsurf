// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A page's answers to Reader, counted, so a test can drive a session without a web view.
@MainActor
final class StubReader {
    var article: ReaderArticle? = ReaderArticle(
        url: URL(filePath: "/story"), title: "The tide clock", content: "<p data-reader-block=\"0\">Body</p>", blocks: ["Body"]
    )
    var isReaderable = true
    private(set) var probes = 0

    var driver: ReaderDriver {
        ReaderDriver(
            probe: { [self] in
                probes += 1
                return isReaderable
            },
            extract: { [self] in article }
        )
    }
}

/// Holds an answer back until the test lets it through.
@MainActor
final class ReaderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// One tab's Reader: what is known about its page, and what ends it.
@MainActor
struct ReaderSessionTests {
    @Test func aPageThatHoldsAnArticleBecomesAvailable() async {
        let stub = StubReader()
        let session = ReaderSession()
        session.driver = stub.driver
        #expect(!session.isAvailable)

        await session.probe()

        #expect(session.availability == .available)
        #expect(session.isAvailable)
        #expect(stub.probes == 1)
    }

    @Test func aPageThatDoesNotIsAskedAgainBeforeReaderGivesUp() async {
        let stub = StubReader()
        stub.isReaderable = false
        let session = ReaderSession()
        session.retryDelay = .milliseconds(1)
        session.driver = stub.driver

        await session.probe()

        #expect(session.availability == .unavailable)
        #expect(!session.isAvailable)
        #expect(stub.probes == 2)
    }

    @Test func openingShowsTheArticleAndClosingHidesIt() async {
        let stub = StubReader()
        let session = ReaderSession()
        session.driver = stub.driver

        #expect(await session.open())
        #expect(session.isActive)
        #expect(session.article == stub.article)
        #expect(session.isAvailable)

        session.close()
        #expect(!session.isActive)
        #expect(session.article == nil, "the next opening reads the page again")
        #expect(session.isAvailable, "the page still holds the article")

        session.toggle()
        #expect(await waitUntil { session.isActive })
        session.toggle()
        #expect(!session.isActive)
    }

    /// The page keeps the tab's translation; the article has its own, which ends with Reader, however Reader ends.
    @Test func theArticlesTranslationEndsWithReader() async {
        let session = ReaderSession()
        session.driver = StubReader().driver
        let english = Locale.Language(identifier: "en")

        for end in [{ session.close() }, { session.pageChanged() }] {
            #expect(await session.open())
            _ = session.translation.begin(to: english)
            #expect(session.translation.isActive)

            end()

            #expect(!session.translation.isActive)
            #expect(session.translation.target == nil)
        }
    }

    @Test func aPageWithoutAnArticleCannotBeOpened() async {
        let stub = StubReader()
        stub.article = nil
        let session = ReaderSession()
        session.driver = stub.driver

        #expect(await session.open() == false)

        #expect(!session.isActive)
        #expect(session.availability == .unavailable)
    }

    @Test func aNavigationEndsReaderAndForgetsTheArticle() async {
        let stub = StubReader()
        let session = ReaderSession()
        session.driver = stub.driver
        #expect(await session.open())
        let generation = session.generation

        session.pageChanged()

        #expect(!session.isActive)
        #expect(session.article == nil)
        #expect(session.availability == .unknown)
        #expect(!session.isAvailable)
        #expect(session.generation != generation)
    }

    @Test func anAnswerAboutAnEarlierPageIsDropped() async throws {
        let gate = ReaderGate()
        let session = ReaderSession()
        session.driver = ReaderDriver(
            probe: {
                await gate.wait()
                return true
            },
            extract: { nil }
        )
        let probing = Task { await session.probe() }
        try #require(await waitUntil { gate.isWaiting })

        session.pageChanged()
        gate.open()
        await probing.value

        #expect(session.availability == .unknown)
    }

    @Test func anArticleThatArrivesAfterTheNavigationIsNotShown() async throws {
        let gate = ReaderGate()
        let stub = StubReader()
        let session = ReaderSession()
        session.driver = ReaderDriver(
            probe: { true },
            extract: {
                await gate.wait()
                return stub.article
            }
        )
        let opening = Task { await session.open() }
        try #require(await waitUntil { gate.isWaiting })
        #expect(session.isOpening)

        session.pageChanged()
        gate.open()

        #expect(await opening.value == false)
        #expect(!session.isActive)
        #expect(!session.isOpening)
        #expect(session.article == nil)
    }
}

/// The document Reader shows an article in, and the choices that dress it.
@MainActor
struct ReaderPageTests {
    private let article = ReaderArticle(
        url: URL(filePath: "/story"), title: "Tide <b>clock</b> & more", byline: "Ana", siteName: "Harbor", language: "hr",
        isRightToLeft: true, content: "<p data-reader-block=\"0\">Body</p>", blocks: ["Body"]
    )

    @Test func thePageAllowsNoScriptFrameOrForm() {
        let html = ReaderPage.html(for: article, typeface: .system, palette: .automatic, textSize: 19)

        #expect(
            ReaderPage.contentSecurityPolicy
                == "default-src 'none'; img-src https: http: data:; media-src https: http:; style-src 'unsafe-inline'"
        )
        #expect(html.contains(#"<meta http-equiv="Content-Security-Policy" content="\#(ReaderPage.contentSecurityPolicy)">"#))
    }

    @Test func theArticleIsSetInItsOwnLanguageAndDirection() {
        let html = ReaderPage.html(for: article, typeface: .georgia, palette: .sepia, textSize: 24)

        #expect(html.contains(#"lang="hr" dir="rtl""#))
        #expect(html.contains(#"data-typeface="georgia""#))
        #expect(html.contains(#"data-palette="sepia""#))
        #expect(html.contains("--size: 24px"))
        #expect(html.contains(#"<article><p data-reader-block="0">Body</p></article>"#))
    }

    @Test func theTitleIsText() {
        let html = ReaderPage.html(for: article, typeface: .system, palette: .light, textSize: 19)

        #expect(html.contains("<title>Tide &lt;b&gt;clock&lt;/b&gt; &amp; more</title>"))
        #expect(!html.contains("<b>clock</b>"))
    }

    @Test func aChangeOfLookDoesNotNeedANewPage() {
        let script = ReaderPage.appearanceScript(typeface: .charter, palette: .dark, textSize: 28)

        #expect(script.contains("dataset.typeface = 'charter'"))
        #expect(script.contains("dataset.palette = 'dark'"))
        #expect(script.contains("setProperty('--size', '28px')"))
    }
}

/// The look of the article is the person's choice for every tab and window, kept with the application's settings.
@MainActor
struct ReaderAppearanceSettingsTests {
    private func withSettings<T>(_ body: (BrowserSettings, UserDefaults) throws -> T) rethrows -> T {
        // ponytail-merge: test-hygiene routes every test suite through `defaultsSuite`; these wave-2a suites now do too.
        let suite = AppDatabase.defaultsSuite("ReaderAppearance-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return try body(BrowserSettings(defaults: defaults), defaults)
    }

    @Test func theLookStartsAsTheSystemTextOnAnAutomaticPage() {
        withSettings { settings, defaults in
            #expect(settings.readerTypeface == .system)
            #expect(settings.readerPalette == .automatic)
            #expect(settings.readerTextSize == ReaderAppearance.defaultTextSize)
            #expect(settings.isReaderAppearanceDefault)
            #expect(defaults.object(forKey: "reader.typeface") == nil, "reading a default writes nothing")
        }
    }

    @Test func theChoicesAreKeptInTheApplicationDefaults() {
        withSettings { settings, defaults in
            settings.readerTypeface = .charter
            settings.readerPalette = .sepia
            settings.readerTextSize = 24

            #expect(defaults.string(forKey: "reader.typeface") == "charter")
            #expect(defaults.string(forKey: "reader.theme") == "sepia")
            #expect(defaults.integer(forKey: "reader.textSize") == 24)
            let reopened = BrowserSettings(defaults: defaults)
            #expect(reopened.readerTypeface == .charter)
            #expect(reopened.readerPalette == .sepia)
            #expect(reopened.readerTextSize == 24)
            #expect(!reopened.isReaderAppearanceDefault)
        }
    }

    @Test func theTextSizeStaysBetweenFifteenAndThirtyTwo() {
        withSettings { settings, defaults in
            settings.readerTextSize = 100
            #expect(settings.readerTextSize == 32)
            #expect(defaults.integer(forKey: "reader.textSize") == 32)

            settings.readerTextSize = -4
            #expect(settings.readerTextSize == 15)
            #expect(BrowserSettings(defaults: defaults).readerTextSize == 15)
        }
    }

    @Test func aDamagedStoredChoiceIsRepaired() {
        withSettings { _, defaults in
            defaults.set(500, forKey: "reader.textSize")
            defaults.set("comic-sans", forKey: "reader.typeface")
            defaults.set("neon", forKey: "reader.theme")
            let repaired = BrowserSettings(defaults: defaults)

            #expect(repaired.readerTextSize == 32)
            #expect(repaired.readerTypeface == .system)
            #expect(repaired.readerPalette == .automatic)

            defaults.set(Double.nan, forKey: "reader.textSize")
            #expect(BrowserSettings(defaults: defaults).readerTextSize == ReaderAppearance.defaultTextSize)
            defaults.set("big", forKey: "reader.textSize")
            #expect(BrowserSettings(defaults: defaults).readerTextSize == ReaderAppearance.defaultTextSize)
        }
    }

    @Test func aWindowSettingsObjectFollowsTheApplicationLook() {
        let suites = (0..<2).map { AppDatabase.defaultsSuite("ReaderAppearance-\($0)-\(UUID().uuidString)") }
        let defaults = suites.compactMap { UserDefaults(suiteName: $0) }
        defer {
            for (suite, store) in zip(suites, defaults) {
                store.removePersistentDomain(forName: suite)
            }
        }
        let application = BrowserSettings(defaults: defaults[0])
        let window = BrowserSettings(defaults: defaults[0], sessionDefaults: defaults[1], application: application)

        window.readerTextSize = 28
        window.readerPalette = .dark

        #expect(application.readerTextSize == 28)
        #expect(application.readerPalette == .dark)
        #expect(defaults[1].object(forKey: "reader.textSize") == nil, "the profile's defaults hold none of it")
    }

    @Test func resettingRestoresTheLook() {
        withSettings { settings, _ in
            settings.readerTypeface = .times
            settings.readerPalette = .dark
            settings.readerTextSize = 32
            settings.resetReaderAppearance()

            #expect(settings.isReaderAppearanceDefault)

            settings.readerTextSize = 15
            settings.resetToDefaults()

            #expect(settings.readerTextSize == ReaderAppearance.defaultTextSize)
        }
    }

    @Test func theTextStepsThroughItsSizes() {
        #expect(ReaderAppearance.larger(than: 19) == 21)
        #expect(ReaderAppearance.smaller(than: 19) == 17)
        #expect(ReaderAppearance.larger(than: 32) == 32)
        #expect(ReaderAppearance.smaller(than: 15) == 15)
        #expect(ReaderAppearance.larger(than: 16) == 17, "a size between two steps goes to the next one")
        #expect(ReaderAppearance.smaller(than: 20) == 19)
    }

    @Test func anAutomaticPageFollowsTheWindow() {
        #expect(ReaderAppearance.Palette.automatic.resolved(isDark: true) == .dark)
        #expect(ReaderAppearance.Palette.automatic.resolved(isDark: false) == .light)
        #expect(ReaderAppearance.Palette.sepia.resolved(isDark: true) == .sepia)
    }
}

/// What Reader's view does with a navigation: it loads its own document once, hands links to the browser, and scrolls to a heading
/// of the article itself.
struct ReaderNavigationTests {
    private let article = URL(filePath: "/story")

    private func decision(
        _ url: URL?,
        type: WKNavigationType = .linkActivated,
        inSubframe: Bool = false,
        acceptsFirstLoad: Bool = false,
        modifiers: NSEvent.ModifierFlags = [],
        buttonNumber: Int = 0
    ) -> ReaderNavigation.Decision {
        ReaderNavigation.decision(
            for: url, type: type, inSubframe: inSubframe, article: article, acceptsFirstLoad: acceptsFirstLoad,
            modifiers: modifiers, buttonNumber: buttonNumber
        )
    }

    @Test func theDocumentReaderLoadsItselfIsAllowedOnce() {
        #expect(decision(article, type: .other, acceptsFirstLoad: true) == .allow)
        #expect(decision(article, type: .other, acceptsFirstLoad: false) == .cancel)
        #expect(decision(article, type: .reload, acceptsFirstLoad: true) == .cancel)
    }

    @Test func aLinkOpensATabAndTheViewStaysWhereItIs() throws {
        let address = try #require(URL(string: "https://example.test/next"))
        let result = decision(address)

        #expect(result == .open(address, activate: true))
        #expect(result.policy == .cancel, "the reader view does not navigate")
    }

    @Test func aLinkOpenedWithCommandOrTheMiddleButtonOpensBehind() throws {
        let address = try #require(URL(string: "http://example.test/next"))

        #expect(decision(address, modifiers: .command) == .open(address, activate: false))
        #expect(decision(address, buttonNumber: 4) == .open(address, activate: false))
        #expect(decision(address, modifiers: [.command, .shift]) == .open(address, activate: true))
    }

    @Test func aLinkInsideTheArticleScrollsInPlace() throws {
        let article = try #require(URL(string: "https://example.test/story"))
        let heading = try #require(URL(string: "https://example.test/story#part-2"))
        let result = ReaderNavigation.decision(
            for: heading, type: .linkActivated, inSubframe: false, article: article, acceptsFirstLoad: false,
            modifiers: [], buttonNumber: 0
        )

        #expect(result == .scroll(toFragment: "part-2"))
        #expect(result.policy == .cancel)
    }

    @Test func aLinkToAnotherPageWithAFragmentIsStillALink() throws {
        let article = try #require(URL(string: "https://example.test/story"))
        let other = try #require(URL(string: "https://example.test/other#part-2"))
        let result = ReaderNavigation.decision(
            for: other, type: .linkActivated, inSubframe: false, article: article, acceptsFirstLoad: false,
            modifiers: [], buttonNumber: 0
        )

        #expect(result == .open(other, activate: true))
    }

    @Test func nothingElseNavigates() throws {
        let address = try #require(URL(string: "https://example.test/next"))

        #expect(decision(address, inSubframe: true) == .cancel, "a frame in the article")
        #expect(decision(address, type: .formSubmitted) == .cancel)
        #expect(decision(address, type: .formResubmitted) == .cancel)
        #expect(decision(address, type: .backForward) == .cancel)
        #expect(decision(address, type: .other) == .cancel, "a script or redirect after the first load")
        #expect(decision(nil) == .cancel)
        for unsafe in ["javascript:alert(1)", "file:///etc/hosts", "mailto:a@example.test", "data:text/html,hi"] {
            #expect(decision(URL(string: unsafe)) == .cancel, "\(unsafe)")
        }
    }
}
