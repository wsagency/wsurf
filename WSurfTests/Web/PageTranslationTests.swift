// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct PageTranslationTests {
    private func tagged(_ parts: [(String, Int?)]) -> AttributedString {
        var result = AttributedString()
        for (text, node) in parts {
            var part = AttributedString(text)
            part.link = node.map { URL(string: "wsurf-node:\($0)")! }
            result += part
        }
        return result
    }

    @Test func translatedRunsGoBackToTheNodesTheyCameFrom() {
        let translated = tagged([("Click ", 4), ("here ", 5), ("to continue", 6), ("!", nil)])
        let texts = PageTranslationRuns.distribute(translated, fallback: "", over: [4, 5, 6, 7])
        #expect(texts == [4: "Click ", 5: "here ", 6: "to continue!", 7: ""])
    }

    @Test func untaggedOrForeignRunsJoinTheFirstNode() {
        let translated = tagged([("Hello ", nil), ("world", 99)])
        #expect(PageTranslationRuns.distribute(translated, fallback: "", over: [1, 2]) == [1: "Hello world", 2: ""])
        #expect(PageTranslationRuns.distribute(nil, fallback: "Hello world", over: [1, 2]) == [1: "Hello world", 2: ""])
    }

    @Test func requestTagsEverySegment() {
        let request = PageTranslationRuns.request(for: [.init(node: 3, text: "Klicken Sie "), .init(node: 8, text: "hier")])
        #expect(String(request.characters) == "Klicken Sie hier")
        #expect(request.runs.map { $0.link?.absoluteString } == ["wsurf-node:3", "wsurf-node:8"])
    }

    @Test func languagesMatchByLanguageAndChineseScript() {
        let english = Locale.Language(identifier: "en-US")
        #expect(TranslationLanguage.matches(english, Locale.Language(identifier: "en-GB")))
        #expect(!TranslationLanguage.matches(english, Locale.Language(identifier: "de")))
        #expect(!TranslationLanguage.matches(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
        #expect(TranslationLanguage.matches(Locale.Language(identifier: "zh-CN"), Locale.Language(identifier: "zh-Hans")))
    }

    @Test func languageNamesUseTheLanguageWithoutItsRegion() {
        #expect(TranslationLanguage.key(Locale.Language(identifier: "de-AT")) == "de")
        #expect(TranslationLanguage.key(Locale.Language(identifier: "zh-TW")) == "zh-Hant")
        #expect(TranslationLanguage.key(Locale.Language(identifier: "zh-CN")) == "zh-Hans")
    }

    @Test func offersPreferredLanguagesOnlyForPagesTheReaderCannotRead() {
        let preferred = ["en-GB", "uk-UA", "en-US"]
        let japanese = TranslationLanguage.targets(for: Locale.Language(identifier: "ja"), preferring: "", preferred: preferred)
        #expect(japanese.map(TranslationLanguage.key) == ["en", "uk"])

        let ukrainian = TranslationLanguage.targets(for: Locale.Language(identifier: "uk"), preferring: "", preferred: preferred)
        #expect(ukrainian.isEmpty)

        let remembered = TranslationLanguage.targets(for: Locale.Language(identifier: "ja"), preferring: "uk", preferred: preferred)
        #expect(remembered.map(TranslationLanguage.key) == ["uk", "en"])

        let pageLanguage = TranslationLanguage.targets(for: Locale.Language(identifier: "uk"), preferring: "uk", preferred: ["en"])
        #expect(pageLanguage.map(TranslationLanguage.key) == ["en"])
    }

    @Test func movingWithinThePageForgetsTheDetectedLanguage() {
        let translation = PageTranslation()
        translation.offer([Locale.Language(identifier: "en")])
        let before = translation.document

        translation.pageMoved()
        #expect(translation.targets.isEmpty)
        #expect(translation.document == before + 1)

        _ = translation.begin(to: Locale.Language(identifier: "en"))
        translation.offer([Locale.Language(identifier: "en")])
        translation.pageMoved()
        #expect(translation.targets.count == 1)
    }

    @Test func documentChangeEndsTheRequestAndForgetsTheOffer() {
        let translation = PageTranslation()
        let english = Locale.Language(identifier: "en")
        let request = translation.begin(to: english)
        translation.offer([english])
        let before = translation.document

        translation.documentChanged()

        #expect(translation.phase == .original)
        #expect(translation.target == nil)
        #expect(translation.targets.isEmpty)
        #expect(!translation.isCurrent(request))
        #expect(translation.document == before + 1)
    }

    @Test func detectionReadsTheTextBeforeTheDeclaredLanguage() throws {
        let japanese = PageTranslationSample(
            declaredLanguage: "en",
            text: "今日は天気がとても良いので、公園まで散歩に行きました。桜がきれいに咲いていました。"
        )
        let detected = try #require(TranslationLanguage.detect(japanese))
        #expect(TranslationLanguage.key(detected) == "ja")

        let shell = PageTranslationSample(declaredLanguage: "de-DE", text: "YouTube")
        #expect(TranslationLanguage.detect(shell) == nil)
    }

    @Test func detectionIsNotDecidedByTheTitleAndMenu() throws {
        let apple = PageTranslationSample(
            declaredLanguage: "en-US",
            text: """
            OS - macOS 27 Golden Gate - Apple
            Apple
            Overview
            iOS
            macOS
            iPadOS
            watchOS
            visionOS
            Apple Intelligence
            Siri AI is rolling out in English.
            Explore what’s new for macOS 27.
            New Siri AI. An even more capable AI assistant with expanded intelligence to be more helpful every day.
            Type or talk naturally with Siri AI to find what you need and get more done.
            """
        )
        let detected = try #require(TranslationLanguage.detect(apple))
        #expect(TranslationLanguage.key(detected) == "en")
    }

    @Test func thinEvidenceDefersToAPlausibleDeclaredLanguage() throws {
        let loading = PageTranslationSample(
            declaredLanguage: "en-us",
            text: "App Store Connect\nCopia: Clipboard Manager\nDistributionAnalyticsTestFlight"
        )
        let detected = try #require(TranslationLanguage.detect(loading))
        #expect(TranslationLanguage.key(detected) == "en")

        let german = PageTranslationSample(declaredLanguage: "en", text: "Startseite\nNachrichten und aktuelle Themen aus Deutschland")
        #expect(TranslationLanguage.detect(german).map(TranslationLanguage.key) == "de")
    }

    @Test func alreadyTranslatedBlocksAreSkipped() async {
        let skipper = TranslationLanguage.Skipper(source: Locale.Language(identifier: "de"), target: Locale.Language(identifier: "en"))
        let english = await skipper.isAlreadyTarget([.init(node: 0, text: "This paragraph is already written in English.")])
        let german = await skipper.isAlreadyTarget([.init(node: 0, text: "Dieser Absatz ist noch auf Deutsch geschrieben.")])
        let short = await skipper.isAlreadyTarget([.init(node: 0, text: "Login")])
        #expect(english)
        #expect(!german)
        #expect(!short)
    }

    @Test func onlyTheNewestRequestChangesTheState() {
        let translation = PageTranslation()
        let ukrainian = translation.begin(to: Locale.Language(identifier: "uk"))
        let english = translation.begin(to: Locale.Language(identifier: "en"))

        translation.abandon(ukrainian, in: nil)
        #expect(translation.phase == .translating)
        #expect(translation.target.map(TranslationLanguage.key) == "en")

        translation.showOriginal(in: nil)
        #expect(!translation.isCurrent(english))
        #expect(translation.phase == .original)
        #expect(translation.target == nil)
    }
}
