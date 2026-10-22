// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A voice that says nothing and is told by the test when a sentence begins and ends.
@MainActor
private final class ScriptedSpeech: SpeechOutput {
    var isMuted = false
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var rate: Float = 1
    private(set) var language: String?
    private(set) var spoken: [String] = []
    private(set) var stops = 0

    func setRate(_ rate: Float) {
        self.rate = rate
    }

    func setLanguage(_ language: String?) {
        self.language = language
    }

    func speak(_ text: String) {
        spoken.append(text)
    }

    func stopSpeaking() {
        stops += 1
    }

    func begin() {
        onSpeakingChange?(true)
    }

    func end() {
        onSpeakingChange?(false)
    }

    func finishCurrent() {
        begin()
        end()
    }

    /// Waits until `count` sentences have been handed to the voice. A block's text is asked for first, so that takes a moment.
    func untilSpoken(_ count: Int) async -> Bool {
        await waitUntil { spoken.count >= count }
    }
}

/// A listener over a `ScriptedSpeech`, with settings of its own, and the marks it asked for.
@MainActor
private final class ListeningFixture {
    let speech = ScriptedSpeech()
    let defaults: UserDefaults
    let settings: BrowserSettings
    let listener: ReaderListener
    private(set) var marks: [ReaderSpeech.Spot?] = []

    /// The defaults are in the per-process test directory (`AppDatabase.defaultsSuite`), which a test run removes.
    init() {
        defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite("ReaderListener-\(UUID().uuidString)"))!
        settings = BrowserSettings(defaults: defaults)
        listener = ReaderListener(output: speech, settings: settings)
        listener.mark = { [weak self] spot in self?.marks.append(spot) }
    }

    /// The sentence marked now, nil when the mark was cleared or nothing was marked.
    var marked: ReaderSpeech.Spot? {
        marks.last ?? nil
    }

    /// A source of block texts, each in `language`.
    func source(_ texts: [Int: String], language: String? = nil) -> ReaderListener.Source {
        { block in texts[block].map { ReaderSpeech.Passage(text: $0, language: language) } }
    }

    func spot(_ block: Int, _ range: Range<Int>) -> ReaderSpeech.Spot {
        ReaderSpeech.Spot(block: block, range: range)
    }
}

// MARK: - The pace, the sentences, the language

@MainActor
struct ReaderSpeechTests {
    @Test func theSpeedStaysBetweenHalfAndOneAndAHalfInTenths() {
        #expect(ReaderSpeech.rateRange == 0.5...1.5)
        #expect(ReaderSpeech.clampedRate(0.2) == 0.5)
        #expect(ReaderSpeech.clampedRate(-3) == 0.5)
        #expect(ReaderSpeech.clampedRate(3) == 1.5)
        #expect(ReaderSpeech.clampedRate(0.5) == 0.5)
        #expect(ReaderSpeech.clampedRate(1.5) == 1.5)
        #expect(ReaderSpeech.clampedRate(1.04) == 1.0)
        #expect(ReaderSpeech.clampedRate(1.26) == 1.3)
        #expect(ReaderSpeech.clampedRate(.nan) == ReaderSpeech.defaultRate)
        #expect(ReaderSpeech.clampedRate(.infinity) == ReaderSpeech.defaultRate)
        #expect(ReaderSpeech.defaultRate == 1)
    }

    @Test func aBlockIsSplitIntoItsSentencesWithTheirPlaces() {
        let found = ReaderSpeech.sentences(in: "One. Two! Three?")

        #expect(found.map(\.text) == ["One.", "Two!", "Three?"])
        #expect(found.map(\.range) == [0..<4, 5..<9, 10..<16])
    }

    @Test func spaceAroundASentenceIsNotPartOfIt() {
        let found = ReaderSpeech.sentences(in: "  Padded.  Next one here.  ")

        #expect(found.map(\.text) == ["Padded.", "Next one here."])
        #expect(found.map(\.range) == [2..<9, 11..<25])
    }

    @Test func aTextWithoutPunctuationIsOneSentence() {
        let text = "A heading with no full stop"

        #expect(ReaderSpeech.sentences(in: text) == [ReaderSpeech.Sentence(text: text, range: 0..<text.utf16.count)])
        #expect(ReaderSpeech.sentences(in: "").isEmpty)
        #expect(ReaderSpeech.sentences(in: "   ").isEmpty)
    }

    @Test func aPieceWithNothingToSayIsLeftOut() {
        #expect(ReaderSpeech.sentences(in: "* * *").isEmpty)
        #expect(ReaderSpeech.sentences(in: "— … .").isEmpty)
        let between = ReaderSpeech.sentences(in: "Before.\n* * *\nAfter.")
        #expect(between.map(\.text) == ["Before.", "After."])
        #expect(between.map(\.range) == [0..<7, 14..<20])
    }

    /// The page counts text in UTF-16 units, so a range must hold the same sentence there, past an emoji and an accent.
    @Test func theRangesAreInTheUnitsThePageCounts() {
        let text = "Dobar dan 🌍 svima. Šta ima novo? Ništa."
        let found = ReaderSpeech.sentences(in: text)

        #expect(found.count == 3)
        for sentence in found {
            #expect((text as NSString).substring(with: NSRange(location: sentence.range.lowerBound, length: sentence.range.count)) == sentence.text)
        }
        #expect(found[1].range.lowerBound == "Dobar dan 🌍 svima. ".utf16.count)
    }

    @Test func aVoiceIsLookedUpByLanguageAndRegion() {
        #expect(ReaderSpeech.voiceLanguage(Locale.Language(identifier: "de")) == "de-DE")
        #expect(ReaderSpeech.voiceLanguage(Locale.Language(identifier: "hr")) == "hr-HR")
        #expect(ReaderSpeech.voiceLanguage(Locale.Language(identifier: "en-GB")) == "en-GB")
        #expect(ReaderSpeech.voiceLanguage(Locale.Language(identifier: "pt-BR")) == "pt-BR")
    }

    // MARK: The text that is read

    private static let german = Locale.Language(identifier: "de")

    @Test func theShownTextIsReadInTheLanguageItWasTranslatedTo() {
        let passage = ReaderSpeech.passage(shown: "Der Hafen", original: "The harbour", translatedTo: Self.german, articleLanguage: "en")

        #expect(passage == ReaderSpeech.Passage(text: "Der Hafen", language: "de-DE"))
    }

    @Test func anArticleThatIsNotTranslatedIsReadInItsOwnLanguage() {
        #expect(
            ReaderSpeech.passage(shown: "The harbour", original: "The harbour", translatedTo: nil, articleLanguage: "en-GB")
                == ReaderSpeech.Passage(text: "The harbour", language: "en-GB")
        )
        #expect(ReaderSpeech.passage(shown: "The harbour", original: nil, translatedTo: nil, articleLanguage: "")?.language == nil)
    }

    @Test func theArticlesOwnTextIsForAViewThatCannotBeRead() {
        #expect(ReaderSpeech.passage(shown: nil, original: "Own text", translatedTo: nil, articleLanguage: "en")?.text == "Own text")
        #expect(ReaderSpeech.passage(shown: "", original: "Own text", translatedTo: nil, articleLanguage: "en")?.text == "Own text")
        #expect(ReaderSpeech.passage(shown: nil, original: nil, translatedTo: nil, articleLanguage: "en") == nil)
        #expect(ReaderSpeech.passage(shown: "", original: "", translatedTo: nil, articleLanguage: "en") == nil)
    }

    // MARK: The page

    @Test func theArticlePageStylesTheMarkAndNamesItsHeadline() {
        let article = ReaderArticle(url: URL(filePath: "/story"), title: "Headline", content: "<p>Body</p>", blocks: ["Body"])
        let html = ReaderPage.html(for: article, typeface: .system, palette: .automatic, textSize: 19)

        #expect(html.contains(#"<h1 class="title" id="\#(ReaderPage.titleID)">Headline</h1>"#))
        #expect(html.contains("::highlight(\(ReaderSpeech.highlightName))"))
        #expect(ReaderSpeech.markScript.contains("'\(ReaderSpeech.highlightName)'"))
        #expect(!html.contains("<script"), "the page still runs nothing of its own")
    }

    /// An utterance in progress keeps the pace it began with, so after a change what is left of it is spoken again.
    @Test func whatIsLeftOfASentenceStartsAtTheWordBeingSpoken() {
        #expect(AppleSpeechOutput.remainder(of: "Hello brave new world", from: 6) == "brave new world")
        #expect(AppleSpeechOutput.remainder(of: "Hello", from: 0) == "Hello")
        #expect(AppleSpeechOutput.remainder(of: "Hello", from: 99) == "")
        #expect(AppleSpeechOutput.remainder(of: "Hello", from: -4) == "Hello")
        #expect(AppleSpeechOutput.remainder(of: "🌍 world", from: 3) == "world")
    }
}

// MARK: - The speed is the person's, for every article

@MainActor
struct ReaderSpeechRateSettingsTests {
    private func withSettings<T>(_ body: (BrowserSettings, UserDefaults) throws -> T) rethrows -> T {
        let suite = AppDatabase.defaultsSuite("ReaderSpeechRate-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return try body(BrowserSettings(defaults: defaults), defaults)
    }

    @Test func theSpeedStartsAtNormalAndReadingItWritesNothing() {
        withSettings { settings, defaults in
            #expect(settings.readerSpeechRate == 1)
            #expect(defaults.object(forKey: "reader.speechRate") == nil)
        }
    }

    @Test func theChosenSpeedIsKeptInTheApplicationDefaults() {
        withSettings { settings, defaults in
            settings.readerSpeechRate = 1.3

            #expect(defaults.float(forKey: "reader.speechRate") == 1.3)
            #expect(BrowserSettings(defaults: defaults).readerSpeechRate == 1.3)
        }
    }

    @Test func aSpeedOutsideTheRangeIsBroughtBackToIt() {
        withSettings { settings, defaults in
            settings.readerSpeechRate = 9
            #expect(settings.readerSpeechRate == 1.5)
            #expect(defaults.float(forKey: "reader.speechRate") == 1.5)

            settings.readerSpeechRate = 0.1
            #expect(settings.readerSpeechRate == 0.5)
            #expect(BrowserSettings(defaults: defaults).readerSpeechRate == 0.5)
        }
    }

    @Test func aDamagedStoredSpeedIsRepaired() {
        withSettings { _, defaults in
            defaults.set(40, forKey: "reader.speechRate")
            #expect(BrowserSettings(defaults: defaults).readerSpeechRate == 1.5)

            defaults.set("fast", forKey: "reader.speechRate")
            #expect(BrowserSettings(defaults: defaults).readerSpeechRate == 1)
        }
    }

    @Test func resettingTheSettingsReturnsTheSpeedToNormal() {
        withSettings { settings, _ in
            settings.readerSpeechRate = 0.7
            settings.resetToDefaults()

            #expect(settings.readerSpeechRate == 1)
        }
    }
}

// MARK: - Listening, sentence by sentence

@MainActor
struct ReaderListenerTests {
    @Test func listeningReadsTheHeadlineThenEverySentenceInOrder() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(
            blocks: [ReaderPage.titleBlock, 0, 1],
            source: reading.source([-1: "Headline", 0: "One. Two.", 1: "Three."])
        )
        #expect(reading.listener.state == .playing)

        #expect(await speech.untilSpoken(1))
        #expect(speech.spoken == ["Headline"])
        #expect(reading.listener.spot == reading.spot(ReaderPage.titleBlock, 0..<8))

        speech.finishCurrent()
        #expect(await speech.untilSpoken(2))
        #expect(speech.spoken == ["Headline", "One."])
        #expect(reading.listener.spot == reading.spot(0, 0..<4))

        speech.finishCurrent()
        #expect(speech.spoken.last == "Two.", "the next sentence of the same block follows at once")
        #expect(reading.listener.spot == reading.spot(0, 5..<9))

        speech.finishCurrent()
        #expect(await speech.untilSpoken(4))
        #expect(speech.spoken == ["Headline", "One.", "Two.", "Three."])
        #expect(reading.listener.spot == reading.spot(1, 0..<6))

        speech.finishCurrent()
        #expect(reading.listener.state == .idle)
        #expect(reading.listener.spot == nil)
    }

    @Test func theSentenceBeingReadIsMarkedAndTheMarkIsClearedAtTheEnd() async {
        let reading = ListeningFixture()
        reading.listener.start(blocks: [0], source: reading.source([0: "One. Two."]))
        #expect(await reading.speech.untilSpoken(1))

        #expect(reading.marked == reading.spot(0, 0..<4))
        reading.speech.finishCurrent()
        #expect(reading.marked == reading.spot(0, 5..<9))
        reading.speech.finishCurrent()
        #expect(reading.marked == nil)
        #expect(reading.marks.count == 3)
    }

    /// The voice reports the end of a sentence it was stopped in the middle of after the next one was handed to it.
    @Test func aStaleEndFromTheSentenceBeforeDoesNotSkipAhead() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(blocks: [0], source: reading.source([0: "One. Two. Three."]))
        #expect(await speech.untilSpoken(1))
        speech.begin()

        reading.listener.skip(by: 1)
        speech.end()
        #expect(reading.listener.spot == reading.spot(0, 5..<9))
        #expect(speech.spoken == ["One.", "Two."])

        speech.begin()
        speech.end()
        #expect(reading.listener.spot == reading.spot(0, 10..<16))
    }

    @Test func pausingHoldsThePlaceAndResumingRepeatsTheSentence() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(blocks: [0], source: reading.source([0: "One. Two."]))
        #expect(await speech.untilSpoken(1))
        speech.begin()

        reading.listener.togglePause()
        speech.end()
        #expect(reading.listener.state == .paused)
        #expect(reading.listener.spot == reading.spot(0, 0..<4))
        #expect(speech.spoken == ["One."], "stopping the voice is not the end of the sentence")

        reading.listener.togglePause()
        #expect(reading.listener.state == .playing)
        #expect(speech.spoken == ["One.", "One."])
    }

    @Test func skippingMovesBySentenceAcrossBlocks() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(blocks: [0, 1], source: reading.source([0: "One. Two.", 1: "Three. Four."]))
        #expect(await speech.untilSpoken(1))
        #expect(!reading.listener.canSkipBack)
        #expect(reading.listener.canSkipForward)

        reading.listener.skip(by: 1)
        #expect(speech.spoken.last == "Two.")

        reading.listener.skip(by: 1)
        #expect(await speech.untilSpoken(3))
        #expect(speech.spoken.last == "Three.")
        #expect(reading.listener.spot == reading.spot(1, 0..<6))
        #expect(reading.listener.canSkipBack)

        reading.listener.skip(by: -1)
        #expect(await speech.untilSpoken(4))
        #expect(speech.spoken.last == "Two.", "back from a block's first sentence goes to the last of the block before")
        #expect(reading.listener.spot == reading.spot(0, 5..<9))
    }

    @Test func skippingWhilePausedMovesThePlaceInSilence() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(blocks: [0], source: reading.source([0: "One. Two."]))
        #expect(await speech.untilSpoken(1))
        reading.listener.togglePause()

        reading.listener.skip(by: 1)
        #expect(reading.listener.state == .paused)
        #expect(reading.listener.spot == reading.spot(0, 5..<9))
        #expect(reading.marked == reading.spot(0, 5..<9))
        #expect(speech.spoken == ["One."])
        #expect(!reading.listener.canSkipForward)

        reading.listener.togglePause()
        #expect(speech.spoken == ["One.", "Two."])
    }

    @Test func aBlockWithNothingToSayIsPassedOverInEitherDirection() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(blocks: [0, 1, 2], source: reading.source([0: "One.", 2: "Three."]))
        #expect(await speech.untilSpoken(1))

        speech.finishCurrent()
        #expect(await speech.untilSpoken(2))
        #expect(speech.spoken == ["One.", "Three."])
        #expect(reading.listener.spot == reading.spot(2, 0..<6))

        reading.listener.skip(by: -1)
        #expect(await speech.untilSpoken(3))
        #expect(speech.spoken.last == "One.")
    }

    @Test func readingEndsAfterTheLastBlockEvenWhenTheRestIsEmpty() async {
        let reading = ListeningFixture()
        reading.listener.start(blocks: [0, 1], source: reading.source([0: "One."]))
        #expect(await reading.speech.untilSpoken(1))

        reading.speech.finishCurrent()

        #expect(await waitUntil { reading.listener.state == .idle })
        #expect(reading.speech.spoken == ["One."])
    }

    @Test func stoppingClearsTheMarkAndSilencesTheVoice() async {
        let reading = ListeningFixture()
        reading.listener.start(blocks: [0], source: reading.source([0: "One. Two."]))
        #expect(await reading.speech.untilSpoken(1))
        let stops = reading.speech.stops

        reading.listener.stop()

        #expect(reading.listener.state == .idle)
        #expect(reading.listener.spot == nil)
        #expect(reading.marked == nil)
        #expect(reading.marks.count == 2)
        #expect(reading.speech.stops > stops)
        #expect(!reading.listener.canSkipForward && !reading.listener.canSkipBack)

        reading.listener.stop()
        #expect(reading.marks.count == 2, "stopping what is stopped does nothing")
        reading.speech.finishCurrent()
        #expect(reading.speech.spoken == ["One."], "a late end from the voice reads on nothing")
    }

    /// A block's text is asked for before it is spoken; if the person stops or moves on while it is on its way, it is dropped.
    @Test func aTextThatArrivesAfterTheListenerMovedOnIsDropped() async {
        let reading = ListeningFixture()
        let gate = ReaderGate()
        reading.listener.start(blocks: [0]) { _ in
            await gate.wait()
            return ReaderSpeech.Passage(text: "Late.", language: nil)
        }
        #expect(await waitUntil { gate.isWaiting })

        reading.listener.stop()
        gate.open()
        for _ in 0..<50 {
            await Task.yield()
        }

        #expect(reading.speech.spoken.isEmpty)
        #expect(reading.listener.state == .idle)
    }

    @Test func startingAgainReadsFromTheTopAndDropsTheEarlierReading() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(blocks: [0], source: reading.source([0: "Old. Older."]))
        #expect(await speech.untilSpoken(1))

        reading.listener.start(blocks: [0], source: reading.source([0: "New."]))

        #expect(await speech.untilSpoken(2))
        #expect(speech.spoken == ["Old.", "New."])
        speech.finishCurrent()
        #expect(await waitUntil { reading.listener.state == .idle })
        #expect(speech.spoken == ["Old.", "New."])
    }

    // MARK: The speed

    @Test func theSpeedReachesTheVoiceStaysInRangeAndIsRemembered() {
        let reading = ListeningFixture()
        #expect(reading.listener.rate == 1)
        #expect(reading.speech.rate == 1)

        reading.listener.setRate(1.5)
        #expect(reading.speech.rate == 1.5)
        #expect(reading.defaults.float(forKey: "reader.speechRate") == 1.5)

        reading.listener.setRate(9)
        #expect(reading.listener.rate == 1.5)
        reading.listener.setRate(0.1)
        #expect(reading.listener.rate == 0.5)
        #expect(reading.speech.rate == 0.5)
        reading.listener.setRate(1.26)
        #expect(reading.listener.rate == 1.3)
        #expect(reading.speech.rate == 1.3)

        let nextSpeech = ScriptedSpeech()
        let next = ReaderListener(output: nextSpeech, settings: BrowserSettings(defaults: reading.defaults))
        #expect(next.rate == 1.3)
        #expect(nextSpeech.rate == 1.3, "a new listener starts the voice at the speed the person chose")
    }

    /// The voice restarts what is left of the sentence at the new pace itself, so the listener has nothing to repeat and no place to lose.
    @Test func aChangeOfSpeedWhileSpeakingKeepsTheSentenceAndTheMark() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        reading.listener.start(blocks: [0], source: reading.source([0: "One. Two."]))
        #expect(await speech.untilSpoken(1))
        speech.begin()

        reading.listener.setRate(1.5)

        #expect(speech.rate == 1.5)
        #expect(speech.spoken == ["One."])
        #expect(reading.listener.state == .playing)
        #expect(reading.listener.spot == reading.spot(0, 0..<4))

        speech.end()
        #expect(speech.spoken == ["One.", "Two."], "reading goes on from where it was")
    }

    @Test func theLanguageOfEachBlockReachesTheVoiceBeforeItIsSpoken() async {
        let reading = ListeningFixture()
        let speech = reading.speech
        let texts: [Int: String] = [0: "Der Hafen.", 1: "The harbour."]
        reading.listener.start(blocks: [0, 1]) { block in
            texts[block].map { ReaderSpeech.Passage(text: $0, language: block == 0 ? "de-DE" : nil) }
        }
        #expect(await speech.untilSpoken(1))
        #expect(speech.language == "de-DE")

        speech.finishCurrent()
        #expect(await speech.untilSpoken(2))
        #expect(speech.language == nil)
    }
}

// MARK: - What the article's view shows, and what ends listening

@MainActor
@Suite(.serialized)
struct ReaderListeningTests {
    private static let story = URL(string: "https://example.test/story")!
    private static let german = Locale.Language(identifier: "de")

    private func article(language: String = "en") -> ReaderArticle {
        ReaderArticle(
            url: Self.story, title: "The tide clock", language: language,
            content: #"<p data-reader-block="0">First. Second.</p><p data-reader-block="1">Third.</p>"#,
            blocks: ["First. Second.", "Third."]
        )
    }

    /// A Reader that has opened an article and is read by `reading`'s listener.
    private func openedSession(_ reading: ListeningFixture, language: String = "en") async -> ReaderSession {
        let stub = StubReader()
        stub.article = article(language: language)
        let session = ReaderSession()
        session.driver = stub.driver
        session.speaker = reading.listener
        #expect(await session.open())
        return session
    }

    @Test func theArticleIsReadFromItsHeadlineInItsOwnTextWithoutAView() async {
        let reading = ListeningFixture()
        let session = await openedSession(reading, language: "hr")

        session.listen()

        #expect(await reading.speech.untilSpoken(1))
        #expect(reading.speech.spoken == ["The tide clock"])
        #expect(reading.speech.language == "hr-HR")
        reading.speech.finishCurrent()
        #expect(await reading.speech.untilSpoken(2))
        #expect(reading.speech.spoken.last == "First.")
        reading.speech.finishCurrent()
        reading.speech.finishCurrent()
        #expect(await reading.speech.untilSpoken(4))
        #expect(reading.speech.spoken == ["The tide clock", "First.", "Second.", "Third."])
    }

    @Test func anArticleBeingTranslatedIsReadInTheLanguageOfTheTranslation() async {
        let reading = ListeningFixture()
        let session = await openedSession(reading, language: "en")

        session.listen()
        #expect(await reading.speech.untilSpoken(1))
        #expect(reading.speech.language == "en-US")
        session.stopListening()

        _ = session.translation.begin(to: Self.german)
        session.listen()
        #expect(await reading.speech.untilSpoken(2))
        #expect(reading.speech.language == "de-DE")
    }

    @Test func theCommandReadsPausesAndResumes() async {
        let reading = ListeningFixture()
        let session = await openedSession(reading)
        #expect(!session.isListening)

        session.toggleListening()
        #expect(session.isListening)
        #expect(reading.listener.state == .playing)
        #expect(await reading.speech.untilSpoken(1))

        session.toggleListening()
        #expect(reading.listener.state == .paused)
        #expect(session.isListening)

        session.toggleListening()
        #expect(reading.listener.state == .playing)
        #expect(reading.speech.spoken == ["The tide clock", "The tide clock"])

        session.stopListening()
        #expect(!session.isListening)
        #expect(reading.listener.state == .idle)
    }

    @Test func aTabThatNeverReadsAloudHasNoSynthesizerAndAskingMakesNone() async {
        let session = ReaderSession()
        let stub = StubReader()
        session.driver = stub.driver

        #expect(!session.isListening)
        session.toggleListening()
        #expect(session.speaker == nil, "nothing is shown yet, so nothing is read")
        session.stopListening()
        session.pageChanged()
        #expect(session.speaker == nil)

        #expect(await session.open())
        session.close()
        #expect(session.speaker == nil, "leaving Reader without reading made no listener")
    }

    @Test func theVoiceIsTheOnDeviceOneAndNotTheAssistants() {
        let coordinator = AppCoordinator()
        let wasMuted = coordinator.speech.isMuted
        let session = ReaderSession()

        #expect(session.listener.output is AppleSpeechOutput, "no cloud voice is ever the Reader's")
        #expect(session.listener.output !== coordinator.speech)
        #expect(session.listener === session.listener, "one listener for the tab")

        session.listener.stop()
        #expect(coordinator.speech.isMuted == wasMuted, "the assistant's output is its own")
    }

    // MARK: Leaving Reader

    @Test func hidingReaderStopsListening() async {
        let reading = ListeningFixture()
        let session = await openedSession(reading)
        session.listen()
        #expect(await reading.speech.untilSpoken(1))
        let marks = reading.marks.count

        session.close()

        #expect(reading.listener.state == .idle)
        #expect(reading.marked == nil)
        #expect(reading.marks.count > marks, "the mark was cleared")
        #expect(!session.isActive)
    }

    @Test func aNewPageStopsListening() async {
        let reading = ListeningFixture()
        let session = await openedSession(reading)
        session.listen()
        #expect(await reading.speech.untilSpoken(1))

        session.pageChanged()

        #expect(reading.listener.state == .idle)
        reading.speech.finishCurrent()
        #expect(reading.speech.spoken == ["The tide clock"])
    }

    @Test(.boundedWebViews) func closingTheTabStopsListening() async {
        let reading = ListeningFixture()
        let tab = BrowserTab(context: BrowserProfileContext(profile: .privateBrowsing()))
        let stub = StubReader()
        stub.article = article()
        tab.reader.driver = stub.driver
        tab.reader.speaker = reading.listener
        #expect(await tab.reader.open())
        tab.reader.listen()
        #expect(await reading.speech.untilSpoken(1))

        tab.detach()

        #expect(reading.listener.state == .idle)
        #expect(reading.marked == nil)
    }

    @Test(.boundedWebViews) func leavingTheTabOrReplacingTheViewStopsListening() async {
        let reading = ListeningFixture()
        let tab = BrowserTab(context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        let first = BrowserPage(webKit: ReaderPageController.makeWebView(dataStore: tab.context.dataStore), context: tab.context)
        let second = BrowserPage(webKit: ReaderPageController.makeWebView(dataStore: tab.context.dataStore), context: tab.context)
        let stub = StubReader()
        stub.article = article()
        tab.reader.driver = stub.driver
        tab.reader.speaker = reading.listener
        #expect(await tab.reader.open())
        tab.reader.presentedPage = first
        tab.reader.listen()
        #expect(await reading.speech.untilSpoken(1))

        tab.reader.presentedPage = second
        #expect(reading.listener.state == .idle, "a new view of the article is not the one being read")

        tab.reader.listen()
        #expect(reading.listener.state == .playing)
        tab.reader.presentedPage = nil
        #expect(reading.listener.state == .idle, "the view goes when another tab is brought to the front")

        await first.close()
        await second.close()
    }

    // MARK: The View menu

    @Test(.boundedWebViews) func theViewMenuReadsAloudPausesAndStops() async throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let items = root.items.compactMap(\.submenu).flatMap(\.items)
        let read = try #require(items.first { $0.title == String(localized: "Read Aloud") })
        let stop = try #require(items.first { $0.title == String(localized: "Stop Reading") })
        let tab = coordinator.browser.newTab()
        defer { coordinator.browser.closeAllTabs(saving: false) }

        #expect(read.keyEquivalent == "p")
        #expect(read.keyEquivalentModifierMask == [.command, .option])
        #expect(items.filter { $0.keyEquivalent == "p" && $0.keyEquivalentModifierMask == [.command, .option] }.count == 1)
        #expect(stop.keyEquivalent.isEmpty)
        #expect(!menu.validateMenuItem(read), "there is no article on screen")
        #expect(!menu.validateMenuItem(stop))

        let reading = ListeningFixture()
        let stub = StubReader()
        stub.article = article()
        tab.reader.driver = stub.driver
        tab.reader.speaker = reading.listener
        #expect(await tab.reader.open())
        #expect(menu.validateMenuItem(read))
        #expect(read.title == String(localized: "Read Aloud"))
        #expect(!menu.validateMenuItem(stop), "nothing is being read")

        coordinator.toggleReadAloud()
        #expect(reading.listener.state == .playing)
        #expect(menu.validateMenuItem(read))
        #expect(read.title == String(localized: "Pause Reading"))
        #expect(menu.validateMenuItem(stop))

        coordinator.toggleReadAloud()
        #expect(reading.listener.state == .paused)
        #expect(read.title == String(localized: "Resume Reading"))
        #expect(menu.validateMenuItem(stop))

        coordinator.stopReadAloud()
        #expect(reading.listener.state == .idle)
        #expect(menu.validateMenuItem(read))
        #expect(read.title == String(localized: "Read Aloud"))
        #expect(!menu.validateMenuItem(stop))

        coordinator.toggleReadAloud()
        tab.reader.close()
        #expect(reading.listener.state == .idle, "Hide Reader ends it")
        #expect(!menu.validateMenuItem(read))
    }
}

// MARK: - In the article's view

/// The two scripts against the page Reader builds, in the view that runs none of the page's JavaScript.
@MainActor
@Suite(.serialized)
struct ReaderMarkTests {
    private static let story = URL(string: "https://example.test/story")!

    /// A block whose text is split over nodes and set in pretty-printed source, to show the offsets count what the page's text
    /// reads as once whitespace is collapsed.
    private static let article = ReaderArticle(
        url: story, title: "Tide. Clock.",
        content: """
        <p data-reader-block="0">
          First  sentence.
          <b>Second</b>
         sentence with <a href="#x">a link</a>. Third.</p>
        <p data-reader-block="1">Next block here.</p>
        """,
        blocks: ["First sentence. Second sentence with a link. Third.", "Next block here."]
    )

    private func withArticleView(body: (BrowserPage) async throws -> Void) async throws {
        let tab = BrowserTab(context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        let view = ReaderPageController.makeWebView(dataStore: tab.context.dataStore)
        let controller = ReaderPageController()
        controller.webView = view
        view.navigationDelegate = controller
        let page = BrowserPage(webKit: view, context: tab.context)
        controller.show(Self.article, appearance: .init(typeface: .system, palette: .automatic, textSize: 19))
        defer { withExtendedLifetime(controller) {} }
        try #require(await waitUntil { controller.isLoaded }, "the article was not loaded")
        do {
            try await body(page)
        } catch {
            await page.close()
            throw error
        }
        await page.close()
    }

    private func run(_ script: String, in page: BrowserPage) async -> String? {
        try? await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String
    }

    /// What the page has marked, as each range's text with its whitespace collapsed, joined by `|`.
    private func marked(in page: BrowserPage) async -> String? {
        await run(
            """
            CSS.highlights.has('\(ReaderSpeech.highlightName)')
              ? [...CSS.highlights.get('\(ReaderSpeech.highlightName)')]
                  .map(range => range.toString().replace(/\\s+/g, ' ')).join('|')
              : ''
            """,
            in: page
        )
    }

    private func sentence(_ index: Int, ofBlock block: Int = 0) -> ReaderSpeech.Spot {
        let found = ReaderSpeech.sentences(in: Self.article.blocks[block])
        return ReaderSpeech.Spot(block: block, range: found[index].range)
    }

    @Test(.boundedWebViews) func aBlockIsReadAsTheViewShowsItAndTheHeadlineToo() async throws {
        try await withArticleView { page in
            #expect(await ReaderSpeech.shownText(ofBlock: 0, in: page) == Self.article.blocks[0])
            #expect(await ReaderSpeech.shownText(ofBlock: 1, in: page) == "Next block here.")
            #expect(await ReaderSpeech.shownText(ofBlock: ReaderPage.titleBlock, in: page) == "Tide. Clock.")
            #expect(await ReaderSpeech.shownText(ofBlock: 40, in: page) == nil, "a block the page does not have")
        }
    }

    /// A translation replaces the text nodes of the article's view from another content world; the DOM is the same in every world.
    @Test(.boundedWebViews) func textChangedInThePageIsWhatIsRead() async throws {
        try await withArticleView { page in
            _ = await run(
                """
                for (const id of ['reader-title', null]) {
                  const root = id ? document.getElementById(id) : document.querySelector('[data-reader-block="0"]');
                  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                    node.nodeValue = node.nodeValue.replace(/sentence/g, 'Satz').replace(/Clock/g, 'Uhr');
                  }
                }
                'done'
                """,
                in: page
            )

            let block = await ReaderSpeech.shownText(ofBlock: 0, in: page)
            #expect(block == "First Satz. Second Satz with a link. Third.")
            #expect(await ReaderSpeech.shownText(ofBlock: ReaderPage.titleBlock, in: page) == "Tide. Uhr.")
            let passage = ReaderSpeech.passage(
                shown: block, original: Self.article.blocks[0], translatedTo: Locale.Language(identifier: "de"), articleLanguage: "en"
            )
            #expect(passage?.text == "First Satz. Second Satz with a link. Third.")
            #expect(passage?.language == "de-DE")
        }
    }

    /// The article is translated by the page translation itself, which edits the view from a world of its own.
    @Test(.boundedWebViews) func anArticleTranslatedByThePageTranslationIsReadTranslated() async throws {
        try await withArticleView { page in
            let translation = PageTranslation()
            let request = translation.begin(to: Locale.Language(identifier: "de"))
            translation.translate(request, in: page) { segments in
                Dictionary(uniqueKeysWithValues: segments.map { ($0.node, $0.text.replacingOccurrences(of: "block", with: "Block")) })
            }

            #expect(await waitUntil { await ReaderSpeech.shownText(ofBlock: 1, in: page) == "Next Block here." })
            #expect(await waitUntil { translation.phase == .translated })

            translation.showOriginal(in: page)
            #expect(await waitUntil { await ReaderSpeech.shownText(ofBlock: 1, in: page) == "Next block here." })
        }
    }

    @Test(.boundedWebViews) func theMarkCoversExactlyTheSentenceWhateverTheNodesAndWhitespaceAround() async throws {
        try await withArticleView { page in
            await ReaderSpeech.mark(sentence(1), in: page)
            #expect(await marked(in: page) == "Second sentence with a link.")

            await ReaderSpeech.mark(sentence(0), in: page)
            #expect(await marked(in: page) == "First sentence.")

            await ReaderSpeech.mark(sentence(2), in: page)
            #expect(await marked(in: page) == "Third.")

            await ReaderSpeech.mark(sentence(0, ofBlock: 1), in: page)
            #expect(await marked(in: page) == "Next block here.")
        }
    }

    @Test(.boundedWebViews) func theHeadlineCanBeMarkedAndOneMarkReplacesTheOther() async throws {
        try await withArticleView { page in
            let headline = ReaderSpeech.sentences(in: "Tide. Clock.")
            await ReaderSpeech.mark(ReaderSpeech.Spot(block: ReaderPage.titleBlock, range: headline[1].range), in: page)
            #expect(await marked(in: page) == "Clock.")

            await ReaderSpeech.mark(sentence(0), in: page)
            #expect(await marked(in: page) == "First sentence.", "only one mark at a time")
            #expect(await run("String(CSS.highlights.size)", in: page) == "1")
        }
    }

    @Test(.boundedWebViews) func clearingTheMarkLeavesNothingMarkedAndTheTextAlone() async throws {
        try await withArticleView { page in
            let before = await run("document.body.innerHTML", in: page)
            await ReaderSpeech.mark(sentence(1), in: page)
            #expect(await run("document.body.innerHTML", in: page) == before, "the mark is not in the DOM, so a screen reader keeps its place")

            await ReaderSpeech.mark(nil, in: page)

            #expect(await run("String(CSS.highlights.size)", in: page) == "0")
        }
    }

    @Test(.boundedWebViews) func aPlaceThePageDoesNotHaveMarksNothing() async throws {
        try await withArticleView { page in
            await ReaderSpeech.mark(sentence(0), in: page)
            #expect(await run("String(CSS.highlights.size)", in: page) == "1")

            await ReaderSpeech.mark(ReaderSpeech.Spot(block: 0, range: 900..<910), in: page)
            #expect(await run("String(CSS.highlights.size)", in: page) == "0", "the old mark is gone and no new one is made")

            await ReaderSpeech.mark(ReaderSpeech.Spot(block: 77, range: 0..<4), in: page)
            #expect(await run("String(CSS.highlights.size)", in: page) == "0")
        }
    }
}
