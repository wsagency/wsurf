// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// The three Folder indent steps, drawn: each level of an open folder moves its rows in by its own step, the steps add
/// up down the tree, and the icon still meets the capitals of its title at every value. The math and the migration of
/// a theme saved with the one indent that came before are in `ThemeSpacingTests`.
@MainActor
struct FolderIndentLevelTests {
    /// Five folders, each inside the one before, with the first four open and the last shut. An open folder draws an
    /// outline 2 pt inside its parent's, so each open folder's row starts 2 pt and one step right of its parent's; the
    /// shut one has no outline and starts one step right. The titles are read, not the icons: their edges are flat and
    /// their ink is as strong at every row.
    @Test(arguments: [[0.0, 0, 0], [4, 8, 12], [8, 8, 8], [24, 0, 2], [0, 10, 20]])
    func eachLevelOfAnOpenFolderMovesItsRowsInByItsOwnStep(steps: [Double]) throws {
        let rig = SidebarRowRig(space: "FolderIndentLevelTests")
        defer { rig.restore() }
        let settings = BrowserSettings.application
        rig.adjust(ThemeAdjustment(folderIndentLevel1: steps[0], folderIndentLevel2: steps[1], folderIndentLevel3: steps[2]))
        let browser = rig.browser
        let folders = (0..<5).map { _ in browser.createFolder(named: "HHH") }
        for (parent, child) in zip(folders, folders.dropFirst()) {
            browser.move([.folder(child.id)], into: parent)
        }
        folders.forEach { $0.color = .red }
        folders.last?.isExpanded = false

        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: settings)
        let outline = FolderSection.outlineInset
        let total = 5 * row + 4 * spacing + 8 * outline
        // The middle of each row, and where each row's icon ends if the indent is what it should be.
        var centers: [CGFloat] = [outline + row / 2]
        for index in 1..<5 {
            centers.append(centers[index - 1] + row + spacing + (index < 4 ? outline : 0))
        }
        let level = [steps[0], steps[1], steps[2], steps[2]]
        var insets: [CGFloat] = [outline]
        for index in 1..<5 {
            insets.append(insets[index - 1] + (index < 4 ? outline : 0) + level[index - 1])
        }
        let iconEnds = insets.map { SidebarMetrics.rowContentPadding(style: .full) + SidebarMetrics.rowIconSize + $0 }

        let picture = try rig.picture(of: rig.sidebar(FolderSection(folder: folders[0], depth: 0, context: rig.context), height: total))
        let base = try picture.color(x: SidebarRowRig.width - 4, y: 0.5)
        let edges = try zip(centers, iconEnds).map { center, end in
            try #require(try picture.leftEdge(in: (center - 3)...(center + 3), from: end + 2, against: base))
        }

        for index in 1..<5 {
            let expected = (index < 4 ? outline : 0) + level[index - 1]
            #expect(
                abs((edges[index] - edges[index - 1]) - expected) <= 1,
                "row \(index) starts \(edges[index] - edges[index - 1]) pt right of row \(index - 1), expected \(expected), with steps \(steps)"
            )
        }
    }

    @Test func theIconsOnlySidebarIgnoresTheIndent() throws {
        let rig = SidebarRowRig(space: "FolderIndentLevelTests")
        defer { rig.restore() }
        let settings = BrowserSettings.application
        func edge(of steps: Double) throws -> CGFloat {
            rig.adjust(ThemeAdjustment(folderIndentLevel1: steps, folderIndentLevel2: steps, folderIndentLevel3: steps))
            let browser = rig.browser
            let outer = browser.createFolder(named: "Outer")
            let inner = browser.createFolder(named: "Inner")
            browser.move([.folder(inner.id)], into: outer)
            outer.color = .red
            inner.color = .red
            inner.isExpanded = false
            let row = rig.rowHeight
            let spacing = SidebarMetrics.rowVerticalSpacing(settings: settings)
            let outline = FolderSection.outlineInset
            let total = 2 * row + spacing + 4 * outline
            let picture = try rig.picture(of: rig.sidebar(
                FolderSection(folder: outer, depth: 0, context: rig.context),
                width: SidebarMetrics.iconsWidth, height: total, style: .icons
            ))
            let base = try picture.color(x: 1, y: 0.5)
            let center = outline + row + spacing + outline + row / 2
            return try #require(try picture.leftEdge(in: (center - 3)...(center + 3), from: 0, against: base))
        }
        let none = try edge(of: 0)
        let wide = try edge(of: 24)
        #expect(abs(none - wide) <= 0.6, "the inner folder is at \(none) pt with no indent and \(wide) pt with 24 pt")
    }

    /// A tab two folders down, at every value of the steps: the icon's ink and the capitals of its title meet. Moving a
    /// row in changes where it is, not how high its icon sits.
    @Test(arguments: [[0.0, 0, 0], [10, 10, 10], [24, 24, 24], [2, 14, 6]])
    func theIconStaysLevelWithTheTitleAtEveryIndent(steps: [Double]) throws {
        let rig = SidebarRowRig(space: "FolderIndentLevelTests")
        defer { rig.restore() }
        let settings = BrowserSettings.application
        rig.adjust(ThemeAdjustment(folderIndentLevel1: steps[0], folderIndentLevel2: steps[1], folderIndentLevel3: steps[2]))
        let browser = rig.browser
        let tab = browser.newTab()
        tab.title = "HHH"
        tab.urlString = "https://example.com/"
        tab.favicon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            return true
        }
        let inner = browser.createFolder(named: "Inner", containing: [tab])
        let outer = browser.createFolder(named: "Outer")
        browser.move([.folder(inner.id)], into: outer)
        _ = browser.newTab()
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: settings)
        let outline = FolderSection.outlineInset
        let total = 3 * row + 2 * spacing + 4 * outline
        let top = outline + row + spacing + outline + row + spacing
        let left = 2 * outline + steps[0] + steps[1]
        let padding = SidebarMetrics.rowContentPadding(style: .full)
        let icon = SidebarMetrics.rowIconSize
        let font = BrowserSettings.nativeSidebarFont(
            family: settings.sidebarFontFamily, size: CGFloat(settings.sidebarFontSize), weight: settings.sidebarFontWeight
        )
        let titleWidth = ("HHH" as NSString).size(withAttributes: [.font: font]).width

        let picture = try rig.picture(of: rig.sidebar(FolderSection(folder: outer, depth: 0, context: rig.context), height: total))
        let base = try picture.color(x: SidebarRowRig.width - 4, y: 0.5)
        let rows = top...(top + row)
        let iconStart = left + padding
        let titleStart = iconStart + icon + SidebarMetrics.rowIconSpacing
        let iconEdges = try #require(picture.verticalInk(in: iconStart...(iconStart + icon), rows: rows, against: base))
        let titleEdges = try #require(picture.verticalInk(in: titleStart...(titleStart + titleWidth), rows: rows, against: base))
        let offset = (iconEdges.lowerBound + iconEdges.upperBound) / 2 - (titleEdges.lowerBound + titleEdges.upperBound) / 2

        #expect(abs(offset) <= 0.5, "with steps \(steps) the icon is \(offset) pt below the capitals")
    }
}
