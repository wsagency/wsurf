// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A page's colour chooser is the shared colour panel; it closes when its tab stops being the one in front, and the panel the
/// folder colour editor opened is left alone. The panel is shared by every test here, so they run one at a time.
@MainActor
@Suite(.serialized)
struct ColourChooserDismissalTests {
    @Test func switchingTabsClosesTheColourChooser() {
        let browser = BrowserModel(database: .temporary())
        let first = browser.addPage("https://one.example/")
        let second = browser.addPage("https://two.example/")
        browser.activate(first)
        let panel = NSColorPanel.shared
        panel.orderFront(nil)
        defer { panel.close() }
        #expect(panel.isVisible)

        browser.activate(second)

        #expect(!panel.isVisible, "the chooser of the tab left behind is gone")
    }

    @Test func theFolderColourPanelStaysWhenTabsSwitch() {
        let browser = BrowserModel(database: .temporary())
        let first = browser.addPage("https://one.example/")
        let second = browser.addPage("https://two.example/")
        browser.activate(first)
        let folder = browser.createFolder(named: "Work")
        FolderColorEdit.present(for: folder, browser: browser)
        let panel = NSColorPanel.shared
        defer { panel.close() }

        browser.activate(second)

        #expect(panel.isVisible, "the folder's colour panel is not a page's")
    }
}
