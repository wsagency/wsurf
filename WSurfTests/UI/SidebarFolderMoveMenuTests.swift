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

    @Test func creatingFromTheMoveMenuRequestsNamingAndRevealsTheFolder() throws {
        let browser = BrowserModel(database: .temporary())
        let parent = browser.createFolder(named: "Parent")
        let child = browser.createFolder(named: "Child")
        browser.move([.folder(child.id)], into: parent)
        parent.isExpanded = false
        let menu = FolderContextMenu.moveMenu([.folder(child.id)], browser: browser)

        menu.performActionForItem(at: menu.items.count - 1)

        let id = try #require(browser.folderRenameID)
        let created = try #require(browser.folder(id: id))
        #expect(browser.folder(containing: child) === created)
        #expect(created.isExpanded)
        var ancestor = browser.sidebarTree.parent(of: .folder(id))
        while let ancestorID = ancestor {
            #expect(browser.folder(id: ancestorID)?.isExpanded == true)
            ancestor = browser.sidebarTree.parent(of: .folder(ancestorID))
        }
        browser.renameFolder(created, to: "Manual name")
        browser.finishFolderRename(id)
        #expect(browser.folderRenameID == nil)
        #expect(created.name == "Manual name")
    }

    @Test func lowerFolderRowsReceiveContextMenuMouseHitsInSuperviewCoordinates() throws {
        let window = FolderContextEventWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        window.contentView = parent
        let catcher = FolderContextMenuCatcher.CatcherView(
            frame: NSRect(x: 20, y: 60, width: 120, height: 28)
        )
        parent.addSubview(catcher)
        window.event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 40, y: 74),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        #expect(catcher.hitTest(NSPoint(x: 40, y: 74)) === catcher)
        #expect(catcher.hitTest(NSPoint(x: 40, y: 54)) == nil)
    }
}

@MainActor
private final class FolderContextEventWindow: NSWindow {
    var event: NSEvent?

    override var currentEvent: NSEvent? {
        event
    }
}
