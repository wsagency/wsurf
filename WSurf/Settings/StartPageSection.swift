// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

enum StartPageSection: String, CaseIterable, Identifiable {
    case suggestions
    case recentTasks
    case frequentSites
    case history
    case downloads

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .suggestions:
            "Suggestions"
        case .recentTasks:
            "Recent Tasks"
        case .frequentSites:
            "Frequently Visited"
        case .history:
            "History"
        case .downloads:
            "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .suggestions:
            "sparkles"
        case .recentTasks:
            "clock.arrow.circlepath"
        case .frequentSites:
            "chart.bar"
        case .history:
            "clock"
        case .downloads:
            "arrow.down"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .suggestions:
            "Things to try"
        case .recentTasks:
            "Repeat a recent task"
        case .frequentSites:
            "Websites you visit most"
        case .history:
            "Recently visited pages"
        case .downloads:
            "Recent files"
        }
    }
}
