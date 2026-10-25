// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// One person's pass through the system color panel for one folder. The panel changes the color again and again while
/// a person drags in it, and every change shows on the folder at once, but only the first change is an undo step, so
/// one undo puts back the color the folder had when the panel was opened.
@MainActor
final class FolderColorEdit: NSObject {
    private weak var folder: TabFolder?
    private weak var browser: BrowserModel?
    private var hasChanged = false

    init(folder: TabFolder, browser: BrowserModel) {
        self.folder = folder
        self.browser = browser
    }

    func apply(_ color: NSColor) {
        guard let folder, let browser else { return }
        if browser.setFolderCustomColor(CustomFolderColor(color), for: folder, registersUndo: !hasChanged) {
            hasChanged = true
        }
    }

    @objc func panelChanged(_ panel: NSColorPanel) {
        apply(panel.color)
    }

    /// The edit the color panel is working for, kept for as long as the panel points at it.
    private static var current: FolderColorEdit?

    /// Opens the shared color panel on the folder's color. The panel has no transparency: a folder color is solid.
    static func present(for folder: TabFolder, browser: BrowserModel) {
        let edit = FolderColorEdit(folder: folder, browser: browser)
        current = edit
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(edit)
        panel.setAction(#selector(FolderColorEdit.panelChanged(_:)))
        panel.color = (folder.customColor?.nsColor ?? folder.color.nsTint).usingColorSpace(.sRGB) ?? .gray
        panel.makeKeyAndOrderFront(nil)
    }
}
