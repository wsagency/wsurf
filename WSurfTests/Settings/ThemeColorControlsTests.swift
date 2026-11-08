// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// Each control of Settings > Appearance > Colors changes what a real consumer of the resolved theme draws, in both
/// appearances. A color or opacity that is too faint to read keeps its hue and moves only as far as 4.5:1 needs.
@MainActor
struct ThemeColorControlsTests {
    private func withSettings(_ test: @MainActor (BrowserSettings) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("ThemeColorControlsTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
        settings.previewsEveryStep()
        try test(settings)
    }

    private func rgb(_ color: Color, _ scheme: ColorScheme) -> NSColor {
        SidebarRowStyle.srgb(color, scheme: scheme)
    }

    private func contrast(of ink: NSColor, in settings: BrowserSettings, _ scheme: ColorScheme) -> CGFloat {
        let ground = settings.resolvedTheme.variant(scheme).window.srgb(scheme: scheme)
        return SidebarRowStyle.contrast(ThemeReadability.composite(ink, on: ground), ground)
    }

    private func edited(
        _ settings: BrowserSettings, _ scheme: ColorScheme, _ change: (inout ThemeVariant) -> Void
    ) {
        settings.editColors(scheme: scheme, change)
    }

    private let schemes = [ColorScheme.light, .dark]

    /// Two colors that differ by no more than rounding.
    private func same(_ first: NSColor, _ second: NSColor) -> Bool {
        abs(first.redComponent - second.redComponent) < 0.004 && abs(first.greenComponent - second.greenComponent) < 0.004
            && abs(first.blueComponent - second.blueComponent) < 0.004 && abs(first.alphaComponent - second.alphaComponent) < 0.004
    }

    // MARK: - Tab text and unloaded tab text

    /// A color that cannot be read on the window turns toward black or white, not into black or white.
    @Test(arguments: [false, true])
    func aChosenTextColorKeepsItsHueWhileItReads(unloaded: Bool) throws {
        for scheme in schemes {
            try withSettings { settings in
                // Red on a light window and blue on a dark one are both under 4.5:1.
                let hex: UInt32 = scheme == .light ? 0xFF0000 : 0x2040FF
                edited(settings, scheme) {
                    if unloaded {
                        $0.unloadedText = SidebarTextStyle(colorRGB: hex, opacity: 1)
                    } else {
                        $0.sidebarText = SidebarTextStyle(colorRGB: hex, opacity: 1)
                    }
                }
                let ink = rgb(settings.sidebarTextColor(isDeferred: unloaded, scheme: scheme), scheme)
                let chosen = rgb(Color(hex: hex), scheme)
                let dominant = scheme == .light ? ink.redComponent - ink.greenComponent : ink.blueComponent - ink.redComponent
                #expect(contrast(of: ink, in: settings, scheme) >= 4.5, "\(scheme), unloaded \(unloaded)")
                #expect(dominant > 0.25, "\(scheme), unloaded \(unloaded): \(ink) keeps the hue of \(chosen)")
            }
        }
    }

    @Test(arguments: [false, true])
    func aChosenTextColorThatReadsIsDrawnExactly(unloaded: Bool) throws {
        for scheme in schemes {
            try withSettings { settings in
                let hex: UInt32 = scheme == .light ? 0x1A237E : 0xFFD54F
                edited(settings, scheme) {
                    if unloaded {
                        $0.unloadedText = SidebarTextStyle(colorRGB: hex, opacity: 1)
                    } else {
                        $0.sidebarText = SidebarTextStyle(colorRGB: hex, opacity: 1)
                    }
                }
                let ink = rgb(settings.sidebarTextColor(isDeferred: unloaded, scheme: scheme), scheme)
                let chosen = rgb(Color(hex: hex), scheme)
                #expect(same(ink, chosen), "\(scheme), unloaded \(unloaded): \(ink) is not \(chosen)")
            }
        }
    }

    /// The slider is felt from the top down to the floor, and the floor is the least that reads.
    @Test(arguments: [false, true])
    func theOpacityMovesTheTextDownToTheLeastThatReads(unloaded: Bool) throws {
        for scheme in schemes {
            try withSettings { settings in
                @MainActor func drawn(_ opacity: Double) -> NSColor {
                    edited(settings, scheme) {
                        if unloaded {
                            $0.unloadedText.opacity = opacity
                        } else {
                            $0.sidebarText.opacity = opacity
                        }
                    }
                    return rgb(settings.sidebarTextColor(isDeferred: unloaded, scheme: scheme), scheme)
                }
                let high = drawn(1)
                let fairly = drawn(0.9)
                #expect(fairly.alphaComponent == 0.9 && high.alphaComponent == 1, "\(scheme): above the floor it is as chosen")

                let faint = drawn(0.1)
                #expect(faint.alphaComponent > 0.1 && faint.alphaComponent < 1, "\(scheme): raised, not made solid")
                #expect(contrast(of: faint, in: settings, scheme) >= 4.5)
                let below = faint.withAlphaComponent(faint.alphaComponent - 0.01)
                #expect(contrast(of: below, in: settings, scheme) < 4.5, "\(scheme): one step lower would not read")
                #expect(drawn(0).alphaComponent == faint.alphaComponent, "\(scheme): every opacity under the floor is the floor")
            }
        }
    }

    @Test func loadedAndUnloadedTextAreTwoControls() throws {
        for scheme in schemes {
            try withSettings { settings in
                edited(settings, scheme) {
                    $0.sidebarText = SidebarTextStyle(colorRGB: nil, opacity: 1)
                    $0.unloadedText = SidebarTextStyle(colorRGB: nil, opacity: 0.8)
                }
                let loaded = rgb(settings.sidebarTextColor(isDeferred: false, scheme: scheme), scheme)
                let unloaded = rgb(settings.sidebarTextColor(isDeferred: true, scheme: scheme), scheme)
                #expect(loaded.alphaComponent == 1 && abs(unloaded.alphaComponent - 0.8) < 0.011, "\(scheme)")
            }
        }
    }

    // MARK: - Icons, URL text, hue and primary color

    @Test func iconsAndUrlTextReachTheirOverrides() throws {
        for scheme in schemes {
            try withSettings { settings in
                let hex: UInt32 = 0xC0392B
                edited(settings, scheme) {
                    $0.icons = SidebarTextStyle(colorRGB: hex, opacity: 1)
                    $0.url = SidebarTextStyle(colorRGB: 0x2E86C1, opacity: 1)
                }
                let variant = settings.resolvedTheme.variant(scheme)
                let icons = try #require(variant.controlInk)
                let url = try #require(variant.urlInk)
                #expect(rgb(icons, scheme).redComponent > 0.6 && rgb(icons, scheme).blueComponent < 0.5, "\(scheme)")
                #expect(rgb(url, scheme).blueComponent > rgb(url, scheme).redComponent, "\(scheme)")
            }
        }
    }

    @Test func huePrimaryAndTheirResetReachTheSurfaces() throws {
        for scheme in schemes {
            try withSettings { settings in
                let before = settings.resolvedTheme.variant(scheme).window.srgb(scheme: scheme)
                edited(settings, scheme) { $0.primary = 0xFF8800 }
                let tinted = settings.resolvedTheme.variant(scheme).window.srgb(scheme: scheme)
                #expect(tinted != before, "\(scheme): the primary color moves the window")
                edited(settings, scheme) { $0.hue = 0.3 }
                #expect(settings.resolvedTheme.variant(scheme).window.srgb(scheme: scheme) != tinted, "\(scheme): hue")
                settings.resetColors(scheme: scheme)
                #expect(settings.resolvedTheme.variant(scheme).window.srgb(scheme: scheme) == before, "\(scheme): reset")
            }
        }
    }

    // MARK: - Accent and assistant

    @Test func theAccentColorIsWhatTheThemeDrawsAndTheAppTints() throws {
        for scheme in schemes {
            try withSettings { settings in
                edited(settings, scheme) { $0.accent = 0xFF0000 }
                let variant = settings.resolvedTheme.variant(scheme)
                #expect(same(variant.accent.srgb(scheme: scheme), rgb(Color(hex: 0xFF0000), scheme)), "\(scheme)")
                #expect(contrast(of: rgb(variant.accentText, scheme), in: settings, scheme) >= 4.5, "the accent as text")
                // The window's tint, and every switch and slider in it, is the system accent unless a theme sets one.
                let tint = settings.resolvedTheme.systemAccent
                #expect(same(rgb(tint, scheme), rgb(Color(hex: 0xFF0000), scheme)), "\(scheme): the tint follows the accent")
            }
        }
    }

    /// A row outside a window reads the light variant, and the default sidebar ground is dark: the dot is the
    /// accent where it reaches 3:1 on that ground, so these colors are light enough to be drawn as themselves.
    @Test func aRowsNewTabDotTakesTheThemesAccent() throws {
        let settings = BrowserSettings.application
        try #require(settings.themePreview == nil, "must not replace a theme preview in progress")
        let restoreClock = settings.previewsEveryStep()
        defer { restoreClock() }
        settings.beginThemePreview()
        defer { settings.cancelThemePreview() }
        let unseen = SidebarRowStyle.resolve(
            isCurrent: false, isMarked: false, isUnseen: true, paletteOpen: false, increasedContrast: false
        )

        var dots: [NSColor] = []
        for hex: UInt32 in [0xFFD54F, 0x66E0FF] {
            settings.previewThemeColors(scheme: .light) { $0.accent = hex }
            let ink = SidebarRowInkSource().ink(for: unseen)
            dots.append(try #require(ink.mark.map { SidebarRowStyle.srgb($0, scheme: .light) }))
        }
        #expect(!same(dots[0], dots[1]), "a new accent color is a new dot")
        #expect(dots[0].redComponent > dots[0].blueComponent && dots[1].blueComponent > dots[1].redComponent)
    }

    /// The default WSurf theme sets its own assistant color. A theme that sets none, like Standard, draws the assistant in its accent.
    @Test func theAssistantColorIsWhatAssistantSurfacesDrawAndFollowsTheAccentWhenNoneIsSet() throws {
        for scheme in schemes {
            try withSettings { settings in
                edited(settings, scheme) {
                    $0.accent = 0xFF0000
                    $0.assistant = nil
                }
                var variant = settings.resolvedTheme.variant(scheme)
                #expect(same(variant.assistant.srgb(scheme: scheme), variant.accent.srgb(scheme: scheme)), "\(scheme): follows")
                #expect(same(rgb(variant.assistantText, scheme), rgb(variant.accentText, scheme)))

                edited(settings, scheme) { $0.assistant = 0x00AA00 }
                variant = settings.resolvedTheme.variant(scheme)
                #expect(same(variant.assistant.srgb(scheme: scheme), rgb(Color(hex: 0x00AA00), scheme)), "\(scheme): chosen")
                #expect(same(variant.accent.srgb(scheme: scheme), rgb(Color(hex: 0xFF0000), scheme)), "the accent stays")
                #expect(contrast(of: rgb(variant.assistantText, scheme), in: settings, scheme) >= 4.5, "as text")
            }
        }
    }

    @Test func theAssistantSurfaceTakesTheAssistantColorAndTheRestKeepsTheAccent() throws {
        let settings = BrowserSettings.application
        try #require(settings.themePreview == nil, "must not replace a theme preview in progress")
        settings.beginThemePreview()
        defer { settings.cancelThemePreview() }
        settings.previewThemeColors(scheme: .light) {
            $0.accent = 0xFF0000
            $0.assistant = 0x00AA00
        }

        #expect(same(rgb(AskSurfaceStatus.agent.color, .light), rgb(Color(hex: 0x00AA00), .light)), "the assistant's tint")
        #expect(same(rgb(Theme.assistant, .light), rgb(Color(hex: 0x00AA00), .light)))
        #expect(same(rgb(Theme.accent, .light), rgb(Color(hex: 0xFF0000), .light)), "everything else keeps the accent")
    }
}
