// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The layout knobs of a theme: page edge, row edges, corner rounding and tab icons. Every case owns its settings
/// and a throwaway defaults suite, so none of them touches the app-wide theme.
@MainActor
struct ThemeLayoutTests {
    private let adjustmentsKey = "appearance.themes.adjustments"

    /// Every knob away from its default.
    private let layout = ThemeAdjustment(
        pageFrame: .hairline, rowFrame: FrameStyle.none, cornerScale: 0.5, loadedFavicons: .color
    )

    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("ThemeLayoutTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
        settings.previewsEveryStep()
        try test(settings, defaults)
    }

    private func reopened(_ defaults: UserDefaults) -> BrowserSettings {
        BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
    }

    private func shape(cornerScale: CGFloat) -> ThemeShape {
        var shape = ThemeShape()
        shape.cornerScale = cornerScale
        return shape
    }

    // MARK: - Model

    @Test func theDefaultKnobsDrawTodaysShape() throws {
        let shape = ThemeShape(ThemeAdjustment())
        #expect(shape == ThemeShape())
        #expect(shape.pageFrame == .standard && shape.rowFrame == .standard)
        #expect(shape.cornerScale == 1 && !shape.colorsFavicons)
        try withSettings { settings, _ in
            #expect(settings.chromeShape == ThemeShape())
        }
    }

    @Test func everyKnobReachesTheShape() {
        let shape = ThemeShape(layout)
        #expect(shape.pageFrame == .hairline)
        #expect(shape.rowFrame == FrameStyle.none)
        #expect(shape.cornerScale == 0.5)
        #expect(shape.colorsFavicons)
    }

    @Test func cornerRoundingScalesRowsAndThePageWithinTheirLimits() {
        #expect(shape(cornerScale: 0).rowRadius(10) == 0)
        #expect(shape(cornerScale: 0).pageRadius(10, window: 16) == 0)
        #expect(shape(cornerScale: 1).rowRadius(10) == 10)
        #expect(shape(cornerScale: 1).pageRadius(10, window: 16) == 10)
        #expect(shape(cornerScale: 0.5).rowRadius(10) == 5)
        // A row never rounds past half the shortest row, nor the page past the window's own corner.
        #expect(shape(cornerScale: 1.5).rowRadius(10) == ThemeShape.rowRadiusLimit)
        #expect(shape(cornerScale: 1.5).pageRadius(10, window: 14) == 14)
    }

    @Test func squareCornersNestSquare() {
        let row = shape(cornerScale: 0).rowRadius(Theme.Radius.control)
        #expect(row == 0)
        #expect(Theme.Radius.nested(in: row, inset: FolderSection.outlineInset) == 0)
        let round = shape(cornerScale: 1).rowRadius(Theme.Radius.control)
        #expect(Theme.Radius.nested(in: round, inset: FolderSection.outlineInset) == round - FolderSection.outlineInset)
    }

    @Test func increaseContrastGivesAFramelessPageAThinEdge() {
        var shape = ThemeShape()
        for frame in [FrameStyle.standard, .hairline, .none] {
            shape.pageFrame = frame
            #expect(shape.pageFrame(contrast: .standard) == frame)
        }
        shape.pageFrame = .none
        #expect(shape.pageFrame(contrast: .increased) == .hairline)
        shape.pageFrame = .standard
        #expect(shape.pageFrame(contrast: .increased) == .standard)
        shape.pageFrame = .hairline
        #expect(shape.pageFrame(contrast: .increased) == .hairline)
    }

    @Test func folderOutlinesFollowTheRowEdge() {
        #expect(FolderSection.outlineEdgeWidth(.standard, increasedContrast: false, displayScale: 2) == 1)
        #expect(FolderSection.outlineEdgeWidth(.hairline, increasedContrast: false, displayScale: 2) == 0.5)
        #expect(FolderSection.outlineEdgeWidth(.none, increasedContrast: false, displayScale: 2) == nil)
        for frame in [FrameStyle.standard, .hairline, .none] {
            #expect(FolderSection.outlineEdgeWidth(frame, increasedContrast: true, displayScale: 2) == 1, "\(frame)")
        }
    }

    // MARK: - Themes

    @Test func theShapeFollowsTheSelectedThemeAndNeverCopiesABuiltIn() throws {
        try withSettings { settings, _ in
            settings.themeID = "nord"
            settings.themeAdjustment = layout
            #expect(settings.themeID == "nord" && settings.userThemes.isEmpty)
            #expect(settings.chromeShape == ThemeShape(layout))
            settings.themeID = "standard"
            #expect(settings.chromeShape == ThemeShape())
            settings.themeID = "nord"
            #expect(settings.chromeShape == ThemeShape(layout))
            #expect(settings.resolvedTheme.adjustment == layout)
        }
    }

    @Test func aCornerDragPreviewsWithoutWritingAndWritesOnceWhenItEnds() throws {
        try withSettings { settings, defaults in
            let before = defaults.data(forKey: adjustmentsKey)
            settings.beginThemePreview()
            for step in 0...15 {
                var adjustment = settings.themeAdjustment
                adjustment.cornerScale = Double(step) / 10
                settings.previewThemeAdjustment(adjustment)
                #expect(settings.chromeShape.cornerScale == CGFloat(Double(step) / 10))
                #expect(defaults.data(forKey: adjustmentsKey) == before)
            }
            settings.commitThemePreview()
            #expect(settings.themePreview == nil)
            #expect(settings.chromeShape.cornerScale == 1.5)
            #expect(reopened(defaults).themeAdjustment.cornerScale == 1.5)
            #expect(settings.userThemes.isEmpty)
        }
    }

    @Test func aCancelledPreviewPutsTheShapeBack() throws {
        try withSettings { settings, defaults in
            settings.themeAdjustment = layout
            let before = defaults.data(forKey: adjustmentsKey)
            settings.beginThemePreview()
            var adjustment = layout
            adjustment.cornerScale = 0
            adjustment.rowFrame = .standard
            settings.previewThemeAdjustment(adjustment)
            #expect(settings.chromeShape == ThemeShape(adjustment))
            settings.cancelThemePreview()
            #expect(settings.chromeShape == ThemeShape(layout))
            #expect(defaults.data(forKey: adjustmentsKey) == before)
        }
    }

    @Test func layoutTravelsWithSavedAndDuplicatedThemesAcrossARestart() throws {
        try withSettings { settings, defaults in
            settings.themeID = "wsurf"
            settings.themeAdjustment = layout
            let saved = try #require(settings.saveTheme(named: "Shaped"))
            #expect(settings.themeID == saved.id && settings.themeAdjustment == layout)
            #expect(settings.chromeShape == ThemeShape(layout))
            let duplicate = try #require(settings.duplicateTheme(saved.id))
            #expect(settings.themeID == duplicate.id && settings.themeAdjustment == layout)

            let restarted = reopened(defaults)
            #expect(restarted.themeID == duplicate.id)
            #expect(restarted.chromeShape == ThemeShape(layout))
            restarted.themeID = saved.id
            #expect(restarted.themeAdjustment == layout && restarted.chromeShape == ThemeShape(layout))
            restarted.themeID = "wsurf"
            #expect(restarted.themeAdjustment == layout, "the built-in keeps its own knobs")
        }
    }

    @Test func changingTheLayoutOfASavedThemeChangesItInPlace() throws {
        try withSettings { settings, _ in
            let saved = try #require(settings.saveTheme(named: "Mine"))
            var adjustment = settings.themeAdjustment
            adjustment.rowFrame = .hairline
            adjustment.loadedFavicons = .color
            settings.themeAdjustment = adjustment
            #expect(settings.userThemes.map(\.id) == [saved.id])
            #expect(settings.themeAdjustments[saved.id]?.rowFrame == .hairline)
            #expect(settings.themeAdjustments[saved.id]?.loadedFavicons == .color)
            #expect(settings.chromeShape.rowFrame == .hairline && settings.chromeShape.colorsFavicons)
        }
    }

    @Test func resettingToDefaultsRestoresTodaysShape() throws {
        try withSettings { settings, defaults in
            settings.themeAdjustment = layout
            settings.resetToDefaults()
            #expect(settings.chromeShape == ThemeShape())
            #expect(reopened(defaults).chromeShape == ThemeShape())
        }
    }

    @Test func theGalleryDrawsEachThemesCornersAndPageEdge() {
        let theme = ThemeCatalog.fallback
        for scheme in [ColorScheme.light, .dark] {
            let plain = ThemeThumbnailPalette(theme, adjustment: ThemeAdjustment(), scheme: scheme)
            let shaped = ThemeThumbnailPalette(theme, adjustment: layout, scheme: scheme)
            #expect(plain.cornerScale == 1 && plain.pageFrame == .standard)
            #expect(shaped.cornerScale == 0.5 && shaped.pageFrame == .hairline)
            #expect(shaped.accent == plain.accent && shaped.canvas == plain.canvas, "layout changes no color")
        }
    }

    /// The layout knobs are one disclosure in the Window card and one in the Sidebar card, so each knob is found in the card that has it.
    @Test func searchFindsTheLayoutOfTheWindowAndOfTheSidebar() throws {
        for (query, id) in [
            ("corner", "appearance.windowLayout"), ("square", "appearance.windowLayout"),
            ("favicon", "appearance.sidebarLayout"), ("edge", "appearance.windowLayout"), ("edge", "appearance.sidebarLayout"),
            ("layout", "appearance.windowLayout"), ("layout", "appearance.sidebarLayout"),
        ] {
            #expect(SettingsIndex.search(query).contains { $0.id == id }, "\(query)")
        }
        for id in ["appearance.windowLayout", "appearance.sidebarLayout"] {
            let entry = try #require(SettingsIndex.all.first { $0.id == id })
            #expect(entry.targetAnchor == id)
        }
        #expect(!SettingsIndex.all.contains { $0.id == "appearance.layout" })
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: path), encoding: .utf8)
    }

    /// Search opens the row or card an entry names, so every entry of the Appearance page must name an anchor the page
    /// draws. The Window and the Sidebar sections follow each other, and each holds the layout disclosure that is its own.
    @Test func everyAppearanceEntryLandsOnAnAnchorTheSectionsDraw() throws {
        let pages = try [
            "AppearanceSettings", "AppearanceThemeSection", "AppearanceColorsSection", "AppearanceLayoutSection",
            "AppearanceWindowSection", "AppearanceDockIconSection",
        ].map { try source("WSurf/Settings/Pages/\($0).swift") }.joined()
        for entry in SettingsIndex.all where entry.category == .appearance {
            #expect(pages.contains("\"\(entry.targetAnchor)\""), "\(entry.id)")
        }

        let page = try source("WSurf/Settings/Pages/AppearanceSettings.swift")
        let window = try #require(page.range(of: "AppearanceWindowSection(settings: settings)"))
        let sidebar = try #require(page.range(of: "AppearanceSidebarSection(settings: settings"))
        let dock = try #require(page.range(of: "AppearanceDockIconSection(settings: settings)"))
        #expect(window.lowerBound < sidebar.lowerBound && sidebar.lowerBound < dock.lowerBound)
        #expect(page.contains("AppearanceLayoutSection(settings: settings, part: .sidebar)"))
        #expect(try source("WSurf/Settings/Pages/AppearanceWindowSection.swift")
            .contains("AppearanceLayoutSection(settings: settings, part: .window)"))
    }
}
