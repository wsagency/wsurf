// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

enum UpdateChannel: String, CaseIterable, Identifiable {
    case release
    case preview

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .release:
            "Release"
        case .preview:
            "Preview"
        }
    }

    var caption: LocalizedStringResource {
        switch self {
        case .release:
            "WSurf updates when a version is ready for everyone."
        case .preview:
            "WSurf updates to preview builds, ahead of the release."
        }
    }
}

enum HistoryRetention: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case forever

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .day:
            "A day"
        case .week:
            "A week"
        case .month:
            "A month"
        case .year:
            "A year"
        case .forever:
            "Forever"
        }
    }

    var maximumAge: TimeInterval? {
        switch self {
        case .day:
            86_400
        case .week:
            7 * 86_400
        case .month:
            30 * 86_400
        case .year:
            365 * 86_400
        case .forever:
            nil
        }
    }
}

enum UserAgentMode: String, CaseIterable, Identifiable {
    case safari
    case wsurf = "WSurf"
    case custom

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .safari:
            "Safari"
        case .wsurf:
            "WSurf"
        case .custom:
            "Custom"
        }
    }
}
