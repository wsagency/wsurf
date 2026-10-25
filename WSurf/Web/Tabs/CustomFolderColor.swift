// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// A folder color that a person chose with the color panel, beyond the nine presets. It is an opaque sRGB color held
/// as three bytes, so two picks of the same color are equal and it is stored as the text `#RRGGBB`.
nonisolated struct CustomFolderColor: Equatable, Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The color as sRGB, whatever space it is in. Its transparency is dropped: a folder color is always solid.
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
    }

    /// `#RRGGBB` or `RRGGBB`; nil for anything else.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
