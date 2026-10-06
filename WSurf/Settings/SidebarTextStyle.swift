// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct SidebarTextStyle: Codable, Equatable {
    var colorRGB: UInt32?
    var opacity: Double = 1

    var color: Color? {
        colorRGB.map {
            Color(
                red: Double(($0 >> 16) & 255) / 255,
                green: Double(($0 >> 8) & 255) / 255,
                blue: Double($0 & 255) / 255
            )
        }
    }

    func bounded(defaultOpacity: Double) -> Self {
        Self(
            colorRGB: colorRGB.flatMap { $0 <= 0xFFFFFF ? $0 : nil },
            opacity: opacity.isFinite ? min(max(opacity, 0), 1) : defaultOpacity
        )
    }
}

extension BrowserSettings {
    func sidebarAppearance(scheme: ColorScheme) -> AppearanceMode {
        if forcesDarkAppearance {
            return appearance == .lightCalm || appearance == .darkCalm ? .darkCalm : .dark
        }
        return appearance == .system ? (scheme == .dark ? .dark : .light) : appearance
    }

    func sidebarTextStyle(theme: AppearanceMode, isDeferred: Bool) -> SidebarTextStyle {
        sidebarTextStyles[Self.sidebarTextKey(theme: theme, isDeferred: isDeferred)]
            ?? SidebarTextStyle(opacity: isDeferred ? 0.55 : 1)
    }

    func setSidebarTextStyle(_ style: SidebarTextStyle, theme: AppearanceMode, isDeferred: Bool) {
        sidebarTextStyles[Self.sidebarTextKey(theme: theme, isDeferred: isDeferred)] = style.bounded(
            defaultOpacity: isDeferred ? 0.55 : 1
        )
    }

    func sidebarTextBaseColor(theme: AppearanceMode, isDeferred: Bool) -> Color {
        sidebarTextStyle(theme: theme, isDeferred: isDeferred).color
            ?? (theme == .dark || theme == .darkCalm ? .white : .black)
    }

    func sidebarTextColor(isDeferred: Bool = false, scheme: ColorScheme) -> Color {
        let theme = sidebarAppearance(scheme: scheme)
        let style = sidebarTextStyle(theme: theme, isDeferred: isDeferred)
        return (style.color ?? (scheme == .dark ? .white : .black)).opacity(style.opacity)
    }

    func setSidebarTextColor(_ color: Color, theme: AppearanceMode, isDeferred: Bool) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB),
              rgb.redComponent.isFinite, rgb.greenComponent.isFinite, rgb.blueComponent.isFinite
        else { return }
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        var style = sidebarTextStyle(theme: theme, isDeferred: isDeferred)
        style.colorRGB = channel(rgb.redComponent) << 16
            | channel(rgb.greenComponent) << 8
            | channel(rgb.blueComponent)
        setSidebarTextStyle(style, theme: theme, isDeferred: isDeferred)
    }

    static func sidebarTextKey(theme: AppearanceMode, isDeferred: Bool) -> String {
        "\(theme.rawValue).\(isDeferred ? "unloaded" : "loaded")"
    }

    static func decodeSidebarTextStyles(_ data: Data?) -> [String: SidebarTextStyle] {
        guard let data, let stored = try? JSONDecoder().decode([String: SidebarTextStyle].self, from: data) else {
            return [:]
        }
        return stored.mapValues { $0.bounded(defaultOpacity: 1) }
    }
}
