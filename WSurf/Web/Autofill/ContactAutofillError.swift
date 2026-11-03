// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

nonisolated enum ContactAutofillError: Error, LocalizedError {
    case noField
    case changedPage
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noField:
            String(localized: "Select a visible name, email, phone, or address field and try again.")
        case .changedPage:
            String(localized: "The page or selected field changed. Select the field again.")
        case .unavailable:
            String(localized: "Couldn’t read saved contacts. Check Settings › Autofill.")
        }
    }
}
