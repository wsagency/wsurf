// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

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

    var isMuted = false
    var onSpeakingChange: ((Bool) -> Void)?

    init() {
        let watcher = SpeakingWatcher { [weak self] speaking in
            Task { @MainActor in
                self?.onSpeakingChange?(speaking)
            }
        }
        self.watcher = watcher
        synthesizer.delegate = watcher
    }

    func speak(_ text: String) {
        guard !isMuted else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AppleSpeechVoiceCatalog.shared.voice
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private nonisolated final class SpeakingWatcher: NSObject, AVSpeechSynthesizerDelegate {
    private let onChange: @Sendable (Bool) -> Void

    init(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onChange(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onChange(synthesizer.isSpeaking)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onChange(synthesizer.isSpeaking)
    }
}
