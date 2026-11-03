// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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
    /// Nil once the panel closes, so a page's colour chooser is never taken for it.
    private(set) static var current: FolderColorEdit?

    /// Forgets the edit when the panel closes, from the first `present` on. The panel does not retain its target, so it is
    /// let go of first: otherwise the panel keeps pointing at the freed edit and its next action (a text field updating
    /// the font panel sends one) crashes the app.
    private static let closeWatcher = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: NSColorPanel.shared, queue: .main
    ) { _ in
        MainActor.assumeIsolated { release() }
    }

    /// Points the panel away from the current edit and forgets it.
    static func release(_ panel: NSColorPanel = .shared) {
        guard current != nil else { return }
        panel.setTarget(nil)
        panel.setAction(nil)
        current = nil
    }

    /// Opens the shared color panel on the folder's color. The panel has no transparency: a folder color is solid.
    static func present(for folder: TabFolder, browser: BrowserModel) {
        let edit = FolderColorEdit(folder: folder, browser: browser)
        let panel = NSColorPanel.shared
        _ = closeWatcher
        // Target first, then let go of the previous edit, so the panel never points at a freed one.
        panel.setTarget(edit)
        panel.setAction(#selector(FolderColorEdit.panelChanged(_:)))
        current = edit
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = (folder.customColor?.nsColor ?? folder.color.nsTint).usingColorSpace(.sRGB) ?? .gray
        panel.makeKeyAndOrderFront(nil)
    }
}
