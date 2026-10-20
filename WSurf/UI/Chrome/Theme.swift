// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

enum Theme {
    private static var resolved: ResolvedTheme {
        BrowserSettings.application.resolvedTheme
    }

    static var windowBackground: Color {
        resolved.windowBackground
    }

    static var controlSurface: Color {
        resolved.controlSurface
    }

    static var sidebarTint: Color {
        resolved.sidebarTint
    }

    static var accent: Color {
        resolved.accent
    }

    static var assistant: Color {
        resolved.assistant
    }

    static var accentText: Color {
        resolved.accentText
    }

    static var onAccent: Color {
        resolved.onAccent
    }

    private static let standardThinkingMax = adaptive(
        dark: NSColor(red: 0.77, green: 0.64, blue: 1.00, alpha: 1),
        light: NSColor(red: 0.38, green: 0.12, blue: 0.62, alpha: 1)
    )
    private static let calmThinkingMax = adaptive(
        dark: NSColor(red: 0.76, green: 0.68, blue: 0.96, alpha: 1),
        light: NSColor(red: 0.48, green: 0.30, blue: 0.62, alpha: 1)
    )
    static var thinkingMax: Color {
        isCalm ? calmThinkingMax : standardThinkingMax
    }

    static var systemAccent: Color {
        resolved.systemAccent
    }

    static let danger = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)

    private static let standardWarning = adaptive(
        dark: NSColor(red: 0.90, green: 0.64, blue: 0.39, alpha: 1),
        light: NSColor(red: 0.71, green: 0.33, blue: 0.05, alpha: 1)
    )
    private static let calmWarning = adaptive(
        dark: NSColor(red: 0.91, green: 0.68, blue: 0.52, alpha: 1),
        light: NSColor(red: 0.62, green: 0.35, blue: 0.24, alpha: 1)
    )
    static var warning: Color {
        isCalm ? calmWarning : standardWarning
    }

    enum Radius {
        static var window: CGFloat {
            SystemWindowShape.cornerRadius
        }

        static var panel: CGFloat {
            min(window, 14)
        }
        static let popover: CGFloat = 16
        static var card: CGFloat {
            min(window, 12)
        }
        static var control: CGFloat {
            min(window, 10)
        }
        static var chip: CGFloat {
            min(window, 8)
        }
        static let tight: CGFloat = 4

        /// A radius `inset` points inside a container of radius `container`. It never rounds more than the container,
        /// so a square container keeps square content.
        static func nested(in container: CGFloat, inset: CGFloat) -> CGFloat {
            min(container, max(tight, container - inset))
        }

        static var hover: CGFloat {
            control
        }

        /// Sidebar rows, their highlights and folder outlines: `control` scaled by the theme's corner rounding.
        static var row: CGFloat {
            BrowserSettings.application.chromeShape.rowRadius(control)
        }
    }

    nonisolated static let topBarHeight: CGFloat = 44

    static let addressBarMaxWidth: CGFloat = 620

    static func edgeHandle(along axis: Axis) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: accent.opacity(0), location: 0),
                .init(color: accent, location: 0.08),
                .init(color: accent, location: 0.92),
                .init(color: accent.opacity(0), location: 1),
            ],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
    }

    static var edgeHandle: LinearGradient {
        edgeHandle(along: .vertical)
    }

    static func chrome(_ opacity: Double) -> Color {
        Color.primary.opacity(opacity)
    }

    enum Wash {
        static let faint = chrome(0.04)
        static let hairline = chrome(0.06)
        static let hover = chrome(0.08)
        static let selection = chrome(0.12)
        static let strong = chrome(0.16)
        static let emphasis = chrome(0.30)
        static let scrim = chrome(0.55)
    }

    enum Motion {
        static let quick: Animation = .easeOut(duration: 0.12)
        static let settle: Animation = .easeOut(duration: 0.18)
        static let drift: Animation = .easeOut(duration: 0.25)
    }

    enum Font {
        static let title: SwiftUI.Font = .system(size: 13, weight: .medium)
        static let rowTitle: SwiftUI.Font = .system(size: 12.5, weight: .medium)
        static let row: SwiftUI.Font = .system(size: 12.5)
        static let control: SwiftUI.Font = .system(size: 12, weight: .medium)
        static let body: SwiftUI.Font = .system(size: 12)
        static let secondary: SwiftUI.Font = .system(size: 11.5)
        static let label: SwiftUI.Font = .system(size: 11)
        static let caption: SwiftUI.Font = .system(size: 10.5)
        static let mono: SwiftUI.Font = .system(size: 11.5, design: .monospaced)
        static let monoCaption: SwiftUI.Font = .system(size: 10.5, design: .monospaced)
        static let badge: SwiftUI.Font = .system(size: 10, weight: .semibold)
        static let micro: SwiftUI.Font = .system(size: 10)
    }

    /// True while the Calm look is on: a soft tint instead of the page's own color. It follows the theme's ground,
    /// so a copy of Calm stays Calm.
    static var isCalm: Bool {
        resolved.isSoftTinted
    }

    /// `base` with the hue, primary color and brightness of `change` laid over it. The primary color replaces the hue
    /// and, for an accent, the brightness too; surfaces keep their own and borrow at most a little of its saturation.
    static func customized(_ base: NSColor, change: PaletteChange, isAccent: Bool) -> NSColor {
        guard change.isActive, let rgb = base.usingColorSpace(.sRGB) else { return base }
        let primary = change.primary.map {
            NSColor(
                srgbRed: CGFloat(($0 >> 16) & 255) / 255, green: CGFloat(($0 >> 8) & 255) / 255,
                blue: CGFloat($0 & 255) / 255, alpha: 1
            )
        }
        let source = primary ?? rgb
        let hue = (Double(source.hueComponent) + change.hue + 1).truncatingRemainder(dividingBy: 1)
        let saturation = primary == nil ? rgb.saturationComponent
            : (isAccent ? source.saturationComponent : min(source.saturationComponent, 0.35))
        let brightness = (isAccent && primary != nil ? source.brightnessComponent : rgb.brightnessComponent)
            + CGFloat(change.brightness)
        return NSColor(
            hue: CGFloat(hue), saturation: saturation,
            brightness: min(max(brightness, 0), 1), alpha: rgb.alphaComponent
        )
    }

    /// The ink a theme prescribes for control icons and for URL text, nil when a surface should draw its own.
    static var controlOverride: Color? {
        resolved.controlOverride
    }

    static func controlOverride(in windowScheme: ColorScheme) -> Color? {
        resolved.controlOverride(in: windowScheme)
    }

    static var urlOverride: Color? {
        resolved.urlOverride
    }

    static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var materialOpacity: CGFloat = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.alphaValue = materialOpacity
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.alphaValue = materialOpacity
    }
}
