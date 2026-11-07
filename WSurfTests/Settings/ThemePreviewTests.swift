// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import WSurf

@MainActor
struct ThemePreviewTests {
    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("ThemePreviewTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
        settings.previewsEveryStep()
        try test(settings, defaults)
    }

    private func withSettingsAsync(_ test: (BrowserSettings, UserDefaults) async throws -> Void) async throws {
        let name = AppDatabase.defaultsSuite("ThemePreviewTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false), defaults)
    }

    @Test func materialAndBrightnessPersistPerThemeAndVariant() throws {
        try withSettings { settings, defaults in
            settings.themeMaterial = .glass
            settings.transparency = 0.8
            var adjustment = settings.themeAdjustment
            adjustment.setBrightness(-0.2, for: .light)
            adjustment.setBrightness(0.3, for: .dark)
            settings.themeAdjustment = adjustment
            settings.themeID = "nord"
            #expect(settings.themeAdjustment == ThemeAdjustment())
            settings.themeAdjustment = ThemeAdjustment(lightBrightness: 0.1)
            let reopened = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(reopened.themeAdjustment.lightBrightness == 0.1)
            reopened.themeID = "wsurf"
            #expect(reopened.themeAdjustment == adjustment)
            #expect(reopened.userThemes.isEmpty)
        }
    }

    @Test func draggingBrightnessAndOpacityWritesOnlyOnCommit() throws {
        try withSettings { settings, defaults in
            let before = defaults.data(forKey: "appearance.themes.adjustments")
            // A step every interval, so the window applies each one; the throttle has its own tests below.
            var now = ContinuousClock.now
            settings.themeApplyClock = { now }
            settings.beginThemePreview()
            for step in 1...30 {
                now = now.advanced(by: BrowserSettings.themePreviewInterval)
                settings.previewThemeAdjustment(ThemeAdjustment(
                    material: .glass, glassOpacity: Double(step) / 30, darkBrightness: Double(step) / 100
                ))
                #expect(defaults.data(forKey: "appearance.themes.adjustments") == before)
                #expect(settings.resolvedTheme.adjustment == settings.themeAdjustment)
            }
            settings.commitThemePreview()
            let reopened = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(reopened.themeMaterial == .glass && reopened.transparency == 1)
            #expect(reopened.themeAdjustment.darkBrightness == 0.3)
            #expect(settings.themePreview == nil && reopened.userThemes.isEmpty)
        }
    }

    /// A drag of N steps over T seconds applies to the window at most ceil(10 T) + 1 times; the gallery card
    /// (`previewedTheme`) follows every step, and the last value lands on release.
    @Test func draggingAppliesToTheWindowAtMostTenTimesASecond() throws {
        try withSettings { settings, _ in
            var now = ContinuousClock.now
            settings.themeApplyClock = { now }
            let applies = ChangeCounter { _ = settings.themeRevision }
            let steps = 60
            let seconds = 3.0
            settings.beginThemePreview()
            for step in 1...steps {
                now = now.advanced(by: .seconds(seconds / Double(steps)))
                settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: Double(step) / 200))
                #expect(settings.previewedTheme == settings.selectedTheme)
                #expect(settings.themeAdjustment.darkBrightness == Double(step) / 200)
            }
            #expect(applies.count > 1)
            #expect(applies.count <= Int((seconds * 10).rounded(.up)) + 1)
            settings.pendingThemeApply?.cancel()
            settings.commitThemePreview()
            #expect(settings.resolvedTheme.adjustment.darkBrightness == 0.3)
            #expect(settings.themeAdjustment.darkBrightness == 0.3)
        }
    }

    /// What the window backdrop reads with Glass on (`windowBackdrop`, which `LoomChrome` draws from)
    /// changes at most ceil(10 T) + 1 times in a drag of the opacity slider. The live read (`transparency`, which
    /// `LoomChrome` used to read) changes on every step, which shows that the counter can see the difference.
    @Test func draggingGlassOpacityReachesTheWindowBackdropAtMostTenTimesASecond() throws {
        try withSettings { settings, _ in
            settings.themeMaterial = .glass
            var now = ContinuousClock.now
            settings.themeApplyClock = { now }
            let backdrop = ChangeCounter { _ = settings.windowBackdrop }
            let live = ChangeCounter { _ = settings.transparency }
            let steps = 60
            let seconds = 3.0
            settings.beginThemePreview()
            for step in 1...steps {
                now = now.advanced(by: .seconds(seconds / Double(steps)))
                var adjustment = settings.themeAdjustment
                adjustment.glassOpacity = 0.3 + Double(step) / 100
                settings.previewThemeAdjustment(adjustment)
                #expect(settings.transparency == adjustment.glassOpacity)
            }
            #expect(live.count >= steps)
            #expect(backdrop.count > 1)
            #expect(backdrop.count <= Int((seconds * 10).rounded(.up)) + 1)
            settings.pendingThemeApply?.cancel()
            settings.commitThemePreview()
            #expect(abs(settings.resolvedTheme.adjustment.glassOpacity - 0.9) < 0.0001)
        }
    }

    /// The readability note under an ink control compares the chosen ink with the drawn ink. Both follow the live
    /// preview: the drawn one is not the window's throttled copy, so the note does not flicker during a drag.
    @Test func theReadabilityNoteReadsTheLivePreviewNotTheThrottledWindow() throws {
        try withSettings { settings, _ in
            var now = ContinuousClock.now
            settings.themeApplyClock = { now }
            settings.beginThemePreview()
            for step in 1...30 {
                now = now.advanced(by: .milliseconds(10))
                settings.previewThemeColors(scheme: .dark) { $0.sidebarText = SidebarTextStyle(colorRGB: UInt32(step) * 0x080808) }
                let live = settings.liveResolvedVariant(.dark)
                let expected = ResolvedTheme(settings.previewedTheme, adjustment: settings.themeAdjustment).dark
                #expect(live.loadedInk == expected.loadedInk && live.unloadedInk == expected.unloadedInk, "step \(step)")
            }
            #expect(settings.resolvedTheme.dark.loadedInk != settings.liveResolvedVariant(.dark).loadedInk,
                    "the window lags inside the interval; the note does not")
            settings.commitThemePreview()
            #expect(settings.resolvedTheme.dark.loadedInk == settings.liveResolvedVariant(.dark).loadedInk, "at rest they agree")
        }
    }

    /// A refresh that finds the theme's inputs unchanged does not redraw the theme's readers in every window.
    @Test func aRefreshThatChangesNothingDoesNotBumpTheRevision() throws {
        try withSettings { settings, _ in
            settings.refreshTheme()
            let revisions = ChangeCounter { _ = settings.themeRevision }
            settings.refreshTheme()
            settings.refreshTheme()
            #expect(revisions.count == 0)
            settings.themeAdjustment = ThemeAdjustment(darkBrightness: 0.2)
            #expect(revisions.count == 1)
            settings.refreshTheme()
            #expect(revisions.count == 1)
            settings.themeID = "nord"
            #expect(revisions.count == 2)
            #expect(settings.resolvedTheme.id == "nord")
        }
    }

    @Test func theLastStepOfADragReachesTheWindowWithoutRelease() async throws {
        try await withSettingsAsync { settings, _ in
            settings.beginThemePreview()
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.1))
            #expect(settings.resolvedTheme.adjustment.darkBrightness == 0.1)
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.2))
            #expect(settings.resolvedTheme.adjustment.darkBrightness == 0.1, "within the interval the window keeps the last applied value")
            let pending = try #require(settings.pendingThemeApply)
            await pending.value
            #expect(settings.resolvedTheme.adjustment.darkBrightness == 0.2)
            settings.cancelThemePreview()
            #expect(settings.resolvedTheme.adjustment == ThemeAdjustment())
        }
    }

    @Test func releasingADragAppliesAtOnceAndDropsThePendingStep() throws {
        try withSettings { settings, _ in
            let now = ContinuousClock.now
            settings.themeApplyClock = { now }
            settings.beginThemePreview()
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.1))
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.2))
            #expect(settings.pendingThemeApply != nil)
            settings.commitThemePreview()
            #expect(settings.pendingThemeApply == nil)
            #expect(settings.resolvedTheme.adjustment.darkBrightness == 0.2)
        }
    }

    @Test func draggingColorsMakesOneCopyOnlyOnCommit() throws {
        try withSettings { settings, defaults in
            let before = defaults.data(forKey: "appearance.themes.user")
            let original = settings.selectedTheme
            settings.themeAdjustment = ThemeAdjustment(material: .glass, darkBrightness: -0.1)
            settings.beginThemePreview()
            for step in 1...30 {
                settings.previewThemeColors(scheme: .dark) { $0.hue = Double(step) / 100 }
                #expect(settings.userThemes.isEmpty && settings.selectedTheme == original)
                #expect(defaults.data(forKey: "appearance.themes.user") == before)
                #expect(settings.previewedTheme.dark.hue == Double(step) / 100)
            }
            settings.commitThemePreview()
            #expect(settings.userThemes.count == 1 && settings.selectedTheme.basedOn == original.id)
            #expect(settings.selectedTheme.dark.hue == 0.3 && settings.selectedTheme.light == original.light)
            #expect(settings.themeMaterial == .glass && settings.themeAdjustment.darkBrightness == -0.1)
            let reopened = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(reopened.selectedTheme == settings.selectedTheme && reopened.themeAdjustment == settings.themeAdjustment)
        }
    }

    @Test(arguments: ["standard", "calm"], [ColorScheme.light, .dark])
    func tintedGalleryAccentsFollowPreviewAndSavedCopies(_ id: String, _ scheme: ColorScheme) throws {
        try withSettings { settings, defaults in
            settings.themeID = id
            var adjustment = ThemeAdjustment()
            adjustment.setBrightness(0.15, for: scheme)
            settings.themeAdjustment = adjustment
            let original = settings.selectedTheme
            let originalThumbnail = ThemeThumbnailPalette(original, adjustment: adjustment, scheme: scheme)
            let before = defaults.data(forKey: "appearance.themes.user")
            settings.beginThemePreview()
            settings.previewThemeColors(scheme: scheme) { $0.accent = 0xE01C32 }
            let preview = ThemeThumbnailPalette(settings.previewedTheme, adjustment: settings.themeAdjustment, scheme: scheme)
            #expect(preview.accent != originalThumbnail.accent)
            #expect(SidebarRowStyle.srgb(preview.accent, scheme: scheme)
                == settings.resolvedTheme.variant(scheme).accent.srgb(scheme: scheme))
            #expect(settings.userThemes.isEmpty && settings.selectedTheme == original)
            #expect(defaults.data(forKey: "appearance.themes.user") == before)
            settings.cancelThemePreview()
            #expect(ThemeThumbnailPalette(settings.previewedTheme, adjustment: settings.themeAdjustment, scheme: scheme)
                == originalThumbnail)

            settings.beginThemePreview()
            settings.previewThemeColors(scheme: scheme) { $0.accent = 0xE01C32 }
            settings.commitThemePreview()
            let saved = settings.selectedTheme
            #expect(settings.userThemes.count == 1 && saved.basedOn == id && saved.id != id)
            #expect(saved.variant(scheme).accent == 0xE01C32)
            let otherScheme: ColorScheme = scheme == .dark ? .light : .dark
            #expect(saved.variant(otherScheme) == original.variant(otherScheme))
            #expect(ThemeThumbnailPalette(saved, adjustment: adjustment, scheme: otherScheme).accent
                == ThemeThumbnailPalette(original, adjustment: adjustment, scheme: otherScheme).accent)
            #expect(settings.themeAdjustment == adjustment)
            let reopened = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(reopened.selectedTheme == saved)
            #expect(ThemeThumbnailPalette(saved, adjustment: reopened.themeAdjustment, scheme: scheme).accent == preview.accent)

            reopened.editColors(scheme: scheme) { $0.accent = 0x214CE0 }
            let edited = reopened.selectedTheme
            #expect(reopened.userThemes.count == 1 && edited.id == saved.id && edited.basedOn == id)
            let editedThumbnail = ThemeThumbnailPalette(edited, adjustment: reopened.themeAdjustment, scheme: scheme)
            #expect(editedThumbnail.accent != preview.accent)
            #expect(SidebarRowStyle.srgb(editedThumbnail.accent, scheme: scheme)
                == reopened.resolvedTheme.variant(scheme).accent.srgb(scheme: scheme))
            let reread = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(reread.selectedTheme == edited && reread.themeAdjustment == adjustment)
            #expect(ThemeThumbnailPalette(reread.selectedTheme, adjustment: reread.themeAdjustment, scheme: scheme)
                == editedThumbnail)
        }
    }

    @Test func cancelingOrSwitchingThemesNeverSavesThePreview() throws {
        try withSettings { settings, defaults in
            settings.beginThemePreview()
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.2))
            settings.cancelThemePreview()
            #expect(settings.themeAdjustment == ThemeAdjustment())
            settings.beginThemePreview()
            settings.previewThemeColors(scheme: .light) { $0.hue = 0.2 }
            settings.themeID = "nord"
            settings.commitThemePreview()
            #expect(settings.themePreview == nil && settings.userThemes.isEmpty)
            let reopened = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            reopened.themeID = "wsurf"
            #expect(reopened.themeAdjustment == ThemeAdjustment())
        }
    }

    @Test func anUnchangedDragDoesNotMakeACopy() throws {
        try withSettings { settings, _ in
            settings.beginThemePreview()
            settings.previewThemeColors(scheme: .dark) { $0.hue = 0 }
            settings.commitThemePreview()
            #expect(settings.selectedTheme.id == "wsurf" && settings.userThemes.isEmpty)
        }
    }

    @Test func restingRowsObserveOnlyChangesToTheirInk() throws {
        try withSettings { settings, _ in
            let invalidated = Mutex(false)
            withObservationTracking {
                _ = settings.sidebarTextColor(scheme: .dark)
            } onChange: {
                invalidated.withLock { $0 = true }
            }
            settings.beginThemePreview()
            settings.previewThemeAdjustment(ThemeAdjustment(material: .glass, glassOpacity: 0.2))
            #expect(!invalidated.withLock { $0 })
            settings.previewThemeColors(scheme: .dark) { $0.sidebarText.colorRGB = 0xFFFFFF }
            #expect(invalidated.withLock { $0 })
            settings.cancelThemePreview()
        }
    }

    @Test func assigningUnchangedKnobsClearsPreviewedColorsFromTheCache() throws {
        try withSettings { settings, _ in
            let originalInk = settings.sidebarTextColor(scheme: .dark)
            settings.previewThemeColors(scheme: .dark) { $0.sidebarText = SidebarTextStyle(colorRGB: 0) }
            let preview = settings.resolvedTheme
            #expect(settings.sidebarTextColor(scheme: .dark) != originalInk)

            settings.themeAdjustment = ThemeAdjustment()

            #expect(settings.themePreview == nil)
            #expect(settings.resolvedTheme !== preview)
            #expect(settings.sidebarTextColor(scheme: .dark) == originalInk)
            #expect(settings.userThemes.isEmpty)
        }
    }

    @Test func sidebarInkSelectsTheActualDockedOrFloatingGround() throws {
        try withSettings { settings, _ in
            let colors = ThemeVariant(window: 0x808080, sidebar: 0x707070, text: 0)
            let theme = ThemeDefinition(id: "grounds", name: "Grounds", ground: .solid, light: colors, dark: colors)
            settings.userThemes = [theme]
            settings.themeID = theme.id
            let resolved = settings.resolvedTheme
            for scheme in [ColorScheme.light, .dark] {
                for isDeferred in [false, true] {
                    let docked = settings.sidebarTextColor(isDeferred: isDeferred, scheme: scheme)
                    let floating = settings.sidebarTextColor(isDeferred: isDeferred, scheme: scheme, isFloating: true)
                    #expect(docked != floating)
                    #expect(SidebarRowStyle.srgb(docked, scheme: scheme).redComponent == 0)
                    // Black reads on the window (5.3:1) but not on the darker sidebar (4.2:1), so the floating ink
                    // turns toward white by the least that reads there, and keeps the opacity it needs.
                    let ink = SidebarRowStyle.srgb(floating, scheme: scheme)
                    let sidebar = NSColor(srgbRed: 0x70 / 255, green: 0x70 / 255, blue: 0x70 / 255, alpha: 1)
                    #expect(ink.redComponent > 0.5)
                    #expect(SidebarRowStyle.contrast(ThemeReadability.composite(ink, on: sidebar), sidebar) >= 4.5)
                }
            }
            #expect(settings.resolvedTheme === resolved)
            #expect(settings.selectedTheme == theme)
        }
    }

    @Test func profilesShareThePreviewAndSeparatelyObservedInk() throws {
        try withSettings { root, defaults in
            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: root)
            profile.beginThemePreview()
            profile.previewThemeAdjustment(ThemeAdjustment(darkBrightness: -0.2))
            #expect(profile.themeAdjustment == root.themeAdjustment)
            #expect(profile.resolvedTheme === root.resolvedTheme)
            #expect(profile.sidebarTextColor(scheme: .dark) == root.sidebarTextColor(scheme: .dark))
            profile.commitThemePreview()
            #expect(root.themePreview == nil && root.themeAdjustment.darkBrightness == -0.2)
        }
    }

    @Test func cachedProfileThemeObservesEachRootDependency() throws {
        try withSettings { root, defaults in
            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: root)
            let saved = ThemeDefinition(
                id: "observed-theme", name: "Observed theme", ground: .solid,
                light: ThemeVariant(accent: 0x003366), dark: ThemeVariant(accent: 0x99CCFF)
            )
            root.userThemes = [saved]
            @MainActor func expectInvalidation(_ change: @MainActor () -> Void) {
                let before = root.resolvedTheme
                #expect(profile.resolvedTheme === before)
                let invalidated = Mutex(false)
                withObservationTracking {
                    _ = profile.resolvedTheme
                } onChange: {
                    invalidated.withLock { $0 = true }
                }
                change()
                #expect(invalidated.withLock { $0 })
                let after = profile.resolvedTheme
                #expect(after !== before)
                #expect(after === root.resolvedTheme && profile.resolvedTheme === after)
                #expect(after.adjustment == root.themeAdjustment)
                #expect(profile.themeAdjustment == root.themeAdjustment)
                #expect(profile.previewedTheme == root.previewedTheme)
            }

            expectInvalidation { root.themeID = saved.id }
            #expect(profile.resolvedTheme.id == saved.id)
            expectInvalidation { root.editColors(scheme: .dark) { $0.accent = 0xAA5500 } }
            #expect(profile.selectedTheme.dark.accent == 0xAA5500)
            #expect(profile.resolvedTheme.dark.accent.base == Color(hex: 0xAA5500))
            let adjustment = ThemeAdjustment(darkBrightness: -0.1)
            expectInvalidation { root.themeAdjustments[saved.id] = adjustment }
            #expect(profile.resolvedTheme.adjustment == adjustment)

            // The window applies a preview at most every interval; each step here comes a second after the last.
            var now = ContinuousClock.now
            root.themeApplyClock = { now }
            root.beginThemePreview()
            let persisted = root.themeAdjustments
            let preview = ThemeAdjustment(material: .glass, darkBrightness: 0.2)
            now = now.advanced(by: .seconds(1))
            expectInvalidation { root.previewThemeAdjustment(preview) }
            #expect(profile.resolvedTheme.adjustment == preview)
            #expect(root.themeAdjustments == persisted)
            now = now.advanced(by: .seconds(1))
            expectInvalidation { root.previewThemeColors(scheme: .dark) { $0.accent = 0x226688 } }
            #expect(profile.previewedTheme.dark.accent == 0x226688)
            #expect(profile.resolvedTheme.dark.accent.base == Color(hex: 0x226688))
            #expect(root.selectedTheme.dark.accent == 0xAA5500)
            expectInvalidation { root.cancelThemePreview() }
            #expect(root.themePreview == nil)
            #expect(profile.resolvedTheme.adjustment == adjustment)
            #expect(profile.resolvedTheme.dark.accent.base == Color(hex: 0xAA5500))
            #expect(root.themeAdjustments == persisted && root.userThemes.count == 1)
        }
    }

    @Test func missingThemeUsesTheFallbacksAdjustmentAndOnlyItsPreview() throws {
        try withSettings { root, defaults in
            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: root)
            let fallback = ThemeCatalog.fallback
            let missingID = "missing-theme"
            let savedAdjustment = ThemeAdjustment(material: .glass, lightBrightness: 0.1, darkBrightness: -0.2)
            let missingAdjustment = ThemeAdjustment(lightBrightness: -0.4, darkBrightness: 0.4)
            let adjustments = [fallback.id: savedAdjustment, missingID: missingAdjustment]
            root.themeAdjustments = adjustments
            root.themeID = missingID
            @MainActor func expectResolved(_ definition: ThemeDefinition, adjustment: ThemeAdjustment) {
                #expect(root.themeID == missingID && profile.themeID == missingID)
                #expect(root.selectedTheme == fallback && profile.selectedTheme == fallback)
                #expect(root.previewedTheme == definition && profile.previewedTheme == definition)
                #expect(root.themeAdjustment == adjustment && profile.themeAdjustment == adjustment)
                let actual = root.resolvedTheme
                #expect(actual.id == fallback.id && actual.adjustment == adjustment)
                #expect(profile.resolvedTheme === actual && root.resolvedTheme === actual)
                let expected = ResolvedTheme(definition, adjustment: adjustment)
                for scheme in [ColorScheme.light, .dark] {
                    let variant = actual.variant(scheme)
                    let reference = expected.variant(scheme)
                    #expect(variant.window.srgb(scheme: scheme) == reference.window.srgb(scheme: scheme))
                    #expect(variant.accent.srgb(scheme: scheme) == reference.accent.srgb(scheme: scheme))
                }
            }

            expectResolved(fallback, adjustment: savedAdjustment)
            let original = root.resolvedTheme
            let previewAdjustment = ThemeAdjustment(lightBrightness: 0.3, darkBrightness: -0.1)
            profile.previewThemeAdjustment(previewAdjustment)
            profile.previewThemeColors(scheme: .dark) { $0.accent = 0x226688 }
            var previewed = fallback
            previewed.dark.accent = 0x226688
            #expect(root.themePreview?.themeID == fallback.id)
            #expect(root.resolvedTheme !== original)
            expectResolved(previewed, adjustment: previewAdjustment)

            let matchingPreview = root.resolvedTheme
            root.themePreview = ThemePreview(
                themeID: missingID, adjustment: missingAdjustment,
                colors: ThemeVariant(accent: 0xAA5500), scheme: .dark
            )
            root.refreshTheme()
            #expect(root.resolvedTheme !== matchingPreview)
            expectResolved(fallback, adjustment: savedAdjustment)
            #expect(root.themeAdjustments == adjustments && root.userThemes.isEmpty)
        }
    }

    @Test func resetCancelsTheDefaultThemesPreviewAndKeepsSavedColors() throws {
        try withSettings { settings, _ in
            settings.editColors(scheme: .light) { $0.accent = 0x112233 }
            let saved = settings.userThemes
            settings.themeID = "wsurf"
            settings.beginThemePreview()
            settings.previewThemeAdjustment(ThemeAdjustment(darkBrightness: 0.2))
            settings.resetToDefaults()
            #expect(settings.themePreview == nil && settings.themeAdjustment == ThemeAdjustment())
            #expect(settings.userThemes == saved)
        }
    }

    @Test func colorsResetRestoresTheBuiltInColors() throws {
        try withSettings { settings, _ in
            let original = settings.selectedTheme
            settings.editColors(scheme: .dark) {
                $0.accent = 0x112233
                $0.sidebarText.opacity = 0.2
            }
            settings.themeAdjustment = ThemeAdjustment(material: .glass, lightBrightness: 0.1, darkBrightness: 0.3)
            settings.resetColors(scheme: .dark)
            #expect(settings.selectedTheme.dark == original.dark && settings.selectedTheme.light == original.light)
            #expect(settings.themeAdjustment == ThemeAdjustment(material: .glass, lightBrightness: 0.1))
        }
    }
}
