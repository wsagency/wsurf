// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import WSurf

struct AppearanceSettingsTests {
    @Test func contextSettingsShareObservableApplicationPreferences() {
        let suites = (0..<3).map { "SharedBrowserSettings-\($0)-\(UUID().uuidString)" }
        let defaults = suites.map { UserDefaults(suiteName: $0)! }
        defer {
            for (suiteName, suiteDefaults) in zip(suites, defaults) {
                suiteDefaults.removePersistentDomain(forName: suiteName)
            }
        }

        let application = BrowserSettings(defaults: defaults[0])
        let first = BrowserSettings(defaults: defaults[0], sessionDefaults: defaults[1], application: application)
        let second = BrowserSettings(defaults: defaults[0], sessionDefaults: defaults[2], application: application)

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = second.pageZoom
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        first.pageZoom = 1.25
        first.sidebarFontSize = 18
        first.javaScriptEnabled = false

        #expect(invalidated.withLock { $0 })
        #expect(second.pageZoom == 1.25)
        #expect(second.sidebarFontSize == 18)
        #expect(!first.javaScriptEnabled)
        #expect(second.javaScriptEnabled)
    }

    @Test func sleepAfterDefaultsToMemoryPressureOnlyAndNotifiesTheOwnerOnChange() {
        let suite = "SleepAfter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let changes = Mutex(0)
        settings.onSleepPolicyChanged = { changes.withLock { $0 += 1 } }

        #expect(!settings.sleepsInactiveTabs)
        #expect(settings.sleepAfterMinutes == 0)

        settings.sleepsInactiveTabs = true
        settings.sleepAfterMinutes = 210
        settings.sleepAfterMinutes = 210
        #expect(changes.withLock { $0 } == 2)

        let restored = BrowserSettings(defaults: defaults)
        #expect(restored.sleepAfterMinutes == 210)
        restored.sleepAfterMinutes = -5
        #expect(restored.sleepAfterMinutes == 0)
        restored.sleepAfterMinutes = .max
        #expect(Duration.seconds(restored.sleepAfterMinutes * 60) > .zero)
    }

    /// A light preset in a window drawn dark (a private window) uses the standard sidebar text, not the saved light
    /// custom colors; the saved styles stay untouched and apply again once the preset is cleared.
    @MainActor
    @Test func presetMismatchFallsBackToStandardSidebarTextWithoutTouchingSavedColors() throws {
        let suite = "PresetFallback-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let savedNativeAppearance = NSApp.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.appearance = savedNativeAppearance
        }
        let settings = BrowserSettings(defaults: defaults)
        settings.appearance = .light
        settings.setSidebarTextStyle(SidebarTextStyle(colorRGB: 0xCC3300, opacity: 0.8), theme: .light, isDeferred: false)
        let saved = settings.sidebarTextStyles

        settings.themePreset = .catppuccinLatte
        let loaded = try #require(NSColor(settings.sidebarTextColor(scheme: .dark)).usingColorSpace(.sRGB))
        let unloaded = try #require(NSColor(settings.sidebarTextColor(isDeferred: true, scheme: .dark)).usingColorSpace(.sRGB))
        #expect(loaded.redComponent > 0.99 && loaded.greenComponent > 0.99 && abs(loaded.alphaComponent - 1) < 0.01)
        #expect(unloaded.redComponent > 0.99 && abs(unloaded.alphaComponent - 0.55) < 0.01)
        #expect(settings.sidebarTextStyles == saved)

        settings.themePreset = nil
        let restored = try #require(NSColor(settings.sidebarTextColor(scheme: .light)).usingColorSpace(.sRGB))
        #expect(restored.redComponent > 0.7 && restored.blueComponent < 0.1)
    }

    /// Search results for rows a preset hides open the preset row instead; other rows keep their own anchor.
    @Test func searchRedirectsHiddenAppearanceRowsToThePresetRowOnlyWhileOneIsOn() throws {
        let hidden = try #require(SettingsIndex.all.first { $0.id == "appearance.websiteTint" })
        let shown = try #require(SettingsIndex.all.first { $0.id == "appearance.sidebarFontSize" })
        #expect(hidden.targetAnchor(presetIsOn: false) == "appearance.websiteTint")
        #expect(hidden.targetAnchor(presetIsOn: true) == "appearance.themePreset")
        #expect(shown.targetAnchor(presetIsOn: true) == "appearance.sidebarFontSize")
    }

    /// A typed custom duration is only accepted as a whole, positive number within the app's `Int32` minute bound.
    @Test func customSleepAmountRejectsWhatItCannotStoreInsteadOfClamping() {
        #expect(SleepAfterRow.minutes(from: " 90 ", factor: 1) == 90)
        #expect(SleepAfterRow.minutes(from: "2", factor: 60) == 120)
        #expect(SleepAfterRow.minutes(from: "35791394", factor: 60) == 35_791_394 * 60)
        #expect(SleepAfterRow.minutes(from: "35791395", factor: 60) == nil)
        for invalid in ["", "0", "-5", "1.5", "abc", "٣", "99999999999999999999"] {
            #expect(SleepAfterRow.minutes(from: invalid, factor: 1) == nil, "\(invalid)")
        }
    }

    @Test func presetPersistsAndLeavesTheSavedThemeAndColorsUntouched() throws {
        let suite = "ThemePreset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previousAppearance = NSApp.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.appearance = previousAppearance
        }
        let settings = BrowserSettings(defaults: defaults)
        #expect(settings.themePreset == nil)
        settings.appearance = .darkCalm
        settings.setThemeCustomization(ThemeCustomization(brightness: 0.2), theme: .darkCalm)
        settings.setSidebarTextStyle(SidebarTextStyle(colorRGB: 0x336699, opacity: 0.8), theme: .darkCalm, isDeferred: false)
        let customizations = settings.themeCustomizations
        let textStyles = settings.sidebarTextStyles

        for preset in ThemePreset.allCases {
            settings.themePreset = preset
            #expect(BrowserSettings(defaults: defaults).themePreset == preset)
            #expect(settings.resolvedAppearance == (preset.isDark ? .dark : .light))
        }
        #expect(settings.appearance == .darkCalm)
        #expect(settings.themeCustomizations == customizations)
        #expect(settings.sidebarTextStyles == textStyles)

        settings.themePreset = nil
        #expect(BrowserSettings(defaults: defaults).themePreset == nil)
        #expect(settings.resolvedAppearance == .darkCalm)
        #expect(BrowserSettings(defaults: defaults).themeCustomization(theme: .darkCalm).brightness == 0.2)

        settings.themePreset = .nord
        settings.resetToDefaults()
        #expect(BrowserSettings(defaults: defaults).themePreset == nil)
    }

    /// A preset replaces the whole chrome palette, so every text and accent
    /// color it ships has to stay legible on the surfaces it is drawn on.
    @Test func everyPresetKeepsItsTextAndAccentLegible() {
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let value = Double((rgb >> shift) & 255) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        func contrast(_ first: Double, _ second: Double) -> Double {
            (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }
        for preset in ThemePreset.allCases {
            let text = luminance(preset.rgb(.text))
            for role in [ThemePreset.Role.window, .sidebar, .surface] {
                #expect(contrast(text, luminance(preset.rgb(role))) >= 4.5, "\(preset) text on \(role)")
            }
            for role in [ThemePreset.Role.window, .sidebar] {
                #expect(contrast(luminance(preset.rgb(.accent)), luminance(preset.rgb(role))) >= 3, "\(preset) accent on \(role)")
            }
            // The unloaded sidebar text is the preset's text at reduced opacity over the sidebar.
            let alpha = preset.unloadedTextOpacity
            let blended = [16, 8, 0].reduce(UInt32(0)) { result, shift in
                let ink = Double((preset.rgb(.text) >> shift) & 255)
                let ground = Double((preset.rgb(.sidebar) >> shift) & 255)
                return result | UInt32((alpha * ink + (1 - alpha) * ground).rounded()) << shift
            }
            #expect(
                contrast(luminance(blended), luminance(preset.rgb(.sidebar))) >= 4.5,
                "\(preset) unloaded text"
            )
        }
    }

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
            text: "example.com", chips: [], fontSize: 13, isDark: false, textColor: color, favicons: FaviconLoader()
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
        let settings = BrowserSettings.application
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

    /// While a preset is on its colors are what the chrome draws, whatever the
    /// website tint or the saved custom colors say; clearing it brings the
    /// custom colors back, and a private window forced dark never shows a light preset.
    @MainActor
    @Test func presetColorsDriveTheChromeAndClearingItRestoresCustomColors() throws {
        let settings = BrowserSettings.application
        let savedPreset = settings.themePreset
        let savedAppearance = settings.appearance
        let savedThemes = settings.themeCustomizations
        let savedForcedDark = settings.forcesDarkAppearance
        let savedNativeAppearance = NSApp.appearance
        defer {
            settings.themePreset = savedPreset
            settings.themeCustomizations = savedThemes
            settings.appearance = savedAppearance
            settings.forcesDarkAppearance = savedForcedDark
            NSApp.appearance = savedNativeAppearance
        }
        func hex(_ color: NSColor?) throws -> UInt32 {
            let rgb = try #require(color?.usingColorSpace(.sRGB))
            func channel(_ value: CGFloat) -> UInt32 {
                UInt32((value * 255).rounded())
            }
            return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
        }
        settings.forcesDarkAppearance = false
        settings.appearance = .light
        settings.themePreset = nil
        settings.themeCustomizations = [:]
        settings.setThemeCustomization(
            ThemeCustomization(controls: SidebarTextStyle(colorRGB: 0x00FF00)), theme: .light
        )
        let page = NSColor(srgbRed: 0, green: 0.2, blue: 1, alpha: 1)
        let tinted = try hex(LoomChrome.sampledColor(page, scheme: .light))
        #expect(try hex(Theme.controlOverride.map { NSColor($0) }) == 0x00FF00)

        let preset = ThemePreset.catppuccinLatte
        settings.themePreset = preset
        #expect(try hex(LoomChrome.sampledColor(page, scheme: .light)) == preset.rgb(.window))
        #expect(try hex(LoomChrome.sampledColor(page, scheme: .light, isFloating: true)) == preset.rgb(.sidebar))
        #expect(try hex(Theme.controlOverride.map { NSColor($0) }) == preset.rgb(.text))
        #expect(try hex(Theme.urlOverride.map { NSColor($0) }) == preset.rgb(.text))
        let loaded = settings.sidebarTextColor(scheme: .light)
        let unloaded = settings.sidebarTextColor(isDeferred: true, scheme: .light)
        #expect(try hex(NSColor(loaded)) == preset.rgb(.text))
        #expect(try hex(NSColor(unloaded)) == preset.rgb(.text))
        let unloadedAlpha = try #require(NSColor(unloaded).usingColorSpace(.sRGB)).alphaComponent
        #expect(abs(unloadedAlpha - preset.unloadedTextOpacity) < 0.01)

        // The window is drawn dark under a light application appearance (a drawing-context check, not a real
        // window): the ink follows the drawing appearance, so the light preset's text never lands on dark.
        NSApp.appearance = NSAppearance(named: .aqua)
        func ink(_ color: Color?, in name: NSAppearance.Name) throws -> UInt32 {
            var resolved: NSColor?
            try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                resolved = NSColor(color ?? .clear).usingColorSpace(.sRGB)
            }
            return try hex(resolved)
        }
        #expect(try ink(Theme.controlOverride, in: .aqua) == preset.rgb(.text))
        #expect(try ink(Theme.controlOverride, in: .darkAqua) != preset.rgb(.text))
        #expect(try ink(Theme.urlOverride, in: .darkAqua) != preset.rgb(.text))
        #expect(try hex(LoomChrome.sampledColor(page, scheme: .dark)) != preset.rgb(.window))
        // The preset's solid backdrop applies only in the appearance it was designed for.
        #expect(LoomChrome.showsPresetExactly(in: .light))
        #expect(!LoomChrome.showsPresetExactly(in: .dark))

        settings.themePreset = nil
        #expect(try hex(LoomChrome.sampledColor(page, scheme: .light)) == tinted)
        #expect(try hex(Theme.controlOverride.map { NSColor($0) }) == 0x00FF00)
    }

    @MainActor
    @Test func privateAppearanceDoesNotChangeTheApplicationAppearance() throws {
        let appName = "AppearanceApp-\(UUID().uuidString)"
        let sessionName = "AppearanceSession-\(UUID().uuidString)"
        let appDefaults = try #require(UserDefaults(suiteName: appName))
        let sessionDefaults = try #require(UserDefaults(suiteName: sessionName))
        defer {
            appDefaults.removePersistentDomain(forName: appName)
            sessionDefaults.removePersistentDomain(forName: sessionName)
        }
        let settings = BrowserSettings(
            defaults: appDefaults,
            sessionDefaults: sessionDefaults,
            appliesAppearanceGlobally: false
        )
        let originalAppearance = NSApp.appearance?.name
        settings.forcesDarkAppearance = true
        #expect(NSApp.appearance?.name == originalAppearance)
    }
}
