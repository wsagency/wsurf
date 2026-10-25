// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// What a folder looks like to the rows that draw it: its color, and the symbol that stands for it. A person's own
/// color and symbol take the place of the preset color and the plain folder icon; nothing else about drawing changes,
/// so Folder color opacity, Size and Tint Icons as Folder work on them as they do on the presets.
extension TabFolder {
    /// The folder's color before anything has made sure it reads: the color a person chose, else the preset.
    var tint: Color {
        customColor.map { Color(nsColor: $0.nsColor) } ?? color.tint
    }

    /// The color at `opacity`. At 1 it is the color itself, as it always was.
    func tint(opacity: Double) -> Color {
        opacity >= 1 ? tint : tint.opacity(opacity)
    }

    /// The color for drawing an icon on `wash`. A preset is a system color and reads on its own. A color a person chose
    /// can be too close to the sidebar, so it moves toward black or white by the least that reads at 3 to 1, the
    /// contrast an icon needs, before the opacity of Folder color opacity is applied.
    func ink(opacity: Double, on wash: ChromeWash) -> Color {
        guard let custom = customColor else { return color.tint(opacity: opacity) }
        let rgb = custom.nsColor
        let readable = ThemeReadability.guarded(Color(nsColor: rgb), rgb: rgb, on: [wash.groundColor], minimum: 3)
        return opacity >= 1 ? readable : readable.opacity(opacity)
    }

    /// The symbol the folder's row draws. The plain folder opens and shuts; a symbol a person chose is the same either
    /// way, and a symbol this Mac does not have (one chosen on a newer system) is the plain folder.
    func glyph(isOpen: Bool) -> String {
        if let symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return symbol
        }
        return isOpen ? "folder" : "folder.fill"
    }
}
