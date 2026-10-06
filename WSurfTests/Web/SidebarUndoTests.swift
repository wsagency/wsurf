// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

@MainActor
struct SidebarUndoTests {
    @Test func deletingFolderCanRestoreItsNestedContentsAndPosition() throws {
        let model = BrowserModel(database: .temporary())
        let after = model.createFolder(named: "After")
        let parent = model.createFolder(named: "Work")
        let nested = model.createFolder(named: "Design")
        model.move([.folder(nested.id)], into: parent)
        parent.color = .blue
        parent.isExpanded = false
        model.pin(parent)
        let before = model.sidebarTree

        model.deleteFolder(parent)
        #expect(model.folder(id: parent.id) == nil)
        #expect(model.folder(id: nested.id) === nested)
        #expect(model.sidebarUndoManager.canUndo)
        model.sidebarUndoManager.undo()

        #expect(model.sidebarTree == before)
        #expect(model.folder(id: parent.id) === parent)
        #expect(parent.name == "Work")
        #expect(parent.color == .blue)
        #expect(parent.isPinned)
        #expect(!parent.isExpanded)
        #expect(model.folder(containing: nested) === parent)
        #expect(model.folder(id: after.id) === after)
        model.sidebarUndoManager.redo()
        #expect(model.folder(id: parent.id) == nil)
    }

    @Test(.boundedWebViews) func undoCloseRestoresPinnedIdentityAndDoesNotLoseNewTabs() throws {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let tab = model.newTab()
        tab.urlString = "https://example.test/inbox"
        tab.pageTitle = "Inbox"
        tab.customTitle = "Mail"
        model.pin(tab)
        let folder = model.createFolder(named: "Work")
        model.move([.tab(tab.id)], into: folder, settlingPins: false)

        model.close(tab)
        let later = model.newTab()
        model.sidebarUndoManager.undo()

        let restored = try #require(model.tab(id: tab.id))
        #expect(restored.customTitle == "Mail")
        #expect(restored.pageTitle == "Inbox")
        #expect(restored.urlString == "https://example.test/inbox")
        #expect(restored.pinnedURL == URL(string: "https://example.test/inbox"))
        #expect(restored.pinnedTitle == "Mail")
        #expect(model.folder(containing: restored) === folder)
        #expect(model.tab(id: later.id) === later)
        #expect(!model.canReopenClosedTab)
        model.sidebarUndoManager.redo()
        #expect(model.tab(id: tab.id) == nil)
        #expect(model.tab(id: later.id) === later)
    }

    @Test(.boundedWebViews) func removingASelectionIsOneUndoOperation() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let first = model.newTab()
        let second = model.newTab()
        let folder = model.createFolder(named: "Work", containing: [first, second])
        let before = model.sidebarTree

        model.close([.folder(folder.id)])
        #expect(model.tabs.isEmpty)
        model.sidebarUndoManager.undo()

        #expect(model.sidebarTree == before)
        #expect(Set(model.tabs.map(\.id)) == [first.id, second.id])
        #expect(!model.sidebarUndoManager.canUndo)
        model.sidebarUndoManager.redo()
        #expect(model.tabs.isEmpty)
        #expect(model.folders.isEmpty)
    }
    @Test(.boundedWebViews) func undoRestoresAVisibleSplitPaneWithoutChangingTheActivePane() throws {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let first = model.newTab()
        first.urlString = "https://example.test/first"
        let second = model.newTab()
        model.split(first, with: second, axis: .sideBySide)
        model.close(first)
        model.sidebarUndoManager.undo()
        let restored = try #require(model.tab(id: first.id))
        #expect(model.activeTabID == second.id)
        #expect(model.isVisibleInSplit(restored))
        #expect(!restored.isDeferred)
        #expect(restored.urlString == "https://example.test/first")
    }

    @Test(.boundedWebViews) func undoAfterExplicitReopeningResolvesTheCurrentTabIdentity() throws {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let tab = model.newTab()
        model.close(tab)
        model.reopenLastClosedTab()
        model.close(try #require(model.tab(id: tab.id)))
        model.sidebarUndoManager.undo()
        #expect(model.tab(id: tab.id) != nil)
        model.sidebarUndoManager.undo()
        #expect(model.tab(id: tab.id) == nil)
        model.sidebarUndoManager.redo()
        #expect(model.tab(id: tab.id) != nil)
        model.sidebarUndoManager.redo()
        #expect(model.tab(id: tab.id) == nil)
    }

    @Test(.boundedWebViews) func removingOtherTabsRestoresTheirSplitInOneUndo() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let first = model.newTab()
        let second = model.newTab()
        model.split(first, with: second, axis: .sideBySide)
        let kept = model.newTab()
        let tree = model.sidebarTree
        let splits = model.splits
        model.closeOthers(kept)
        #expect(model.tabs.map(\.id) == [kept.id])
        model.sidebarUndoManager.undo()
        #expect(model.sidebarTree == tree)
        #expect(model.splits == splits)
        #expect(Set(model.tabs.map(\.id)) == [first.id, second.id, kept.id])
        #expect(!model.sidebarUndoManager.canUndo)
        model.sidebarUndoManager.redo()
        #expect(model.tabs.map(\.id) == [kept.id])
    }

    @Test(.boundedWebViews) func backgroundCloseDoesNotClaimSidebarKeyboardOwnership() {
        let model = BrowserModel(database: .temporary())
        defer { model.closeAllTabs(saving: false) }
        let background = model.newTab()
        _ = model.newTab()
        model.sidebarSelection.clear()
        model.close(background)
        #expect(!model.sidebarSelection.ownsKeyboard)
        #expect(model.sidebarUndoManager.canUndo)
    }
}
