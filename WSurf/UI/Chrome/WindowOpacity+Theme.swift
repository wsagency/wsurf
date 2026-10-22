// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

extension WindowOpacity {
    static func isOpaque(
        ground: ThemeGround, material: ThemeMaterial, reduceTransparency: Bool, increaseContrast: Bool
    ) -> Bool {
        isOpaque(reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
            || (ground == .solid && material == .plain)
    }

    static var isOpaqueForThemeNow: Bool {
        let theme = BrowserSettings.application.resolvedTheme
        let workspace = NSWorkspace.shared
        return isOpaque(
            ground: theme.ground, material: theme.material,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }
}
