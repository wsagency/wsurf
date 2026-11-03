// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Knows which window the shared colour panel was opened from, so a page's chooser (an `input type=color` on either engine)
/// can be closed when its tab leaves the front without closing a picker WSurf's own windows opened (Settings' `ColorPicker`).
/// The panel gives no owner; the window that was key when it appeared is the nearest thing.
@MainActor
final class PageColourChooser {
    static let shared = PageColourChooser()

    private(set) weak var openedFrom: NSWindow?
    private var observation: NSKeyValueObservation?

    private init() {
        observation = NSColorPanel.shared.observe(\.isVisible, options: [.new]) { panel, _ in
            MainActor.assumeIsolated {
                let key = NSApp.keyWindow
                PageColourChooser.shared.openedFrom = panel.isVisible ? (key === panel ? NSApp.mainWindow : key) : nil
            }
        }
    }

    /// Closes the panel when it was opened from `window`, the one the page that left the front is in. Not while the folder
    /// colour editor has it.
    func close(openedBy window: NSWindow?, panel: NSColorPanel = .shared) {
        guard panel.isVisible, FolderColorEdit.current == nil, let window, openedFrom === window else { return }
        panel.close()
    }

    /// For tests: the panel was opened from this window.
    func noteOpened(from window: NSWindow?) {
        openedFrom = window
    }
}
