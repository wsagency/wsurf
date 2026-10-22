// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

@MainActor
struct ThemeToolbarInkTests {
    private func withTheme(
        _ definition: ThemeDefinition,
        adjustment: ThemeAdjustment = ThemeAdjustment(),
        _ test: (ResolvedTheme) throws -> Void
    ) rethrows {
        let settings = BrowserSettings.application
        let saved = settings.themeCache
        let theme = ResolvedTheme(definition, adjustment: adjustment)
        settings.themeCache = theme
        defer { settings.themeCache = saved }
        try test(theme)
    }

    /// BrowserView seeds the window scheme before its descendants choose local surface appearances.
    private struct WindowRoot<Content: View>: View {
        let content: Content
        let localScheme: ColorScheme
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            content
                .environment(\.colorScheme, localScheme)
                .environment(\.chromeIsLight, localScheme == .light)
                .environment(\.windowColorScheme, scheme)
        }
    }

    /// An unshown native window supplies the actual appearance, including the private-window dark appearance.
    private func pixel(
        _ view: some View,
        windowScheme: ColorScheme,
        localScheme: ColorScheme,
        ground: NSColor
    ) throws -> NSColor {
        let root = WindowRoot(content: view, localScheme: localScheme)
            .frame(width: 40, height: 40)
            .background(Color(nsColor: ground))
            .environment(\.colorScheme, windowScheme)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: windowScheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func reference(_ ink: Color, font: Font = .system(size: 12, weight: .semibold)) -> some View {
        Image(systemName: "square.fill").font(font).foregroundStyle(ink)
    }

    @Test func toolbarUsesTheWindowVariantAcrossOppositeSurfaceSchemes() throws {
        let wsurf = try #require(ThemeCatalog.builtIn("wsurf"))
        var reversed = wsurf
        reversed.id = "reversed-window"
        reversed.light = wsurf.dark
        reversed.dark = wsurf.light
        let cases: [(ThemeDefinition, ThemeAdjustment, ColorScheme)] = [
            (wsurf, ThemeAdjustment(darkBrightness: 0.4), .dark),
            (reversed, ThemeAdjustment(), .light),
        ]
        for (definition, adjustment, windowScheme) in cases {
            try withTheme(definition, adjustment: adjustment) { theme in
                let ground = theme.variant(windowScheme).window.srgb(scheme: windowScheme)
                let localScheme: ColorScheme = PageInk.isLight(ground, scheme: windowScheme) ? .light : .dark
                #expect(localScheme != windowScheme)
                let ink = try #require(Theme.controlOverride(in: windowScheme))
                let wrongVariant = try #require(theme.variant(localScheme).controlInk)
                #expect(SidebarRowStyle.contrast(SidebarRowStyle.srgb(wrongVariant, scheme: localScheme), ground) < 3)
                let actual = try pixel(ToolbarButton(symbol: "square.fill", enabled: true) {},
                                       windowScheme: windowScheme, localScheme: localScheme, ground: ground)
                let expected = try pixel(reference(ink), windowScheme: windowScheme, localScheme: localScheme, ground: ground)
                #expect(actual == expected, "the enabled toolbar glyph uses the actual window variant's guarded ink")
                #expect(SidebarRowStyle.contrast(actual, ground) >= 3)
            }
        }
    }

    @Test func aPrivateDarkToolbarKeepsItsWindowInkWithoutChangingAppAppearance() throws {
        let appearance = NSApp.appearance
        let wsurf = try #require(ThemeCatalog.builtIn("wsurf"))
        try withTheme(wsurf, adjustment: ThemeAdjustment(darkBrightness: 0.4)) { theme in
            let ground = theme.dark.window.srgb(scheme: .dark)
            let ink = try #require(Theme.controlOverride(in: .dark))
            let actual = try pixel(ToolbarButton(symbol: "square.fill", enabled: true) {},
                                   windowScheme: .dark, localScheme: .light, ground: ground)
            #expect(try actual == pixel(reference(ink), windowScheme: .dark, localScheme: .light, ground: ground))
            #expect(SidebarRowStyle.contrast(actual, ground) >= 3)
        }
        #expect(NSApp.appearance == appearance)
    }

    @Test func lightRootConsumersOutsideTheToolbarReceiveTheWindowScheme() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "WSurf/UI/Shell/BrowserView.swift"), encoding: .utf8)
        #expect(source.contains("""
                .environment(\\.chromeWash, .of(nil, isLight: scheme == .light))
                .environment(\\.windowColorScheme, scheme)
                .animation(chromeMotion, value: sidebar.isVisible)
        """))
        try withTheme(try #require(ThemeCatalog.builtIn("wsurf"))) { theme in
            let ground = theme.light.window.srgb(scheme: .light)
            let ink = try #require(Theme.controlOverride(in: .light))
            let settingsIcon = ChromeIcon(symbol: "square.fill") {}
            let panelButton = QuietIconButton(symbol: "square.fill", isOn: false, help: "") {}
            let settingsPixel = try pixel(settingsIcon, windowScheme: .light, localScheme: .light, ground: ground)
            let panelPixel = try pixel(panelButton, windowScheme: .light, localScheme: .light, ground: ground)
            #expect(try settingsPixel == pixel(reference(ink, font: .system(size: 10.5, weight: .medium)),
                                            windowScheme: .light, localScheme: .light, ground: ground))
            #expect(try panelPixel == pixel(reference(ink, font: Theme.Font.rowTitle),
                                       windowScheme: .light, localScheme: .light, ground: ground))
            #expect(SidebarRowStyle.contrast(settingsPixel, ground) >= 3)
            #expect(SidebarRowStyle.contrast(panelPixel, ground) >= 3)
        }
    }

    @Test func aMissingVariantOverrideKeepsTheLocalFallbackAndTint() throws {
        let definition = ThemeDefinition(
            id: "optional-control", name: "Optional control", ground: .solid,
            light: ThemeVariant(window: 0xFFFFFF, sidebar: 0xFFFFFF),
            dark: ThemeVariant(window: 0, sidebar: 0, icons: SidebarTextStyle(colorRGB: 0xFFFFFF))
        )
        try withTheme(definition) { _ in
            #expect(Theme.controlOverride(in: .light) == nil)
            #expect(Theme.controlOverride(in: .dark) != nil)
            let ground = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            let toolbar = try pixel(ToolbarButton(symbol: "square.fill", enabled: true) {},
                                    windowScheme: .light, localScheme: .dark, ground: ground)
            #expect(try toolbar == pixel(reference(Color.white.opacity(0.85)),
                                     windowScheme: .light, localScheme: .dark, ground: ground))
            let panel = QuietIconButton(symbol: "square.fill", isOn: false, tint: .green, help: "") {}
            #expect(try pixel(panel, windowScheme: .light, localScheme: .dark, ground: ground)
                == pixel(reference(.green, font: Theme.Font.rowTitle),
                         windowScheme: .light, localScheme: .dark, ground: ground))
        }
    }

    @Test func adaptivePrimaryControlInkKeepsItsActualVariantAndAlpha() throws {
        let definition = ThemeDefinition(
            id: "adaptive-control", name: "Adaptive control", ground: .solid,
            light: ThemeVariant(window: 0xFFFFFF, sidebar: 0xFFFFFF, icons: SidebarTextStyle(opacity: 0.8)),
            dark: ThemeVariant(window: 0, sidebar: 0, icons: SidebarTextStyle(opacity: 0.8))
        )
        try withTheme(definition) { theme in
            for scheme in [ColorScheme.light, .dark] {
                let opposite: ColorScheme = scheme == .light ? .dark : .light
                let original = SidebarRowStyle.srgb(Color.primary.opacity(0.8), scheme: scheme)
                let ink = try #require(Theme.controlOverride(in: scheme))
                #expect(SidebarRowStyle.srgb(ink, scheme: opposite) == original)
                #expect(original.alphaComponent > 0 && original.alphaComponent < 1)
                #expect(definition.variant(scheme).icons == SidebarTextStyle(opacity: 0.8))
                let ground = theme.variant(scheme).window.srgb(scheme: scheme)
                let actual = try pixel(ToolbarButton(symbol: "square.fill", enabled: true) {},
                                       windowScheme: scheme, localScheme: opposite, ground: ground)
                #expect(try actual == pixel(reference(Color(nsColor: original)),
                                        windowScheme: scheme, localScheme: opposite, ground: ground))
                #expect(SidebarRowStyle.contrast(actual, ground) >= 3)
            }
        }
    }

    @Test func aDisabledToolbarStillDimsTheChosenOverrideByPointThreeFive() throws {
        try withTheme(try #require(ThemeCatalog.builtIn("wsurf"))) { theme in
            let ground = theme.dark.window.srgb(scheme: .dark)
            let ink = try #require(Theme.controlOverride(in: .dark))
            let actual = try pixel(ToolbarButton(symbol: "square.fill", enabled: false) {},
                                   windowScheme: .dark, localScheme: .light, ground: ground)
            let glyph = Image(systemName: "square.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChromeInk.glyph(onLight: true, windowScheme: .dark, enabled: false))
            #expect(try pixel(glyph, windowScheme: .dark, localScheme: .light, ground: ground)
                == pixel(reference(ink.opacity(0.35)), windowScheme: .dark, localScheme: .light, ground: ground))
            // Keep AppKit's disabled-button treatment on both sides, as well as the exact .35 glyph alpha.
            let expected = Button {} label: {
                Image(systemName: "square.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ink.opacity(0.35))
            .disabled(true)
            #expect(try actual == pixel(expected, windowScheme: .dark, localScheme: .light, ground: ground))
        }
    }

    @Test func overridesStillPrecedeTintAndInverseRowsCanIgnoreThem() throws {
        try withTheme(try #require(ThemeCatalog.builtIn("wsurf"))) { theme in
            let ground = theme.dark.window.srgb(scheme: .dark)
            let ink = try #require(Theme.controlOverride(in: .dark))
            let icon = ChromeIcon(symbol: "square.fill", tint: .pink) {}
            let panel = QuietIconButton(symbol: "square.fill", isOn: false, tint: .pink, help: "") {}
            #expect(try pixel(icon, windowScheme: .dark, localScheme: .light, ground: ground)
                == pixel(reference(ink, font: .system(size: 10.5, weight: .medium)),
                         windowScheme: .dark, localScheme: .light, ground: ground))
            #expect(try pixel(panel, windowScheme: .dark, localScheme: .light, ground: ground)
                == pixel(reference(ink, font: Theme.Font.rowTitle),
                         windowScheme: .dark, localScheme: .light, ground: ground))
            #expect(try pixel(icon.environment(\.ignoresControlOverride, true),
                          windowScheme: .dark, localScheme: .light, ground: ground)
                == pixel(reference(Color.pink.deepened(by: 0.28), font: .system(size: 10.5, weight: .medium)),
                         windowScheme: .dark, localScheme: .light, ground: ground))
            let fallback = ChromeIcon(symbol: "square.fill") {}.environment(\.ignoresControlOverride, true)
            #expect(try pixel(fallback, windowScheme: .dark, localScheme: .light, ground: ground)
                == pixel(reference(Color.black.opacity(0.75), font: .system(size: 10.5, weight: .medium)),
                         windowScheme: .dark, localScheme: .light, ground: ground))
        }
    }
}
