// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// What a sidebar row shows about its tab: shown now, marked, or never opened. Tab rows, split panes, favorites
/// and folders all take their state from this one type, so every kind of row looks and reads the same. It holds
/// no views and reads no settings.
struct SidebarRowStyle: Equatable {
    enum Emphasis: Equatable {
        case resting
        /// A marked row, or the pair of a split that is on screen: the faint glass.
        case lit
        /// The tab being shown and focused: inverse colors.
        case current
    }

    /// How the new-tab dot is drawn. Increase Contrast always uses the row's ink, never the accent.
    enum Mark: Equatable {
        case none
        case accent
        case ink
    }

    /// What VoiceOver adds to the row's name.
    enum Status: Equatable {
        case new
        case containsCurrent
        case containsNew

        var label: String {
            switch self {
            case .new:
                String(localized: "New")
            case .containsCurrent:
                String(localized: "Contains current tab")
            case .containsNew:
                String(localized: "Contains new tabs")
            }
        }
    }

    let emphasis: Emphasis
    let mark: Mark
    /// A collapsed folder shows that it holds the current tab with an inverse badge. No other row sets this.
    let marksCurrentTab: Bool
    let statuses: [Status]

    /// The row is selected for VoiceOver: current, marked, or on screen in a split.
    var isSelected: Bool {
        emphasis != .resting
    }

    var spokenStatus: String? {
        statuses.isEmpty ? nil : statuses.map(\.label).joined(separator: ", ")
    }

    /// A tab row, a split pane, or a favorite. Nothing is current while the new-tab palette is open: the palette
    /// stands in for the tab it will create. A current tab is never new.
    static func resolve(
        isCurrent: Bool,
        isMarked: Bool,
        isUnseen: Bool,
        paletteOpen: Bool,
        increasedContrast: Bool
    ) -> Self {
        let isShown = isCurrent && !paletteOpen
        let isNew = isUnseen && !isShown
        return Self(
            emphasis: isShown ? .current : (isMarked ? .lit : .resting),
            mark: isNew ? mark(increasedContrast: increasedContrast) : .none,
            marksCurrentTab: false,
            statuses: isNew ? [.new] : []
        )
    }

    /// The row of a split: glass while the pair is on screen or any pane is marked. It is never inverse, because
    /// only the focused pane is current; each pane takes its own `resolve`.
    static func splitRow(isOnScreen: Bool, isMarked: Bool, paletteOpen: Bool) -> Self {
        Self(
            emphasis: (isOnScreen && !paletteOpen) || isMarked ? .lit : .resting,
            mark: .none,
            marksCurrentTab: false,
            statuses: []
        )
    }

    /// A folder row. It is never current itself; a collapsed one reports the current and new tabs inside it.
    static func folder(
        isMarked: Bool,
        containsCurrent: Bool,
        containsNew: Bool,
        paletteOpen: Bool,
        increasedContrast: Bool
    ) -> Self {
        let holdsCurrent = containsCurrent && !paletteOpen
        return Self(
            emphasis: isMarked ? .lit : .resting,
            mark: containsNew ? mark(increasedContrast: increasedContrast) : .none,
            marksCurrentTab: holdsCurrent,
            statuses: (holdsCurrent ? [.containsCurrent] : []) + (containsNew ? [.containsNew] : [])
        )
    }

    private static func mark(increasedContrast: Bool) -> Mark {
        increasedContrast ? .ink : .accent
    }
}

extension BrowserModel {
    /// The style of one tab's row, for every place that draws the tab. `isMarked` is the multi-selection.
    func rowStyle(
        of tab: BrowserTab,
        isMarked: Bool,
        paletteOpen: Bool,
        increasedContrast: Bool
    ) -> SidebarRowStyle {
        SidebarRowStyle.resolve(
            isCurrent: activeTab === tab,
            isMarked: isMarked,
            isUnseen: tab.isUnseen,
            paletteOpen: paletteOpen,
            increasedContrast: increasedContrast
        )
    }

    /// The row of the split that `leading` heads. Only the pane in focus is current, so its own `rowStyle(of:)`
    /// decides that; this row is glass while the pair is on screen.
    func rowStyle(ofSplitLedBy leading: BrowserTab, isMarked: Bool, paletteOpen: Bool) -> SidebarRowStyle {
        SidebarRowStyle.splitRow(isOnScreen: isVisibleInSplit(leading), isMarked: isMarked, paletteOpen: paletteOpen)
    }

    func rowStyle(
        of folder: TabFolder,
        isMarked: Bool,
        paletteOpen: Bool,
        increasedContrast: Bool
    ) -> SidebarRowStyle {
        let inside = collapsedContents(of: folder)
        return SidebarRowStyle.folder(
            isMarked: isMarked,
            containsCurrent: inside.containsCurrent,
            containsNew: inside.containsNew,
            paletteOpen: paletteOpen,
            increasedContrast: increasedContrast
        )
    }

    /// What a folder says about the tabs under it, nested folders included. An open folder says nothing: its
    /// rows speak for themselves.
    func collapsedContents(of folder: TabFolder) -> (containsCurrent: Bool, containsNew: Bool) {
        guard !folder.isExpanded else { return (false, false) }
        let inside = allTabs(in: folder)
        return (inside.contains { $0 === activeTab }, inside.contains { $0.isUnseen })
    }
}
