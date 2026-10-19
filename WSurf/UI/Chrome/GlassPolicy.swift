// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// When chrome glass gives way to an opaque fill. System controls adapt to Reduce Transparency and Increase
/// Contrast by themselves; a custom stack of materials, glass and washes does not, so every such stack asks here.
enum GlassPolicy {
    /// Reduce Transparency asks for opaque surfaces and Increase Contrast for firm edges. Either one replaces
    /// the glass, because a glass surface cannot offer a firm edge over live content.
    nonisolated static func fallsBack(reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        reduceTransparency || contrast == .increased
    }

    /// The opacity of the 1 pt edge on a stand-in for glass: `Theme.Wash.strong`, and `Theme.Wash.emphasis`
    /// under Increase Contrast.
    nonisolated static func borderOpacity(contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.30 : 0.16
    }
}

/// Whether the browser window lets the desktop show through. It follows the same rule as the glass, so a window
/// never paints glass over a desktop that the person asked to hide.
enum WindowOpacity {
    nonisolated static func isOpaque(reduceTransparency: Bool, increaseContrast: Bool) -> Bool {
        GlassPolicy.fallsBack(
            reduceTransparency: reduceTransparency,
            contrast: increaseContrast ? .increased : .standard
        )
    }

    @MainActor
    static var isOpaqueNow: Bool {
        let workspace = NSWorkspace.shared
        return isOpaque(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

private struct ChromeGlass<S: InsettableShape>: ViewModifier {
    let glass: Glass
    let fill: Color
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeHasGlassBackground) private var hasGlassBackground

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass == .identity {
            content
        } else if hasGlassBackground || GlassPolicy.fallsBack(reduceTransparency: reduceTransparency, contrast: contrast) {
            content
                .background { shape.fill(fill) }
                .overlay {
                    shape.strokeBorder(
                        Theme.chrome(GlassPolicy.borderOpacity(contrast: contrast)),
                        lineWidth: 1
                    )
                }
        } else {
            content
                .environment(\.chromeHasGlassBackground, true)
                .glassEffect(glass, in: shape)
        }
    }
}

extension EnvironmentValues {
    /// Controls inside a glass card use fills, because glass cannot sample glass.
    @Entry var chromeHasGlassBackground = false
}

extension View {
    /// Draws the glass of everything inside in one sampling pass instead of one per element. `spacing` is how
    /// close two shapes may come before they merge; 0 keeps neighbors apart.
    func glassGroup(spacing: CGFloat = 0) -> some View {
        GlassEffectContainer(spacing: spacing) { self }
    }

    /// Draws `glass` in `shape`, or an opaque `fill` with a 1 pt border inside glass or while Reduce Transparency
    /// or Increase Contrast is on. Every glass surface in the chrome goes through here, so the policy lives in one place.
    func chromeGlass<S: InsettableShape>(
        _ glass: Glass = .regular,
        fill: Color = Theme.windowBackground,
        in shape: S
    ) -> some View {
        modifier(ChromeGlass(glass: glass, fill: fill, shape: shape))
    }
}
