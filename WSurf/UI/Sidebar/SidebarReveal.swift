// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A request to show the row of a tab that was just opened: the list scrolls to it and the row pulses. `token` tells
/// two requests for one tab apart, `start` is when the pulse began.
struct SidebarReveal: Equatable {
    let tabID: UUID
    let token: Int
    let start: Date
}

/// Where the list scrolls to show a new tab, and when it does not. The row goes to the middle of the list (the list
/// stops at its ends, so a row near the top or bottom lands as far toward the middle as there is room for). A row in a
/// folder that is not drawn yet cannot be found by its own id, so the list first goes to the top-level folder around it,
/// which draws all its rows, and then to the row.
nonisolated enum SidebarRevealPlan {
    struct Step: Equatable {
        let item: SidebarItem
        let anchor: UnitPoint
    }

    /// The scrolls to make, in order; none while a row is dragged or renamed, or the person is scrolling the list
    /// themselves. `isDrawn` says whether the list has built the row of an item.
    static func steps(
        for tabID: UUID,
        in tree: SidebarTree,
        isDrawn: (SidebarItem) -> Bool,
        isDragging: Bool,
        isRenaming: Bool,
        isScrolling: Bool
    ) -> [Step] {
        guard !isDragging, !isRenaming, !isScrolling else { return [] }
        let row = Step(item: .tab(tabID), anchor: .center)
        guard let outermost = outermostFolder(above: .tab(tabID), in: tree), !isDrawn(.folder(outermost)) else { return [row] }
        return [Step(item: .folder(outermost), anchor: .top), row]
    }

    /// The folder at the top level of the list that holds `item`, or nil for a row at the top level.
    static func outermostFolder(above item: SidebarItem, in tree: SidebarTree) -> UUID? {
        let parents = tree.parents()
        var outermost: UUID?
        var walked = Set<UUID>()
        var current = parents[item]
        while let id = current, walked.insert(id).inserted {
            outermost = id
            current = parents[.folder(id)]
        }
        return outermost
    }
}

/// The pulse of a revealed row: how strongly the highlight draws `elapsed` seconds after the reveal. Two soft swells
/// of the accent over 0.8 s; with Reduce Motion one steady highlight that fades, so nothing swells or moves.
nonisolated enum SidebarPulse {
    static let duration: TimeInterval = 0.8
    /// The strongest the wash gets, as an opacity of the accent. The row's edge draws at a multiple of it.
    static let peak = 0.26
    static let edgeStrength = 2.6

    static func opacity(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let progress = elapsed / duration
        if reduceMotion {
            return peak * (1 - progress) * (1 - progress)
        }
        // 0 at the start, the peak a quarter in, 0 at the half, the peak at three quarters, 0 at the end.
        return peak * 0.5 * (1 - cos(4 * .pi * progress))
    }
}

extension EnvironmentValues {
    /// Whether the rows below pulse when the sidebar is asked to show their tab. The sidebar's list turns it on; a row
    /// drawn anywhere else (a drag chip, a test) never pulses.
    @Entry var sidebarPulsesRevealedRows = false
}

/// The highlight of a revealed row, laid over it. It reads the model itself, so a reveal redraws this view and not
/// every row, and it works from the time the reveal began, so a row that the list draws late joins the pulse where it
/// is. It takes no clicks and no focus.
struct SidebarRevealPulse: View {
    let browser: BrowserModel
    let tabID: UUID
    let radius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarPulsesRevealedRows) private var isOn

    var body: some View {
        if isOn, let reveal = browser.sidebarReveal, reveal.tabID == tabID {
            TimelineView(.animation) { timeline in
                let strength = SidebarPulse.opacity(
                    elapsed: timeline.date.timeIntervalSince(reveal.start), reduceMotion: reduceMotion
                )
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                shape
                    .fill(Theme.accent.opacity(strength))
                    .overlay { shape.strokeBorder(Theme.accent.opacity(strength * SidebarPulse.edgeStrength), lineWidth: 1.5) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
