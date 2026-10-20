// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

private struct SidebarRowSelectionEffect: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool
    var hoverTint: Color?
    var glassTint: Color?
    var radius = Theme.Radius.hover
    /// The theme's edge for marked rows. Only Standard wears glass.
    var frame = FrameStyle.standard

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowColorScheme) private var windowColorScheme
    @Environment(\.chromeWash) private var wash
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    private var fill: AnyShapeStyle {
        guard isHovering, !isSelected else { return AnyShapeStyle(.clear) }
        if let hoverTint {
            return AnyShapeStyle(hoverTint.opacity(0.18))
        }
        return ChromeInk.hoverStyle(on: wash)
    }

    private var wearsGlass: Bool {
        isSelected && frame == .standard
    }

    private var wearsPanelGlass: Bool {
        windowColorScheme == .dark
    }

    private var glass: Glass {
        if wearsPanelGlass {
            guard let glassTint else { return .regular }
            return .regular.tint(glassTint.opacity(0.32))
        }
        let base = glassTint ?? Theme.windowBackground
        return .regular.tint(base.opacity(glassTint == nil ? 0.34 : 0.16))
    }

    /// What a selected row shows while Reduce Transparency or Increase Contrast replaces its glass.
    private var solidFill: Color {
        guard let glassTint else { return Theme.controlSurface }
        return Theme.controlSurface.mix(with: glassTint, by: 0.32)
    }

    private var surfaceWash: Color {
        guard let glassTint else { return Color.primary.opacity(0.06) }
        return glassTint.opacity(0.10)
    }

    private var surfaceEdge: Color {
        guard let glassTint else { return Color.primary.opacity(0.12) }
        return glassTint.opacity(0.24)
    }

    /// The edge of a marked row without glass: one pixel for Thin edge and none for None. Increase Contrast gives both
    /// a firm 1 pt edge, so a marked row never relies on its fill alone.
    private var plainEdge: (color: Color, width: CGFloat)? {
        if contrast == .increased {
            return (Theme.chrome(GlassPolicy.borderOpacity(contrast: contrast)), 1)
        }
        return frame == .hairline ? (surfaceEdge, 1 / displayScale) : nil
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                ZStack {
                    if wearsGlass {
                        Color.clear.chromeGlass(glass, fill: solidFill, in: shape)
                        if !wearsPanelGlass {
                            shape.fill(surfaceWash)
                            shape.strokeBorder(surfaceEdge, lineWidth: 1)
                        }
                    } else if isSelected {
                        shape.fill(solidFill)
                        if let plainEdge {
                            shape.strokeBorder(plainEdge.color, lineWidth: plainEdge.width)
                        }
                    }
                    shape.fill(fill)
                }
                .environment(\.colorScheme, windowColorScheme)
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func sidebarHoverFill<S: InsettableShape>(
        isHovering: Bool,
        tint: Color? = nil,
        in shape: S
    ) -> some View {
        hoverBackground(isActive: isHovering, tint: tint, in: shape)
            .contentShape(shape)
    }
}

extension View {
    func sidebarRowSelectionEffect(
        isSelected: Bool,
        isHovering: Bool,
        hoverTint: Color? = nil,
        glassTint: Color? = nil,
        radius: CGFloat = Theme.Radius.row,
        frame: FrameStyle = BrowserSettings.application.chromeShape.rowFrame
    ) -> some View {
        modifier(SidebarRowSelectionEffect(
            isSelected: isSelected,
            isHovering: isHovering,
            hoverTint: hoverTint,
            glassTint: glassTint,
            radius: radius,
            frame: frame
        ))
    }
}
