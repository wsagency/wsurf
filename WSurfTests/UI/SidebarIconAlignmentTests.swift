// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// What a sidebar row can show as its icon.
nonisolated enum AlignmentSource: String, CaseIterable, CustomStringConvertible, Sendable {
    /// Favicons: white art on clear, so its edges can be read. 16 and 32 px fill their frame.
    case favicon16
    case favicon32
    /// 48 px with the art 32 px square in the middle: transparent padding on every side.
    case favicon48Padded
    /// 48 px with the art 4 px from the top and 12 px from the bottom: padding that is not even.
    case favicon48High
    /// 32 px with the art flush to the top and two rows of padding at the bottom.
    case favicon32Low
    /// The symbols a tab shows when it has no favicon.
    case globe
    case startFace
    case settingsPage
    case historyPage
    case downloadsPage
    case releaseNotesPage
    /// A folder row, shut and open.
    case folderShut
    case folderOpen
    /// A folder row that wears a symbol a person chose: tall, wide, round and thin ones.
    case folderStar
    case folderBriefcase
    case folderCart
    case folderTerminal

    var description: String {
        rawValue
    }

    var isFolder: Bool {
        switch self {
        case .folderShut, .folderOpen, .folderStar, .folderBriefcase, .folderCart, .folderTerminal:
            true
        default:
            false
        }
    }

    /// The symbol a person chose for the folder, or nil for the plain folder.
    var chosenSymbol: String? {
        switch self {
        case .folderStar:
            "star.fill"
        case .folderBriefcase:
            "briefcase"
        case .folderCart:
            "cart"
        case .folderTerminal:
            "terminal"
        default:
            nil
        }
    }
}

/// One drawn row: what it shows and the sizes it is drawn at.
nonisolated struct AlignmentCell: CustomStringConvertible, Sendable {
    var source: AlignmentSource
    var iconSize: Double
    var fontSize: Double
    var family = ""
    var folderSize = TabFolderSize.normal
    var scale: CGFloat = 2

    var description: String {
        let font = family.isEmpty ? "" : " \(family)"
        return "\(source) icon \(Int(iconSize)) pt, font \(Int(fontSize)) pt\(font), folder \(folderSize.rawValue)x, \(Int(scale))x"
    }
}

/// Where the middle of the icon's ink and the middle of the capitals sit below the middle of the row, in points.
nonisolated struct AlignmentOffsets {
    let icon: CGFloat
    let capitals: CGFloat

    /// Positive: the icon sits lower than the title.
    var offset: CGFloat {
        icon - capitals
    }
}

nonisolated enum AlignmentMatrix {
    static let title = "HHH"
    static let iconSizes = [12.0, 16, 20, 24]
    static let fontSizes = [10.0, 12, 16, 20]

    static var reportRequested: Bool {
        ProcessInfo.processInfo.environment["WSURF_ALIGN_REPORT"] != nil
    }

    static var evidenceDirectory: URL? {
        ProcessInfo.processInfo.environment["WSURF_ALIGN_EVIDENCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Every cell: each source at each icon and font size; folders at each folder size too.
    static var all: [AlignmentCell] {
        var cells: [AlignmentCell] = []
        for source in AlignmentSource.allCases {
            for icon in iconSizes {
                for font in fontSizes {
                    if source.isFolder {
                        for size in TabFolderSize.allCases {
                            cells.append(AlignmentCell(source: source, iconSize: icon, fontSize: font, folderSize: size))
                        }
                    } else {
                        cells.append(AlignmentCell(source: source, iconSize: icon, fontSize: font))
                    }
                }
            }
        }
        return cells
    }

    /// A representative cell of each kind of icon at the extremes and at the default.
    static let representative: [AlignmentCell] = {
        var cells: [AlignmentCell] = []
        for source in AlignmentSource.allCases where !source.isFolder {
            for (icon, font) in [(16.0, 12.0), (12, 20), (24, 10), (20, 16)] {
                cells.append(AlignmentCell(source: source, iconSize: icon, fontSize: font))
            }
        }
        let folders: [(Double, Double, TabFolderSize)] = [(16, 12, .normal), (12, 20, .large), (24, 10, .largest), (20, 16, .larger)]
        for source in [AlignmentSource.folderShut, .folderOpen, .folderStar, .folderBriefcase, .folderCart, .folderTerminal] {
            for (icon, font, size) in folders {
                cells.append(AlignmentCell(source: source, iconSize: icon, fontSize: font, folderSize: size))
            }
        }
        for family in ["Helvetica Neue", "Menlo", "Georgia"] {
            cells.append(AlignmentCell(source: .globe, iconSize: 16, fontSize: 12, family: family))
            cells.append(AlignmentCell(source: .folderShut, iconSize: 16, fontSize: 12, family: family))
        }
        return cells
    }()
}

/// Draws real sidebar rows in an unshown window at the scale of a Retina display and measures where the visible
/// ink of the icon sits against the middle of the capitals in the title beside it, for every kind of icon a row
/// shows at every icon size, font size and folder size. A title of capitals has flat edges, so the middle of its
/// ink is the middle of its capitals. The target is half a point.
@MainActor
struct SidebarIconAlignmentTests {
    // MARK: - Fixture

    private let darkGround = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1)
    private let rowWidth: CGFloat = 260

    private struct Fixture {
        let coordinator: AppCoordinator
        let context: SidebarRowContext
        let restore: () -> Void

        var browser: BrowserModel {
            coordinator.browser
        }
    }

    private func makeFixture() -> Fixture {
        let settings = BrowserSettings.application
        let saved = (settings.themeID, settings.themeAdjustments, settings.sidebarFontSize, settings.sidebarFontFamily)
        settings.themeID = "standard"
        settings.themeAdjustments["standard"] = nil
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        let context = SidebarRowContext(
            browser: coordinator.browser,
            coordinator: coordinator,
            selection: coordinator.browser.sidebarSelection,
            drag: nil,
            pinsCarried: false,
            space: "SidebarIconAlignmentTests",
            frames: SidebarFrames()
        )
        return Fixture(coordinator: coordinator, context: context, restore: {
            settings.sidebarFontSize = saved.2
            settings.sidebarFontFamily = saved.3
            settings.themeAdjustments = saved.1
            settings.themeID = saved.0
        })
    }

    private func sidebar(_ row: some View, height: CGFloat) -> some View {
        row
            .frame(width: rowWidth, height: height)
            .environment(\.sidebarStyle, .full)
            .environment(\.sidebarIsFloating, false)
            .sidebarWash(.of(darkGround, isLight: false))
            .environment(\.chromeIsLight, false)
            .environment(\.colorScheme, .dark)
            .environment(\.windowColorScheme, .dark)
            .background(Color(red: 0.5, green: 0.5, blue: 0.5))
    }

    /// A window that reports the backing scale it is asked to, so a row is drawn at 2x without a Retina screen.
    private final class ScaledWindow: NSWindow {
        var scale: CGFloat = 2

        override var backingScaleFactor: CGFloat {
            scale
        }
    }

    /// `view` drawn by AppKit at `scale` pixels to the point. The rows hold AppKit views that `ImageRenderer` cannot draw.
    private func render(_ view: some View, scale: CGFloat) throws -> (bitmap: NSBitmapImageRep, scale: CGFloat) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = ScaledWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.colorSpace = .pixelTests
        window.scale = scale
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let drawn = CGFloat(bitmap.pixelsWide) / host.bounds.width
        if abs(drawn - scale) < 0.01 {
            return (bitmap, drawn)
        }
        // The window's own scale was not honored: draw into a bitmap of the scale that was asked for.
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / size.width)
    }

    // MARK: - Reading ink

    /// How far each pixel is from the base toward the thing drawn: 0 where the base shows, 1 where the ink is.
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

        private func distance(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return max(
                abs(color.redComponent - base[0]),
                abs(color.greenComponent - base[1]),
                abs(color.blueComponent - base[2])
            )
        }

        /// The top and bottom of the ink between the columns `xs` and the rows `ys` (points), in points from the top.
        /// A row weighs as much as its strongest pixel, so a round shape is read at its extremes like a flat one, and
        /// an edge sits inside its outermost row by the share of the pixel that the ink leaves empty.
        func vertical(in xs: ClosedRange<CGFloat>, rows ys: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
            let columns = Int((xs.lowerBound * scale).rounded(.down))..<min(bitmap.pixelsWide, Int((xs.upperBound * scale).rounded(.up)))
            let top = Int((ys.lowerBound * scale).rounded(.down))
            let bottom = min(bitmap.pixelsHigh, Int((ys.upperBound * scale).rounded(.up)))
            let grid = (top..<bottom).map { y in columns.map { distance($0, y) } }
            let strongest = grid.joined().max() ?? 0
            guard strongest > 0 else { return nil }
            let weights = grid.map { ($0.max() ?? 0) / strongest }
            let inked = weights.indices.filter { weights[$0] > 0.08 }
            guard let first = inked.first, let last = inked.last, last > first else { return nil }
            let upper = CGFloat(top + first) + 1 - min(weights[first], 1)
            let lower = CGFloat(top + last) + min(weights[last], 1)
            return (upper / scale)...(lower / scale)
        }
    }

    // MARK: - Favicons

    /// A favicon of `pixels` square with white art in `art` (pixels from the top left), clear elsewhere.
    private func favicon(pixels: Int, art: CGRect? = nil) -> NSImage {
        let side = CGFloat(pixels)
        let art = art ?? CGRect(x: 0, y: 0, width: side, height: side)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: art.minX, y: side - art.maxY, width: art.width, height: art.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    private func favicon(for source: AlignmentSource) -> NSImage? {
        switch source {
        case .favicon16:
            favicon(pixels: 16)
        case .favicon32:
            favicon(pixels: 32)
        case .favicon48Padded:
            favicon(pixels: 48, art: CGRect(x: 8, y: 8, width: 32, height: 32))
        case .favicon48High:
            favicon(pixels: 48, art: CGRect(x: 8, y: 4, width: 32, height: 32))
        case .favicon32Low:
            favicon(pixels: 32, art: CGRect(x: 0, y: 0, width: 32, height: 30))
        default:
            nil
        }
    }

    private func address(of source: AlignmentSource) -> String {
        switch source {
        case .startFace:
            ""
        case .settingsPage:
            BrowserTab.InternalPage.settings.url.absoluteString
        case .historyPage:
            BrowserTab.InternalPage.history.url.absoluteString
        case .downloadsPage:
            BrowserTab.InternalPage.downloads.url.absoluteString
        case .releaseNotesPage:
            BrowserTab.InternalPage.releaseNotes.url.absoluteString
        default:
            "https://example.com/"
        }
    }

    // MARK: - Measuring a cell

    /// Draws the row of `cell` and reads the icon and the capitals. `drawn` gets the picture of the row.
    private func measure(_ cell: AlignmentCell, drawn: ((NSBitmapImageRep) -> Void)? = nil) throws -> AlignmentOffsets {
        let settings = BrowserSettings.application
        let fixture = makeFixture()
        defer { fixture.restore() }
        settings.themeAdjustments["standard"] = ThemeAdjustment(tabIconSize: cell.iconSize)
        settings.sidebarFontSize = cell.fontSize
        settings.sidebarFontFamily = cell.family
        settings.refreshTheme()

        let factor = cell.source.isFolder ? cell.folderSize.factor : 1
        let font = BrowserSettings.nativeSidebarFont(
            family: cell.family, size: CGFloat(cell.fontSize) * factor, weight: settings.sidebarFontWeight
        )
        let titleWidth = (AlignmentMatrix.title as NSString).size(withAttributes: [.font: font]).width
        let icon = SidebarMetrics.rowIconSize * factor
        let padding = SidebarMetrics.rowContentPadding(style: .full)
        let rowHeight = SidebarMetrics.rowHeight(settings: settings, scale: factor)
        // An open folder draws its outline round the row and its contents under it.
        let outline = cell.source == .folderOpen ? FolderSection.outlineInset : 0
        let total: CGFloat
        let row: AnyView

        if cell.source.isFolder {
            let inFolder = fixture.browser.newTab()
            let folder = fixture.browser.createFolder(named: AlignmentMatrix.title, containing: [inFolder])
            folder.isExpanded = cell.source == .folderOpen
            folder.size = cell.folderSize
            folder.color = .red
            folder.symbol = cell.source.chosenSymbol
            // The tab opened last is the current one and is filled; the rows measured are not it.
            _ = fixture.browser.newTab()
            total = cell.source == .folderOpen
                ? rowHeight + SidebarMetrics.rowVerticalSpacing(settings: settings) + SidebarMetrics.rowHeight(settings: settings) + 2 * outline
                : rowHeight
            row = AnyView(FolderSection(folder: folder, depth: 0, context: fixture.context))
        } else {
            let tab = fixture.browser.newTab()
            // The tab opened last is the current one and is filled; the row measured is not it.
            _ = fixture.browser.newTab()
            tab.title = AlignmentMatrix.title
            tab.urlString = address(of: cell.source)
            tab.favicon = favicon(for: cell.source)
            total = rowHeight
            row = AnyView(SidebarTabRow(tab: tab, depth: 0, context: fixture.context))
        }

        let picture = try render(sidebar(row, height: total), scale: cell.scale)
        drawn?(picture.bitmap)
        let ink = try Ink(bitmap: picture.bitmap, scale: picture.scale, baseAt: CGPoint(x: rowWidth - 4, y: 0.5))
        let rows = outline...(outline + rowHeight)
        let titleStart = outline + padding + icon + SidebarMetrics.rowIconSpacing
        let iconEdges = try #require(
            ink.vertical(in: (outline + padding)...(outline + padding + icon), rows: rows), "\(cell): no icon was drawn"
        )
        let titleEdges = try #require(
            ink.vertical(in: titleStart...(titleStart + titleWidth), rows: rows), "\(cell): no title was drawn"
        )
        let middle = outline + rowHeight / 2
        return AlignmentOffsets(
            icon: (iconEdges.lowerBound + iconEdges.upperBound) / 2 - middle,
            capitals: (titleEdges.lowerBound + titleEdges.upperBound) / 2 - middle
        )
    }

    // MARK: - The report and the test

    /// Prints the whole matrix as drawn at 2x and at 1x, and writes some rows as images when asked to. It asserts
    /// nothing; the representative cells do. Run it with `WSURF_ALIGN_REPORT=1`.
    @Test(.enabled(if: AlignmentMatrix.reportRequested))
    func theWholeMatrixIsReported() throws {
        var worst: [String: CGFloat] = [:]
        var pictures: [(name: String, data: Data)] = []
        for scale in [CGFloat(2), 1] {
            for var cell in AlignmentMatrix.all {
                cell.scale = scale
                var png: Data?
                let found = try measure(cell, drawn: { bitmap in
                    let keep = cell.fontSize == 12 && cell.folderSize == .normal && [12.0, 16, 24].contains(cell.iconSize)
                    if scale == 2, keep {
                        png = bitmap.representation(using: .png, properties: [:])
                    }
                })
                let key = "\(Int(scale))x \(cell.source)"
                worst[key] = max(worst[key] ?? 0, abs(found.offset))
                print(String(
                    format: "ALIGN %@ | icon %+.2f caps %+.2f offset %+.2f", cell.description, found.icon, found.capitals, found.offset
                ))
                if let png {
                    pictures.append(("\(cell.source)-icon\(Int(cell.iconSize))", png))
                }
            }
        }
        for (key, value) in worst.sorted(by: { $0.key < $1.key }) {
            print(String(format: "ALIGN WORST %@ | %.2f pt", key, value))
        }
        if let directory = AlignmentMatrix.evidenceDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for picture in pictures {
                try picture.data.write(to: directory.appendingPathComponent("row-\(picture.name).png"))
            }
        }
    }

    @Test(arguments: AlignmentMatrix.representative)
    func theIconsInkMeetsTheMiddleOfTheCapitals(cell: AlignmentCell) throws {
        let found = try measure(cell)
        #expect(
            abs(found.offset) <= 0.5,
            "\(cell): the icon is \(found.offset) pt below the capitals (icon \(found.icon), capitals \(found.capitals) from the row's middle)"
        )
    }
}
