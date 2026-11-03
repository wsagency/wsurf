// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import FoundationModels

nonisolated enum SystemModelFailure {
    static func isContextOverflow(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = error {
            return true
        }
        return false
    }
}
