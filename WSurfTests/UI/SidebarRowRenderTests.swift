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
        let restoreTheme: () -> Void

        var browser: BrowserModel {
            coordinator.browser
        }
    }

    private func makeFixture() -> Fixture {
        let settings = BrowserSettings.application
        let saved = (settings.themeID, settings.themeAdjustments)
        settings.themeID = "standard"
        settings.themeAdjustments["standard"] = nil
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
        return Fixture(coordinator: coordinator, context: context, restoreTheme: {
            settings.themeAdjustments = saved.1
            settings.themeID = saved.0
        })
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
        ground: NSColor? = nil,
        isFloating: Bool = false
    ) -> some View {
        row
            .frame(width: width ?? rowWidth, height: height ?? rowHeight)
            .environment(\.sidebarStyle, style)
            .environment(\.sidebarIsFloating, isFloating)
            .environment(\.chromeWash, .of(ground ?? darkGround, isLight: scheme == .light))
            .environment(\.chromeIsLight, scheme == .light)
            .environment(\.colorScheme, scheme)
            .environment(\.windowColorScheme, scheme)
            .background(Color(red: 0.5, green: 0.5, blue: 0.5))
    }

    /// `view` drawn by AppKit in an unshown window: the rows hold AppKit views that `ImageRenderer` cannot draw.
    private func rendered(_ view: some View) throws -> (bitmap: NSBitmapImageRep, scale: CGFloat) {
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
        return (bitmap, CGFloat(bitmap.pixelsWide) / host.bounds.width)
    }

    /// The pixel at `(x, y)` points from the top left.
    private func pixel(of view: some View, x: CGFloat, y: CGFloat) throws -> NSColor {
        let (bitmap, scale) = try rendered(view)
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

    /// The middle of the new-tab dot in a full-width row: on the icon's trailing edge, 2 pt below its top.
    private var dotCenter: CGPoint {
        CGPoint(x: 9 + SidebarMetrics.rowIconSize, y: (rowHeight - SidebarMetrics.rowIconSize) / 2 + 2)
    }

    // MARK: - Tab rows

    @Test func theCurrentTabRowIsFilledAndAnotherIsNot() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        let other = fixture.browser.newTab()
        let current = fixture.browser.newTab()

        let currentRow = sidebar(SidebarTabRow(tab: current, depth: 0, context: fixture.context))
        let otherRow = sidebar(SidebarTabRow(tab: other, depth: 0, context: fixture.context))

        #expect(isWhite(try pixel(of: currentRow, x: emptySpot.x, y: emptySpot.y)))
        #expect(isBase(try pixel(of: otherRow, x: emptySpot.x, y: emptySpot.y)))
    }

    @Test func nothingIsFilledWhileTheNewTabPaletteIsOpen() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        let current = fixture.browser.newTab()
        fixture.coordinator.requestNewTab()
        defer { fixture.coordinator.closePalette() }

        let row = sidebar(SidebarTabRow(tab: current, depth: 0, context: fixture.context))

        #expect(isBase(try pixel(of: row, x: emptySpot.x, y: emptySpot.y)))
    }

    @Test func aNewTabHasTheDotAndAFilledOneDoesNot() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        let current = fixture.browser.newTab()
        let background = fixture.browser.newTab(activate: false)
        fixture.browser.activate(current)
        #expect(background.isUnseen)

        let newRow = sidebar(SidebarTabRow(tab: background, depth: 0, context: fixture.context))
        let currentRow = sidebar(SidebarTabRow(tab: current, depth: 0, context: fixture.context))

        #expect(
            isBlue(try pixel(of: newRow, x: dotCenter.x, y: dotCenter.y)),
            "the dot sits on the icon's trailing edge"
        )
        #expect(isBase(try pixel(of: newRow, x: emptySpot.x, y: emptySpot.y)), "a new tab is not filled")
        #expect(!isBlue(try pixel(of: currentRow, x: dotCenter.x, y: dotCenter.y)), "the current tab has no dot")
    }

    @Test func openingTheNewTabTakesTheDotAndFillsTheRow() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        _ = fixture.browser.newTab()
        let background = fixture.browser.newTab(activate: false)
        let row = SidebarTabRow(tab: background, depth: 0, context: fixture.context)
        #expect(isBlue(try pixel(of: sidebar(row), x: dotCenter.x, y: dotCenter.y)))

        fixture.browser.activate(background)

        let opened = sidebar(SidebarTabRow(tab: background, depth: 0, context: fixture.context))
        #expect(isWhite(try pixel(of: opened, x: emptySpot.x, y: emptySpot.y)))
        #expect(!isBlue(try pixel(of: opened, x: dotCenter.x, y: dotCenter.y)))
    }

    // MARK: - Solid themes

    @Test func theCurrentRowWearsEachSolidThemesOwnTextColor() throws {
        let settings = BrowserSettings.application
        let saved = (settings.colorMode, settings.themeID, settings.userThemes, settings.themeAdjustments)
        let savedForcedDark = settings.forcesDarkAppearance
        let savedNativeAppearance = NSApp.appearance
        defer {
            settings.userThemes = saved.2
            settings.themeAdjustments = saved.3
            settings.themeID = saved.1
            settings.colorMode = saved.0
            settings.forcesDarkAppearance = savedForcedDark
            NSApp.appearance = savedNativeAppearance
        }
        settings.forcesDarkAppearance = false
        settings.userThemes = []
        settings.themeAdjustments = [:]
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        _ = fixture.browser.newTab()
        let current = fixture.browser.newTab()

        for theme in ThemeCatalog.builtIn where theme.ground == .solid {
            settings.themeID = theme.id
            for scheme in [ColorScheme.light, .dark] {
                settings.colorMode = scheme == .dark ? .dark : .light
                let ground = LoomChrome.sampledColor(nil, scheme: scheme, isFloating: true)
                let row = sidebar(
                    SidebarTabRow(tab: current, depth: 0, context: fixture.context), scheme: scheme, ground: ground,
                    isFloating: true
                )

                let painted = try pixel(of: row, x: emptySpot.x, y: emptySpot.y)
                let ink = try #require(theme.variant(scheme).text)

                // The window reads colors back through its own color space, which moves them by a few percent. A
                // fallback to black or white would be off by far more.
                #expect(abs(painted.redComponent - CGFloat((ink >> 16) & 255) / 255) < 0.06, "\(theme.id) \(scheme) red")
                #expect(abs(painted.greenComponent - CGFloat((ink >> 8) & 255) / 255) < 0.06, "\(theme.id) \(scheme) green")
                #expect(abs(painted.blueComponent - CGFloat(ink & 255) / 255) < 0.06, "\(theme.id) \(scheme) blue")
            }
        }
    }

    // MARK: - Icons only

    @Test func theCurrentTabIsFilledInTheIconsOnlySidebar() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
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
        defer { fixture.restoreTheme() }
        let current = fixture.browser.newTab()
        let background = fixture.browser.newTab(activate: false)
        fixture.browser.activate(current)
        let width = SidebarMetrics.iconsWidth
        let dot = CGPoint(
            x: (width + SidebarMetrics.rowIconSize) / 2,
            y: (rowHeight - SidebarMetrics.rowIconSize) / 2 + 2
        )

        let row = sidebar(
            SidebarTabRow(tab: background, depth: 0, context: fixture.context), width: width, style: .icons
        )

        #expect(isBlue(try pixel(of: row, x: dot.x, y: dot.y)))
    }

    // MARK: - Splits

    @Test func onlyTheFocusedPaneOfASplitIsFilled() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
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

    // MARK: - Vertical centering

    /// A drawn row read as ink: how far each pixel has moved from the base toward the thing drawn, 0 where the base
    /// shows and 1 where the ink is. An edge is placed from the partial coverage of its pixel, so it holds to a
    /// fraction of a point at any display scale.
    private struct Ink {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        let base: [CGFloat]

        init(bitmap: NSBitmapImageRep, scale: CGFloat, baseAt spot: CGPoint) throws {
            self.bitmap = bitmap
            self.scale = scale
            let color = try #require(
                bitmap.colorAt(x: Int(spot.x * scale), y: Int(spot.y * scale))?.usingColorSpace(.sRGB)
            )
            base = [color.redComponent, color.greenComponent, color.blueComponent]
        }

        var height: CGFloat {
            CGFloat(bitmap.pixelsHigh) / scale
        }

        private func distance(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return max(
                abs(color.redComponent - base[0]),
                abs(color.greenComponent - base[1]),
                abs(color.blueComponent - base[2])
            )
        }

        /// How much of each pixel the ink covers in `columns`, against the strongest pixel there.
        private func coverage(columns: Range<Int>) -> [[CGFloat]] {
            let grid = (0..<bitmap.pixelsHigh).map { y in columns.map { distance($0, y) } }
            let strongest = grid.joined().max() ?? 0
            guard strongest > 0 else { return grid }
            return grid.map { row in row.map { $0 / strongest < 0.05 ? 0 : $0 / strongest } }
        }

        /// The top and bottom edge, in points, of the ink between the columns `xs` (points). An edge sits where the
        /// ink covers as much of the outermost row as that row holds against the row just inside it.
        func vertical(in xs: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
            let columns = Int((xs.lowerBound * scale).rounded(.down))..<Int((xs.upperBound * scale).rounded(.up))
            let rows = coverage(columns: columns).map { $0.reduce(0, +) }
            guard let peak = rows.max(), peak > 0 else { return nil }
            let inked = rows.indices.filter { rows[$0] > 0.05 * peak }
            guard let first = inked.first, let last = inked.last, last - first > 2 else { return nil }
            let top = CGFloat(first) + 1 - min(rows[first] / rows[first + 1], 1)
            let bottom = CGFloat(last) + min(rows[last] / rows[last - 1], 1)
            return (top / scale)...(bottom / scale)
        }

        /// The first column, in points, right of `x` where the ink reaches a quarter of its densest column.
        func leading(from x: CGFloat) -> CGFloat? {
            let start = Int(x * scale)
            let grid = coverage(columns: start..<bitmap.pixelsWide)
            let columns = (0..<(bitmap.pixelsWide - start)).map { column in grid.reduce(0) { $0 + $1[column] } }
            guard let peak = columns.max(), peak > 0,
                  let first = columns.firstIndex(where: { $0 >= 0.25 * peak }) else { return nil }
            return CGFloat(start + first) / scale
        }
    }

    private func readInk(of view: some View, baseAt spot: CGPoint? = nil) throws -> Ink {
        let drawn = try rendered(view)
        return try Ink(bitmap: drawn.bitmap, scale: drawn.scale, baseAt: spot ?? emptySpot)
    }

    /// A solid white square, so the icon of a tab has flat edges to measure.
    private let solidIcon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
        NSColor.white.setFill()
        bounds.fill()
        return true
    }

    /// A tab that shows a page, titled with four capitals: capitals are as tall as the font says and their edges
    /// are flat, so the baseline can be read off the drawing.
    private func measurable(_ tab: BrowserTab) {
        tab.title = Self.measuredTitle
        tab.urlString = "https://example.com/"
        tab.favicon = solidIcon
    }

    private static let measuredTitle = "HHH"

    private func width(of title: String, in font: NSFont) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width
    }

    private func sidebarFont(size: Double, family: String) -> NSFont {
        BrowserSettings.nativeSidebarFont(
            family: family,
            size: CGFloat(size),
            weight: BrowserSettings.application.sidebarFontWeight
        )
    }

    /// Runs `body` with the sidebar set in `family` at `size`, and puts the settings back.
    private func withSidebarFont(size: Double, family: String, _ body: () throws -> Void) rethrows {
        let settings = BrowserSettings.application
        let saved = (settings.sidebarFontSize, settings.sidebarFontFamily)
        defer { (settings.sidebarFontSize, settings.sidebarFontFamily) = saved }
        settings.sidebarFontSize = size
        settings.sidebarFontFamily = family
        try body()
    }

    /// Half a point, as asked for, and a tenth for reading an edge off the pixel grid: a display of 1x puts text and
    /// icons on whole pixels, which moves them by up to half a point by itself.
    private let tolerance: CGFloat = 0.6

    /// Where the ink of the folder symbol sits in its 16 pt frame, in points below the middle. The drawing of the
    /// symbol is not centered on its own box, and a display of 1x moves a frame that starts between two pixels.
    private func folderSymbolBias() throws -> CGFloat {
        let frame = Image(systemName: "folder.fill")
            .font(Theme.Font.caption)
            .foregroundStyle(.white)
            .frame(width: SidebarMetrics.rowIconSize, height: SidebarMetrics.rowIconSize)
            .background(Color(red: 0.5, green: 0.5, blue: 0.5))
        let ink = try readInk(of: frame, baseAt: CGPoint(x: 0.5, y: 0.5))
        let edges = try #require(ink.vertical(in: 0...SidebarMetrics.rowIconSize))
        return (edges.lowerBound + edges.upperBound) / 2 - ink.height / 2
    }

    /// The icon is as high as the row's middle, and so is the middle of the letters in the title: halfway between
    /// the tops of capitals and of lowercase letters, above the baseline. `iconBias` is where the ink of the icon
    /// sits in its own frame.
    private func expectCentered(
        _ ink: Ink,
        icon: ClosedRange<CGFloat>,
        iconBias: CGFloat = 0,
        font: NSFont,
        _ name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let center = ink.height / 2
        let iconEdges = try #require(ink.vertical(in: icon), "\(name): no icon was drawn", sourceLocation: sourceLocation)
        let title = try #require(
            ink.vertical(in: 33...(33 + width(of: Self.measuredTitle, in: font))),
            "\(name): no title was drawn",
            sourceLocation: sourceLocation
        )
        let midline = (font.capHeight + font.xHeight) / 4
        let iconOff = (iconEdges.lowerBound + iconEdges.upperBound) / 2 - center - iconBias
        let titleOff = title.upperBound - midline - center
        let capitals = title.upperBound - title.lowerBound

        #expect(
            abs(capitals - font.capHeight) <= 1,
            "\(name): measured capitals \(capitals) pt tall, expected \(font.capHeight)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(iconOff) <= tolerance,
            "\(name): the icon is \(iconOff) pt off the row's middle",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(titleOff) <= tolerance,
            "\(name): the title is \(titleOff) pt off the row's middle",
            sourceLocation: sourceLocation
        )
    }

    @Test(arguments: [10.0, 12, 14, 16, 20], ["", "Helvetica Neue", "Menlo", "Georgia"])
    func theIconAndTheTitleMeetOnTheMiddleOfTheRow(size: Double, family: String) throws {
        try withSidebarFont(size: size, family: family) {
            let font = sidebarFont(size: size, family: family)
            let fixture = makeFixture()
            defer { fixture.restoreTheme() }
            let resting = fixture.browser.newTab()
            let inFolder = fixture.browser.newTab()
            let left = fixture.browser.newTab()
            let right = fixture.browser.newTab()
            let current = fixture.browser.newTab()
            let new = fixture.browser.newTab(activate: false)
            [resting, inFolder, left, right, current, new].forEach(measurable)
            let folder = fixture.browser.createFolder(named: Self.measuredTitle, containing: [inFolder])
            folder.isExpanded = false
            fixture.browser.split(left, with: right, axis: .sideBySide)
            fixture.browser.activate(current)
            let split = try #require(fixture.browser.splits.split(containing: left.id))
            let context = fixture.context
            let middle = rowHeight / 2

            for (name, tab) in [("a tab", resting), ("a new tab", new), ("the current tab", current)] {
                let row = sidebar(SidebarTabRow(tab: tab, depth: 0, context: context))
                try expectCentered(readInk(of: row), icon: 10...20, font: font, name)
            }
            try expectCentered(
                readInk(of: sidebar(FolderSection(folder: folder, depth: 0, context: context))),
                icon: 9...25, iconBias: folderSymbolBias(), font: font, "a folder"
            )
            try expectCentered(
                readInk(
                    of: sidebar(SidebarSplitRow(leading: left, split: split, depth: 0, context: context)),
                    baseAt: CGPoint(x: 33 + width(of: Self.measuredTitle, in: font) + 6, y: middle)
                ),
                icon: 10...20, font: font, "a split pane"
            )
        }
    }

    @Test func aFolderTitleStartsWhereATabTitleStarts() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        let tab = fixture.browser.newTab()
        let inFolder = fixture.browser.newTab()
        let current = fixture.browser.newTab()
        [tab, inFolder, current].forEach(measurable)
        let folder = fixture.browser.createFolder(named: Self.measuredTitle, containing: [inFolder])
        folder.isExpanded = false

        let tabRow = sidebar(SidebarTabRow(tab: tab, depth: 0, context: fixture.context))
        let folderRow = sidebar(FolderSection(folder: folder, depth: 0, context: fixture.context))
        // Past the icon of either row, which ends at 25 pt.
        let tabStart = try #require(try readInk(of: tabRow).leading(from: 26))
        let folderStart = try #require(try readInk(of: folderRow).leading(from: 26))

        #expect(
            abs(tabStart - folderStart) <= tolerance,
            "the folder title starts at \(folderStart) pt, a tab title at \(tabStart) pt"
        )
    }

    @Test(arguments: [10.0, 12, 20])
    func theIconIsCenteredInTheIconsOnlySidebar(size: Double) throws {
        try withSidebarFont(size: size, family: "") {
            let fixture = makeFixture()
            defer { fixture.restoreTheme() }
            let tab = fixture.browser.newTab()
            let inFolder = fixture.browser.newTab()
            let current = fixture.browser.newTab()
            [tab, inFolder, current].forEach(measurable)
            let folder = fixture.browser.createFolder(named: Self.measuredTitle, containing: [inFolder])
            folder.isExpanded = false
            let width = SidebarMetrics.iconsWidth
            let corner = CGPoint(x: 1, y: 1)

            let rows: [(String, AnyView, CGFloat)] = try [
                ("a tab", AnyView(SidebarTabRow(tab: tab, depth: 0, context: fixture.context)), 0),
                (
                    "a folder",
                    AnyView(FolderSection(folder: folder, depth: 0, context: fixture.context)),
                    folderSymbolBias()
                ),
            ]
            for (name, row, bias) in rows {
                let ink = try readInk(of: sidebar(row, width: width, style: .icons), baseAt: corner)
                let edges = try #require(ink.vertical(in: 0...width), "\(name): no icon was drawn")
                let off = (edges.lowerBound + edges.upperBound) / 2 - ink.height / 2 - bias
                #expect(abs(off) <= tolerance, "\(name): the icon is \(off) pt off the row's middle")
            }
        }
    }

    @Test func aFavoriteIsCenteredInItsTile() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        _ = fixture.browser.newTab()
        let favorite = fixture.browser.newTab()
        measurable(favorite)

        let tile = sidebar(
            SidebarFavoriteButton(tab: favorite, browser: fixture.browser, coordinator: fixture.coordinator),
            width: 32, height: 32
        )
        let ink = try readInk(of: tile, baseAt: CGPoint(x: 1, y: 1))
        let edges = try #require(ink.vertical(in: 9...23))
        let off = (edges.lowerBound + edges.upperBound) / 2 - ink.height / 2

        #expect(abs(off) <= tolerance, "the icon is \(off) pt off the tile's middle")
    }

    @Test func theNewTabDotStaysInsideTheRow() throws {
        try withSidebarFont(size: 10, family: "") {
            let fixture = makeFixture()
            defer { fixture.restoreTheme() }
            let current = fixture.browser.newTab()
            let background = fixture.browser.newTab(activate: false)
            fixture.browser.activate(current)
            #expect(rowHeight == 24, "the shortest row")

            let row = sidebar(SidebarTabRow(tab: background, depth: 0, context: fixture.context))
            let drawn = try rendered(row)
            let ink = try Ink(bitmap: drawn.bitmap, scale: drawn.scale, baseAt: emptySpot)

            // A dot and its ring would show against the base. Nothing may reach the top 1.5 pt of the row.
            var touched = 0
            for y in 0..<Int(1.5 * drawn.scale) {
                for x in 0..<drawn.bitmap.pixelsWide {
                    let color = try #require(drawn.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if abs(color.redComponent - ink.base[0]) > 0.03 || abs(color.blueComponent - ink.base[2]) > 0.03 {
                        touched += 1
                    }
                }
            }
            #expect(touched == 0, "\(touched) pixels in the top 1.5 pt of the row are not the base")
            #expect(isBlue(try pixel(of: row, x: dotCenter.x, y: dotCenter.y)), "the dot is still there")
        }
    }

    @Test func thePinReturnButtonFitsTheRow() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
        let tab = fixture.browser.newTab()
        let margin: CGFloat = 8
        // The red shows the space the button takes. Beside the row it would spill over the margin.
        let button = PinReturnSegment(tab: tab, help: "", tint: .white, isHovering: .constant(false)) {}
            .background(Color(red: 1, green: 0, blue: 0))
            .frame(height: rowHeight)
            .padding(.vertical, margin)
            .background(Color(red: 0.5, green: 0.5, blue: 0.5))

        // Left of the arrow, which sits in the middle of the button.
        let above = try pixel(of: button, x: 4, y: margin - 2)
        let inside = try pixel(of: button, x: 4, y: margin + rowHeight / 2)
        let below = try pixel(of: button, x: 4, y: margin + rowHeight + 2)

        #expect(inside.redComponent - inside.greenComponent > 0.3, "the button fills the row")
        #expect(isBase(above), "the button does not rise above the row")
        #expect(isBase(below), "the button does not hang below the row")
    }

    // MARK: - Folders

    @Test func aCollapsedFolderMarksTheCurrentTabWithAnInverseBadge() throws {
        let fixture = makeFixture()
        defer { fixture.restoreTheme() }
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
        defer { fixture.restoreTheme() }
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
