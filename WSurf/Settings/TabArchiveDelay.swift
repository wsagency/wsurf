// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// How long a background tab may sit unused before it moves to the archive. Never is the default.
enum TabArchiveDelay: String, CaseIterable, Identifiable {
    case twelveHours
    case day
    case week
    case never

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .twelveHours:
            "After 12 hours"
        case .day:
            "After a day"
        case .week:
            "After a week"
        case .never:
            "Never"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .twelveHours:
            12 * 3600
        case .day:
            86_400
        case .week:
            7 * 86_400
        case .never:
            nil
        }
    }
}
