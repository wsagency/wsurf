// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct ThemeCustomization: Codable, Equatable {
    var brightness: Double = 0
    var hue: Double = 0
    var primary = SidebarTextStyle()
    var controls = SidebarTextStyle()
    var url = SidebarTextStyle()

    var changesPalette: Bool {
        brightness != 0 || hue != 0 || primary.colorRGB != nil
    }

    func bounded() -> Self {
        var result = self
        result.brightness = brightness.isFinite ? min(max(brightness, -0.5), 0.5) : 0
        result.hue = hue.isFinite ? min(max(hue, -0.5), 0.5) : 0
        result.primary = primary.bounded(defaultOpacity: 1)
        result.controls = controls.bounded(defaultOpacity: 1)
        result.url = url.bounded(defaultOpacity: 1)
        return result
    }
}

extension BrowserSettings {
    func themeCustomization(theme: AppearanceMode) -> ThemeCustomization {
        themeCustomizations[theme.rawValue] ?? ThemeCustomization()
    }

    func setThemeCustomization(_ customization: ThemeCustomization, theme: AppearanceMode) {
        themeCustomizations[theme.rawValue] = customization.bounded()
    }

    func resetThemeCustomization(theme: AppearanceMode) {
        themeCustomizations.removeValue(forKey: theme.rawValue)
    }

    var currentThemeCustomization: ThemeCustomization {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return themeCustomization(theme: sidebarAppearance(scheme: dark ? .dark : .light))
    }
}

extension SidebarTextStyle {
    mutating func setColor(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB),
              rgb.redComponent.isFinite, rgb.greenComponent.isFinite, rgb.blueComponent.isFinite
        else { return }
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        colorRGB = channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
    }
}
