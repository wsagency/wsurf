// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserTab {
    enum InternalPage: String, Codable, CaseIterable {
        case history
        case downloads
        case releaseNotes
        case settings

        var title: String {
            switch self {
            case .settings:
                "Settings"
            case .history:
                "History"
            case .downloads:
                "Downloads"
            case .releaseNotes:
                "Release Notes"
            }
        }

        var symbol: String {
            switch self {
            case .settings:
                "gearshape"
            case .history:
                "clock"
            case .downloads:
                "arrow.down"
            case .releaseNotes:
                "doc.text"
            }
        }
    }
}
