// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import WSurf

@MainActor
struct FolderIconTintTests {
    // MARK: - The setting

    @Test func aFolderTintsNoIconsUntilToldTo() {
        #expect(!TabFolder(name: "Work").tintsIcons)
    }

    @Test func theMenuItemSitsNextToSizeAndTogglesWithOneUndoStepEach() throws {
        let rig = SidebarRowRig(space: "FolderIconTintTests")
        defer { rig.restore() }
        let browser = rig.browser
        let folder = browser.createFolder(named: "Work")

        let menu = FolderContextMenu.make(
            folder: folder, browser: browser, coordinator: rig.coordinator, selected: [], onRename: {}
        )
        let titles = menu.items.map(\.title)
        let size = try #require(titles.firstIndex(of: "Size"))
        #expect(titles[size + 1] == "Tint Icons as Folder", "the item follows Size")
        #expect(menu.items[size + 1].state == .off)

        menu.performActionForItem(at: size + 1)
        #expect(folder.tintsIcons)
        #expect(FolderContextMenu.tintIconsItem(for: folder, browser: browser).state == .on, "the menu checks it while on")

        browser.sidebarUndoManager.undo()
        #expect(!folder.tintsIcons, "one undo step puts it back")
        #expect(!browser.sidebarUndoManager.canUndo)
        browser.sidebarUndoManager.redo()
        #expect(folder.tintsIcons)

        browser.setFolderTintsIcons(true, for: folder)
        browser.sidebarUndoManager.undo()
        #expect(!folder.tintsIcons && !browser.sidebarUndoManager.canUndo, "choosing what it already is is not a step")
    }

    @Test func theSettingSurvivesARestartAndRowsSavedWithoutOneReadOff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderIconTint-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = AppDatabase(at: url)
        let browser = BrowserModel(database: database)
        let pinned = browser.createFolder(named: "Pinned")
        browser.pin(pinned)
        let loose = browser.createFolder(named: "Loose")
        let plain = browser.createFolder(named: "Plain")
        browser.setFolderTintsIcons(true, for: pinned)
        browser.setFolderTintsIcons(true, for: loose)
        browser.saveBlocking()

        let restored = BrowserModel(database: AppDatabase(at: url))
        restored.restoreSession()
        #expect(restored.folder(id: pinned.id)?.tintsIcons == true, "a pinned folder keeps it with the profile's pins")
        #expect(restored.folder(id: loose.id)?.tintsIcons == true, "any other folder keeps it with its window")
        #expect(restored.folder(id: plain.id)?.tintsIcons == false)

        try database.writer.write { db in
            try db.execute(sql: "ALTER TABLE sessionFolder DROP COLUMN tintsIcons")
            try db.execute(sql: "ALTER TABLE profilePin DROP COLUMN tintsIcons")
        }
        let older = BrowserModel(database: AppDatabase(at: url))
        older.restoreSession()
        #expect(older.folders.count == 3)
        #expect(older.folders.allSatisfy { !$0.tintsIcons })
    }

    @Test func aFolderTintReplacesTheRowInkAndTheThemesColorFavicons() {
        let resting = SidebarRowStyle(emphasis: .resting, mark: .none, marksCurrentTab: false, statuses: [])
        let ink = SidebarRowInk(style: resting, resting: .white, colors: nil)

        let own = ink.iconStyle(folderTint: nil, colorsFavicon: true, isDeferred: false)
        #expect(own.tint == .white && own.colorsFavicon, "outside a tinting folder nothing changes")

        let tinted = ink.iconStyle(folderTint: .red, colorsFavicon: true, isDeferred: false)
        #expect(tinted.tint == .red && !tinted.colorsFavicon, "a color favicon is drawn as a monochrome in the folder's color")

        let asleep = ink.iconStyle(folderTint: .red, colorsFavicon: false, isDeferred: true)
        #expect(asleep.tint == Color.red.opacity(ThemeVariant.unloadedOpacity), "an unloaded tab stays dimmer than a loaded one")
    }

    // MARK: - What is drawn

    /// A tab that shows a page and has no favicon draws a globe, a symbol that takes its color from the row. (A favicon
    /// is tinted by a Metal shader, which an unshown window does not necessarily run; the row hands it the same tint.)
    private func page(_ browser: BrowserModel) -> BrowserTab {
        let tab = browser.newTab()
        tab.title = "HHH"
        tab.urlString = "https://example.com/"
        return tab
    }

    /// The color of the strokes of the icon of the row at `top`, `inset` points in from the left.
    private func icon(in picture: SidebarRowRig.Picture, top: CGFloat, inset: CGFloat, rig: SidebarRowRig) throws -> NSColor {
        let base = try picture.color(x: SidebarRowRig.width - 4, y: 0.5)
        return try #require(picture.strongestColor(
            x: inset...(inset + SidebarMetrics.rowIconSize), y: top...(top + rig.rowHeight), against: base
        ))
    }

    private func isRed(_ color: NSColor) -> Bool {
        color.redComponent - color.blueComponent > 0.3
    }

    private func isGreen(_ color: NSColor) -> Bool {
        color.greenComponent - color.redComponent > 0.2
    }

    private func isNeutral(_ color: NSColor) -> Bool {
        abs(color.redComponent - color.blueComponent) < 0.1 && abs(color.redComponent - color.greenComponent) < 0.1
    }

    /// Two open folders, one inside the other, with a tab inside the inner one. The outline of an open folder is 2 pt
    /// inside its parent's, so the icon of the tab is at the row's padding plus two outlines.
    @Test func theIconsInsideATintingFolderTakeItsColorAndSubfoldersThatDoNotTintInheritIt() throws {
        let rig = SidebarRowRig(space: "FolderIconTintTests")
        defer { rig.restore() }
        let browser = rig.browser
        let tab = page(browser)
        let inner = browser.createFolder(named: "Inner", containing: [tab])
        let outer = browser.createFolder(named: "Outer")
        browser.move([.folder(inner.id)], into: outer)
        _ = browser.newTab()
        outer.color = .red
        inner.color = .green
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)
        let outline = FolderSection.outlineInset
        let total = 3 * row + 2 * spacing + 4 * outline
        let tabTop = outline + row + spacing + outline + row + spacing
        let inset = SidebarMetrics.rowContentPadding(style: .full) + 2 * outline

        func tabIcon() throws -> NSColor {
            let picture = try rig.picture(of: rig.sidebar(FolderSection(folder: outer, depth: 0, context: rig.context), height: total))
            return try icon(in: picture, top: tabTop, inset: inset, rig: rig)
        }

        #expect(isNeutral(try tabIcon()), "by default a tab keeps the color of its row")
        outer.tintsIcons = true
        #expect(isRed(try tabIcon()), "the outer folder's color reaches a tab two folders down")
        inner.tintsIcons = true
        #expect(isGreen(try tabIcon()), "the nearest folder that tints wins")
        outer.tintsIcons = false
        #expect(isGreen(try tabIcon()), "a folder tints on its own")
        inner.tintsIcons = false
        #expect(isNeutral(try tabIcon()), "and puts it back")
    }

    @Test func aTabOutsideEveryTintingFolderAndTheCurrentTabKeepTheirOwnInk() throws {
        let rig = SidebarRowRig(space: "FolderIconTintTests")
        defer { rig.restore() }
        let browser = rig.browser
        let inside = page(browser)
        let current = page(browser)
        let outside = page(browser)
        let folder = browser.createFolder(named: "Work", containing: [inside, current])
        folder.color = .red
        folder.tintsIcons = true
        browser.activate(current)
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)
        let outline = FolderSection.outlineInset
        let total = 3 * row + 2 * spacing + 2 * outline
        let inset = SidebarMetrics.rowContentPadding(style: .full) + outline

        let section = try rig.picture(of: rig.sidebar(FolderSection(folder: folder, depth: 0, context: rig.context), height: total))
        let insideIcon = try icon(in: section, top: outline + row + spacing, inset: inset, rig: rig)
        #expect(isRed(insideIcon), "a tab in the folder is tinted")
        let currentIcon = try icon(in: section, top: outline + 2 * (row + spacing), inset: inset, rig: rig)
        #expect(!isRed(currentIcon), "the current tab is drawn on an inverse fill and keeps the ink that reads on it")

        let alone = try rig.picture(of: rig.sidebar(SidebarTabRow(tab: outside, depth: 0, context: rig.context), height: row))
        #expect(isNeutral(try icon(in: alone, top: 0, inset: SidebarMetrics.rowContentPadding(style: .full), rig: rig)))
    }
}
