// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AVFAudio

struct TranscriptUpdate: Sendable, Equatable {
    var text: String
    var isFinal: Bool
}

@MainActor
protocol TranscriberEngine: AnyObject {
    var bestFormat: AVAudioFormat? { get }
    func prepare() async throws
    func startSession(input: AsyncStream<CapturedAudio>) -> AsyncThrowingStream<TranscriptUpdate, Error>
    func finishSession() async throws
    func cancelSession() async
}

extension TranscriberEngine {
    func cancelSession() async {
        try? await finishSession()
    }
}
