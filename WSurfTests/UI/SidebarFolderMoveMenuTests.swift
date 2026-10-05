// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

@MainActor
struct SidebarFolderMoveMenuTests {
    @Test func destinationsFollowTheTreeAndKeepParentsSelectableWithoutAllowingCycles() throws {
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SidebarFolderMoveMenu-\(UUID().uuidString).json")
            )
        )
        let other = browser.createFolder(named: "Other")
        let parent = browser.createFolder(named: "Work")
        let child = browser.createFolder(named: "Design")
        let leaf = browser.createFolder(named: "Assets")
        browser.move([.folder(child.id)], into: parent)
        browser.move([.folder(leaf.id)], into: child)
        parent.isExpanded = false
        child.isExpanded = false
        let tab = browser.newTab()
        let items: [SidebarItem] = [.tab(tab.id)]

        let menu = FolderContextMenu.moveMenu(items, browser: browser)
        #expect(menu.items.prefix(2).map(\.title) == [parent.name, other.name])
        let parentMenu = try #require(menu.items.first?.submenu)
        #expect(parentMenu.items.dropFirst(2).map(\.title) == [child.name])
        let childMenu = try #require(parentMenu.items.last?.submenu)
        #expect(childMenu.items.dropFirst(2).map(\.title) == [leaf.name])
        #expect(childMenu.items.last?.submenu == nil)

        parentMenu.performActionForItem(at: 0)
        #expect(browser.folder(containing: tab) === parent)
        childMenu.performActionForItem(at: 0)
        #expect(browser.folder(containing: tab) === child)
        childMenu.performActionForItem(at: 2)
        #expect(browser.folder(containing: tab) === leaf)

        let movingParent = FolderContextMenu.moveMenu([.folder(parent.id)], browser: browser)
        #expect(movingParent.items.first?.title == other.name)
        #expect(movingParent.items.filter { !$0.isSeparatorItem }.count == 2)
        let movingChild = FolderContextMenu.moveMenu([.folder(child.id)], browser: browser)
        #expect(movingChild.items.first?.title == parent.name)
        #expect(movingChild.items.first?.submenu == nil)
        movingChild.performActionForItem(at: 1)
        #expect(browser.folder(containing: child) === other)
        #expect(browser.folder(containing: leaf) === child)
    }
}
