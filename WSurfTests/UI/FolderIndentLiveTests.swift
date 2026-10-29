// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Testing

@testable import WSurf

/// The Folder indent the way a person sets it: through the selected theme, with rows already on screen, in the sidebar the
/// window draws. `FolderInsetTests` draws after it has set the Standard theme's knobs; this suite changes them under rows
/// that are drawn.
@MainActor
@Suite(.serialized)
struct FolderIndentLiveTests {
    private struct Rows {
        let outer: TabFolder
        let tab: BrowserTab
        let inner: TabFolder
        let deepTab: BrowserTab
    }

    /// A folder with a tab and a folder, and in that folder a tab. Both folders are open.
    private func build(in rig: SidebarDriveRig) -> Rows {
        let browser = rig.browser
        let tab = browser.addPage("https://one.example/")
        let deepTab = browser.addPage("https://two.example/")
        let inner = browser.createFolder(named: "Inner", containing: [deepTab])
        let outer = browser.createFolder(named: "Outer")
        browser.move([.tab(tab.id), .folder(inner.id)], into: outer)
        return Rows(outer: outer, tab: tab, inner: inner, deepTab: deepTab)
    }

    private func start(of item: SidebarItem, in rig: SidebarDriveRig) throws -> CGFloat {
        try #require(rig.frame(of: item), "\(item) is not drawn").minX
    }

    /// Each row's start from the one before: the tab in the outer folder is one Level 1 step in from it, the inner folder
    /// that and its own outline, and the tab in the inner folder one Level 2 step in from it.
    private func expectSteps(_ rows: Rows, _ steps: [Double], in rig: SidebarDriveRig) throws {
        let outline = FolderSection.outlineInset
        let outer = try start(of: .folder(rows.outer.id), in: rig)
        let tab = try start(of: .tab(rows.tab.id), in: rig)
        let inner = try start(of: .folder(rows.inner.id), in: rig)
        let deepTab = try start(of: .tab(rows.deepTab.id), in: rig)
        #expect(abs(tab - outer - steps[0]) < 0.01, "the tab is \(tab - outer) in from its folder, steps \(steps)")
        #expect(abs(inner - tab - outline) < 0.01, "the inner folder is \(inner - tab) in from the tab beside it, steps \(steps)")
        #expect(abs(deepTab - inner - steps[1]) < 0.01, "the inner tab is \(deepTab - inner) in from its folder, steps \(steps)")
    }

    /// Runs `body` with the theme `id` selected and its knobs at the default, and puts the person's theme back.
    private func withTheme(_ id: String, _ body: () async throws -> Void) async throws {
        let settings = BrowserSettings.application
        let saved = (settings.themeID, settings.themeAdjustments, settings.userThemes)
        defer {
            settings.themeID = saved.0
            settings.themeAdjustments = saved.1
            settings.userThemes = saved.2
        }
        settings.themeID = id
        settings.themeAdjustments[id] = nil
        settings.refreshTheme()
        try await body()
    }

    @Test(arguments: ["wsurf", "standard", "calm"])
    func theStepsOfTheSelectedThemeMoveTheRows(theme: String) async throws {
        try await withTheme(theme) {
            let rig = SidebarDriveRig()
            defer { rig.close() }
            let rows = build(in: rig)
            try await rig.settle(rounds: 10)
            try expectSteps(rows, [0, 0], in: rig)

            BrowserSettings.application.themeAdjustment = ThemeAdjustment(
                folderIndentLevel1: 8, folderIndentLevel2: 12, folderIndentLevel3: 16
            )
            try await rig.settle(rounds: 10)
            try expectSteps(rows, [8, 12], in: rig)
        }
    }

    @Test func aSliderDragMovesTheRowsAtOnceAndKeepsThemWhereItEnds() async throws {
        try await withTheme("wsurf") {
            let settings = BrowserSettings.application
            let rig = SidebarDriveRig()
            defer { rig.close() }
            let rows = build(in: rig)
            try await rig.settle(rounds: 10)

            settings.beginThemePreview()
            var adjustment = settings.themeAdjustment
            adjustment.folderIndentLevel1 = 10
            adjustment.folderIndentLevel2 = 4
            settings.previewThemeAdjustment(adjustment)
            try await rig.settle(rounds: 10)
            try expectSteps(rows, [10, 4], in: rig)

            settings.commitThemePreview()
            try await rig.settle(rounds: 10)
            try expectSteps(rows, [10, 4], in: rig)
        }
    }

    @Test(arguments: [false, true])
    func theTabListOfTheMinimalWindowAndAPeekingSidebarMoveTheRowsToo(floating: Bool) async throws {
        try await withTheme("wsurf") {
            BrowserSettings.application.themeAdjustment = ThemeAdjustment(
                folderIndentLevel1: 6, folderIndentLevel2: 14, folderIndentLevel3: 14
            )
            let rig = SidebarDriveRig(floating: floating)
            defer { rig.close() }
            let rows = build(in: rig)
            try await rig.settle(rounds: 10)
            try expectSteps(rows, [6, 14], in: rig)
        }
    }

    /// Customize copies the selected theme with its layout and selects the copy.
    @Test func aCopyOfTheThemeKeepsTheSteps() async throws {
        try await withTheme("wsurf") {
            let settings = BrowserSettings.application
            let rig = SidebarDriveRig()
            defer { rig.close() }
            let rows = build(in: rig)
            settings.themeAdjustment = ThemeAdjustment(folderIndentLevel1: 8, folderIndentLevel2: 4, folderIndentLevel3: 4)
            try await rig.settle(rounds: 10)
            try expectSteps(rows, [8, 4], in: rig)

            let copy = try #require(settings.saveTheme(named: "Indented"))
            #expect(settings.themeID == copy.id)
            try await rig.settle(rounds: 10)
            try expectSteps(rows, [8, 4], in: rig)
        }
    }
}
