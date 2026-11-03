// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

@MainActor
protocol SpeechOutput: AnyObject {
    var isMuted: Bool { get set }
    var onSpeakingChange: ((Bool) -> Void)? { get set }
    func speak(_ text: String)
    func stopSpeaking()
}
