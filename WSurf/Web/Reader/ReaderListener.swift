// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// Reads an article aloud with the voice of this Mac, one sentence at a time, and says which sentence it is on. One listener
/// belongs to one tab's Reader and its own speech output, so the assistant's voice and this one never stop each other.
///
/// The text of a block is asked for just before it is spoken, from what the article's view shows then, so an article that is
/// being translated while it is read is heard in the language it has reached.
@MainActor
@Observable
final class ReaderListener {
    enum State: Equatable {
        case idle
        case playing
        case paused
    }

    /// The text of a block as it is shown now, or nil when it cannot be read. `ReaderPage.titleBlock` is the headline.
    typealias Source = @MainActor (_ block: Int) async -> ReaderSpeech.Passage?

    private(set) var state = State.idle
    private(set) var spot: ReaderSpeech.Spot?
    private(set) var rate: Float
    private var blocks: [Int] = []
    private var position = 0
    private var sentences: [ReaderSpeech.Sentence] = []
    private var sentence = 0

    /// Marks the sentence being read in the article's view; nil clears the mark. Whoever owns the listener sets it once.
    @ObservationIgnored var mark: ((ReaderSpeech.Spot?) -> Void)?
    @ObservationIgnored let output: any SpeechOutput
    @ObservationIgnored private let settings: BrowserSettings
    @ObservationIgnored private var source: Source = { _ in nil }
    @ObservationIgnored private var language: String?
    /// Counts the reads of a block's text, so an answer that arrives after the listener moved on is dropped.
    @ObservationIgnored private var loads = 0
    /// True from handing a sentence to the voice until the voice says it began. Until then, "nothing is speaking" is the end of
    /// what was said before, not of this sentence.
    @ObservationIgnored private var awaitingStart = false

    init(output: any SpeechOutput, settings: BrowserSettings = .application) {
        self.output = output
        self.settings = settings
        rate = ReaderSpeech.clampedRate(settings.readerSpeechRate)
        output.setRate(rate)
        output.onSpeakingChange = { [weak self] speaking in
            self?.speakingChanged(speaking)
        }
    }

    func setRate(_ rate: Float) {
        self.rate = ReaderSpeech.clampedRate(rate)
        output.setRate(self.rate)
        settings.readerSpeechRate = self.rate
    }

    var canSkipBack: Bool {
        state != .idle && (sentence > 0 || position > 0)
    }

    var canSkipForward: Bool {
        state != .idle && (sentence < sentences.count - 1 || position < blocks.count - 1)
    }

    /// Reads `blocks` in order from the first, asking `source` for the text of each.
    func start(blocks: [Int], source: @escaping Source) {
        stop()
        guard !blocks.isEmpty else { return }
        self.blocks = blocks
        self.source = source
        state = .playing
        load(0, fromEnd: false)
    }

    func togglePause() {
        switch state {
        case .playing:
            // The state changes first: stopping reports that nothing is speaking, which must not read as the sentence's end.
            state = .paused
            output.stopSpeaking()
        case .paused:
            state = .playing
            if sentences.indices.contains(sentence) {
                move(to: sentence)
            }
        case .idle:
            break
        }
    }

    /// Moves by sentences, across blocks. While paused, the place moves and stays silent until it is resumed.
    func skip(by delta: Int) {
        guard state != .idle else { return }
        let target = sentence + delta
        if sentences.indices.contains(target) {
            move(to: target)
        } else {
            load(position + delta, fromEnd: delta < 0)
        }
    }

    func stop() {
        guard state != .idle else { return }
        state = .idle
        loads += 1
        blocks = []
        position = 0
        sentences = []
        sentence = 0
        spot = nil
        awaitingStart = false
        output.stopSpeaking()
        mark?(nil)
    }

    /// Asks for the text of block `next`, then speaks its first sentence, or its last when going back. A block with nothing to say
    /// is passed over in the direction of travel; the end of the blocks ends the reading, and going back from the first block
    /// starts it again.
    private func load(_ next: Int, fromEnd: Bool) {
        guard blocks.indices.contains(next) else {
            if fromEnd, next < 0 {
                load(0, fromEnd: false)
            } else {
                stop()
            }
            return
        }
        position = next
        sentences = []
        sentence = 0
        loads += 1
        let ticket = loads
        let block = blocks[next]
        let read = source
        awaitingStart = true
        output.stopSpeaking()
        Task { [weak self] in
            let passage = await read(block)
            guard let self, loads == ticket, state != .idle else { return }
            let found = ReaderSpeech.sentences(in: passage?.text ?? "")
            guard !found.isEmpty else {
                self.load(next + (fromEnd ? -1 : 1), fromEnd: fromEnd)
                return
            }
            language = passage?.language
            sentences = found
            move(to: fromEnd ? found.count - 1 : 0)
        }
    }

    private func move(to index: Int) {
        sentence = index
        spot = ReaderSpeech.Spot(block: blocks[position], range: sentences[index].range)
        mark?(spot)
        guard state == .playing else { return }
        awaitingStart = true
        output.stopSpeaking()
        output.setLanguage(language)
        output.speak(sentences[index].text)
    }

    private func speakingChanged(_ speaking: Bool) {
        guard state == .playing else { return }
        if speaking {
            awaitingStart = false
            return
        }
        guard !awaitingStart else { return }
        if sentence + 1 < sentences.count {
            move(to: sentence + 1)
        } else {
            load(position + 1, fromEnd: false)
        }
    }
}
