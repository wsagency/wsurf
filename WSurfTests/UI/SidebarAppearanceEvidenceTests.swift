// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Draws what the sidebar appearance settings do, as images for a person to look at. It asserts nothing and does
/// nothing unless `WSURF_ALIGN_EVIDENCE` names a folder: the tests that check the numbers are `FolderIconTintTests`,
/// `FolderColorOpacityTests`, `FolderIndentLevelTests` and `SidebarIconAlignmentTests`.
@MainActor
struct SidebarAppearanceEvidenceTests {
    private var directory: URL? {
        ProcessInfo.processInfo.environment["WSURF_ALIGN_EVIDENCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func write(_ bitmaps: [(label: String, bitmap: NSBitmapImageRep)], as name: String) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let labelHeight: CGFloat = 36
        let width = bitmaps.map { CGFloat($0.bitmap.pixelsWide) }.max() ?? 0
        let height = bitmaps.reduce(CGFloat(0)) { $0 + CGFloat($1.bitmap.pixelsHigh) + labelHeight }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(white: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = height
        for entry in bitmaps {
            top -= labelHeight
            (entry.label as NSString).draw(
                at: NSPoint(x: 8, y: top + 8),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white]
            )
            let pixels = NSSize(width: entry.bitmap.pixelsWide, height: entry.bitmap.pixelsHigh)
            top -= pixels.height
            let drawn = NSImage(size: pixels)
            entry.bitmap.size = pixels
            drawn.addRepresentation(entry.bitmap)
            drawn.draw(in: NSRect(x: 0, y: top, width: pixels.width, height: pixels.height))
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    /// A folder holding a tab with a globe, one with a blue favicon and one with an orange favicon, and a folder
    /// inside it with a tab.
    private func folderWithTabs(_ rig: SidebarRowRig, name: String = "Research") -> (TabFolder, CGFloat) {
        let browser = rig.browser
        let globe = browser.newTab()
        globe.title = "A page with no icon"
        globe.urlString = "https://example.com/"
        let blue = browser.newTab()
        blue.title = "Blue favicon"
        blue.urlString = "https://example.org/"
        blue.favicon = color(0.15, 0.4, 0.95)
        let orange = browser.newTab()
        orange.title = "Orange favicon"
        orange.urlString = "https://example.net/"
        orange.favicon = color(0.95, 0.5, 0.1)
        let nested = browser.newTab()
        nested.title = "A tab one folder down"
        nested.urlString = "https://example.com/deeper"
        let inner = browser.createFolder(named: "Inner", containing: [nested])
        let folder = browser.createFolder(named: name, containing: [globe, blue, orange])
        browser.move([.folder(inner.id)], into: folder)
        _ = browser.newTab()
        folder.color = .green
        inner.color = .purple
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)
        let outline = FolderSection.outlineInset
        return (folder, 6 * row + 5 * spacing + 4 * outline)
    }

    @Test(.enabled(if: AlignmentMatrix.evidenceDirectory != nil))
    func tintIconsAsFolder() throws {
        let rig = SidebarRowRig(space: "SidebarAppearanceEvidenceTests")
        defer { rig.restore() }
        let (folder, height) = folderWithTabs(rig)
        var pictures: [(String, NSBitmapImageRep)] = []
        for (label, tints) in [("Tint Icons as Folder: off (the default)", false), ("Tint Icons as Folder: on, green folder", true)] {
            folder.tintsIcons = tints
            pictures.append((label, try rig.picture(of: rig.sidebar(
                FolderSection(folder: folder, depth: 0, context: rig.context), height: height
            )).bitmap))
        }
        try write(pictures, as: "tint-icons-as-folder.png")
    }

    /// A favicon with something to see: a ground, a white shape and a dark mark.
    private func detailed(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 14, dy: 14)).fill()
            NSColor(white: 0.1, alpha: 1).setFill()
            NSRect(x: 26, y: 18, width: 12, height: 28).fill()
            return true
        }
    }

    /// The tint a folder gives a favicon, drawn by the real `FaviconImage` (its shader is a Metal effect, which an
    /// unshown window does not run, so this goes through `ImageRenderer`).
    @Test(.enabled(if: AlignmentMatrix.evidenceDirectory != nil))
    func tintedFavicons() throws {
        let icons = [detailed(0.15, 0.4, 0.95), detailed(0.95, 0.5, 0.1), detailed(0.85, 0.2, 0.25), detailed(0.5, 0.5, 0.5)]
        let tints: [(String, Color?)] = [
            ("as the theme draws it (Monochrome)", Color.white.opacity(0.9)),
            ("green folder", TabFolderColor.green.tint), ("red folder", TabFolderColor.red.tint),
            ("blue folder", TabFolderColor.blue.tint), ("orange folder, 40 %", TabFolderColor.orange.tint(opacity: 0.4)),
        ]
        let grid = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(tints.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 14) {
                    Text(entry.0).font(.system(size: 13)).foregroundStyle(.white).frame(width: 220, alignment: .leading)
                    ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in
                        FaviconImage(image: icon, tint: entry.1).frame(width: 40, height: 40)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.25))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: grid)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("tinted-favicons.png"))
    }

    @Test(.enabled(if: AlignmentMatrix.evidenceDirectory != nil))
    func folderColorOpacity() throws {
        let rig = SidebarRowRig(space: "SidebarAppearanceEvidenceTests")
        defer { rig.restore() }
        let (folder, height) = folderWithTabs(rig)
        folder.tintsIcons = true
        var pictures: [(String, NSBitmapImageRep)] = []
        for opacity in [1.0, 0.7, 0.4, 0.2] {
            rig.adjust(ThemeAdjustment(folderColorOpacity: opacity))
            pictures.append(("Folder color opacity \(Int((opacity * 100).rounded())) %, tinting on", try rig.picture(of: rig.sidebar(
                FolderSection(folder: folder, depth: 0, context: rig.context), height: height
            )).bitmap))
        }
        try write(pictures, as: "folder-color-opacity.png")
    }

    @Test(.enabled(if: AlignmentMatrix.evidenceDirectory != nil))
    func folderIndentPerLevel() throws {
        let rig = SidebarRowRig(space: "SidebarAppearanceEvidenceTests")
        defer { rig.restore() }
        let browser = rig.browser
        let folders = (1...4).map { browser.createFolder(named: "Level \($0) folder") }
        for (parent, child) in zip(folders, folders.dropFirst()) {
            browser.move([.folder(child.id)], into: parent)
        }
        let leaf = browser.newTab()
        leaf.title = "A tab at the deepest level"
        leaf.urlString = "https://example.com/"
        browser.move([.tab(leaf.id)], into: folders[3])
        _ = browser.newTab()
        folders.enumerated().forEach { $1.color = [.blue, .green, .orange, .red][$0] }
        let row = rig.rowHeight
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)
        let height = 5 * row + 4 * spacing + 8 * FolderSection.outlineInset
        var pictures: [(String, NSBitmapImageRep)] = []
        for steps in [[0.0, 0, 0], [8, 8, 8], [4, 8, 12], [0, 12, 24]] {
            rig.adjust(ThemeAdjustment(folderIndentLevel1: steps[0], folderIndentLevel2: steps[1], folderIndentLevel3: steps[2]))
            pictures.append((
                "Level 1 \(Int(steps[0])) pt, level 2 \(Int(steps[1])) pt, level 3 and deeper \(Int(steps[2])) pt",
                try rig.picture(of: rig.sidebar(FolderSection(folder: folders[0], depth: 0, context: rig.context), height: height)).bitmap
            ))
        }
        try write(pictures, as: "folder-indent-per-level.png")
    }

    @Test(.enabled(if: AlignmentMatrix.evidenceDirectory != nil))
    func theSettingsRows() throws {
        let rig = SidebarRowRig(space: "SidebarAppearanceEvidenceTests")
        defer { rig.restore() }
        let settings = BrowserSettings.application
        rig.adjust(ThemeAdjustment(
            folderColorOpacity: 0.7, folderIndentLevel1: 4, folderIndentLevel2: 8, folderIndentLevel3: 12
        ))
        var pictures: [(String, NSBitmapImageRep)] = []
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            let ground = scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)
            let layout = SettingsCard { AppearanceLayoutSection(settings: settings, part: .sidebar) }
                .environment(\.settingsHighlight, "appearance.sidebarLayout")
                .frame(width: 560)
                .padding(16)
                .background(ground)
                .environment(\.colorScheme, scheme)
            pictures.append(("Settings > Appearance > Sidebar > Layout, \(name)", try rig.picture(of: layout).bitmap))
            let colors = AppearanceColorsSection(settings: settings, scheme: scheme, isExpanded: .constant(true))
                .frame(width: 560)
                .padding(16)
                .background(ground)
                .environment(\.colorScheme, scheme)
            pictures.append(("Settings > Appearance > Colors, \(name)", try rig.picture(of: colors).bitmap))
        }
        try write(pictures, as: "settings-rows.png")
    }
}
