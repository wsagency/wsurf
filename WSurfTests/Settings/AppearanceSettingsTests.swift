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

    @MainActor
    @Test func resettingAppearanceRestoresSidebarLayoutAfterRestart() throws {
        let suiteName = "SidebarReset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let previousAppearance = NSApp.appearance
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            NSApp.appearance = previousAppearance
        }
        let settings = BrowserSettings(defaults: defaults)
        let initial = (
            family: settings.sidebarFontFamily,
            size: settings.sidebarFontSize,
            weight: settings.sidebarFontWeight,
            spacing: settings.sidebarRowSpacing,
            tint: settings.sidebarFolderTint
        )
        settings.sidebarFontFamily = "Menlo"
        settings.sidebarFontSize = 19
        settings.sidebarFontWeight = .bold
        settings.sidebarRowSpacing = 6
        settings.sidebarFolderTint = 0.8

        settings.resetToDefaults()
        let restored = BrowserSettings(defaults: defaults)
        #expect(restored.sidebarFontFamily == initial.family)
        #expect(restored.sidebarFontSize == initial.size)
        #expect(restored.sidebarFontWeight == initial.weight)
        #expect(restored.sidebarRowSpacing == initial.spacing)
        #expect(restored.sidebarFolderTint == initial.tint)
    }

    @Test func themeCustomizationPersistsSeparatelyAndResetsOnlySelectedTheme() throws {
        let suite = "ThemeCustomization-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        settings.setThemeCustomization(ThemeCustomization(
            brightness: 0.2, hue: 0.15, primary: SidebarTextStyle(colorRGB: 0xCC3300),
            controls: SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.4),
            url: SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.7)
        ), theme: .light)
        settings.setThemeCustomization(ThemeCustomization(brightness: -0.1), theme: .dark)
        let restored = BrowserSettings(defaults: defaults)
        #expect(restored.themeCustomization(theme: .light).controls.colorRGB == 0x0033CC)
        #expect(restored.themeCustomization(theme: .light).url.opacity == 0.7)
        #expect(restored.themeCustomization(theme: .light).primary.colorRGB == 0xCC3300)
        restored.appearance = .system
        #expect(restored.themeCustomization(theme: restored.sidebarAppearance(scheme: .light)).brightness == 0.2)
        #expect(restored.themeCustomization(theme: restored.sidebarAppearance(scheme: .dark)).brightness == -0.1)
        restored.resetThemeCustomization(theme: .light)
        #expect(BrowserSettings(defaults: defaults).themeCustomization(theme: .light) == ThemeCustomization())
        #expect(restored.themeCustomization(theme: .dark).brightness == -0.1)
    }

    @Test func paletteDefaultsStayUnchangedAndCustomTintDerivesSurfaces() throws {
        let base = NSColor(srgbRed: 0.2, green: 0.25, blue: 0.3, alpha: 1)
        let unchanged = Theme.customized(base, customization: ThemeCustomization(), isAccent: false)
        #expect(unchanged == base)
        let tint = ThemeCustomization(primary: SidebarTextStyle(colorRGB: 0xFF0000))
        let surface = try #require(Theme.customized(base, customization: tint, isAccent: false).usingColorSpace(.sRGB))
        let accent = try #require(Theme.customized(base, customization: tint, isAccent: true).usingColorSpace(.sRGB))
        #expect(surface.redComponent > surface.greenComponent)
        #expect(abs(surface.brightnessComponent - base.brightnessComponent) < 0.01)
        #expect(accent.redComponent > 0.99 && accent.greenComponent < 0.01)
        let brighter = Theme.customized(base, customization: ThemeCustomization(brightness: 0.2), isAccent: false)
        #expect(brighter.brightnessComponent > base.brightnessComponent)
        let bounded = ThemeCustomization(brightness: .infinity, hue: 9,
            controls: SidebarTextStyle(colorRGB: 0xFFFFFFFF, opacity: -1)).bounded()
        #expect(bounded.brightness == 0 && bounded.hue == 0.5)
        #expect(bounded.controls.colorRGB == nil && bounded.controls.opacity == 0)
    }

    @MainActor
    @Test func editedAddressKeepsCustomColorWhenPastedStylesAreStripped() {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.6)
        let rendered = MentionFieldRendering.attributed(
            text: "example.com", chips: [], fontSize: 13, isDark: false, textColor: color
        )
        #expect(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == color)
        let editor = NSTextView()
        editor.textStorage?.setAttributedString(NSAttributedString(
            string: "example.com", attributes: [.foregroundColor: NSColor.red, .underlineStyle: 1]
        ))
        MentionFieldRendering.stripPastedStyles(in: editor, fontSize: 13, textColor: color)
        #expect(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == color)
    }

    @MainActor
    @Test func changingAddressColorPreservesTheNativeTextSelection() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        window.contentView?.addSubview(field)
        defer { window.makeFirstResponder(nil) }
        let coordinator = MentionField.Coordinator(text: .constant("example.com"))
        coordinator.apply(text: "example.com", chips: [], isDark: false, to: field)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let selected = NSRange(location: 2, length: 5)
        editor.setSelectedRange(selected)
        field.textColor = .systemRed
        coordinator.apply(text: "example.com", chips: [], isDark: false, to: field)
        #expect(editor.selectedRange() == selected)
        #expect(editor.string == "example.com")
    }

    @MainActor
    @Test func explicitChromeColorsWinOverWebsiteTintAndResetRestoresSampling() throws {
        let settings = BrowserSettings.shared
        let savedAppearance = settings.appearance
        let savedThemes = settings.themeCustomizations
        let savedForcedDark = settings.forcesDarkAppearance
        let savedNativeAppearance = NSApp.appearance
        defer {
            settings.themeCustomizations = savedThemes
            settings.appearance = savedAppearance
            settings.forcesDarkAppearance = savedForcedDark
            NSApp.appearance = savedNativeAppearance
        }
        settings.appearance = .light
        settings.forcesDarkAppearance = false
        settings.themeCustomizations = [:]
        let page = NSColor(srgbRed: 0, green: 0.2, blue: 1, alpha: 1)
        let sampled = LoomChrome.sampledColor(page, scheme: .light)
        settings.setThemeCustomization(ThemeCustomization(
            primary: SidebarTextStyle(colorRGB: 0xFF0000),
            controls: SidebarTextStyle(colorRGB: 0x00FF00, opacity: 0.4),
            url: SidebarTextStyle(colorRGB: 0x0000FF, opacity: 0.7)
        ), theme: .light)
        let chrome = try #require(LoomChrome.sampledColor(page, scheme: .light).usingColorSpace(.sRGB))
        #expect(chrome.redComponent > chrome.blueComponent)
        let controls = try #require(Theme.controlOverride.flatMap { NSColor($0).usingColorSpace(.sRGB) })
        let url = try #require(Theme.urlOverride.flatMap { NSColor($0).usingColorSpace(.sRGB) })
        #expect(controls.greenComponent > 0.99 && abs(controls.alphaComponent - 0.4) < 0.01)
        #expect(url.blueComponent > 0.99 && abs(url.alphaComponent - 0.7) < 0.01)
        settings.resetThemeCustomization(theme: .light)
        #expect(Theme.controlOverride == nil && Theme.urlOverride == nil)
        #expect(LoomChrome.sampledColor(page, scheme: .light) == sampled)
    }
}
