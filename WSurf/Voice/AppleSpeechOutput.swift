// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AVFoundation

@MainActor
final class AppleSpeechVoiceCatalog {
    static let shared = AppleSpeechVoiceCatalog()

    private let loadVoices: () -> [AVSpeechSynthesisVoice]
    private var isPrepared = false
    private(set) var voice: AVSpeechSynthesisVoice?

    init(loadVoices: @escaping () -> [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices) {
        self.loadVoices = loadVoices
    }

    /// Apple's voice lookup must run during synchronous application launch, not from a Swift task.
    func prepare() {
        guard !isPrepared else { return }
        for candidate in loadVoices() where candidate.language.hasPrefix("en") {
            if candidate.quality == .premium {
                voice = candidate
                break
            }
            if voice == nil || (candidate.quality == .enhanced && voice?.quality != .enhanced) {
                voice = candidate
            }
        }
        isPrepared = true
    }
}

@MainActor
final class AppleSpeechOutput: SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private var watcher: SpeakingWatcher?
    /// What was handed to the synthesizer and has not ended, oldest first. An event for an utterance that is not here is a late
    /// one from something already stopped, and says nothing about what is being spoken now.
    private var queued: [AVSpeechUtterance] = []
    private var spokenLocation = 0
    private var rate: Float = 1
    private var language: String?

    var isMuted = false
    var onSpeakingChange: ((Bool) -> Void)?

    init() {
        let watcher = SpeakingWatcher { [weak self] utterance, event in
            Task { @MainActor in
                self?.utteranceChanged(utterance.value, event)
            }
        }
        self.watcher = watcher
        synthesizer.delegate = watcher
    }

    func speak(_ text: String) {
        // The synthesizer reports nothing for text with nothing to say, which would leave it in the queue for good.
        guard !isMuted, text.contains(where: { !$0.isWhitespace }) else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice()
        utterance.rate = min(AVSpeechUtteranceDefaultSpeechRate * rate, AVSpeechUtteranceMaximumSpeechRate)
        if queued.isEmpty {
            spokenLocation = 0
        }
        queued.append(utterance)
        synthesizer.speak(utterance)
    }

    /// Speaking continues at the new pace from the word being spoken: an utterance in progress keeps the pace it started with, so
    /// what is left of it, and what is queued after it, is spoken again at the new one.
    func setRate(_ rate: Float) {
        guard rate != self.rate else { return }
        self.rate = rate
        speakRemainderAtRate()
    }

    func setLanguage(_ language: String?) {
        self.language = language
    }

    func stopSpeaking() {
        let wasSpeaking = !queued.isEmpty
        cancelQueue()
        if wasSpeaking {
            onSpeakingChange?(false)
        }
    }

    /// English has the voice chosen at launch, the best the Mac has. Another language takes the system's voice for it, which may
    /// be a plainer one, and a language with no voice is read in the English one rather than not at all.
    private func voice() -> AVSpeechSynthesisVoice? {
        guard let language, !language.hasPrefix("en") else { return AppleSpeechVoiceCatalog.shared.voice }
        return AVSpeechSynthesisVoice(language: language) ?? AppleSpeechVoiceCatalog.shared.voice
    }

    /// The queue is emptied before the synthesizer is stopped, so the cancellations it reports for these utterances find nothing.
    private func cancelQueue() {
        queued.removeAll()
        spokenLocation = 0
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speakRemainderAtRate() {
        guard let current = queued.first else { return }
        let texts = [Self.remainder(of: current.speechString, from: spokenLocation)] + queued.dropFirst().map(\.speechString)
        cancelQueue()
        texts.forEach(speak)
    }

    /// The text from the UTF-16 offset `location` on, which is how the synthesizer reports the word it is about to speak.
    nonisolated static func remainder(of text: String, from location: Int) -> String {
        (text as NSString).substring(from: min(max(location, 0), text.utf16.count))
    }

    private func utteranceChanged(_ utterance: AVSpeechUtterance, _ event: SpeakingWatcher.Event) {
        guard let index = queued.firstIndex(where: { $0 === utterance }) else { return }
        switch event {
        case .started:
            spokenLocation = 0
            onSpeakingChange?(true)
        case .word(let location):
            if index == 0 {
                spokenLocation = location
            }
        case .ended:
            queued.remove(at: index)
            if index == 0 {
                spokenLocation = 0
            }
            onSpeakingChange?(!queued.isEmpty)
        }
    }
}

private nonisolated struct UtteranceBox: @unchecked Sendable {
    let value: AVSpeechUtterance
}

private nonisolated final class SpeakingWatcher: NSObject, AVSpeechSynthesizerDelegate {
    enum Event: Sendable {
        case started
        case word(Int)
        case ended
    }

    private let onChange: @Sendable (UtteranceBox, Event) -> Void

    init(onChange: @escaping @Sendable (UtteranceBox, Event) -> Void) {
        self.onChange = onChange
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onChange(UtteranceBox(value: utterance), .started)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance
    ) {
        onChange(UtteranceBox(value: utterance), .word(characterRange.location))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onChange(UtteranceBox(value: utterance), .ended)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onChange(UtteranceBox(value: utterance), .ended)
    }
}
