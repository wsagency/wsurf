// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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
        try test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false))
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
}
