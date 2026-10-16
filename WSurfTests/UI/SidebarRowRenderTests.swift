// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Draws the real sidebar rows on a dark sidebar and reads pixels back, so the wiring from the shared style to
/// what a person sees is checked without launching the app. The glass of a lit row is the system's and is not
/// asserted; the inverse fill and the dot are ours.
@MainActor
struct SidebarRowRenderTests {
    private let darkGround = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1)
    private let rowWidth: CGFloat = 220

    private struct Fixture {
        let coordinator: AppCoordinator
        let context: SidebarRowContext

        var browser: BrowserModel {
            coordinator.browser
        }
    }

    private func makeFixture() -> Fixture {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        let context = SidebarRowContext(
            browser: coordinator.browser,
            coordinator: coordinator,
            selection: coordinator.browser.sidebarSelection,
            drag: nil,
            pinsCarried: false,
            space: "SidebarRowRenderTests",
            frames: SidebarFrames()
        )
        return Fixture(coordinator: coordinator, context: context)
    }

    private var rowHeight: CGFloat {
        SidebarMetrics.rowHeight(settings: BrowserSettings.application)
    }

    /// The row as a sidebar hosts it, on a mid gray that neither the fill, the dot nor the sidebar is.
    private func sidebar(
        _ row: some View,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        style: SidebarStyle = .full,
        scheme: ColorScheme = .dark,
        ground: NSColor? = nil
    ) -> some View {
        row
            .frame(width: width ?? rowWidth, height: height ?? rowHeight)
            .environment(\.sidebarStyle, style)
            .environment(\.chromeWash, .of(ground ?? darkGround, isLight: scheme == .light))
            .environment(\.chromeIsLight, scheme == .light)
            .environment(\.colorScheme, scheme)
            .environment(\.windowColorScheme, scheme)
            .background(Color(red: 0.5, green: 0.5, blue: 0.5))
    }

    /// The pixel at `(x, y)` points from the top left, drawn by AppKit in an unshown window: the rows hold
    /// AppKit views that `ImageRenderer` cannot draw.
    private func pixel(of view: some View, x: CGFloat, y: CGFloat) throws -> NSColor {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        return try #require(
            bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        )
    }

    private func isWhite(_ color: NSColor) -> Bool {
        color.redComponent > 0.97 && color.greenComponent > 0.97 && color.blueComponent > 0.97
    }

    private func isBase(_ color: NSColor) -> Bool {
        abs(color.redComponent - 0.5) < 0.05 && abs(color.greenComponent - 0.5) < 0.05
            && abs(color.blueComponent - 0.5) < 0.05
    }

    private func isBlue(_ color: NSColor) -> Bool {
        color.blueComponent > 0.85 && color.redComponent < 0.35 && color.greenComponent < 0.75
    }

    /// Right of the title, clear of the icon and the hover controls.
    private var emptySpot: CGPoint {
        CGPoint(x: rowWidth - 60, y: rowHeight / 2)
    }

    /// The top trailing corner of the icon in a full-width row.
    private var iconCorner: CGPoint {
        CGPoint(x: 9 + SidebarMetrics.rowIconSize, y: (rowHeight - SidebarMetrics.rowIconSize) / 2)
    }

    // MARK: - Tab rows

    @Test func theCurrentTabRowIsFilledAndAnotherIsNot() throws {
        let fixture = makeFixture()
        let other = fixture.browser.newTab()
        let current = fixture.browser.newTab()

        let currentRow = sidebar(SidebarTabRow(tab: current, depth: 0, context: fixture.context))
        let otherRow = sidebar(SidebarTabRow(tab: other, depth: 0, context: fixture.context))

        #expect(isWhite(try pixel(of: currentRow, x: emptySpot.x, y: emptySpot.y)))
        #expect(isBase(try pixel(of: otherRow, x: emptySpot.x, y: emptySpot.y)))
    }

    @Test func nothingIsFilledWhileTheNewTabPaletteIsOpen() throws {
        let fixture = makeFixture()
        let current = fixture.browser.newTab()
        fixture.coordinator.requestNewTab()
        defer { fixture.coordinator.closePalette() }

        let row = sidebar(SidebarTabRow(tab: current, depth: 0, context: fixture.context))

        #expect(isBase(try pixel(of: row, x: emptySpot.x, y: emptySpot.y)))
    }

    @Test func aNewTabHasTheDotAndAFilledOneDoesNot() throws {
        let fixture = makeFixture()
        let current = fixture.browser.newTab()
        let background = fixture.browser.newTab(activate: false)
        fixture.browser.activate(current)
        #expect(background.isUnseen)

        let newRow = sidebar(SidebarTabRow(tab: background, depth: 0, context: fixture.context))
        let currentRow = sidebar(SidebarTabRow(tab: current, depth: 0, context: fixture.context))

        #expect(isBlue(try pixel(of: newRow, x: iconCorner.x, y: iconCorner.y)), "the dot sits on the icon corner")
        #expect(isBase(try pixel(of: newRow, x: emptySpot.x, y: emptySpot.y)), "a new tab is not filled")
        #expect(!isBlue(try pixel(of: currentRow, x: iconCorner.x, y: iconCorner.y)), "the current tab has no dot")
    }

    @Test func openingTheNewTabTakesTheDotAndFillsTheRow() throws {
        let fixture = makeFixture()
        _ = fixture.browser.newTab()
        let background = fixture.browser.newTab(activate: false)
        let row = SidebarTabRow(tab: background, depth: 0, context: fixture.context)
        #expect(isBlue(try pixel(of: sidebar(row), x: iconCorner.x, y: iconCorner.y)))

        fixture.browser.activate(background)

        let opened = sidebar(SidebarTabRow(tab: background, depth: 0, context: fixture.context))
        #expect(isWhite(try pixel(of: opened, x: emptySpot.x, y: emptySpot.y)))
        #expect(!isBlue(try pixel(of: opened, x: iconCorner.x, y: iconCorner.y)))
    }

    // MARK: - Color presets

    @Test func theCurrentRowWearsEachPresetsOwnTextColor() throws {
        let settings = BrowserSettings.application
        let savedPreset = settings.themePreset
        let savedAppearance = settings.appearance
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
        let fixture = makeFixture()
        _ = fixture.browser.newTab()
        let current = fixture.browser.newTab()

        for preset in ThemePreset.allCases {
            settings.themePreset = preset
            let scheme: ColorScheme = preset.isDark ? .dark : .light
            let ground = LoomChrome.sampledColor(nil, scheme: scheme, isFloating: true)
            let row = sidebar(
                SidebarTabRow(tab: current, depth: 0, context: fixture.context), scheme: scheme, ground: ground
            )

            let painted = try pixel(of: row, x: emptySpot.x, y: emptySpot.y)
            let wanted = preset.nsColor(.text)

            // The window reads colors back through its own color space, which moves them by a few percent. A
            // fallback to black or white would be off by far more.
            #expect(abs(painted.redComponent - wanted.redComponent) < 0.06, "\(preset) red")
            #expect(abs(painted.greenComponent - wanted.greenComponent) < 0.06, "\(preset) green")
            #expect(abs(painted.blueComponent - wanted.blueComponent) < 0.06, "\(preset) blue")
        }
    }

    // MARK: - Icons only

    @Test func theCurrentTabIsFilledInTheIconsOnlySidebar() throws {
        let fixture = makeFixture()
        let other = fixture.browser.newTab()
        let current = fixture.browser.newTab()
        let width = SidebarMetrics.iconsWidth

        let currentRow = sidebar(
            SidebarTabRow(tab: current, depth: 0, context: fixture.context), width: width, style: .icons
        )
        let otherRow = sidebar(
            SidebarTabRow(tab: other, depth: 0, context: fixture.context), width: width, style: .icons
        )

        #expect(isWhite(try pixel(of: currentRow, x: 3, y: rowHeight / 2)))
        #expect(isBase(try pixel(of: otherRow, x: 3, y: rowHeight / 2)))
    }

    @Test func aNewTabHasTheDotInTheIconsOnlySidebar() throws {
        let fixture = makeFixture()
        let current = fixture.browser.newTab()
        let background = fixture.browser.newTab(activate: false)
        fixture.browser.activate(current)
        let width = SidebarMetrics.iconsWidth
        let corner = CGPoint(
            x: (width + SidebarMetrics.rowIconSize) / 2,
            y: (rowHeight - SidebarMetrics.rowIconSize) / 2
        )

        let row = sidebar(
            SidebarTabRow(tab: background, depth: 0, context: fixture.context), width: width, style: .icons
        )

        #expect(isBlue(try pixel(of: row, x: corner.x, y: corner.y)))
    }

    // MARK: - Splits

    @Test func onlyTheFocusedPaneOfASplitIsFilled() throws {
        let fixture = makeFixture()
        let left = fixture.browser.newTab()
        let right = fixture.browser.newTab()
        fixture.browser.split(left, with: right, axis: .sideBySide)
        fixture.browser.activate(right)
        let split = try #require(fixture.browser.splits.split(containing: left.id))

        let row = sidebar(SidebarSplitRow(leading: left, split: split, depth: 0, context: fixture.context))
        // Past the end of each title, so no glyph lands on the pixel.
        let leftPane = try pixel(of: row, x: rowWidth / 2 - 12, y: rowHeight / 2)
        let rightPane = try pixel(of: row, x: rowWidth - 6, y: rowHeight / 2)

        #expect(isWhite(rightPane), "the focused pane is inverse")
        #expect(!isWhite(leftPane), "the other pane keeps the glass of the row")
    }

    // MARK: - Folders

    @Test func aCollapsedFolderMarksTheCurrentTabWithAnInverseBadge() throws {
        let fixture = makeFixture()
        let current = fixture.browser.newTab()
        let folder = fixture.browser.createFolder(named: "Work", containing: [current])
        folder.isExpanded = false

        let row = sidebar(FolderSection(folder: folder, depth: 0, context: fixture.context))
        // Just inside the left end of the capsule, away from the digit in its middle.
        let badge = try pixel(of: row, x: rowWidth - 9 - 14, y: rowHeight / 2)

        #expect(isWhite(badge), "the count badge is filled")
        #expect(isBase(try pixel(of: row, x: emptySpot.x, y: emptySpot.y)), "the folder row itself is not")
    }

    @Test func anExpandedFolderGetsNoBadge() throws {
        let fixture = makeFixture()
        let current = fixture.browser.newTab()
        let folder = fixture.browser.createFolder(named: "Work", containing: [current])
        folder.isExpanded = true

        let row = sidebar(
            FolderSection(folder: folder, depth: 0, context: fixture.context),
            height: rowHeight * 2 + 4
        )

        #expect(!isWhite(try pixel(of: row, x: rowWidth - 9 - 14, y: rowHeight / 2)))
    }
}
