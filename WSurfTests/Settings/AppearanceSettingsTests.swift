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
        let suites = (0..<3).map { AppDatabase.defaultsSuite("SharedBrowserSettings-\($0)-\(UUID().uuidString)") }
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
        let suite = AppDatabase.defaultsSuite("SleepAfter-\(UUID().uuidString)")
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

    @Test func sidebarAppearancePersistsAndBoundsMalformedValues() throws {
        let suiteName = AppDatabase.defaultsSuite("AppearanceSettingsTests-\(UUID().uuidString)")
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
    @Test func resettingAppearanceRestoresSidebarLayoutAfterRestart() throws {
        let suiteName = AppDatabase.defaultsSuite("SidebarReset-\(UUID().uuidString)")
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

    /// Material and tint stay discoverable for solid themes too; the Glass-only slider targets Material.
    @Test func searchFindsMaterialBrightnessAndColorsForEveryTheme() throws {
        for id in ["appearance.material", "appearance.brightness", "appearance.colors", "appearance.websiteTint"] {
            let entry = try #require(SettingsIndex.all.first { $0.id == id })
            #expect(entry.targetAnchor == id)
        }
        let transparency = try #require(SettingsIndex.all.first { $0.id == "appearance.transparency" })
        #expect(transparency.targetAnchor == "appearance.material")
        #expect(SettingsIndex.all.allSatisfy { !["appearance.windowStyle", "appearance.themeCustomization",
                                               "appearance.sidebarLoadedColor", "appearance.sidebarUnloadedColor", ].contains($0.id) })
    }

    @MainActor
    @Test func sidebarTextColorsFollowTheVariantAndLoadStateAcrossRestart() throws {
        let suiteName = AppDatabase.defaultsSuite("SidebarTextColors-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func srgb(_ color: Color) throws -> NSColor {
            try #require(NSColor(color).usingColorSpace(.sRGB))
        }
        let settings = BrowserSettings(defaults: defaults)
        settings.editColors(scheme: .light) {
            $0.sidebarText = SidebarTextStyle(colorRGB: 0xCC3300, opacity: 0.8)
            $0.unloadedText = SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.3)
        }
        settings.editColors(scheme: .dark) {
            $0.unloadedText = SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.6)
        }
        let reopened = BrowserSettings(defaults: defaults)

        let loaded = try srgb(reopened.sidebarTextColor(scheme: .light))
        let unloaded = try srgb(reopened.sidebarTextColor(isDeferred: true, scheme: .light))
        #expect(reopened.selectedTheme.light.sidebarText == SidebarTextStyle(colorRGB: 0xCC3300, opacity: 0.8))
        #expect(reopened.selectedTheme.light.unloadedText == SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.3))
        #expect(reopened.selectedTheme.dark.unloadedText == SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.6))

        // §1.4 derives runtime ink only: all three translucent choices fail AA on their window ground.
        func expectReadableFallback(_ ink: NSColor, original: SidebarTextStyle, scheme: ColorScheme) throws {
            let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
            let ground = SidebarRowStyle.srgb(
                Color(nsColor: reopened.resolvedTheme.variant(scheme).window.resolved(in: appearance)), scheme: scheme
            )
            let raw = SidebarRowStyle.srgb(try #require(original.color).opacity(original.opacity), scheme: scheme)
            #expect(SidebarRowStyle.contrast(ThemeReadability.composite(raw, on: ground), ground) < 4.5)
            let channels = [ink.redComponent, ink.greenComponent, ink.blueComponent]
            #expect(ink.alphaComponent == 1 && (channels.allSatisfy { $0 == 0 } || channels.allSatisfy { $0 == 1 }))
            #expect(SidebarRowStyle.contrast(ThemeReadability.composite(ink, on: ground), ground) >= 4.5)
        }
        try expectReadableFallback(loaded, original: reopened.selectedTheme.light.sidebarText, scheme: .light)
        try expectReadableFallback(unloaded, original: reopened.selectedTheme.light.unloadedText, scheme: .light)

        // The dark variant has its own unloaded style and keeps the default loaded text: white.
        let dark = try srgb(reopened.sidebarTextColor(isDeferred: true, scheme: .dark))
        try expectReadableFallback(dark, original: reopened.selectedTheme.dark.unloadedText, scheme: .dark)
        let darkLoaded = try srgb(reopened.sidebarTextColor(scheme: .dark))
        #expect(darkLoaded.redComponent > 0.95 && darkLoaded.greenComponent > 0.95 && darkLoaded.alphaComponent == 1)

        // Another theme has none of it.
        reopened.themeID = "standard"
        let plain = try srgb(reopened.sidebarTextColor(scheme: .light))
        #expect(plain.redComponent < 0.05 && plain.greenComponent < 0.05)

        reopened.themeID = settings.selectedTheme.id
        reopened.editColors(scheme: .dark) {
            $0.unloadedText = SidebarTextStyle(colorRGB: 0xFFFFFFFF, opacity: .infinity)
        }
        let bounded = try srgb(reopened.sidebarTextColor(isDeferred: true, scheme: .dark))
        #expect(bounded.redComponent > 0.95 && bounded.greenComponent > 0.95)
        #expect(bounded.alphaComponent.isFinite && bounded.alphaComponent > 0 && bounded.alphaComponent < 1)
    }

    @Test func themeColorsPersistSeparatelyAndResetOnlyTheShownVariant() throws {
        let suite = AppDatabase.defaultsSuite("ThemeColors-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        settings.editColors(scheme: .light) {
            $0.hue = 0.15
            $0.primary = 0xCC3300
            $0.icons = SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.4)
            $0.url = SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.7)
        }
        settings.editColors(scheme: .dark) { $0.hue = -0.1 }
        var adjustment = settings.themeAdjustment
        adjustment.setBrightness(0.2, for: .light)
        adjustment.setBrightness(-0.1, for: .dark)
        settings.themeAdjustment = adjustment

        let restored = BrowserSettings(defaults: defaults)
        let light = restored.selectedTheme.light
        #expect(light.icons.colorRGB == 0x0033CC && light.url.opacity == 0.7 && light.primary == 0xCC3300)
        #expect(restored.selectedTheme.dark.hue == -0.1)
        #expect(restored.themeAdjustment.brightness(.light) == 0.2)
        #expect(restored.themeAdjustment.brightness(.dark) == -0.1)

        restored.resetColors(scheme: .light)
        let reset = BrowserSettings(defaults: defaults)
        #expect(reset.selectedTheme.light == ThemeCatalog.fallback.light)
        #expect(reset.themeAdjustment.brightness(.light) == 0)
        #expect(reset.selectedTheme.dark.hue == -0.1 && reset.themeAdjustment.brightness(.dark) == -0.1)
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
    @Test func privateAppearanceDoesNotChangeTheApplicationAppearance() throws {
        let appName = AppDatabase.defaultsSuite("AppearanceApp-\(UUID().uuidString)")
        let sessionName = AppDatabase.defaultsSuite("AppearanceSession-\(UUID().uuidString)")
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
