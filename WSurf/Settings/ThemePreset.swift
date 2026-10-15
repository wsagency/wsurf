// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Named color presets. Each color is an exact value from the palette's own
/// published definition; see NOTICE and Acknowledgements for the licenses.
enum ThemePreset: String, CaseIterable, Identifiable {
    case catppuccinLatte
    case catppuccinMocha
    case nord
    case dracula
    case gruvboxLight
    case gruvboxDark
    case rosePine
    case rosePineDawn

    enum Role {
        case window
        case sidebar
        case surface
        case accent
        case text
    }

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .catppuccinLatte:
            "Catppuccin Latte"
        case .catppuccinMocha:
            "Catppuccin Mocha"
        case .nord:
            "Nord"
        case .dracula:
            "Dracula"
        case .gruvboxLight:
            "Gruvbox Light"
        case .gruvboxDark:
            "Gruvbox Dark"
        case .rosePine:
            "Rosé Pine"
        case .rosePineDawn:
            "Rosé Pine Dawn"
        }
    }

    /// Dimming for unloaded tabs. Every preset keeps 4.5:1 text contrast on its sidebar; the light palettes need
    /// more ink, and Rosé Pine Dawn sets the floor.
    var unloadedTextOpacity: Double {
        isDark ? 0.65 : 0.88
    }

    var isDark: Bool {
        switch self {
        case .catppuccinLatte, .gruvboxLight, .rosePineDawn:
            false
        case .catppuccinMocha, .nord, .dracula, .gruvboxDark, .rosePine:
            true
        }
    }

    private struct Hex {
        let window, sidebar, surface, accent, text: UInt32

        init(_ window: UInt32, _ sidebar: UInt32, _ surface: UInt32, _ accent: UInt32, _ text: UInt32) {
            (self.window, self.sidebar, self.surface, self.accent, self.text) = (window, sidebar, surface, accent, text)
        }
    }

    /// sRGB hex values: window, sidebar, control surface, accent, text. Sources: Catppuccin palette 1.8.0
    /// (base, mantle, surface0, mauve, text); Nord (nord1, nord0, nord2, nord8, nord4); Dracula (background,
    /// selection, purple, foreground); Gruvbox as published in tinted-theming/schemes spec-0.11 (light:
    /// light-medium base00, light-soft base00, base01, base0D, base06; dark: dark-medium base00, dark-hard
    /// base00, base01, base0D, base06); Rosé Pine @rose-pine/palette 4.0.1 `dist/index.js` (dawn text is 575279
    /// there; the repository's palette.json still lists the older 464261).
    private var hex: Hex {
        switch self {
        case .catppuccinLatte:
            Hex(0xEFF1F5, 0xE6E9EF, 0xCCD0DA, 0x8839EF, 0x4C4F69)
        case .catppuccinMocha:
            Hex(0x1E1E2E, 0x181825, 0x313244, 0xCBA6F7, 0xCDD6F4)
        case .nord:
            Hex(0x3B4252, 0x2E3440, 0x434C5E, 0x88C0D0, 0xD8DEE9)
        case .dracula:
            Hex(0x282A36, 0x282A36, 0x44475A, 0xBD93F9, 0xF8F8F2)
        case .gruvboxLight:
            Hex(0xFBF1C7, 0xF2E5BC, 0xEBDBB2, 0x076678, 0x3C3836)
        case .gruvboxDark:
            Hex(0x282828, 0x1D2021, 0x3C3836, 0x83A598, 0xEBDBB2)
        case .rosePine:
            Hex(0x1F1D2E, 0x191724, 0x26233A, 0xC4A7E7, 0xE0DEF4)
        case .rosePineDawn:
            Hex(0xFAF4ED, 0xF2E9E1, 0xFFFAF3, 0x286983, 0x575279)
        }
    }

    func rgb(_ role: Role) -> UInt32 {
        switch role {
        case .window:
            hex.window
        case .sidebar:
            hex.sidebar
        case .surface:
            hex.surface
        case .accent:
            hex.accent
        case .text:
            hex.text
        }
    }

    func nsColor(_ role: Role) -> NSColor {
        let value = rgb(role)
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255,
            alpha: 1
        )
    }

    /// The preset color in the appearance it was designed for. A window forced
    /// into the opposite appearance, such as a private one, keeps `fallback`.
    func color(_ role: Role, fallback: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard (appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == self.isDark else {
                var resolved = NSColor(fallback)
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(fallback).usingColorSpace(.sRGB) ?? resolved
                }
                return resolved
            }
            return self.nsColor(role)
        })
    }
}
