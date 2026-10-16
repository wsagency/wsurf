// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Every sidebar row draws from `SidebarRowStyle`, so these tests cover the states once for all of them: the
/// current tab, a marked row, a tab never opened, and the folders and splits that hold them.
@MainActor
struct SidebarRowStyleTests {
    private func resolve(
        current: Bool = false,
        marked: Bool = false,
        unseen: Bool = false,
        paletteOpen: Bool = false,
        increasedContrast: Bool = false
    ) -> SidebarRowStyle {
        SidebarRowStyle.resolve(
            isCurrent: current,
            isMarked: marked,
            isUnseen: unseen,
            paletteOpen: paletteOpen,
            increasedContrast: increasedContrast
        )
    }

    private func makeModel() -> BrowserModel {
        BrowserModel(database: .temporary())
    }

    // MARK: - Emphasis

    @Test func theCurrentRowIsSelected() {
        #expect(resolve(current: true).emphasis == .current)
        #expect(resolve(current: true).isSelected)
        #expect(!resolve().isSelected)
    }

    /// A marked row keeps the faint glass, which is now different from the current row's inverse colors.
    @Test func aMarkedRowKeepsTheGlass() {
        let marked = resolve(marked: true)

        #expect(marked.emphasis == .lit)
        #expect(marked.isSelected)
        #expect(resolve(current: true, marked: true).emphasis == .current, "the current row stays inverse in a selection")
    }

    @Test func nothingIsCurrentWhileTheNewTabPaletteIsOpen() {
        let current = resolve(current: true, paletteOpen: true)

        #expect(current.emphasis == .resting)
        #expect(!current.isSelected)
        #expect(resolve(marked: true, paletteOpen: true).emphasis == .lit)
    }

    // MARK: - New tabs

    @Test func aNewRowSaysNew() {
        let new = resolve(unseen: true)

        #expect(new.mark == .accent)
        #expect(new.statuses == [.new])
        #expect(new.spokenStatus == String(localized: "New"))
        #expect(resolve().mark == .none)
        #expect(resolve().spokenStatus == nil)
    }

    @Test func currentOutranksNew() {
        let current = resolve(current: true, unseen: true)

        #expect(current.emphasis == .current)
        #expect(current.mark == .none)
        #expect(current.spokenStatus == nil)
    }

    @Test func aNewRowStaysNewUnderThePalette() {
        let behindPalette = resolve(current: true, unseen: true, paletteOpen: true)

        #expect(behindPalette.emphasis == .resting)
        #expect(behindPalette.mark == .accent)
    }

    @Test func increasedContrastDrawsTheDotInInk() {
        #expect(resolve(unseen: true, increasedContrast: true).mark == .ink)
        #expect(resolve(unseen: true, increasedContrast: false).mark == .accent)
    }

    // MARK: - Splits

    /// The split row keeps its glass to show the pair is on screen; only the pane in focus is inverse.
    @Test func onlyTheFocusedPaneIsInverse() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab()
        model.split(left, with: right, axis: .sideBySide)
        model.activate(right)

        func pane(_ tab: BrowserTab) -> SidebarRowStyle.Emphasis {
            model.rowStyle(of: tab, isMarked: false, paletteOpen: false, increasedContrast: false).emphasis
        }
        #expect(pane(right) == .current)
        #expect(pane(left) == .resting)
        let row = model.rowStyle(ofSplitLedBy: left, isMarked: false, paletteOpen: false)
        #expect(row.emphasis == .lit)

        model.activate(left)
        #expect(pane(left) == .current)
        #expect(pane(right) == .resting)
    }

    @Test func aSplitOffScreenIsNotLit() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab()
        model.split(left, with: right, axis: .sideBySide)
        let other = model.newTab()
        #expect(model.activeTab === other)

        #expect(model.rowStyle(ofSplitLedBy: left, isMarked: false, paletteOpen: false).emphasis == .resting)
        #expect(model.rowStyle(ofSplitLedBy: left, isMarked: true, paletteOpen: false).emphasis == .lit)
    }

    @Test func aSplitOnScreenIsNotLitUnderThePalette() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab()
        model.split(left, with: right, axis: .sideBySide)
        model.activate(left)

        #expect(model.rowStyle(ofSplitLedBy: left, isMarked: false, paletteOpen: true).emphasis == .resting)
    }

    // MARK: - Folders

    @Test func aCollapsedFolderMarksTheCurrentTabInside() {
        let style = SidebarRowStyle.folder(
            isMarked: false,
            containsCurrent: true,
            containsNew: false,
            paletteOpen: false,
            increasedContrast: false
        )

        #expect(style.marksCurrentTab)
        #expect(style.emphasis == .resting, "the folder is never the current row")
        #expect(style.spokenStatus == String(localized: "Contains current tab"))
    }

    @Test func aCollapsedFolderWithBothSaysBoth() {
        let style = SidebarRowStyle.folder(
            isMarked: true,
            containsCurrent: true,
            containsNew: true,
            paletteOpen: false,
            increasedContrast: false
        )

        #expect(style.marksCurrentTab)
        #expect(style.mark == .accent)
        #expect(style.emphasis == .lit)
        #expect(style.statuses == [.containsCurrent, .containsNew])
    }

    @Test func aFolderMarksNoCurrentTabUnderThePalette() {
        let style = SidebarRowStyle.folder(
            isMarked: false,
            containsCurrent: true,
            containsNew: false,
            paletteOpen: true,
            increasedContrast: false
        )

        #expect(!style.marksCurrentTab)
        #expect(style.spokenStatus == nil)
    }
}
