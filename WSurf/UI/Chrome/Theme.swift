// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

enum Theme {
    private static let standardWindowBackground = adaptive(
        dark: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1),
        light: NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    )
    private static let calmWindowBackground = adaptive(
        dark: NSColor(red: 0.125, green: 0.115, blue: 0.18, alpha: 1),
        light: NSColor(red: 0.86, green: 0.80, blue: 0.79, alpha: 1)
    )
    static var windowBackground: Color {
        isCalm ? calmWindowBackground : standardWindowBackground
    }

    private static let standardControlSurface = adaptive(
        dark: NSColor(white: 0.34, alpha: 1),
        light: NSColor(white: 1, alpha: 1)
    )
    private static let calmControlSurface = adaptive(
        dark: NSColor(red: 0.23, green: 0.20, blue: 0.29, alpha: 1),
        light: NSColor(red: 0.91, green: 0.85, blue: 0.85, alpha: 1)
    )
    static var controlSurface: Color {
        isCalm ? calmControlSurface : standardControlSurface
    }

    private static let standardSidebarTint = adaptive(
        dark: NSColor(red: 0.05, green: 0.05, blue: 0.065, alpha: 1),
        light: NSColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1)
    )
    private static let calmSidebarTint = adaptive(
        dark: NSColor(red: 0.095, green: 0.085, blue: 0.14, alpha: 1),
        light: NSColor(red: 0.78, green: 0.70, blue: 0.74, alpha: 1)
    )
    static var sidebarTint: Color {
        isCalm ? calmSidebarTint : standardSidebarTint
    }

    private static let standardAccent = Color.blue
    private static let calmAccent = adaptive(
        dark: NSColor(red: 0.82, green: 0.63, blue: 0.76, alpha: 1),
        light: NSColor(red: 0.68, green: 0.39, blue: 0.54, alpha: 1)
    )
    static var accent: Color {
        isCalm ? calmAccent : standardAccent
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

    private static let standardSystemAccent = adaptive(
        dark: .controlAccentColor,
        light: .controlAccentColor
    )
    private static let calmSystemAccent = adaptive(
        dark: NSColor(red: 0.82, green: 0.63, blue: 0.76, alpha: 1),
        light: NSColor(red: 0.68, green: 0.39, blue: 0.54, alpha: 1)
    )
    static var systemAccent: Color {
        isCalm ? calmSystemAccent : standardSystemAccent
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

        static func nested(in container: CGFloat, inset: CGFloat) -> CGFloat {
            max(tight, container - inset)
        }

        static var hover: CGFloat {
            control
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

    static var isCalm: Bool {
        switch BrowserSettings.shared.appearance {
        case .lightCalm, .darkCalm:
            true
        case .system, .light, .dark:
            false
        }
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

struct AppKitGlassEffectView: NSViewRepresentable {
    var style: NSGlassEffectView.Style = .clear
    var cornerRadius: CGFloat = 0
    var tintColor: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.contentView = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSGlassEffectView) {
        view.style = style
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
    }
}
