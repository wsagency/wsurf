// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

enum LoomChrome {
    /// The inset shared by chrome-owned surfaces, and the default page spacing of a theme.
    nonisolated static let canvasInset: CGFloat = 6
    /// As wide as the widest page spacing, and a flush page keeps 4 pt of grab on each side of its edge.
    nonisolated static let resizeGrabWidth: CGFloat = 8

    nonisolated static var canvasTop: CGFloat {
        Theme.topBarHeight
    }

    /// The page's corner, from the theme's page spacing and corner rounding. The side panel and split panes follow it.
    static var canvasRadius: CGFloat {
        BrowserSettings.application.chromeShape.canvasRadius(window: Theme.Radius.window)
    }

    static var canvasShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: canvasRadius, style: .continuous)
    }

    /// `isFloating` marks the sidebar surface, which a solid theme colors separately from the window.
    static func sampledColor(_ color: NSColor?, scheme: ColorScheme, isFloating: Bool = false) -> NSColor {
        let theme = BrowserSettings.application.resolvedTheme
        let variant = theme.variant(scheme)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
        // A solid theme and a changed palette set the color themselves; the page does not tint them.
        if theme.ground == .solid || variant.changesPalette {
            let surface = isFloating && theme.ground == .solid ? variant.sidebar : variant.window
            let resolved = surface.resolved(in: appearance)
            return resolved.usingColorSpace(.sRGB) ?? resolved
        }
        let fallbackIsLight = scheme == .light
        guard let color = color?.usingColorSpace(.sRGB), color.alphaComponent > 0.05 else {
            return neutral(isLight: fallbackIsLight, theme: theme)
        }

        // A real page chooses the chrome's tonal family too. In particular,
        // black and grey headers carry useful appearance information; treating
        // them as "no colour" leaves a light Loom around dark sites.
        let isLight = theme.isSoftTinted ? fallbackIsLight : PageInk.isLight(color, scheme: scheme)
        let neutral = neutral(isLight: isLight, theme: theme)

        let floor: CGFloat = isLight ? 0.55 : 0.02
        let ceiling: CGFloat = isLight ? 1 : 0.82
        let tint = NSColor(
            hue: color.hueComponent,
            saturation: min(color.saturationComponent, 0.55),
            brightness: min(max(color.brightnessComponent, floor), ceiling),
            alpha: 1
        )
        let tintFraction: CGFloat = theme.isSoftTinted ? 0.18 : 0.85
        return neutral.blended(withFraction: tintFraction, of: tint) ?? neutral
    }

    private static func neutral(isLight: Bool, theme: ResolvedTheme) -> NSColor {
        if theme.isSoftTinted {
            let appearance = NSAppearance(named: isLight ? .aqua : .darkAqua) ?? NSApp.effectiveAppearance
            let themed = theme.variant(isLight ? .light : .dark).window.resolved(in: appearance)
            if let themed = themed.usingColorSpace(.sRGB) {
                return themed
            }
        }
        if isLight {
            return NSColor(srgbRed: 0.94, green: 0.94, blue: 0.955, alpha: 1)
        }
        return NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1)
    }
}

/// The shared visible affordance for every resize gutter. The surrounding
/// handle owns the larger interaction target; this view only draws the pill.
struct LoomResizePill: View {
    let axis: Axis
    let isVisible: Bool
    let isDragging: Bool
    var thickness: CGFloat = 3
    var length: CGFloat = 64
    var onLightPage: Bool = false

    private var ink: Color {
        onLightPage ? .black : .white
    }

    private var halo: Color {
        (onLightPage ? Color.white : Color.black).opacity(0.35)
    }

    var body: some View {
        Capsule()
            .fill(ink)
            .overlay(Capsule().strokeBorder(halo, lineWidth: 0.5))
            .frame(
                width: axis == .vertical ? thickness : length,
                height: axis == .vertical ? length : thickness
            )
            .opacity(isVisible ? 1 : 0)
            .shadow(color: .black.opacity(isDragging ? 0.45 : 0.3), radius: 4, y: 1)
    }
}

/// Resolves every horizontal shell measurement from the same inputs. The
/// browser, panel, and resize gutters should never each infer these offsets.
nonisolated struct LoomShellGeometry {
    let containerWidth: CGFloat
    let sidebarWidth: CGFloat
    let preferredPanelWidth: CGFloat
    let isSidebarVisible: Bool
    let isPanelVisible: Bool
    let isPanelExpanded: Bool
    /// The theme's page spacing: the gap around the page and between the page and the side panel.
    var pageSpacing = LoomChrome.canvasInset

    var panelWidth: CGFloat {
        guard isPanelExpanded else { return preferredPanelWidth }
        return max(
            containerWidth - (isSidebarVisible ? sidebarWidth : 0) - pageSpacing * 2,
            0
        )
    }

    /// Additional room reserved by the page canvas. The top bar never reads
    /// this value, so opening the panel cannot change toolbar geometry.
    var canvasTrailingInset: CGFloat {
        guard isPanelVisible, !isPanelExpanded else { return 0 }
        return panelWidth + pageSpacing
    }

    /// Leading edge for a resize hit target centred in the canvas gutter. With no gutter it straddles the page edge.
    var sidebarResizeLeading: CGFloat {
        sidebarWidth + (pageSpacing - LoomChrome.resizeGrabWidth) / 2
    }

    var panelLeading: CGFloat {
        containerWidth - panelWidth - pageSpacing
    }

    var panelCoversPage: Bool {
        isPanelVisible && isPanelExpanded
    }

    /// Leading edge for a resize target centred between the page canvas and
    /// the side panel. It is window-owned, so neither surface shifts around it.
    var panelResizeLeading: CGFloat {
        containerWidth
            - panelWidth
            - pageSpacing
            - (pageSpacing + LoomChrome.resizeGrabWidth) / 2
    }
}

struct LoomAmbientBackdrop: View {
    let sampledPageColor: NSColor?
    let settings: BrowserSettings

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        LoomBackdrop(
            sampledPageColor: sampledPageColor,
            settings: settings,
            isFloating: false,
            fallsBack: GlassPolicy.fallsBack(reduceTransparency: reduceTransparency, contrast: contrast)
        )
    }
}

struct LoomFloatingFill: View {
    let sampledPageColor: NSColor?
    let settings: BrowserSettings

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        LoomBackdrop(
            sampledPageColor: sampledPageColor,
            settings: settings,
            isFloating: true,
            fallsBack: GlassPolicy.fallsBack(reduceTransparency: reduceTransparency, contrast: contrast)
        )
    }
}

/// Accessibility takes precedence over material. Glass works with every ground; Plain preserves Standard and
/// Calm's tinted backdrops, while a solid theme needs no visual effect.
struct LoomBackdrop: View {
    let sampledPageColor: NSColor?
    let settings: BrowserSettings
    let isFloating: Bool
    let fallsBack: Bool

    enum Kind {
        case solid, tinted, glass
    }

    static func kind(ground: ThemeGround, material: ThemeMaterial, fallsBack: Bool) -> Kind {
        if fallsBack {
            return .solid
        }
        if material == .glass {
            return .glass
        }
        return ground == .solid ? .solid : .tinted
    }

    var body: some View {
        switch Self.kind(ground: settings.resolvedTheme.ground, material: settings.themeMaterial, fallsBack: fallsBack) {
        case .solid:
            LoomSolidBackdrop(sampledPageColor: websiteTint, isFloating: isFloating)
        case .tinted:
            LoomTintedBackdrop(sampledPageColor: websiteTint, isFloating: isFloating)
        case .glass:
            LoomTransparentBackdrop(
                sampledPageColor: websiteTint,
                opacity: settings.transparency,
                isFloating: isFloating
            )
        }
    }

    private var websiteTint: NSColor? {
        settings.matchesWebsiteColor ? sampledPageColor : nil
    }
}

/// Plain solid themes and accessibility fallbacks draw an opaque ground, without a backdrop effect. Stored
/// material and transparency choices are untouched by the accessibility override.
private struct LoomSolidBackdrop: View {
    let sampledPageColor: NSColor?
    let isFloating: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color(nsColor: LoomChrome.sampledColor(sampledPageColor, scheme: scheme, isFloating: isFloating))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LoomTintedBackdrop: View {
    let sampledPageColor: NSColor?
    let isFloating: Bool

    @Environment(\.colorScheme) private var scheme

    private var sampled: NSColor {
        LoomChrome.sampledColor(sampledPageColor, scheme: scheme, isFloating: isFloating)
    }

    private var washOpacity: CGFloat {
        if Theme.isCalm {
            return isFloating ? 0.92 : 0.96
        }
        if sampledPageColor != nil {
            return isFloating ? 0.72 : 0.92
        }
        if isFloating {
            return 0.55
        }
        return PageInk.isLight(sampled, scheme: scheme) ? 0.34 : 0.28
    }

    var body: some View {
        ZStack {
            VisualEffectView(
                material: .underWindowBackground,
                blending: isFloating ? .withinWindow : .behindWindow
            )

            Color(nsColor: sampled).opacity(washOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The desktop blurred through the window, under a tint. This is a window backdrop, not a floating control, and
/// glass cannot sample glass, so it carries no glass layer of its own: one effect samples the desktop once.
private struct LoomTransparentBackdrop: View {
    let sampledPageColor: NSColor?
    let opacity: Double
    let isFloating: Bool

    @Environment(\.colorScheme) private var scheme

    private var sampled: NSColor {
        LoomChrome.sampledColor(sampledPageColor, scheme: scheme, isFloating: isFloating)
    }

    private var isLight: Bool {
        PageInk.isLight(sampled, scheme: scheme)
    }

    private var level: CGFloat {
        let sliderLevel = CGFloat(min(max(opacity, 0), 1))
        return 0.82 + 0.18 * sliderLevel
    }

    private var intensity: CGFloat {
        level * level * level
    }

    private var substrateOpacity: CGFloat {
        0.12 + 0.82 * intensity
    }

    private var tintWashOpacity: CGFloat {
        (isLight ? 0.34 : 0.42) * intensity
    }

    var body: some View {
        ZStack {
            VisualEffectView(
                material: .underWindowBackground,
                blending: .behindWindow,
                materialOpacity: substrateOpacity
            )

            Color(nsColor: sampled).opacity(tintWashOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shared panel fill for the side panel, internal pages, and Settings.
struct LoomPanelFill<S: InsettableShape>: View {
    let shape: S
    var isVisible = true
    var emphasis: Double = 1
    var tint: Color?
    var isInteractive = false

    @Environment(\.colorScheme) private var colorScheme

    private var glass: Glass {
        guard isVisible else { return .identity }
        let resting = colorScheme == .dark ? 0.18 : 0.10
        let tinted = Glass.regular.tint(
            (tint ?? Theme.sidebarTint).opacity(min(1, resting * emphasis))
        )
        return isInteractive ? tinted.interactive() : tinted
    }

    var body: some View {
        Color.clear
            .chromeGlass(glass, fill: tint ?? Theme.windowBackground, in: shape)
    }
}

struct LoomPageCanvas<Content: View>: View {
    let trailingInset: CGFloat
    let showsPanelFill: Bool
    @ViewBuilder let content: Content

    init(
        trailingInset: CGFloat = 0,
        showsPanelFill: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.trailingInset = trailingInset
        self.showsPanelFill = showsPanelFill
        self.content = content()
    }

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = LoomChrome.canvasShape
        let chrome = BrowserSettings.application.chromeShape
        let frame = chrome.pageFrame(contrast: contrast)
        let hasShadow = frame == .standard

        // The clip and the shadow stay in place for every edge, with values that draw nothing, so changing the edge
        // never changes the identity of the web view inside.
        content
            .background {
                LoomPanelFill(shape: shape, isVisible: showsPanelFill)
            }
            .clipShape(shape)
            .overlay {
                if frame == .hairline {
                    shape
                        .strokeBorder(
                            Theme.chrome(GlassPolicy.borderOpacity(contrast: contrast)),
                            lineWidth: contrast == .increased ? 1 : 1 / displayScale
                        )
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: .black.opacity(hasShadow ? 0.18 : 0),
                radius: hasShadow ? 12 : 0,
                y: hasShadow ? 4 : 0
            )
            .padding(.top, LoomChrome.canvasTop)
            .padding(.leading, chrome.pageSpacing)
            .padding(.trailing, chrome.pageSpacing + trailingInset)
            .padding(.bottom, chrome.pageSpacing)
    }
}
