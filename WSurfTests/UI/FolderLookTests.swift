// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import WSurf

/// A folder's own color and own icon, beyond the nine presets and the plain folder: what is stored and read back, the
/// undo steps, the menu, what the row resolves them to, and what is drawn with Folder color opacity, Size and Tint
/// Icons as Folder.
@MainActor
struct FolderLookTests {
    private let orange = CustomFolderColor(red: 255, green: 136, blue: 0)
    private let violet = CustomFolderColor(red: 120, green: 60, blue: 220)

    // MARK: - The color

    @Test func aCustomColorIsThreeBytesThatBecomeTextAndComeBack() throws {
        #expect(orange.hex == "#FF8800")
        #expect(CustomFolderColor(hex: "#FF8800") == orange)
        #expect(CustomFolderColor(hex: "ff8800") == orange, "the # and the case do not matter")
        for bad in ["", "#FF880", "#FF88000", "#GG8800", "+F8800", "orange", "#FF 800"] {
            #expect(CustomFolderColor(hex: bad) == nil, "\(bad) is not a color")
        }
        // Whatever space the panel gives, the color is kept as sRGB, solid.
        let panel = NSColor(srgbRed: 1, green: 0.5333, blue: 0, alpha: 0.4)
        #expect(CustomFolderColor(panel) == orange)
        let wide = NSColor(displayP3Red: 1, green: 1, blue: 1, alpha: 1)
        #expect(CustomFolderColor(wide) == CustomFolderColor(red: 255, green: 255, blue: 255))
        #expect(orange.nsColor.usingColorSpace(.sRGB)?.redComponent == 1)
    }

    @Test func aFolderHasNoCustomColorOrSymbolUntilGivenOne() {
        let folder = TabFolder(name: "Work")
        #expect(folder.customColor == nil && folder.symbol == nil)
        #expect(folder.tint == folder.color.tint)
        #expect(folder.glyph(isOpen: true) == "folder")
        #expect(folder.glyph(isOpen: false) == "folder.fill")
    }

    @Test func aCustomColorTakesThePlaceOfThePresetAndAPresetTakesItBack() {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        folder.color = .blue

        browser.setFolderCustomColor(orange, for: folder)
        #expect(folder.customColor == orange)
        #expect(folder.tint == Color(nsColor: orange.nsColor))
        #expect(folder.tint(opacity: 0.5) == Color(nsColor: orange.nsColor).opacity(0.5))
        #expect(folder.color == .blue, "the preset is kept underneath")

        browser.setFolderColor(.green, for: folder)
        #expect(folder.customColor == nil)
        #expect(folder.tint == TabFolderColor.green.tint)
    }

    // MARK: - Undo

    @Test func theColorPanelsManyChangesAreOneUndoStep() {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        folder.color = .red
        let edit = FolderColorEdit(folder: folder, browser: browser)

        edit.apply(orange.nsColor)
        edit.apply(violet.nsColor)
        edit.apply(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        #expect(folder.customColor == CustomFolderColor(red: 0, green: 255, blue: 0))

        browser.sidebarUndoManager.undo()
        #expect(folder.customColor == nil && folder.color == .red, "one undo puts back what the panel found")
        #expect(!browser.sidebarUndoManager.canUndo)
        browser.sidebarUndoManager.redo()
        #expect(folder.customColor == CustomFolderColor(red: 0, green: 255, blue: 0), "and one redo the last color")
    }

    @Test func aPanelThatOpensOnTheColorItAlreadyHasIsNotAStep() {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        browser.setFolderCustomColor(orange, for: folder)
        browser.sidebarUndoManager.undo()
        browser.sidebarUndoManager.redo()
        let edit = FolderColorEdit(folder: folder, browser: browser)
        edit.apply(orange.nsColor)
        browser.sidebarUndoManager.undo()
        #expect(folder.customColor == nil, "the only step is the first choice")
    }

    @Test func aPresetAfterACustomColorPutsBothBackWithOneUndo() {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        folder.color = .blue
        browser.setFolderCustomColor(orange, for: folder)
        browser.sidebarUndoManager.removeAllActions()

        browser.setFolderColor(.red, for: folder)
        #expect(folder.customColor == nil && folder.color == .red)
        browser.sidebarUndoManager.undo()
        #expect(folder.customColor == orange && folder.color == .blue)
        #expect(!browser.sidebarUndoManager.canUndo)

        browser.setFolderColor(.blue, for: folder)
        browser.setFolderColor(.blue, for: folder)
        browser.sidebarUndoManager.undo()
        #expect(folder.customColor == orange, "choosing what it already is is not a step")
        #expect(!browser.sidebarUndoManager.canUndo)
    }

    @Test func theIconIsOneUndoStepAndChoosingTheSameOneIsNone() {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")

        browser.setFolderSymbol("star.fill", for: folder)
        #expect(folder.symbol == "star.fill")
        browser.setFolderSymbol("star.fill", for: folder)
        browser.sidebarUndoManager.undo()
        #expect(folder.symbol == nil)
        #expect(!browser.sidebarUndoManager.canUndo, "one step, and none for the same symbol")
        browser.sidebarUndoManager.redo()
        #expect(folder.symbol == "star.fill")

        browser.setFolderSymbol(nil, for: folder)
        #expect(folder.symbol == nil, "Default is the plain folder")
        browser.sidebarUndoManager.undo()
        #expect(folder.symbol == "star.fill")
        browser.setFolderSymbol("", for: folder)
        #expect(folder.symbol == nil, "an empty name is Default too")
    }

    // MARK: - The menu

    @Test func theMenuOffersACustomColorUnderTheSwatchesAndAnIconAfterTheTintItem() throws {
        let rig = SidebarRowRig(space: "FolderLookTests")
        defer { rig.restore() }
        let browser = rig.browser
        let folder = browser.createFolder(named: "Work")
        var chose = false
        let menu = FolderContextMenu.make(
            folder: folder, browser: browser, coordinator: rig.coordinator, selected: [], onRename: {}, onChooseIcon: { chose = true }
        )
        let titles = menu.items.map(\.title)
        let custom = try #require(titles.firstIndex(of: "Custom Color…"))
        #expect(menu.items[custom - 1].view != nil, "the swatches are the item above it")
        #expect(menu.items[custom].state == .off)
        let tint = try #require(titles.firstIndex(of: "Tint Icons as Folder"))
        #expect(titles[tint + 1] == "Icon…")

        menu.performActionForItem(at: tint + 1)
        #expect(chose, "the item asks the row to open its picker")

        browser.setFolderCustomColor(orange, for: folder)
        let again = FolderContextMenu.make(
            folder: folder, browser: browser, coordinator: rig.coordinator, selected: [], onRename: {}
        )
        let checked = try #require(again.items.first { $0.title == "Custom Color…" })
        #expect(checked.state == .on, "checked while the folder wears its own color")
    }

    // MARK: - What is stored

    @Test func colorAndIconSurviveARestartAndOlderRowsReadAsTheDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderLook-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = AppDatabase(at: url)
        let browser = BrowserModel(database: database)
        let pinned = browser.createFolder(named: "Pinned")
        browser.pin(pinned)
        let loose = browser.createFolder(named: "Loose")
        let plain = browser.createFolder(named: "Plain")
        browser.setFolderCustomColor(orange, for: pinned)
        browser.setFolderSymbol("star.fill", for: pinned)
        browser.setFolderCustomColor(violet, for: loose)
        browser.setFolderSymbol("briefcase", for: loose)
        browser.saveBlocking()

        let restored = BrowserModel(database: AppDatabase(at: url))
        restored.restoreSession()
        #expect(restored.folder(id: pinned.id)?.customColor == orange, "a pinned folder keeps it with the profile's pins")
        #expect(restored.folder(id: pinned.id)?.symbol == "star.fill")
        #expect(restored.folder(id: loose.id)?.customColor == violet, "any other folder keeps it with its window")
        #expect(restored.folder(id: loose.id)?.symbol == "briefcase")
        #expect(restored.folder(id: plain.id)?.customColor == nil)
        #expect(restored.folder(id: plain.id)?.symbol == nil)

        try database.writer.write { db in
            for table in ["sessionFolder", "profilePin"] {
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN customColor")
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN symbol")
            }
        }
        let older = BrowserModel(database: AppDatabase(at: url))
        older.restoreSession()
        #expect(older.folders.count == 3)
        #expect(older.folders.allSatisfy { $0.customColor == nil && $0.symbol == nil }, "rows saved before read as Default")
    }

    @Test func aColorOrSymbolThatMeansNothingReadsAsTheDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderLookBad-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = AppDatabase(at: url)
        let browser = BrowserModel(database: database)
        let folder = browser.createFolder(named: "Loose")
        browser.saveBlocking()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE sessionFolder SET customColor = 'not a color', symbol = 'no.such.symbol.anywhere'")
        }
        let restored = BrowserModel(database: AppDatabase(at: url))
        restored.restoreSession()
        let read = try #require(restored.folder(id: folder.id))
        #expect(read.customColor == nil, "damaged text is the preset")
        #expect(read.glyph(isOpen: true) == "folder", "a symbol this Mac does not have is the plain folder")
    }

    // MARK: - What the row resolves them to

    @Test func theGlyphIsTheFolderOpenOrShutUntilASymbolIsChosenAndThenTheSameEitherWay() {
        let folder = TabFolder(name: "Work")
        #expect(folder.glyph(isOpen: true) == "folder")
        #expect(folder.glyph(isOpen: false) == "folder.fill")
        folder.symbol = "star.fill"
        #expect(folder.glyph(isOpen: true) == "star.fill")
        #expect(folder.glyph(isOpen: false) == "star.fill")
    }

    private func luminance(_ color: Color) -> CGFloat {
        SidebarRowStyle.luminance(NSColor(color).usingColorSpace(.sRGB) ?? .black)
    }

    @Test func aColorTooCloseToTheSidebarMovesToReadAndOthersAreLeftAlone() {
        let dark = ChromeWash.of(NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1), isLight: false)
        let light = ChromeWash.of(NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1), isLight: true)
        let folder = TabFolder(name: "Work")

        folder.customColor = CustomFolderColor(red: 24, green: 24, blue: 30)
        let lifted = folder.ink(opacity: 1, on: dark)
        #expect(SidebarRowStyle.contrast(luminance(lifted), SidebarRowStyle.luminance(dark.groundColor)) >= 3, "near black on a dark sidebar")
        #expect(luminance(lifted) > luminance(Color(nsColor: folder.customColor?.nsColor ?? .black)))

        folder.customColor = CustomFolderColor(red: 250, green: 250, blue: 240)
        let lowered = folder.ink(opacity: 1, on: light)
        #expect(SidebarRowStyle.contrast(luminance(lowered), SidebarRowStyle.luminance(light.groundColor)) >= 3, "near white on a light sidebar")

        folder.customColor = orange
        #expect(folder.ink(opacity: 1, on: dark) == Color(nsColor: orange.nsColor), "a color that reads is not touched")
        #expect(folder.ink(opacity: 0.4, on: dark) == Color(nsColor: orange.nsColor).opacity(0.4), "and Folder color opacity applies after")

        folder.customColor = nil
        folder.color = .red
        #expect(folder.ink(opacity: 1, on: dark) == TabFolderColor.red.tint, "a preset is the system color as it was")
    }

    // MARK: - What is drawn

    private func iconBox(rig: SidebarRowRig, top: CGFloat = 0, inset: CGFloat? = nil) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let start = inset ?? SidebarMetrics.rowContentPadding(style: .full)
        return (start...(start + SidebarMetrics.rowIconSize), top...(top + rig.rowHeight))
    }

    /// How many pixels of the box hold ink: the area of the glyph.
    private func inkArea(_ picture: SidebarRowRig.Picture, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) throws -> Int {
        let base = try picture.color(x: SidebarRowRig.width - 4, y: 0.5)
        var count = 0
        for row in Int(y.lowerBound * picture.scale)..<Int(y.upperBound * picture.scale) {
            for column in Int(x.lowerBound * picture.scale)..<Int(x.upperBound * picture.scale) {
                guard let pixel = picture.bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                let distance = max(
                    abs(pixel.redComponent - base.redComponent),
                    abs(pixel.greenComponent - base.greenComponent),
                    abs(pixel.blueComponent - base.blueComponent)
                )
                if distance > 0.25 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Orange, allowing for the pixel being a glyph's edge: it is a mix with the gray behind it.
    private func isOrange(_ color: NSColor) -> Bool {
        color.redComponent > 0.85 && color.blueComponent < 0.3 && color.greenComponent > color.blueComponent + 0.2
    }

    private func picture(of folder: TabFolder, in rig: SidebarRowRig) throws -> SidebarRowRig.Picture {
        try rig.picture(of: rig.sidebar(FolderSection(folder: folder, depth: 0, context: rig.context), height: rig.rowHeight))
    }

    private func strongest(_ picture: SidebarRowRig.Picture, rig: SidebarRowRig) throws -> NSColor {
        let box = iconBox(rig: rig)
        let base = try picture.color(x: SidebarRowRig.width - 4, y: 0.5)
        return try #require(picture.strongestColor(x: box.x, y: box.y, against: base))
    }

    @Test func theRowDrawsTheCustomColorAndTheCustomSymbol() throws {
        let rig = SidebarRowRig(space: "FolderLookTests")
        defer { rig.restore() }
        let folder = rig.browser.createFolder(named: "HHH")
        folder.isExpanded = false
        folder.color = .green

        let preset = try strongest(try picture(of: folder, in: rig), rig: rig)
        #expect(preset.greenComponent - preset.redComponent > 0.2, "the preset first")

        folder.customColor = orange
        let own = try strongest(try picture(of: folder, in: rig), rig: rig)
        #expect(isOrange(own), "the folder is orange: \(own)")

        let box = iconBox(rig: rig)
        let shut = try inkArea(try picture(of: folder, in: rig), x: box.x, y: box.y)
        folder.symbol = "star.fill"
        let star = try picture(of: folder, in: rig)
        #expect(try inkArea(star, x: box.x, y: box.y) < shut * 8 / 10, "a star has less ink than the shut folder")
        let starColor = try strongest(star, rig: rig)
        #expect(isOrange(starColor), "and it takes the folder's color: \(starColor)")

        folder.isExpanded = true
        let opened = try inkArea(try picture(of: folder, in: rig), x: box.x, y: box.y)
        folder.isExpanded = false
        #expect(abs(opened - (try inkArea(try picture(of: folder, in: rig), x: box.x, y: box.y))) <= 2, "the same symbol open and shut")
    }

    @Test func folderColorOpacityAndTheOwnColorWorkTogether() throws {
        let rig = SidebarRowRig(space: "FolderLookTests")
        defer { rig.restore() }
        let folder = rig.browser.createFolder(named: "HHH")
        folder.isExpanded = false
        folder.customColor = orange
        let base = SidebarRowRig.baseColor

        func distance() throws -> CGFloat {
            let picture = try picture(of: folder, in: rig)
            let box = iconBox(rig: rig)
            return picture.peakDistance(x: box.x, y: box.y, from: base)
        }
        let full = try distance()
        rig.adjust(ThemeAdjustment(folderColorOpacity: 0.4))
        let faint = try distance()
        #expect(faint < full * 0.7, "the folder is fainter at 40%: \(faint) against \(full)")
    }

    @Test func aTintingFolderPaintsItsTabsInItsOwnColor() throws {
        let rig = SidebarRowRig(space: "FolderLookTests")
        defer { rig.restore() }
        let browser = rig.browser
        let tab = browser.newTab()
        tab.title = "HHH"
        tab.urlString = "https://example.com/"
        let folder = browser.createFolder(named: "Work", containing: [tab])
        _ = browser.newTab()
        folder.customColor = orange
        folder.tintsIcons = true
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)
        let outline = FolderSection.outlineInset
        let inset = SidebarMetrics.rowContentPadding(style: .full) + outline
        let top = outline + row + spacing

        let picture = try rig.picture(of: rig.sidebar(
            FolderSection(folder: folder, depth: 0, context: rig.context), height: 2 * row + spacing + 2 * outline
        ))
        let base = try picture.color(x: SidebarRowRig.width - 4, y: 0.5)
        let color = try #require(picture.strongestColor(
            x: inset...(inset + SidebarMetrics.rowIconSize), y: top...(top + row), against: base
        ))
        #expect(color.redComponent > 0.8 && color.blueComponent < 0.25, "the tab's icon takes the folder's own color: \(color)")
    }

    @Test func theIconPickerFindsSymbolsByNameAndByTheWordsTheyAreFoundBy() {
        #expect(SymbolCatalog.suggested.contains("star") && SymbolCatalog.suggested.contains("briefcase"))
        #expect(SymbolCatalog.suggested.filter(SymbolCatalog.isAvailable).count > 80, "the suggestions are real symbols")
        #expect(SymbolCatalog.search("").isEmpty)
        let stars = SymbolCatalog.search("star")
        #expect(stars.first == "star", "the closest name first: \(stars.prefix(3))")
        #expect(stars.contains("star.fill"))
        #expect(SymbolCatalog.search("zzzzqqqq").isEmpty)
        #expect(SymbolCatalog.search("briefcase fill").allSatisfy { $0.contains("briefcase") || $0.contains("fill") })
        #expect(SymbolCatalog.search("star", limit: 5).count == 5)
        #expect(SymbolCatalog.search("calendar").count > 5)
    }

    // MARK: - Evidence

    /// Writes pictures of the rows and the icon picker to the folder in `WSURF_REVEAL_EVIDENCE`, for looking at.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WSURF_REVEAL_EVIDENCE"] != nil))
    func theLookIsDrawnForReview() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WSURF_REVEAL_EVIDENCE"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rig = SidebarRowRig(space: "FolderLookTests")
        defer { rig.restore() }
        func write(_ picture: SidebarRowRig.Picture, _ name: String) throws {
            let data = try #require(picture.bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }
        let browser = rig.browser
        let tab = browser.addPage("https://example.com/")
        tab.title = "A tab in the folder"
        let outer = browser.createFolder(named: "Work")
        let inner = browser.createFolder(named: "Reading")
        let third = browser.createFolder(named: "Shopping")
        browser.move([.folder(inner.id)], into: outer)
        browser.move([.folder(third.id)], into: outer)
        browser.move([.tab(tab.id)], into: inner)
        outer.symbol = "briefcase"
        outer.customColor = orange
        inner.symbol = "book"
        inner.color = .green
        third.symbol = "cart"
        third.customColor = violet
        third.isExpanded = false
        inner.tintsIcons = true
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)
        let height = 4 * row + 3 * spacing + 8
        try write(try rig.picture(of: rig.sidebar(FolderSection(folder: outer, depth: 0, context: rig.context), height: height)), "folders-own-color-and-icon")

        let live = browser.addPage("https://pulse.example/")
        live.title = "A tab that was just opened"
        browser.sidebarReveal = SidebarReveal(tabID: live.id, token: 1, start: .now.addingTimeInterval(-SidebarPulse.duration / 4))
        let pulsing = rig.sidebar(SidebarTabRow(tab: live, depth: 0, context: rig.context), height: row)
            .environment(\.sidebarPulsesRevealedRows, true)
        try write(try rig.picture(of: pulsing), "row-at-the-top-of-its-pulse")

        for (name, query) in [("picker-suggested", ""), ("picker-search-star", "star"), ("picker-search-date", "date")] {
            let picker = FolderIconPicker(folder: outer, browser: browser, query: query) {}
                .environment(\.colorScheme, .dark)
                .background(Color(white: 0.16))
            try write(try rig.picture(of: picker), name)
        }
    }
}
