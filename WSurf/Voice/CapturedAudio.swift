// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AVFAudio

nonisolated struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
