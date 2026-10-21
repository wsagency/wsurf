// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The spacing knobs of a theme: page spacing, sidebar margin, tab padding and tab icon size. Every case that stores
/// a theme owns its settings and a throwaway defaults suite; the one that reads the app-wide shape previews it and
/// puts it back before it returns.
@MainActor
struct ThemeSpacingTests {
    private let adjustmentsKey = "appearance.themes.adjustments"

    /// Every spacing knob away from its default, inside its range.
    private let spacing = ThemeAdjustment(pageSpacing: 0, sidebarMargin: 2, rowPadding: 3, tabIconSize: 22)

    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("ThemeSpacingTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false), defaults)
    }

    private func reopened(_ defaults: UserDefaults) -> BrowserSettings {
        BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
    }

    private func shell(pageSpacing: CGFloat, isPanelExpanded: Bool = false) -> LoomShellGeometry {
        LoomShellGeometry(
            containerWidth: 1_200,
            sidebarWidth: 268,
            preferredPanelWidth: 320,
            isSidebarVisible: true,
            isPanelVisible: true,
            isPanelExpanded: isPanelExpanded,
            pageSpacing: pageSpacing
        )
    }

    // MARK: - Model

    @Test func theDefaultsAreTodaysGeometry() throws {
        let adjustment = ThemeAdjustment()
        #expect(adjustment.pageSpacing == 6 && adjustment.sidebarMargin == 6)
        #expect(adjustment.rowPadding == 9 && adjustment.tabIconSize == 16)
        let shape = ThemeShape(adjustment)
        #expect(shape == ThemeShape())
        #expect(shape.pageSpacing == LoomChrome.canvasInset && shape.sidebarMargin == LoomChrome.canvasInset)
        #expect(shape.rowPadding == 9 && shape.tabIconSize == 16)

        // The page, its corner and the shell are where the fixed 6 pt gutter put them.
        let window = Theme.Radius.window
        #expect(shape.canvasRadius(window: window) == Theme.Radius.nested(in: window, inset: LoomChrome.canvasInset))
        #expect(shell(pageSpacing: shape.pageSpacing).canvasTrailingInset == CGFloat(326))
        #expect(shell(pageSpacing: shape.pageSpacing).sidebarResizeLeading == CGFloat(267))

        // The full sidebar sits 6 pt from the window and leaves the page gutter to separate it from the page.
        let insets = SidebarMetrics.contentInsets(
            style: .full, isFloating: false, margin: shape.sidebarMargin, pageSpacing: shape.pageSpacing
        )
        #expect(insets == EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0))
        #expect(insets == SidebarMetrics.contentInsets(style: .full, isFloating: false))

        try withSettings { settings, _ in
            #expect(settings.chromeShape == ThemeShape())
            // A 16 pt icon fits the 24 pt floor, so no row is taller than before.
            #expect(SidebarMetrics.rowHeight(settings: settings)
                == max(24, settings.sidebarLineHeight + CGFloat(settings.sidebarRowSpacing * 2 + 8)))
        }
    }

    @Test func spacingSurvivesAnEncodeAndOlderDataKeepsToday() throws {
        let back = try JSONDecoder().decode(ThemeAdjustment.self, from: JSONEncoder().encode(spacing))
        #expect(back == spacing)

        // A theme saved before these knobs existed, or with a value of the wrong type, keeps today's geometry.
        let older = try JSONDecoder().decode(ThemeAdjustment.self, from: Data(#"{"cornerScale":0.5}"#.utf8))
        #expect(older.pageSpacing == 6 && older.sidebarMargin == 6 && older.rowPadding == 9 && older.tabIconSize == 16)
        let damaged = try JSONDecoder().decode(ThemeAdjustment.self, from: Data(#"{"pageSpacing":"wide","tabIconSize":20}"#.utf8))
        #expect(damaged.pageSpacing == 6 && damaged.tabIconSize == 20)
    }

    @Test func boundedClampsToTheRangesAndWholePoints() {
        let low = ThemeAdjustment(pageSpacing: -3, sidebarMargin: 0, rowPadding: -1, tabIconSize: 2).bounded()
        #expect(low.pageSpacing == 0, "the page may sit flush")
        #expect(low.sidebarMargin == 1, "the sidebar never touches the window edge")
        #expect(low.rowPadding == 1 && low.tabIconSize == 12)

        let high = ThemeAdjustment(pageSpacing: 99, sidebarMargin: 99, rowPadding: 99, tabIconSize: 99).bounded()
        #expect(high.pageSpacing == 8 && high.sidebarMargin == 8 && high.rowPadding == 12 && high.tabIconSize == 24)

        let odd = ThemeAdjustment(pageSpacing: .nan, sidebarMargin: .infinity, rowPadding: 2.4, tabIconSize: 17.6).bounded()
        #expect(odd.pageSpacing == 6 && odd.sidebarMargin == 6)
        #expect(odd.rowPadding == 2 && odd.tabIconSize == 18)
    }

    @Test func storingAThemeClampsItsSpacing() throws {
        try withSettings { settings, defaults in
            settings.themeAdjustment = ThemeAdjustment(pageSpacing: -4, sidebarMargin: 0)
            #expect(settings.themeAdjustment.pageSpacing == 0 && settings.themeAdjustment.sidebarMargin == 1)
            #expect(settings.chromeShape.pageSpacing == 0 && settings.chromeShape.sidebarMargin == 1)
            let restarted = reopened(defaults)
            #expect(restarted.themeAdjustment.pageSpacing == 0 && restarted.themeAdjustment.sidebarMargin == 1)
        }
    }

    // MARK: - Geometry

    @Test func aFlushPageIsSquareAndASpacedOneStaysConcentric() {
        var shape = ThemeShape()
        shape.pageSpacing = 0
        #expect(shape.canvasRadius(window: 16) == 0)
        shape.pageSpacing = 2
        #expect(shape.canvasRadius(window: 16) == 14)
        shape.cornerScale = 0
        #expect(shape.canvasRadius(window: 16) == 0)
    }

    /// With no gutter the page meets the sidebar and the side panel. Each resize handle must still be under the
    /// pointer on both sides of the edge it moves.
    @Test func resizeHandlesStillGrabTheEdgeOfAFlushPage() {
        let flush = shell(pageSpacing: 0)
        let grab = LoomChrome.resizeGrabWidth

        let sidebarHandle = flush.sidebarResizeLeading...(flush.sidebarResizeLeading + grab)
        for x in stride(from: CGFloat(264), through: 272, by: 1) {
            #expect(sidebarHandle.contains(x), "sidebar edge 268, pointer at \(x)")
        }
        #expect(!sidebarHandle.contains(263) && !sidebarHandle.contains(273))

        // The page ends where the panel begins.
        #expect(flush.canvasTrailingInset == flush.panelWidth)
        #expect(flush.panelLeading == CGFloat(880))
        let panelEdge = flush.panelLeading
        let panelHandle = flush.panelResizeLeading...(flush.panelResizeLeading + grab)
        for offset in stride(from: CGFloat(-4), through: 4, by: 1) {
            #expect(panelHandle.contains(panelEdge + offset), "panel edge, pointer at \(offset)")
        }

        #expect(shell(pageSpacing: 0, isPanelExpanded: true).panelWidth == CGFloat(932))
    }

    @Test func theSidebarKeepsItsMarginFromTheWindowAndThePage() {
        func insets(margin: CGFloat, page: CGFloat) -> EdgeInsets {
            SidebarMetrics.contentInsets(style: .full, isFloating: false, margin: margin, pageSpacing: page)
        }
        #expect(insets(margin: 1, page: 6) == EdgeInsets(top: 0, leading: 1, bottom: 0, trailing: 0))
        #expect(insets(margin: 1, page: 0) == EdgeInsets(top: 0, leading: 1, bottom: 0, trailing: 1))
        #expect(insets(margin: 6, page: 0) == EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        #expect(insets(margin: 8, page: 6) == EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 2))

        // Icons only and the floating sidebar keep their own insets.
        for isFloating in [false, true] {
            #expect(SidebarMetrics.contentInsets(style: .icons, isFloating: isFloating, margin: 1, pageSpacing: 0)
                == SidebarMetrics.contentInsets(style: .icons, isFloating: isFloating))
        }
        #expect(SidebarMetrics.contentInsets(style: .full, isFloating: true, margin: 1, pageSpacing: 0)
            == SidebarMetrics.contentInsets(style: .full, isFloating: true))

        // The media card takes the same room as the rows.
        #expect(MediaSidebarCard.panelWidth(sidebarWidth: 268, isStowed: false, isFloating: false, margin: 1, pageSpacing: 6)
            == SidebarMetrics.contentWidth(268, style: .full, isFloating: false, margin: 1, pageSpacing: 6))
        #expect(SidebarMetrics.contentWidth(268, style: .full, isFloating: false, margin: 1, pageSpacing: 6) == 267)
    }

    @Test func rowsGrowOnlyPastTheDefaultIcon() throws {
        try withSettings { settings, _ in
            let resting = SidebarMetrics.rowHeight(settings: settings)
            var adjustment = settings.themeAdjustment
            adjustment.tabIconSize = 12
            settings.themeAdjustment = adjustment
            #expect(SidebarMetrics.rowHeight(settings: settings) == resting)
            adjustment.tabIconSize = 24
            settings.themeAdjustment = adjustment
            #expect(SidebarMetrics.rowHeight(settings: settings) == max(resting, 32))
        }
    }

    /// Tab padding and icon size reach every kind of row through `SidebarMetrics`, which reads the app-wide shape.
    @Test func everyRowReadsTheAppWideSpacing() throws {
        let settings = BrowserSettings.application
        try #require(settings.themePreview == nil, "must not replace a theme preview in progress")
        settings.beginThemePreview()
        defer { settings.cancelThemePreview() }
        var adjustment = settings.themeAdjustment
        adjustment.rowPadding = 1
        adjustment.tabIconSize = 24
        settings.previewThemeAdjustment(adjustment)

        #expect(SidebarMetrics.rowContentPadding(style: .full) == 1)
        #expect(SidebarMetrics.rowContentPadding(style: .icons) == 0)
        #expect(SidebarMetrics.rowIconSize == 24)
        #expect(SidebarMetrics.rowHeight(settings: settings) >= 32)
    }

    // MARK: - Themes

    @Test func aSpacingDragPreviewsWithoutWritingAndWritesOnceWhenItEnds() throws {
        try withSettings { settings, defaults in
            let before = defaults.data(forKey: adjustmentsKey)
            settings.beginThemePreview()
            for points in 0...8 {
                var adjustment = settings.themeAdjustment
                adjustment.pageSpacing = Double(points)
                adjustment.tabIconSize = Double(16 + points)
                settings.previewThemeAdjustment(adjustment)
                #expect(settings.chromeShape.pageSpacing == CGFloat(points))
                #expect(settings.chromeShape.tabIconSize == CGFloat(16 + points))
                #expect(defaults.data(forKey: adjustmentsKey) == before)
            }
            settings.commitThemePreview()
            #expect(settings.themePreview == nil)
            #expect(reopened(defaults).themeAdjustment.pageSpacing == 8)
            #expect(reopened(defaults).themeAdjustment.tabIconSize == 24)
            #expect(settings.userThemes.isEmpty, "a knob never copies a built-in theme")
        }
    }

    @Test func spacingTravelsWithSavedAndDuplicatedThemesAcrossARestart() throws {
        try withSettings { settings, defaults in
            settings.themeID = "nord"
            settings.themeAdjustment = spacing
            #expect(settings.userThemes.isEmpty)
            let saved = try #require(settings.saveTheme(named: "Roomy"))
            #expect(settings.themeID == saved.id && settings.themeAdjustment == spacing)
            let duplicate = try #require(settings.duplicateTheme(saved.id))
            #expect(settings.themeID == duplicate.id && settings.chromeShape == ThemeShape(spacing))

            let restarted = reopened(defaults)
            #expect(restarted.chromeShape == ThemeShape(spacing))
            restarted.themeID = saved.id
            #expect(restarted.themeAdjustment == spacing)
            restarted.themeID = "standard"
            #expect(restarted.chromeShape == ThemeShape(), "another theme keeps its own spacing")
            restarted.themeID = "nord"
            #expect(restarted.themeAdjustment == spacing, "the built-in keeps its own knobs")
        }
    }

    @Test func searchFindsTheSpacingKnobs() {
        for query in ["spacing", "margin", "padding", "flush"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "appearance.layout" }, "\(query)")
        }
    }
}
