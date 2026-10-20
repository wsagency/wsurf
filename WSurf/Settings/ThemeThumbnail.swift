// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

enum AppearanceThumbnailMetrics {
    static let width: CGFloat = 108
    static let height: CGFloat = 68
    static let spacing: CGFloat = 12

    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: width, maximum: width), spacing: spacing, alignment: .top)]
    }
}

struct ThemeThumbnailPalette: Equatable {
    let id: String
    let backdrop: Color
    let chrome: Color
    let canvas: Color
    let surface: Color
    let primary: Color
    let secondary: Color
    let accent: Color
    /// Only a solid theme paints the sidebar as its own surface; the other palettes share the backdrop.
    var sidebar: Color?
    /// A flat translucent preview, not a backdrop or glass effect.
    var materialOpacity: Double = 1
    /// The theme's corner rounding and page edge, drawn as plain shapes.
    var cornerScale: CGFloat = 1
    var pageFrame = FrameStyle.standard

    private static let light = ThemeThumbnailPalette(
        id: "light",
        backdrop: Color(red: 0.88, green: 0.90, blue: 0.94),
        chrome: Color(white: 0.91),
        canvas: Color(white: 0.985),
        surface: Color(white: 0.90),
        primary: Color(white: 0.28),
        secondary: Color(white: 0.63),
        accent: Color(red: 0.18, green: 0.48, blue: 0.94)
    )

    private static let dark = ThemeThumbnailPalette(
        id: "dark",
        backdrop: Color(red: 0.07, green: 0.08, blue: 0.11),
        chrome: Color(white: 0.16),
        canvas: Color(white: 0.105),
        surface: Color(white: 0.23),
        primary: Color(white: 0.78),
        secondary: Color(white: 0.43),
        accent: Color(red: 0.26, green: 0.57, blue: 1.0)
    )

    private static let lightCalm = ThemeThumbnailPalette(
        id: "lightCalm",
        backdrop: Color(red: 0.80, green: 0.73, blue: 0.75),
        chrome: Color(red: 0.86, green: 0.80, blue: 0.79),
        canvas: Color(red: 0.91, green: 0.85, blue: 0.85),
        surface: Color(red: 0.78, green: 0.70, blue: 0.74),
        primary: Color(red: 0.36, green: 0.26, blue: 0.34),
        secondary: Color(red: 0.62, green: 0.49, blue: 0.56),
        accent: Color(red: 0.70, green: 0.40, blue: 0.55)
    )

    private static let darkCalm = ThemeThumbnailPalette(
        id: "darkCalm",
        backdrop: Color(red: 0.12, green: 0.11, blue: 0.17),
        chrome: Color(red: 0.18, green: 0.16, blue: 0.24),
        canvas: Color(red: 0.15, green: 0.14, blue: 0.21),
        surface: Color(red: 0.28, green: 0.24, blue: 0.33),
        primary: Color(red: 0.86, green: 0.75, blue: 0.82),
        secondary: Color(red: 0.59, green: 0.51, blue: 0.63),
        accent: Color(red: 0.82, green: 0.57, blue: 0.72)
    )

    /// The thumbnail of `theme` in one appearance. A solid theme shows its own colors; the tinted themes show a
    /// fixed picture of their material, with the person's palette changes and inks laid over it.
    init(_ theme: ThemeDefinition, adjustment: ThemeAdjustment, scheme: ColorScheme) {
        let isDark = scheme == .dark
        let colors = theme.variant(scheme)
        let variant = ResolvedVariant(
            colors, isDark: isDark, brightness: adjustment.brightness(scheme), ground: theme.ground
        )
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
        func color(_ role: RoleColor) -> Color {
            Color(nsColor: role.resolved(in: appearance))
        }
        let id = "\(theme.id).\(isDark ? "dark" : "light")"
        if theme.ground == .solid {
            self.init(
                id: id, backdrop: color(variant.window), chrome: color(variant.window), canvas: color(variant.sidebar),
                surface: color(variant.surface), primary: variant.controlInk ?? variant.loadedInk,
                secondary: variant.urlInk ?? variant.unloadedInk, accent: color(variant.accent),
                sidebar: color(variant.sidebar)
            )
            materialOpacity = adjustment.material == .glass ? 0.35 + 0.55 * adjustment.glassOpacity : 1
            cornerScale = CGFloat(adjustment.cornerScale)
            pageFrame = adjustment.pageFrame
            return
        }
        let base = switch (theme.ground, isDark) {
        case (.softTinted, false):
            Self.lightCalm
        case (.softTinted, true):
            Self.darkCalm
        case (_, false):
            Self.light
        case (_, true):
            Self.dark
        }
        func adjusted(_ color: Color, accent: Bool = false) -> Color {
            guard variant.changesPalette else { return color }
            return Color(nsColor: Theme.customized(NSColor(color), change: variant.change, isAccent: accent))
        }
        let inheritedAccent = ThemeCatalog.builtIn(theme.basedOn ?? theme.id)?.variant(scheme).accent
        let accent = colors.accent == nil || colors.accent == inheritedAccent
            ? adjusted(base.accent, accent: true) : color(variant.accent)
        self.init(
            id: id, backdrop: adjusted(base.backdrop), chrome: adjusted(base.chrome), canvas: base.canvas,
            surface: adjusted(base.surface), primary: variant.controlInk ?? base.primary,
            secondary: variant.urlInk ?? base.secondary, accent: accent
        )
        materialOpacity = adjustment.material == .glass ? 0.35 + 0.55 * adjustment.glassOpacity : 1
        cornerScale = CGFloat(adjustment.cornerScale)
        pageFrame = adjustment.pageFrame
    }

    init(
        id: String, backdrop: Color, chrome: Color, canvas: Color, surface: Color, primary: Color,
        secondary: Color, accent: Color, sidebar: Color? = nil
    ) {
        self.id = id
        self.backdrop = backdrop
        self.chrome = chrome
        self.canvas = canvas
        self.surface = surface
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.sidebar = sidebar
    }
}

nonisolated struct Slice: Shape {
    let start: CGFloat
    let end: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX + rect.width * start,
            y: rect.minY,
            width: rect.width * (end - start),
            height: rect.height
        ))
    }
}

struct ThemeThumbnailWindow: View {
    let palette: ThemeThumbnailPalette

    var body: some View {
        AppearanceBrowserThumbnail(palette: palette, chromeInk: palette.primary) {
            ZStack {
                LinearGradient(
                    colors: [.white.opacity(0.3), .black.opacity(0.2)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                palette.backdrop.opacity(palette.materialOpacity)

                if palette.sidebar == nil {
                    LinearGradient(
                        colors: [
                            palette.accent.opacity(0.12),
                            Color.white.opacity(0.055),
                            Color.black.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
    }
}

struct AppearanceBrowserThumbnail<Backdrop: View>: View {
    let palette: ThemeThumbnailPalette
    let chromeInk: Color
    let tintsSelectedTab: Bool
    let backdrop: Backdrop

    init(
        palette: ThemeThumbnailPalette,
        chromeInk: Color,
        tintsSelectedTab: Bool = false,
        @ViewBuilder backdrop: () -> Backdrop
    ) {
        self.palette = palette
        self.chromeInk = chromeInk
        self.tintsSelectedTab = tintsSelectedTab
        self.backdrop = backdrop()
    }

    var body: some View {
        ZStack {
            backdrop
            palette.chrome.opacity(palette.materialOpacity)
                .frame(maxWidth: .infinity)
                .frame(height: 14, alignment: .top)
            if let sidebar = palette.sidebar {
                sidebar.opacity(palette.materialOpacity)
                    .frame(width: 27)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            AppearanceBrowserPage(palette: palette)
                .padding(.top, 14)
                .padding(.leading, 29)
                .padding(.trailing, 5)
                .padding(.bottom, 5)

            AppearanceBrowserChrome(
                ink: chromeInk,
                secondaryInk: palette.secondary,
                accent: palette.accent,
                tintsSelectedTab: tintsSelectedTab,
                dimsUnloadedRow: palette.sidebar != nil,
                cornerScale: palette.cornerScale
            )
        }
        .overlay(alignment: .top) {
            if palette.sidebar == nil {
                LinearGradient(
                    colors: [Color.white.opacity(0.13), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 13)
                .allowsHitTesting(false)
            }
        }
    }
}

private struct AppearanceBrowserPage: View {
    let palette: ThemeThumbnailPalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7 * palette.cornerScale, style: .continuous)
        let hasShadow = palette.pageFrame == .standard
        shape
            .fill(palette.canvas)
            .overlay {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule()
                        .fill(palette.primary.opacity(0.72))
                        .frame(width: 28, height: 3)

                    Capsule()
                        .fill(palette.secondary.opacity(0.55))
                        .frame(width: 38, height: 2)

                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(index == 0 ? palette.accent.opacity(0.34) : palette.surface)
                                .frame(height: 11)
                        }
                    }

                    Spacer(minLength: 0)

                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(palette.surface.opacity(0.92))
                        .frame(height: 8)
                }
                .padding(6)
            }
            .overlay {
                if palette.pageFrame == .hairline {
                    shape.strokeBorder(palette.primary.opacity(0.35), lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(hasShadow ? 0.23 : 0), radius: hasShadow ? 3 : 0, y: hasShadow ? 1 : 0)
    }
}

private struct AppearanceBrowserChrome: View {
    let ink: Color
    let secondaryInk: Color
    let accent: Color
    let tintsSelectedTab: Bool
    let dimsUnloadedRow: Bool
    let cornerScale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            AppearanceBrowserSidebar(
                ink: ink,
                secondaryInk: secondaryInk,
                accent: accent,
                tintsSelectedTab: tintsSelectedTab,
                dimsUnloadedRow: dimsUnloadedRow,
                cornerScale: cornerScale
            )
                .padding(.leading, 6)
                .padding(.top, 17)

            AppearanceTrafficLights()
                .frame(width: 13, height: 3)
                .padding(.leading, 6)
                .padding(.top, 6)

            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                Image(systemName: "chevron.right")
            }
            .font(.system(size: 4, weight: .bold))
            .foregroundStyle(ink.opacity(0.64))
            .frame(width: 12, height: 7)
            .padding(.leading, 31.5)
            .padding(.top, 4)

            Capsule()
                .fill(ink.opacity(0.18))
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
                .frame(width: 40, height: 7)
                .padding(.top, 4)
                .padding(.leading, 46)

            Circle()
                .fill(ink.opacity(0.20))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
                .padding(.leading, 95)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AppearanceBrowserSidebar: View {
    let ink: Color
    let secondaryInk: Color
    let accent: Color
    let tintsSelectedTab: Bool
    let dimsUnloadedRow: Bool
    let cornerScale: CGFloat

    /// A preset shows loaded rows in its text color and the last row unloaded, as the sidebar draws them.
    private func rowInk(_ index: Int) -> Color {
        dimsUnloadedRow && index == 3 ? secondaryInk : ink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule()
                .fill(ink.opacity(0.60))
                .frame(width: 15, height: 2)

            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 2) {
                    Circle()
                        .fill(
                            index == 1 && tintsSelectedTab
                                ? accent
                                : (dimsUnloadedRow ? rowInk(index) : secondaryInk.opacity(0.76))
                        )
                        .frame(width: 3, height: 3)
                    Capsule()
                        .fill(rowInk(index).opacity(dimsUnloadedRow ? 1 : (index == 1 ? 0.78 : 0.43)))
                        .frame(width: index == 1 ? 10 : 12, height: 2)
                }
                .padding(.horizontal, 1.5)
                .frame(height: 6)
                .background {
                    RoundedRectangle(cornerRadius: 2.5 * cornerScale, style: .continuous)
                        .fill(
                            index == 1
                                ? (tintsSelectedTab ? accent.opacity(0.58) : ink.opacity(0.10))
                                : Color.clear
                        )
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Circle()
                    .strokeBorder(ink.opacity(0.48), lineWidth: 1)
                    .frame(width: 4, height: 4)
                Capsule()
                    .fill(ink.opacity(0.48))
                    .frame(width: 11, height: 2)
            }
        }
        .frame(width: 20, height: 45, alignment: .topLeading)
    }
}

private struct AppearanceTrafficLights: View {
    var body: some View {
        HStack(spacing: 2) {
            Circle().fill(Color.red.opacity(0.86))
            Circle().fill(Color.yellow.opacity(0.86))
            Circle().fill(Color.green.opacity(0.86))
        }
    }
}
