// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The Folder color opacity of a theme: a knob like the Layout sliders, between 20 % and 100 %, stored with the theme and
/// put back by Reset Theme to Default, that makes every place a folder's color is drawn fainter.
@MainActor
struct FolderColorOpacityTests {
    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("FolderColorOpacityTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false), defaults)
    }

    // MARK: - The knob

    @Test func theDefaultIsFullStrengthSoFoldersLookAsTheyAlwaysDid() throws {
        #expect(ThemeAdjustment().folderColorOpacity == 1)
        #expect(ThemeShape().folderColorOpacity == 1 && ThemeShape(ThemeAdjustment()).folderColorOpacity == 1)
        // A theme saved before the knob existed, or with a value of the wrong type, draws folders as they were.
        #expect(try JSONDecoder().decode(ThemeAdjustment.self, from: Data(#"{"tabIconSize":20}"#.utf8)).folderColorOpacity == 1)
        #expect(try JSONDecoder().decode(ThemeAdjustment.self, from: Data(#"{"folderColorOpacity":"faint"}"#.utf8)).folderColorOpacity == 1)
        // At full strength the color is the color itself: nothing is laid over it.
        func resolved(_ color: Color) throws -> NSColor {
            try #require(NSColor(color).usingColorSpace(.sRGB))
        }
        for color in TabFolderColor.allCases {
            let plain = try resolved(color.tint)
            let full = try resolved(color.tint(opacity: 1))
            #expect(full.alphaComponent == plain.alphaComponent && full.redComponent == plain.redComponent)
            #expect(full.greenComponent == plain.greenComponent && full.blueComponent == plain.blueComponent)
            #expect(abs(try resolved(color.tint(opacity: 0.5)).alphaComponent - plain.alphaComponent / 2) < 0.01)
        }
    }

    @Test func theOpacityIsBoundedToFivePercentStepsFromTwentyToOneHundred() throws {
        func bounded(_ value: Double) -> Double {
            ThemeAdjustment(folderColorOpacity: value).bounded().folderColorOpacity
        }
        #expect(bounded(0) == 0.2 && bounded(-1) == 0.2 && bounded(0.05) == 0.2 && bounded(0.2) == 0.2)
        #expect(bounded(1) == 1 && bounded(7) == 1 && bounded(.infinity) == 1 && bounded(.nan) == 1)
        #expect(abs(bounded(0.73) - 0.75) < 1e-9 && abs(bounded(0.7) - 0.7) < 1e-9)
        #expect(ThemeAdjustment.folderColorOpacityRange == 0.2...1 && ThemeAdjustment.folderColorOpacityStep == 0.05)

        let faint = ThemeAdjustment(folderColorOpacity: 0.4)
        let back = try JSONDecoder().decode(ThemeAdjustment.self, from: JSONEncoder().encode(faint))
        #expect(back == faint && ThemeShape(back).folderColorOpacity == 0.4)
    }

    @Test func theOpacityIsStoredWithTheThemeAndResetWithIt() throws {
        try withSettings { settings, defaults in
            settings.themeAdjustment = ThemeAdjustment(folderColorOpacity: 0.7)
            #expect(settings.chromeShape.folderColorOpacity == 0.7)
            #expect(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false).chromeShape.folderColorOpacity == 0.7)

            // Another theme keeps its own.
            let first = settings.themeID
            settings.themeID = "nord"
            #expect(settings.chromeShape.folderColorOpacity == 1)
            settings.themeID = first
            #expect(settings.chromeShape.folderColorOpacity == 0.7)

            #expect(settings.canResetTheme)
            settings.resetSelectedTheme()
            #expect(settings.chromeShape.folderColorOpacity == 1 && !settings.canResetTheme)
        }
    }

    @Test func searchFindsTheOpacityInTheColorsCard() {
        for query in ["folder color", "folder opacity", "folder color opacity"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "appearance.colors" }, "\(query)")
        }
    }

    // MARK: - What is drawn

    /// How far the folder's icon and the icon it tints are from the sidebar behind them, at full strength and at 40 %.
    @Test func theFolderIconAndTheIconsItTintsDrawFainterAsTheOpacityFalls() throws {
        let rig = SidebarRowRig(space: "FolderColorOpacityTests")
        defer { rig.restore() }
        let browser = rig.browser
        let tab = browser.newTab()
        tab.title = "HHH"
        tab.urlString = "https://example.com/"
        let folder = browser.createFolder(named: "Work", containing: [tab])
        _ = browser.newTab()
        folder.color = .red
        folder.tintsIcons = true
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)
        let outline = FolderSection.outlineInset
        let total = 2 * row + spacing + 2 * outline
        let padding = SidebarMetrics.rowContentPadding(style: .full)

        func strengths(of opacity: Double) throws -> (folder: CGFloat, tab: CGFloat) {
            rig.adjust(ThemeAdjustment(folderColorOpacity: opacity))
            let picture = try rig.picture(of: rig.sidebar(FolderSection(folder: folder, depth: 0, context: rig.context), height: total))
            let base = try picture.color(x: SidebarRowRig.width - 4, y: 0.5)
            let columns = (padding + outline)...(padding + outline + SidebarMetrics.rowIconSize)
            let folderRows = outline...(outline + row)
            let tabRows = (outline + row + spacing)...(outline + 2 * row + spacing)
            return (
                folder: picture.peakDistance(x: columns, y: folderRows, from: base),
                tab: picture.peakDistance(x: columns, y: tabRows, from: base)
            )
        }

        let full = try strengths(of: 1)
        let faint = try strengths(of: 0.4)
        #expect(full.folder > 0.3 && full.tab > 0.3, "at full strength the folder and its tinted icons are plain")
        #expect(faint.folder < 0.6 * full.folder, "the folder icon is fainter: \(faint.folder) against \(full.folder)")
        #expect(faint.tab < 0.6 * full.tab, "so is the icon it tints: \(faint.tab) against \(full.tab)")
    }
}
