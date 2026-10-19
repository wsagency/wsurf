// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The selection model is pure: rows in, a set and a cursor out. The page tells it which rows it shows; nothing else reaches it.

@MainActor
struct CredentialSelectionTests {
    private let ids = (0..<6).map { _ in UUID() }

    private func selection(showing rows: [UUID]? = nil) -> CredentialSelection {
        let selection = CredentialSelection()
        selection.show(rows ?? ids)
        return selection
    }

    @Test func spaceTogglesTheCursorRow() {
        let selection = selection()
        selection.takeKeyboard()
        #expect(selection.cursor == ids[0], "the keyboard starts on the first row")
        selection.toggleCursor()
        #expect(selection.selected == [ids[0]])
        selection.moveCursor(by: 2, extending: false)
        selection.toggleCursor()
        #expect(selection.selected == [ids[0], ids[2]])
        selection.toggleCursor()
        #expect(selection.selected == [ids[0]])
    }

    @Test func aPlainClickTakesTheKeyboardButSelectsNothing() {
        let selection = selection()
        selection.click(ids[3])
        #expect(selection.cursor == ids[3] && selection.ownsKeyboard)
        #expect(selection.selected.isEmpty)
        #expect(selection.targets == [ids[3]], "with nothing selected an action acts on the cursor row")
    }

    @Test func shiftExtendsFromTheAnchorInListOrder() {
        let selection = selection()
        selection.click(ids[1])
        selection.moveCursor(by: 2, extending: true)
        #expect(selection.selected == Set(ids[1...3]))
        selection.moveCursor(by: -1, extending: true)
        #expect(selection.selected == Set(ids[1...2]), "moving back shrinks the range")
        selection.moveCursor(by: -5, extending: true)
        #expect(selection.selected == Set(ids[0...1]), "the range runs the other way past the anchor, and stops at the first row")
        selection.extend(to: ids[4])
        #expect(selection.selected == Set(ids[1...4]), "a shift-click selects from the anchor too")
        #expect(selection.cursor == ids[4])
    }

    @Test func theCursorStopsAtBothEnds() {
        let selection = selection()
        selection.takeKeyboard()
        selection.moveCursor(by: -1, extending: false)
        #expect(selection.cursor == ids[0])
        selection.moveCursor(by: 100, extending: false)
        #expect(selection.cursor == ids[5])
        selection.moveCursor(by: 1, extending: false)
        #expect(selection.cursor == ids[5])
    }

    @Test func selectAllTakesOnlyVisibleRows() {
        let selection = selection(showing: Array(ids[0..<3]))
        selection.selectAll()
        #expect(selection.selected == Set(ids[0..<3]))
        #expect(selection.targets == Array(ids[0..<3]))
    }

    @Test func aSearchPrunesHiddenSelections() {
        let selection = selection()
        selection.selectAll()
        selection.click(ids[5])
        selection.show(Array(ids[0..<3]))
        #expect(selection.selected == Set(ids[0..<3]), "a row the list stops showing leaves the selection")
        #expect(selection.cursor == nil, "and the cursor, so an action never acts on a row you cannot see")
        #expect(selection.targets == Array(ids[0..<3]))
    }

    @Test func targetsAreTheSelectionElseTheCursor() {
        let selection = selection()
        selection.click(ids[2])
        #expect(selection.targets == [ids[2]])
        selection.toggle(ids[4])
        selection.toggle(ids[1])
        #expect(selection.targets == [ids[1], ids[4]], "the selection, in list order, not the cursor row")
        selection.clear()
        #expect(selection.targets == [ids[1]], "after clearing, the cursor row again")
        let none = CredentialSelection()
        #expect(none.targets.isEmpty)
    }

    @Test func cursorMovesToTheNextRowAfterRemoval() {
        let selection = selection()
        #expect(selection.cursorAfterRemoving([ids[2]]) == ids[3])
        #expect(selection.cursorAfterRemoving([ids[1], ids[2]]) == ids[3])
        #expect(selection.cursorAfterRemoving([ids[5]]) == ids[4], "the last row hands over to the one before")
        #expect(selection.cursorAfterRemoving([ids[4], ids[5]]) == ids[3])
        #expect(selection.cursorAfterRemoving(ids) == nil)
    }

    @Test func bySiteUsesGroupOrder() {
        // Two groups, listed one after the other: the order the page passes is the order of the keys, not of the vault.
        let grouped = [ids[3], ids[0], ids[5], ids[1]]
        let selection = selection(showing: grouped)
        selection.takeKeyboard()
        #expect(selection.cursor == ids[3])
        selection.moveCursor(by: 1, extending: false)
        #expect(selection.cursor == ids[0])
        selection.moveCursor(by: 2, extending: true)
        #expect(selection.selected == [ids[0], ids[5], ids[1]])
        #expect(selection.targets == [ids[0], ids[5], ids[1]])
    }

    @Test func clearingKeepsTheCursorAndLeavingTheKeyboardKeepsTheSelection() {
        let selection = selection()
        selection.click(ids[2])
        selection.toggleCursor()
        selection.releaseKeyboard()
        #expect(!selection.ownsKeyboard && selection.selected == [ids[2]])
        selection.clear()
        #expect(selection.selected.isEmpty && selection.cursor == ids[2])
        selection.reset()
        #expect(selection.cursor == nil && selection.order.isEmpty && !selection.ownsKeyboard)
    }

    @Test func takingTheKeyboardAgainKeepsTheCursorOrStartsWhereAsked() {
        let selection = selection()
        selection.takeKeyboard(cursor: ids[4])
        #expect(selection.cursor == ids[4])
        let request = selection.keyboardRequestID
        selection.takeKeyboard()
        #expect(selection.cursor == ids[4] && selection.keyboardRequestID == request + 1)
        selection.takeKeyboard(cursor: UUID())
        #expect(selection.cursor == ids[4], "a row the list does not show is not a place to start")
    }
}
