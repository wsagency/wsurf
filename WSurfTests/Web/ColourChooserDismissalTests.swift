// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A page's colour chooser is the shared colour panel; it closes when its tab stops being the one in front. A panel WSurf's own
/// windows opened (Settings' colour wells, the folder colour editor) is left alone. The panel is shared, so one test at a time.
@MainActor
@Suite(.serialized)
struct ColourChooserDismissalTests {
    private func window(showing tab: BrowserTab) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        return window
    }

    private func switchTabs(openedFrom opener: (NSWindow) -> NSWindow?) -> Bool {
        let browser = BrowserModel(database: .temporary())
        let first = browser.addPage("https://one.example/")
        let second = browser.addPage("https://two.example/")
        browser.activate(first)
        let pageWindow = window(showing: first)
        let panel = NSColorPanel.shared
        panel.orderFront(nil)
        PageColourChooser.shared.noteOpened(from: opener(pageWindow))
        defer { panel.close() }

        browser.activate(second)
        return panel.isVisible
    }

    @Test func switchingTabsClosesTheChooserTheTabsWindowOpened() {
        #expect(!switchTabs { $0 }, "the chooser of the tab left behind is gone")
    }

    @Test func aPickerSettingsOpenedStaysWhenTabsSwitch() {
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        #expect(switchTabs { _ in settings }, "a colour well of another window of the app is not a page's")
    }

    @Test func aPanelOfUnknownOriginStaysWhenTabsSwitch() {
        #expect(switchTabs { _ in nil })
    }

    @Test func theFolderColourPanelStaysWhenTabsSwitch() {
        #expect(switchTabsWithFolderEdit(), "the folder's colour panel is not a page's")
    }

    private func switchTabsWithFolderEdit() -> Bool {
        let browser = BrowserModel(database: .temporary())
        let first = browser.addPage("https://one.example/")
        let second = browser.addPage("https://two.example/")
        browser.activate(first)
        let pageWindow = window(showing: first)
        let folder = browser.createFolder(named: "Work")
        FolderColorEdit.present(for: folder, browser: browser)
        PageColourChooser.shared.noteOpened(from: pageWindow)
        defer { NSColorPanel.shared.close() }
        browser.activate(second)
        return NSColorPanel.shared.isVisible
    }
}
