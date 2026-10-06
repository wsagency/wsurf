// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import SwiftUI
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
        settings.showsDirectRemoveForUnloadedTabs = true
        let restored = BrowserSettings(defaults: defaults)
        #expect(restored.sidebarFontFamily == "Menlo")
        #expect(restored.sidebarFontSize == 18.5)
        #expect(restored.sidebarFontWeight == .bold)
        #expect(restored.sidebarRowSpacing == 4.5)
        #expect(restored.showsDirectRemoveForUnloadedTabs)
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

    @MainActor
    @Test func sidebarTextColorsFollowThemeAndLoadStateAcrossRestart() throws {
        let suiteName = "SidebarTextColors-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let previousAppearance = NSApp.appearance
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            NSApp.appearance = previousAppearance
        }
        let settings = BrowserSettings(defaults: defaults)
        settings.setSidebarTextStyle(
            SidebarTextStyle(opacity: 0.8), theme: .light, isDeferred: false
        )
        settings.setSidebarTextColor(Color(red: 0.8, green: 0.2, blue: 0), theme: .light, isDeferred: false)
        settings.setSidebarTextStyle(
            SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.3), theme: .light, isDeferred: true
        )
        settings.setSidebarTextStyle(
            SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.6), theme: .darkCalm, isDeferred: true
        )
        let reopened = BrowserSettings(defaults: defaults)
        reopened.appearance = .light
        let loaded = try #require(NSColor(reopened.sidebarTextColor(scheme: .light)).usingColorSpace(.sRGB))
        let unloaded = try #require(NSColor(
            reopened.sidebarTextColor(isDeferred: true, scheme: .light)
        ).usingColorSpace(.sRGB))
        #expect(loaded.redComponent > 0.7 && loaded.blueComponent < 0.1)
        #expect(abs(loaded.alphaComponent - 0.8) < 0.01)
        #expect(unloaded.blueComponent > 0.7 && unloaded.redComponent < 0.1)
        #expect(abs(unloaded.alphaComponent - 0.3) < 0.01)

        reopened.appearance = .darkCalm
        let calm = try #require(NSColor(
            reopened.sidebarTextColor(isDeferred: true, scheme: .dark)
        ).usingColorSpace(.sRGB))
        #expect(calm.greenComponent > 0.7 && calm.blueComponent < 0.1)
        #expect(abs(calm.alphaComponent - 0.6) < 0.01)
        let lightSurface = try #require(NSColor(reopened.sidebarTextColor(scheme: .light)).usingColorSpace(.sRGB))
        #expect(lightSurface.redComponent < 0.05 && lightSurface.greenComponent < 0.05)

        reopened.appearance = .system
        let autoDark = try #require(NSColor(reopened.sidebarTextColor(scheme: .dark)).usingColorSpace(.sRGB))
        #expect(autoDark.redComponent > 0.95 && autoDark.greenComponent > 0.95)
        let autoLight = try #require(NSColor(reopened.sidebarTextColor(scheme: .light)).usingColorSpace(.sRGB))
        #expect(autoLight.redComponent > 0.7 && autoLight.blueComponent < 0.1)

        reopened.appearance = .lightCalm
        reopened.forcesDarkAppearance = true
        let privateCalm = try #require(NSColor(
            reopened.sidebarTextColor(isDeferred: true, scheme: .light)
        ).usingColorSpace(.sRGB))
        #expect(privateCalm.greenComponent > 0.7 && privateCalm.blueComponent < 0.1)

        reopened.setSidebarTextStyle(
            SidebarTextStyle(colorRGB: 0xFFFFFFFF, opacity: .infinity), theme: .darkCalm, isDeferred: true
        )
        let bounded = try #require(NSColor(
            reopened.sidebarTextColor(isDeferred: true, scheme: .dark)
        ).usingColorSpace(.sRGB))
        #expect(bounded.redComponent > 0.95 && bounded.greenComponent > 0.95)
        #expect(bounded.alphaComponent.isFinite && bounded.alphaComponent > 0 && bounded.alphaComponent < 1)
    }
}
