// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// A lazy list of plain tab rows takes its height from the model (`WorkspaceList.uniformHeight`), not from the lazy stack's estimate
/// of the rows it has not built. An estimate that kept changing resized the list's document on every layout pass, which
/// laid the list out again, without end (0.1.22 audit, item 1). So such a list must be exactly as tall as the list that
/// draws every row and hold that height still, its last row must be where the full list puts it, and a reveal far down
/// must bring its row into view in any shape of list.
@MainActor
@Suite(.serialized)
struct SidebarListHeightTests {
    enum Shape: CaseIterable {
        case flat
        case folders
        case splits
        case icons
        case largeIcons
    }

    private func build(_ shape: Shape, in rig: SidebarDriveRig, pages: Int = 300) {
        let browser = rig.browser
        let tabs = rig.addPages(pages)
        switch shape {
        case .flat, .icons, .largeIcons:
            break
        case .folders:
            let open = browser.createFolder(named: "Open", containing: Array(tabs[0..<20]))
            let inner = browser.createFolder(named: "Inner", containing: Array(tabs[20..<30]))
            browser.move([.folder(inner.id)], into: open)
            browser.createFolder(named: "Shut", containing: Array(tabs[30..<50])).isExpanded = false
            browser.createFolder(named: "Empty", containing: []).isExpanded = true
            browser.createFolder(named: "Big", containing: Array(tabs[50..<55])).size = .largest
            browser.createFolder(named: "Big shut", containing: Array(tabs[55..<58])).size = .largest
        case .splits:
            browser.split(tabs[1], with: tabs[2], axis: .sideBySide)
            browser.split(tabs[10], with: tabs[11], axis: .stacked)
            browser.split(tabs[20], with: tabs[21], axis: .stacked)
            browser.createFolder(named: "Split inside", containing: [tabs[20], tabs[21], tabs[22]])
        }
    }

    private func style(_ shape: Shape) -> SidebarStyle {
        shape == .icons ? .icons : .full
    }

    private func documentHeight(_ rig: SidebarDriveRig) throws -> CGFloat {
        try #require(rig.scrollView?.documentView).frame.height
    }

    /// A list with folders, splits or the pin line keeps the lazy stack's own height (see `WorkspaceList.uniformHeight`).
    @Test(arguments: [Shape.flat, .icons, .largeIcons])
    func theLazyListIsExactlyAsTallAsEveryRowAndHoldsStill(_ shape: Shape) async throws {
        let full = SidebarDriveRig(style: style(shape), voiceOver: true)
        defer { full.close() }
        let lazy = SidebarDriveRig(style: style(shape))
        defer { lazy.close() }
        if shape == .largeIcons {
            full.adjustTheme(ThemeAdjustment(tabIconSize: 24))
        }
        build(shape, in: full)
        build(shape, in: lazy)
        try await full.settle(rounds: 20)
        try await lazy.settle(rounds: 20)

        let expected = try documentHeight(full)
        var heights: [CGFloat] = []
        for _ in 0..<15 {
            try await lazy.settle(rounds: 2)
            heights.append(try documentHeight(lazy))
        }
        #expect(heights.allSatisfy { abs($0 - expected) < 0.5 }, "\(shape): every row \(expected), lazy \(heights)")
    }

    /// The bottom of the lowest row drawn, in the list's content, which does not move as it scrolls.
    private func bottom(_ rig: SidebarDriveRig) throws -> CGFloat {
        let frames = rig.coordinator.sidebarDrag.frames
        return try #require(frames.visible(in: rig.browser).values.map { $0.maxY - frames.contentOrigin.y }.max())
    }

    /// Scrolled straight to the end, the lazy list draws its last row where the list that draws every row puts it.
    @Test func theLastRowIsWhereTheFullListPutsItAtTheEnd() async throws {
        let full = SidebarDriveRig(voiceOver: true)
        defer { full.close() }
        let lazy = SidebarDriveRig()
        defer { lazy.close() }
        build(.flat, in: full, pages: 1_000)
        build(.flat, in: lazy, pages: 1_000)
        try await full.settle(rounds: 20)
        try await lazy.settle(rounds: 20)

        let scroll = try #require(lazy.scrollView)
        try await lazy.scroll(to: try documentHeight(lazy) - scroll.contentView.bounds.height)
        let expected = try bottom(full)
        let drawn = try bottom(lazy)
        #expect(abs(drawn - expected) < 0.5, "the last row ends at \(expected), the lazy list's at \(drawn)")
    }

    /// Showing a tab far down the list (a reveal scrolls to a row the lazy stack has not built) brings its row on screen,
    /// inside the list's height: in a plain list, which has the model's height, and in one with splits, which has the
    /// stack's own. (A list with open folders is left out: there the stack's guess can place a far row out of view on its
    /// own, without any fixed height.)
    @Test(arguments: [Shape.flat, .splits])
    func aRevealedRowFarDownIsOnScreenAndInsideTheList(_ shape: Shape) async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        build(shape, in: rig)
        try await rig.settle(rounds: 20)
        let browser = rig.browser
        let hidden = browser.hiddenSidebarTabIDs
        let shown = browser.sidebarTree.visibleRows(isExpanded: { browser.folder(id: $0)?.isExpanded ?? false })
        let last = try #require(shown.last { item in
            guard case .tab(let id) = item else { return false }
            return !hidden.contains(id)
        })
        browser.revealInSidebar(try rig.tab(last))
        try await rig.settle(rounds: 40)

        let frames = rig.coordinator.sidebarDrag.frames
        let height = try documentHeight(rig)
        let offset = rig.scrollView?.contentView.bounds.origin.y ?? -1
        let row = try #require(frames[last], "\(shape): the revealed row is drawn (list \(height) high, scrolled to \(offset))")
        let end = row.maxY - frames.contentOrigin.y
        #expect(end <= height + 0.5, "\(shape): the row ends at \(end), past the list's \(height)")
        let list = try #require(rig.scrollView).frame.height
        #expect(row.minY >= -0.5 && row.maxY <= list + 0.5, "\(shape): the row is at \(row) in a list \(list) high")
    }
}
