// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Testing

@testable import WSurf

/// A row of the sidebar draws again when something it read changes: whether it is marked (`SidebarSelection.contains`) and
/// whether a drag is going (`SidebarDragModel.drag`). A click that marks nothing and a step of a drag change neither, so they must
/// not tell any row to draw again. Checked with the observation SwiftUI uses for a view.
@MainActor
struct SidebarInvalidationTests {
    /// Raised by an observation's change handler, which runs where the change is made: here, on the main actor.
    private nonisolated final class Flag: @unchecked Sendable {
        var isRaised = false
    }

    /// Whether `change` tells something that has read what `read` reads to draw again.
    private func invalidates(_ read: () -> Void, by change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read, onChange: { flag.isRaised = true })
        change()
        return flag.isRaised
    }

    @Test func aClickThatMarksNothingTellsNoOtherRowToDrawAgain() {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let rows = (0..<3).map { browser.addPage("https://row\($0).example/") }
        let favorite = browser.addPage("https://favorite.example/")
        favorite.isFavorite = true
        let selection = SidebarSelection()
        let other = SidebarItem.tab(rows[2].id)

        // What a plain click on a row does to the selection (`SidebarTabRow.tapped`), twice: the second lands where the first did.
        for clicked in [rows[0], rows[1], rows[1]] {
            #expect(!invalidates({ _ = selection.contains(other) }, by: {
                selection.anchor(on: .tab(clicked.id))
                selection.excludeFavorites([favorite])
            }), "a click on \(clicked.urlString)")
        }
    }

    @Test func aChangeThatChangesNothingTellsNoRowToDrawAgain() {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let rows = (0..<3).map { SidebarItem.tab(browser.addPage("https://row\($0).example/").id) }
        let selection = SidebarSelection()
        let read = { _ = selection.contains(rows[2]) }

        #expect(!invalidates(read) { selection.clear() })
        #expect(!invalidates(read) { selection.dropMarks() })
        selection.select(rows[0])
        #expect(!invalidates(read) { selection.select(rows[0]) })
        #expect(!invalidates(read) { selection.prune(to: Set(rows)) })
        #expect(!invalidates(read) { selection.excludeFavorites([]) })
    }

    @Test func aChangeOfTheMarksStillTellsTheRows() {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let rows = (0..<3).map { browser.addPage("https://row\($0).example/") }
        let selection = SidebarSelection()
        let read = { _ = selection.contains(.tab(rows[2].id)) }

        #expect(invalidates(read) { selection.toggle(.tab(rows[2].id)) })
        #expect(invalidates(read) { selection.anchor(on: .tab(rows[0].id)) }, "a click clears the marks")
        selection.toggle(.tab(rows[1].id))
        rows[1].isFavorite = true
        #expect(invalidates(read) { selection.excludeFavorites([rows[1]]) }, "a marked favorite leaves the marks")
        #expect(selection.isEmpty)
    }

    @Test func aStepOfADragTellsOnlyTheChip() {
        let model = SidebarDragModel()
        let item = SidebarItem.tab(UUID())
        model.drag = SidebarDrag(items: [item], lead: item, origin: .zero, tree: SidebarTree(root: [item], children: [:]),
                                 keepsSection: false, wasKept: false)

        for step in 1...3 {
            let width = CGFloat(step) * 2
            #expect(!invalidates({ _ = model.drag }, by: { model.translation = CGSize(width: width, height: 0) }), "the list and the rows")
            #expect(invalidates({ _ = model.translation }, by: { model.translation = CGSize(width: width + 1, height: 0) }))
        }
        #expect(invalidates({ _ = model.drag }, by: { model.drag?.landing = true }), "landing is a change of the drag")
    }

    /// A row builds its context menu with its body, so whatever the menu reads is read by the row. A row must not read the other
    /// tabs (Remove Other Tabs), the splits (Exit Split) or the window (Move to Micro Window): they would draw every row that is
    /// on screen again whenever a tab opens, closes or is pinned.
    @Test func aRowReadsNothingAboutTheOtherTabs() {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        let browser = coordinator.browser
        defer { browser.cancelPendingSave() }
        let tab = browser.addPage("https://row.example/")
        let other = browser.addPage("https://other.example/")
        // The current tab has its own row, which does change when another tab opens; the row under test is not that one.
        browser.activeTabID = browser.addPage("https://current.example/").id
        let context = SidebarRowContext(
            browser: browser,
            coordinator: coordinator,
            selection: browser.sidebarSelection,
            drag: nil,
            pinsCarried: false,
            space: "invalidation",
            frames: SidebarFrames()
        )
        let row = SidebarTabRow(tab: tab, depth: 0, context: context)
        let read = { _ = row.body }

        #expect(invalidates(read) { tab.title = "Renamed" }, "the row does read its own tab")
        #expect(!invalidates(read) { _ = browser.newTab(url: nil, activate: false) }, "a tab opens")
        #expect(!invalidates(read) { other.pinnedURL = URL(string: "https://other.example/") }, "another tab is pinned")
        #expect(!invalidates(read) { browser.close(other) }, "another tab closes")
    }

    /// The button on the right of a row follows the Command key (it unloads instead of closing). One that is not shown must not read
    /// the key: every row that is drawn has one, and a press would draw them all.
    @Test func aCloseButtonThatIsNotShownDoesNotFollowTheCommandKey() {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.browser.cancelPendingSave() }
        let tab = coordinator.browser.addPage("https://row.example/")
        let hidden = SidebarTabActionButton(tab: tab, coordinator: coordinator, followsCommandKey: false)
        let shown = SidebarTabActionButton(tab: tab, coordinator: coordinator)

        #expect(invalidates({ _ = shown.body }, by: { coordinator.linkModifiers = [.command] }), "a shown button follows the key")
        #expect(!invalidates({ _ = hidden.body }, by: { coordinator.linkModifiers = [] }), "the key comes up")
        #expect(!invalidates({ _ = hidden.body }, by: { coordinator.linkModifiers = [.command] }), "the key goes down")
    }
}
