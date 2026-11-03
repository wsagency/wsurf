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
        defer { restorePanel() }

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
        defer { restorePanel() }
        browser.activate(second)
        return NSColorPanel.shared.isVisible
    }

    /// Leaves the shared panel as the next test (and the rest of the host) expects it: closed, aimed at nothing, no folder
    /// edit and no opener.
    private func restorePanel() {
        let panel = NSColorPanel.shared
        panel.close()
        FolderColorEdit.release(panel)
        panel.setTarget(nil)
        panel.setAction(nil)
        PageColourChooser.shared.noteOpened(from: nil)
    }

    /// The panel does not retain its target. Closing it dropped the folder edit while the panel still pointed at it, so the
    /// next action it sent (a text field updating the font panel sends one) went to freed memory and crashed the host.
    @Test func aClosedFolderColourPanelSendsNothingToTheEditItHad() throws {
        let browser = BrowserModel(database: .temporary())
        let folder = browser.createFolder(named: "Work")
        let panel = NSColorPanel.shared
        defer { restorePanel() }
        FolderColorEdit.present(for: folder, browser: browser)
        let edit = try #require(FolderColorEdit.current)
        let red = CustomFolderColor(red: 255, green: 0, blue: 0)
        panel.color = red.nsColor
        #expect(folder.customColor == red, "while open the panel colours the folder")

        panel.close()
        #expect(FolderColorEdit.current == nil)
        panel.color = CustomFolderColor(red: 0, green: 0, blue: 255).nsColor
        panel.sendAction()
        #expect(folder.customColor == red, "once closed it no longer aims at the edit")
        withExtendedLifetime(edit) {}
    }
}

private extension NSColorPanel {
    /// What the panel does when its colour changes, or when a text view updating the font panel makes it (the crash went
    /// through this AppKit path). Fails the test, instead of crashing the host, if AppKit drops the method.
    func sendAction() {
        let send = Selector(("_sendActionAndNotification"))
        guard responds(to: send) else {
            Issue.record("NSColorPanel no longer has _sendActionAndNotification")
            return
        }
        perform(send)
    }
}
