// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

@MainActor
protocol SpeechOutput: AnyObject {
    var isMuted: Bool { get set }
    var onSpeakingChange: ((Bool) -> Void)? { get set }
    /// How fast the voice reads, as a multiple of its normal pace. Only the on-device voice has a pace to change.
    func setRate(_ rate: Float)
    /// The language of what is spoken next, as a BCP 47 code such as `de-DE`, or nil for the voice's own. Only the on-device voice
    /// has a voice for each language.
    func setLanguage(_ language: String?)
    func speak(_ text: String)
    func stopSpeaking()
}

extension SpeechOutput {
    func setRate(_ rate: Float) {}
    func setLanguage(_ language: String?) {}
}
