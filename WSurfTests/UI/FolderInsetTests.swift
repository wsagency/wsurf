// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Where the rows of nested folders start, read from the real sidebar: a folder's row and a tab's row at the same depth
/// start at the same place, and each level adds its own step. `FolderIndentLevelTests` reads titles and icons to see
/// that each level moves its rows by its step and that the icon stays level with the title; this suite compares rows
/// with each other, at every depth, for every way a folder can be drawn.
@MainActor
@Suite(.serialized)
struct FolderInsetTests {
    enum Look: CaseIterable, CustomStringConvertible {
        case plain
        /// The largest Size factor and Tint Icons as Folder on every folder.
        case largestAndTinted
        /// The outermost folder is a pinned folder, above the pin line.
        case pinned
        /// How a peeking sidebar and the Minimal window's tab list draw the list.
        case floating
        case everything

        var description: String {
            "\(self)"
        }
    }

    /// The tab and the shut folder at one depth, and the open folder that goes a level deeper.
    private struct Level {
        let tab: BrowserTab
        let shut: TabFolder
    }

    /// Four folders, each open and inside the one before (depths 0 to 3), and at every depth from 1 to 4 a tab and a
    /// shut, empty folder beside the next open folder.
    private func build(in rig: SidebarDriveRig, look: Look) -> (chain: [TabFolder], levels: [Level]) {
        let browser = rig.browser
        let chain = ["A", "B", "C", "D"].map { browser.createFolder(named: $0) }
        for (parent, child) in zip(chain, chain.dropFirst()) {
            browser.move([.folder(child.id)], into: parent)
        }
        let levels = (1...4).map { depth -> Level in
            let tab = browser.addPage("https://depth\(depth).example/")
            let shut = browser.createFolder(named: "Shut\(depth)")
            shut.isExpanded = false
            browser.move([.tab(tab.id), .folder(shut.id)], into: chain[depth - 1])
            return Level(tab: tab, shut: shut)
        }
        let everyFolder = chain + levels.map(\.shut)
        if look == .largestAndTinted || look == .everything {
            for folder in everyFolder {
                folder.size = .largest
                folder.tintsIcons = true
                folder.color = .green
            }
        }
        if look == .pinned || look == .everything {
            browser.pin(chain[0])
        }
        return (chain, levels)
    }

    private func start(of item: SidebarItem, in rig: SidebarDriveRig) throws -> CGFloat {
        try #require(rig.frame(of: item), "\(item) is not drawn").minX
    }

    @Test(arguments: [[0.0, 0, 0], [4, 8, 12], [10, 10, 10], [24, 2, 6]], Look.allCases)
    func aFolderAndATabAtTheSameDepthStartTogetherAndTheStepsAddUp(steps: [Double], look: Look) async throws {
        let rig = SidebarDriveRig(floating: look == .floating || look == .everything)
        defer { rig.close() }
        rig.adjustTheme(ThemeAdjustment(folderIndentLevel1: steps[0], folderIndentLevel2: steps[1], folderIndentLevel3: steps[2]))
        let (chain, levels) = build(in: rig, look: look)
        try await rig.settle(rounds: 10)

        let outline = FolderSection.outlineInset
        let shape = BrowserSettings.application.chromeShape
        let top = try start(of: .folder(chain[0].id), in: rig)
        let tabs = try levels.map { try start(of: .tab($0.tab.id), in: rig) }
        let shut = try levels.map { try start(of: .folder($0.shut.id), in: rig) }
        let open = try chain.dropFirst().map { try start(of: .folder($0.id), in: rig) }

        // Beside a tab, a shut folder starts in the same place, at every depth.
        for depth in 1...4 {
            #expect(abs(shut[depth - 1] - tabs[depth - 1]) < 0.01, "the shut folder at depth \(depth) starts at \(shut[depth - 1]), its tab at \(tabs[depth - 1]); \(steps)")
        }
        // An open folder is drawn inside its own outline, which starts where its tab does: its row is the outline's width in.
        for depth in 1...3 {
            #expect(abs(open[depth - 1] - tabs[depth - 1] - outline) < 0.01, "the open folder at depth \(depth) is \(open[depth - 1] - tabs[depth - 1]) in from its tab; \(steps)")
        }
        // Each depth adds its level's step, and each open folder above it its outline.
        let expected = [steps[0], steps[1] + outline, steps[2] + outline, steps[2] + outline]
        var previous = top
        for depth in 1...4 {
            let step = tabs[depth - 1] - previous
            #expect(abs(step - expected[depth - 1]) < 0.01, "depth \(depth) starts \(step) in from the row above, expected \(expected[depth - 1]); \(steps)")
            previous = tabs[depth - 1]
        }
        // The step each folder pads its rows by is what the theme's inset between depths says.
        for depth in 0..<4 {
            #expect(abs(shape.folderStep(below: depth) - CGFloat(steps[min(depth, 2)])) < 0.01)
            #expect(abs(shape.folderInset(depth: depth + 1) - shape.folderInset(depth: depth) - shape.folderStep(below: depth)) < 0.01)
        }
    }

    @Test func theIconsOnlySidebarKeepsEveryFolderAndTabInLine() async throws {
        let rig = SidebarDriveRig(width: SidebarMetrics.iconsWidth, style: .icons)
        defer { rig.close() }
        rig.adjustTheme(ThemeAdjustment(folderIndentLevel1: 24, folderIndentLevel2: 24, folderIndentLevel3: 24))
        let (chain, levels) = build(in: rig, look: .plain)
        try await rig.settle(rounds: 10)

        let outline = FolderSection.outlineInset
        let tabs = try levels.map { try start(of: .tab($0.tab.id), in: rig) }
        let open = try chain.dropFirst().map { try start(of: .folder($0.id), in: rig) }
        // The step is ignored; only the outlines move the rows.
        for depth in 1..<4 {
            #expect(abs(tabs[depth] - tabs[depth - 1] - outline) < 0.01)
            #expect(abs(open[depth - 1] - tabs[depth - 1] - outline) < 0.01)
        }
    }

    @Test func theStepsOfTheThemeAddUp() {
        var shape = ThemeShape(ThemeAdjustment(folderIndentLevel1: 4, folderIndentLevel2: 8, folderIndentLevel3: 12))
        #expect((0...5).map { shape.folderInset(depth: $0) } == [0, 4, 12, 24, 36, 48])
        #expect((0...4).map { shape.folderStep(below: $0) } == [4, 8, 12, 12, 12])
        shape = ThemeShape(ThemeAdjustment())
        #expect((0...5).map { shape.folderInset(depth: $0) } == [0, 0, 0, 0, 0, 0])
    }
}
