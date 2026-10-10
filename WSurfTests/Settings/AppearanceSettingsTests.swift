// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

struct AppearanceSettingsTests {
    @Test func sidebarAppearancePersistsAndBoundsMalformedValues() throws {
        let suiteName = "AppearanceSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = BrowserSettings(defaults: defaults)
        settings.sidebarFontFamily = "Menlo"
        settings.sidebarFontSize = 18.5
        settings.sidebarFontWeight = .bold
        settings.sidebarRowSpacing = 4.5
        settings.sidebarFolderTint = 0.8

        let restored = BrowserSettings(defaults: defaults)
        #expect(restored.sidebarFontFamily == "Menlo")
        #expect(restored.sidebarFontSize == 18.5)
        #expect(restored.sidebarFontWeight == .bold)
        #expect(restored.sidebarRowSpacing == 4.5)
        #expect(restored.sidebarFolderTint == 0.8)

        defaults.set(Double.nan, forKey: "appearance.sidebar.fontSize")
        defaults.set(Double.infinity, forKey: "appearance.sidebar.rowSpacing")
        defaults.set(-1, forKey: "appearance.sidebar.folderTint")
        let bounded = BrowserSettings(defaults: defaults)
        #expect(bounded.sidebarFontSize.isFinite)
        #expect((10...20).contains(bounded.sidebarFontSize))
        #expect(bounded.sidebarRowSpacing.isFinite)
        #expect((0...8).contains(bounded.sidebarRowSpacing))
        #expect(bounded.sidebarFolderTint == 0)

        bounded.sidebarFontSize = 200
        bounded.sidebarRowSpacing = -20
        bounded.sidebarFolderTint = Double.infinity
        let revised = BrowserSettings(defaults: defaults)
        #expect(revised.sidebarFontSize == 20)
        #expect(revised.sidebarRowSpacing == 0)
        #expect(revised.sidebarFolderTint.isFinite)
        #expect((0...1).contains(revised.sidebarFolderTint))

        bounded.sidebarFontFamily = "Zapfino"
        bounded.sidebarRowSpacing = 0
        let tallFont = try #require(NSFontManager.shared.font(
            withFamily: "Zapfino", traits: [],
            weight: bounded.sidebarFontWeight.appKitWeight,
            size: bounded.sidebarFontSize
        ))
        #expect(SidebarMetrics.rowHeight(settings: bounded) >= tallFont.ascender - tallFont.descender + tallFont.leading)
    }
}
