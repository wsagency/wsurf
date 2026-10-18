// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A group of command palette results whose position the person can choose.
///
/// The cases are declared in the built-in order, so `allCases` is the default. History and Recently visited
/// are separate cases because they appear at different times: History matches what the person types, and
/// Recently visited fills the palette before anything is typed. Keeping them apart lets the default
/// reproduce both layouts, where Actions sits below History while typing and above Recently visited at rest.
/// Command mode (the `>` prefix) lists commands only and has no order.
enum CommandPaletteSection: String, CaseIterable, Identifiable {
    case search
    case suggestions
    case tabs
    case history
    case actions
    case recent

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .search:
            "Search or ask"
        case .suggestions:
            "Search suggestions"
        case .tabs:
            "Open tabs"
        case .history:
            "History"
        case .actions:
            "Actions"
        case .recent:
            "Recently visited"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .search:
            "What you type as a search or address, and the option to ask the assistant"
        case .suggestions:
            "Suggestions from your search engine as you type."
        case .tabs:
            "Tabs that match, or recent tabs before you type"
        case .history:
            "Pages that match as you type"
        case .actions:
            "Commands that match, or suggested ones before you type"
        case .recent:
            "Pages you visited, before you type"
        }
    }

    /// The order to show while the person types. Return runs the first result, so two cases keep their place
    /// whatever the person chose: an address keeps Search or ask first, which makes Return open it, and a
    /// command that matches strongly sits right under the first section so it is never buried. The default
    /// order already satisfies both, so for it this changes nothing.
    static func typingOrder(
        _ order: [CommandPaletteSection],
        isAddress: Bool,
        hasStrongCommand: Bool
    ) -> [CommandPaletteSection] {
        var order = order
        if isAddress, let index = order.firstIndex(of: .search), index > 0 {
            order.insert(order.remove(at: index), at: 0)
        }
        if hasStrongCommand, let index = order.firstIndex(of: .actions), index > 1 {
            order.insert(order.remove(at: index), at: 1)
        }
        return order
    }
}
