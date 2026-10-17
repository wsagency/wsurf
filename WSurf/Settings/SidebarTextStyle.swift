// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct SidebarTextStyle: Codable, Equatable {
    var colorRGB: UInt32?
    var opacity: Double = 1

    var color: Color? {
        colorRGB.map(Color.init(hex:))
    }

    func bounded(defaultOpacity: Double) -> Self {
        Self(
            colorRGB: colorRGB.flatMap { $0 <= 0xFFFFFF ? $0 : nil },
            opacity: opacity.isFinite ? min(max(opacity, 0), 1) : defaultOpacity
        )
    }

    /// `0xRRGGBB` for `color`, or nil when it has no finite sRGB value.
    static func rgb(of color: Color) -> UInt32? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB),
              rgb.redComponent.isFinite, rgb.greenComponent.isFinite, rgb.blueComponent.isFinite
        else { return nil }
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
    }

    mutating func setColor(_ color: Color) {
        guard let rgb = Self.rgb(of: color) else { return }
        colorRGB = rgb
    }
}

extension BrowserSettings {
    static func nativeSidebarFont(family: String, size: CGFloat, weight: SidebarFontWeight) -> NSFont {
        guard !family.isEmpty else { return .systemFont(ofSize: size, weight: weight.nativeWeight) }
        return NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: weight.appKitWeight,
            size: size
        ) ?? .systemFont(ofSize: size, weight: weight.nativeWeight)
    }

    /// The text color of a sidebar row in the appearance `scheme` names, from the cached theme.
    func sidebarTextColor(isDeferred: Bool = false, scheme: ColorScheme) -> Color {
        let variant = resolvedTheme.variant(scheme)
        return isDeferred ? variant.unloadedInk : variant.loadedInk
    }
}
