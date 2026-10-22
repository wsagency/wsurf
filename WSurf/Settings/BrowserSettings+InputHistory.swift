// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension BrowserSettings {
    /// Recording was switched on or off, or the excluded sites changed: every open page learns what it may record.
    func inputHistoryPolicyChanged() {
        InputHistoryCapture.shared.refreshPolicy()
    }

    func inputHistoryRetentionChanged() {
        applyInputHistoryRetention(to: ProfileStore.shared.profiles, history: .shared)
    }

    /// Entries already kept move to the expiry the new retention gives them. A settings object belongs to one persistent profile,
    /// and a private window has no history to change.
    func applyInputHistoryRetention(to profiles: [Profile], history: InputHistory) {
        for profile in profiles where BrowserProfileContext.existing(for: profile.id)?.settings === self {
            history.applyRetention(inputHistoryRetention, in: profile)
        }
    }
}
