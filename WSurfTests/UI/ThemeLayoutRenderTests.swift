// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Draws the pieces a theme's layout changes and reads pixels back. Each piece takes its knob as an input, so no case
/// changes the app-wide theme.
@MainActor
struct ThemeLayoutRenderTests {
    private let gray = Color(red: 0.5, green: 0.5, blue: 0.5)

    private func rendered(_ view: some View, scheme: ColorScheme) throws -> (bitmap: NSBitmapImageRep, scale: CGFloat) {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .environment(\.windowColorScheme, scheme)
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return (bitmap, CGFloat(bitmap.pixelsWide) / host.bounds.width)
    }

    /// The pixel at `(x, y)` points from the top left, in sRGB.
    private func pixel(of view: some View, scheme: ColorScheme, x: CGFloat, y: CGFloat) throws -> NSColor {
        let (bitmap, scale) = try rendered(view, scheme: scheme)
        return try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }

    private func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.7 && color.greenComponent < 0.35 && color.blueComponent < 0.35
    }

    private func isNeutral(_ color: NSColor) -> Bool {
        abs(color.redComponent - color.greenComponent) < 0.08 && abs(color.greenComponent - color.blueComponent) < 0.08
    }

    // MARK: - Tab icons

    private let redIcon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
        NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
        bounds.fill()
        return true
    }

    private func icon(_ tab: BrowserTab, colors: Bool) -> some View {
        TabIcon(tab: tab, tint: .white, colorsFavicon: colors)
            .padding(4)
            .background(gray)
    }

    private func tabs(in browser: BrowserModel) -> (loaded: BrowserTab, unloaded: BrowserTab) {
        let loaded = browser.newTab(activate: false)
        loaded.urlString = "https://example.com/"
        loaded.isLoading = false
        loaded.favicon = redIcon
        let unloaded = browser.addPage("https://example.org/")
        unloaded.favicon = redIcon
        return (loaded, unloaded)
    }

    @Test func colorTabIconsDropTheTintOnlyForLoadedTabs() {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let (loaded, unloaded) = tabs(in: browser)
        #expect(!loaded.isDeferred && unloaded.isDeferred)

        #expect(TabIcon(tab: loaded, tint: .white, colorsFavicon: true).faviconTint == nil)
        #expect(TabIcon(tab: loaded, tint: .white).faviconTint == .white)
        #expect(TabIcon(tab: unloaded, tint: .white, colorsFavicon: true).faviconTint == .white)
        #expect(TabIcon(tab: unloaded, colorsFavicon: true).faviconTint == .secondary)
    }

    /// Without a tint the favicon is drawn as it is, so the red survives on the screen.
    @Test func aLoadedColorTabIconShowsTheFaviconsOwnColor() throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let (loaded, _) = tabs(in: browser)
        let middle = 4 + SidebarMetrics.rowIconSize / 2
        let colored = try pixel(of: icon(loaded, colors: true), scheme: .dark, x: middle, y: middle)
        #expect(isRed(colored), "\(colored)")
    }

    // MARK: - Row edges

    /// Thin edge and None replace a marked row's glass with the opaque fill that Reduce Transparency uses. The fill is
    /// compared with the same color drawn plainly, because the display profile moves drawn colors by a few levels.
    @Test func aMarkedRowWithoutGlassShowsTheOpaqueFill() throws {
        let plain = Color.clear
            .frame(width: 80, height: 30)
            .background(Theme.controlSurface)
            .padding(10)
            .background(gray)
        let expected = try pixel(of: plain, scheme: .light, x: 50, y: 25)
        for frame in [FrameStyle.hairline, .none] {
            let row = Color.clear
                .frame(width: 80, height: 30)
                .sidebarRowSelectionEffect(isSelected: true, isHovering: false, radius: 0, frame: frame)
                .padding(10)
                .background(gray)
            let actual = try pixel(of: row, scheme: .light, x: 50, y: 25)
            #expect(abs(actual.redComponent - expected.redComponent) < 0.03, "\(frame)")
            #expect(abs(actual.greenComponent - expected.greenComponent) < 0.03, "\(frame)")
            #expect(abs(actual.blueComponent - expected.blueComponent) < 0.03, "\(frame)")
        }
    }

    @Test func anUnmarkedRowDrawsNothingWhateverItsEdge() throws {
        for frame in [FrameStyle.standard, .hairline, .none] {
            let row = Color.clear
                .frame(width: 80, height: 30)
                .sidebarRowSelectionEffect(isSelected: false, isHovering: false, radius: 0, frame: frame)
                .padding(10)
                .background(gray)
            let color = try pixel(of: row, scheme: .light, x: 50, y: 25)
            #expect(abs(color.redComponent - 0.5) < 0.05 && isNeutral(color), "\(frame)")
        }
    }
}
