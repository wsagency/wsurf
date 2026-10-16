// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// Every sidebar row draws from `SidebarRowStyle`, so these tests cover the states once for all of them: the
/// current tab, a marked row, a tab never opened, and the folders and splits that hold them.
@MainActor
struct SidebarRowStyleTests {
    private func resolve(
        current: Bool = false,
        marked: Bool = false,
        unseen: Bool = false,
        paletteOpen: Bool = false,
        increasedContrast: Bool = false
    ) -> SidebarRowStyle {
        SidebarRowStyle.resolve(
            isCurrent: current,
            isMarked: marked,
            isUnseen: unseen,
            paletteOpen: paletteOpen,
            increasedContrast: increasedContrast
        )
    }

    private func makeModel() -> BrowserModel {
        BrowserModel(database: .temporary())
    }

    // MARK: - Emphasis

    @Test func theCurrentRowIsSelected() {
        #expect(resolve(current: true).emphasis == .current)
        #expect(resolve(current: true).isSelected)
        #expect(!resolve().isSelected)
    }

    /// A marked row keeps the faint glass, which is now different from the current row's inverse colors.
    @Test func aMarkedRowKeepsTheGlass() {
        let marked = resolve(marked: true)

        #expect(marked.emphasis == .lit)
        #expect(marked.isSelected)
        #expect(resolve(current: true, marked: true).emphasis == .current, "the current row stays inverse in a selection")
    }

    @Test func nothingIsCurrentWhileTheNewTabPaletteIsOpen() {
        let current = resolve(current: true, paletteOpen: true)

        #expect(current.emphasis == .resting)
        #expect(!current.isSelected)
        #expect(resolve(marked: true, paletteOpen: true).emphasis == .lit)
    }

    // MARK: - New tabs

    @Test func aNewRowSaysNew() {
        let new = resolve(unseen: true)

        #expect(new.mark == .accent)
        #expect(new.statuses == [.new])
        #expect(new.spokenStatus == String(localized: "New"))
        #expect(resolve().mark == .none)
        #expect(resolve().spokenStatus == nil)
    }

    @Test func currentOutranksNew() {
        let current = resolve(current: true, unseen: true)

        #expect(current.emphasis == .current)
        #expect(current.mark == .none)
        #expect(current.spokenStatus == nil)
    }

    @Test func aNewRowStaysNewUnderThePalette() {
        let behindPalette = resolve(current: true, unseen: true, paletteOpen: true)

        #expect(behindPalette.emphasis == .resting)
        #expect(behindPalette.mark == .accent)
    }

    @Test func increasedContrastDrawsTheDotInInk() {
        #expect(resolve(unseen: true, increasedContrast: true).mark == .ink)
        #expect(resolve(unseen: true, increasedContrast: false).mark == .accent)
    }

    // MARK: - Splits

    /// The split row keeps its glass to show the pair is on screen; only the pane in focus is inverse.
    @Test func onlyTheFocusedPaneIsInverse() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab()
        model.split(left, with: right, axis: .sideBySide)
        model.activate(right)

        func pane(_ tab: BrowserTab) -> SidebarRowStyle.Emphasis {
            model.rowStyle(of: tab, isMarked: false, paletteOpen: false, increasedContrast: false).emphasis
        }
        #expect(pane(right) == .current)
        #expect(pane(left) == .resting)
        let row = model.rowStyle(ofSplitLedBy: left, isMarked: false, paletteOpen: false)
        #expect(row.emphasis == .lit)

        model.activate(left)
        #expect(pane(left) == .current)
        #expect(pane(right) == .resting)
    }

    @Test func aSplitOffScreenIsNotLit() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab()
        model.split(left, with: right, axis: .sideBySide)
        let other = model.newTab()
        #expect(model.activeTab === other)

        #expect(model.rowStyle(ofSplitLedBy: left, isMarked: false, paletteOpen: false).emphasis == .resting)
        #expect(model.rowStyle(ofSplitLedBy: left, isMarked: true, paletteOpen: false).emphasis == .lit)
    }

    @Test func aSplitOnScreenIsNotLitUnderThePalette() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab()
        model.split(left, with: right, axis: .sideBySide)
        model.activate(left)

        #expect(model.rowStyle(ofSplitLedBy: left, isMarked: false, paletteOpen: true).emphasis == .resting)
    }

    // MARK: - Colors

    private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func same(_ first: NSColor, _ second: NSColor) -> Bool {
        guard let one = first.usingColorSpace(.sRGB), let two = second.usingColorSpace(.sRGB) else { return false }
        return abs(one.redComponent - two.redComponent) < 0.003
            && abs(one.greenComponent - two.greenComponent) < 0.003
            && abs(one.blueComponent - two.blueComponent) < 0.003
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        SidebarRowStyle.contrast(first, second)
    }

    private let darkGround = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1)
    private let lightGround = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.955, alpha: 1)
    private let blue = NSColor(srgbRed: 0, green: 0.35, blue: 1, alpha: 1)

    /// Holds for one theme: the fill stands out from the sidebar, and what is drawn on the fill reads on it.
    private func expectInverse(
        _ colors: SidebarRowStyle.Colors,
        on ground: NSColor,
        _ context: String
    ) {
        #expect(contrast(colors.fill, ground) >= SidebarRowStyle.minimumFillContrast, "fill on ground, \(context)")
        #expect(
            contrast(colors.content, colors.fill) >= SidebarRowStyle.minimumContentContrast,
            "content on fill, \(context)"
        )
        #expect(contrast(colors.accent, ground) >= SidebarRowStyle.minimumMarkContrast, "dot on ground, \(context)")
        #expect(!same(colors.fill, colors.content), "fill and content differ, \(context)")
    }

    private func appearances(of mode: AppearanceMode) -> [ColorScheme] {
        switch mode {
        case .system:
            [.light, .dark]
        case .light, .lightCalm:
            [.light]
        case .dark, .darkCalm:
            [.dark]
        }
    }

    /// The five themes on the grounds the sidebar takes from a page, and every preset on both of its surfaces.
    /// Colors come from the same settings, loom and theme calls the sidebar uses.
    @Test func theCurrentRowIsInverseInEveryTheme() {
        let settings = BrowserSettings.application
        let savedAppearance = settings.appearance
        let savedPreset = settings.themePreset
        let savedThemes = settings.themeCustomizations
        let savedForcedDark = settings.forcesDarkAppearance
        let savedNativeAppearance = NSApp.appearance
        defer {
            settings.themePreset = savedPreset
            settings.themeCustomizations = savedThemes
            settings.appearance = savedAppearance
            settings.forcesDarkAppearance = savedForcedDark
            NSApp.appearance = savedNativeAppearance
        }
        settings.forcesDarkAppearance = false
        settings.themeCustomizations = [:]
        settings.themePreset = nil

        func colors(on ground: NSColor, scheme: ColorScheme) -> SidebarRowStyle.Colors {
            let ink: ColorScheme = PageInk.isLight(ground, scheme: scheme) ? .light : .dark
            return SidebarRowStyle.colors(
                text: SidebarRowStyle.srgb(settings.sidebarTextColor(scheme: ink), scheme: ink),
                ground: ground,
                accent: SidebarRowStyle.srgb(Theme.accent, scheme: ink)
            )
        }

        let pages: [NSColor?] = [
            nil, blue, rgb(1, 0.9, 0.2), rgb(0.5, 0.5, 0.5), rgb(0.02, 0.02, 0.03), rgb(1, 1, 1),
        ]
        var checked = 0
        for mode in AppearanceMode.allCases {
            settings.appearance = mode
            for scheme in appearances(of: mode) {
                for page in pages {
                    let ground = LoomChrome.sampledColor(page, scheme: scheme)
                    expectInverse(colors(on: ground, scheme: scheme), on: ground, "\(mode) \(scheme) \(String(describing: page))")
                    checked += 1
                }
            }
        }
        // Five themes, with Auto drawn in both appearances, on six grounds each.
        #expect(checked == 6 * pages.count)

        for preset in ThemePreset.allCases {
            settings.themePreset = preset
            let scheme: ColorScheme = preset.isDark ? .dark : .light
            for isFloating in [false, true] {
                let ground = LoomChrome.sampledColor(blue, scheme: scheme, isFloating: isFloating)
                let result = colors(on: ground, scheme: scheme)
                expectInverse(result, on: ground, "\(preset) floating \(isFloating)")
                #expect(same(result.fill, preset.nsColor(.text)), "\(preset) keeps its own text color")
                #expect(same(result.content, ground), "\(preset) draws the row in its own sidebar color")
            }
        }
    }

    @Test func aCustomTextColorFillsTheCurrentRow() {
        let orange = rgb(0.9, 0.5, 0, alpha: 0.6)
        let colors = SidebarRowStyle.colors(text: orange, ground: darkGround, accent: blue)

        #expect(same(colors.fill, rgb(0.9, 0.5, 0)))
        #expect(colors.fill.alphaComponent == 1, "the fill ignores the text opacity")
        #expect(same(colors.content, darkGround))
        #expect(colors.fillIsLight, "orange is bright enough that dark controls read better on it")
    }

    @Test func aFaintCustomColorFallsBackToInk() {
        let faintOnDark = SidebarRowStyle.colors(text: rgb(0.14, 0.14, 0.16), ground: darkGround, accent: blue)
        #expect(same(faintOnDark.fill, rgb(1, 1, 1)))
        #expect(same(faintOnDark.content, darkGround))
        #expect(faintOnDark.fillIsLight)

        let faintOnLight = SidebarRowStyle.colors(text: rgb(0.9, 0.9, 0.9), ground: lightGround, accent: blue)
        #expect(same(faintOnLight.fill, rgb(0, 0, 0)))
        #expect(same(faintOnLight.content, lightGround))
        #expect(!faintOnLight.fillIsLight)
    }

    /// A mid gray stands out from a light sidebar well enough to fill a row, but the sidebar color is too faint
    /// to write on it.
    @Test func contentFallsBackToBlackOrWhite() {
        let gray = rgb(0.5, 0.5, 0.5)
        let colors = SidebarRowStyle.colors(text: gray, ground: lightGround, accent: blue)

        #expect(same(colors.fill, gray))
        #expect(same(colors.content, rgb(0, 0, 0)))
        #expect(contrast(colors.content, colors.fill) >= SidebarRowStyle.minimumContentContrast)
    }

    @Test func aFaintAccentDotUsesInk() {
        let pale = rgb(1, 0.95, 0.6)
        let onLight = SidebarRowStyle.colors(text: rgb(0, 0, 0), ground: lightGround, accent: pale)
        #expect(same(onLight.accent, rgb(0, 0, 0)))
        #expect(same(onLight.mark(.accent) ?? .clear, rgb(0, 0, 0)))

        let visible = SidebarRowStyle.colors(text: rgb(0, 0, 0), ground: lightGround, accent: blue)
        #expect(same(visible.accent, blue))
    }

    @Test func theDotAsksForTheAccentTheInkOrNothing() {
        let colors = SidebarRowStyle.colors(text: rgb(1, 1, 1), ground: darkGround, accent: blue)

        #expect(colors.mark(.none) == nil)
        #expect(colors.mark(.accent).map { same($0, blue) } == true)
        #expect(colors.mark(.ink).map { same($0, rgb(1, 1, 1)) } == true)
    }

    // MARK: - What a row draws with

    @Test func theContentOfAnInverseRowFollowsTheFill() {
        let current = resolve(current: true)
        let colors = SidebarRowStyle.colors(text: rgb(1, 1, 1), ground: darkGround, accent: blue)
        let ink = SidebarRowInk(style: current, resting: .white, colors: colors)

        let inverse = ink.inverse
        #expect(inverse?.scheme == .light, "white fill: controls and secondary text draw as on a light chrome")
        #expect(inverse?.isLight == true)
        #expect(inverse?.wash.isLight == true)
        #expect(same(NSColor(ink.text), darkGround), "the text is the sidebar color on the fill")
    }

    @Test func aRowThatIsNotCurrentKeepsItsOwnInk() {
        let colors = SidebarRowStyle.colors(text: rgb(1, 1, 1), ground: darkGround, accent: blue)
        let ink = SidebarRowInk(style: resolve(marked: true), resting: .orange, colors: colors)

        #expect(ink.inverse == nil)
        #expect(ink.text == .orange)
        #expect(ink.badge == nil)
    }

    @Test func aFolderBadgeUsesTheInverseColorsWithoutInvertingTheRow() {
        let folder = SidebarRowStyle.folder(
            isMarked: false,
            containsCurrent: true,
            containsNew: false,
            paletteOpen: false,
            increasedContrast: false
        )
        let colors = SidebarRowStyle.colors(text: rgb(0, 0, 0), ground: lightGround, accent: blue)
        let ink = SidebarRowInk(style: folder, resting: .black, colors: colors)

        #expect(ink.inverse == nil)
        #expect(ink.badge.map { same(NSColor($0.fill), rgb(0, 0, 0)) } == true)
        #expect(ink.badge.map { same(NSColor($0.text), lightGround) } == true)
    }

    // MARK: - Folders

    @Test func aCollapsedFolderMarksTheCurrentTabInside() {
        let style = SidebarRowStyle.folder(
            isMarked: false,
            containsCurrent: true,
            containsNew: false,
            paletteOpen: false,
            increasedContrast: false
        )

        #expect(style.marksCurrentTab)
        #expect(style.emphasis == .resting, "the folder is never the current row")
        #expect(style.spokenStatus == String(localized: "Contains current tab"))
    }

    @Test func aCollapsedFolderWithBothSaysBoth() {
        let style = SidebarRowStyle.folder(
            isMarked: true,
            containsCurrent: true,
            containsNew: true,
            paletteOpen: false,
            increasedContrast: false
        )

        #expect(style.marksCurrentTab)
        #expect(style.mark == .accent)
        #expect(style.emphasis == .lit)
        #expect(style.statuses == [.containsCurrent, .containsNew])
    }

    @Test func aFolderMarksNoCurrentTabUnderThePalette() {
        let style = SidebarRowStyle.folder(
            isMarked: false,
            containsCurrent: true,
            containsNew: false,
            paletteOpen: true,
            increasedContrast: false
        )

        #expect(!style.marksCurrentTab)
        #expect(style.spokenStatus == nil)
    }
}
