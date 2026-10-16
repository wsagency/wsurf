// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// What a row draws with for its `SidebarRowStyle`: the text color, the inverse fill of a current row, and the
/// environment that row's content draws in. The colors come from `SidebarRowStyle.colors`.
struct SidebarRowInk {
    /// How the content of a row on an inverse fill sees its surroundings. The fill is the row's own ground, so
    /// icons, hover washes and `.secondary` text follow it instead of the sidebar.
    struct Inverse {
        let fill: Color
        let scheme: ColorScheme
        let isLight: Bool
        let wash: ChromeWash
    }

    let style: SidebarRowStyle
    /// Title and icon color of a row that is not inverse.
    let resting: Color
    let colors: SidebarRowStyle.Colors?
    /// The sidebar behind the row. It rings the new-tab dot so the dot does not run into the icon.
    var ground: Color = .clear

    var inverse: Inverse? {
        guard style.emphasis == .current, let colors else { return nil }
        return Inverse(
            fill: Color(nsColor: colors.fill),
            scheme: colors.fillIsLight ? .light : .dark,
            isLight: colors.fillIsLight,
            wash: .of(colors.fill, isLight: colors.fillIsLight)
        )
    }

    /// Title and icon color: the sidebar ground on an inverse row, the sidebar's text color otherwise.
    var text: Color {
        guard style.emphasis == .current, let colors else { return resting }
        return Color(nsColor: colors.content)
    }

    /// The new-tab dot: the accent where it shows against the sidebar, ink otherwise.
    var mark: Color? {
        colors?.mark(style.mark).map { Color(nsColor: $0) }
    }

    /// A heavier title says a tab is new without relying on color.
    var titleFont: Font {
        let settings = BrowserSettings.application
        return style.mark == .none ? settings.sidebarFont : settings.sidebarEmphasizedFont
    }

    /// The badge of a collapsed folder that holds the current tab: the same two colors, on a small shape.
    var badge: (fill: Color, text: Color)? {
        guard style.marksCurrentTab, let colors else { return nil }
        return (Color(nsColor: colors.fill), Color(nsColor: colors.content))
    }
}

/// What a row reads from its surroundings to draw a `SidebarRowStyle`. Every kind of row keeps one, so none of
/// them reads the environment on its own.
struct SidebarRowInkSource: DynamicProperty {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chromeWash) private var wash
    @Environment(\.colorSchemeContrast) private var contrast

    var increasedContrast: Bool {
        contrast == .increased
    }

    func ink(for style: SidebarRowStyle, isDeferred: Bool = false) -> SidebarRowInk {
        let settings = BrowserSettings.application
        let resting = settings.sidebarTextColor(isDeferred: isDeferred, scheme: scheme)
        guard style.emphasis == .current || style.marksCurrentTab || style.mark != .none else {
            return SidebarRowInk(style: style, resting: resting, colors: nil)
        }
        return SidebarRowInk(
            style: style,
            resting: resting,
            colors: SidebarRowStyle.colors(
                text: SidebarRowStyle.srgb(settings.sidebarTextColor(scheme: scheme), scheme: scheme),
                ground: wash.groundColor,
                accent: SidebarRowStyle.srgb(Theme.accent, scheme: scheme)
            ),
            ground: Color(nsColor: wash.groundColor)
        )
    }
}

/// The dot on a new tab, ringed in the sidebar color.
private struct SidebarNewMark: View {
    let color: Color
    let ring: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background { Circle().fill(ring).padding(-1) }
            .offset(x: 3, y: -3)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The new-tab dot on the top trailing corner of an icon. A row that is not new is left as it is.
    func sidebarNewMark(_ ink: SidebarRowInk) -> some View {
        overlay(alignment: .topTrailing) {
            if let mark = ink.mark {
                SidebarNewMark(color: mark, ring: ink.ground)
            }
        }
    }

    /// Tells VoiceOver that a row is selected and what it holds. Put it on the element that carries the row's
    /// name: its title, or its icon in the icons-only sidebar.
    func sidebarRowAccessibility(_ style: SidebarRowStyle) -> some View {
        accessibilityAddTraits(style.isSelected ? .isSelected : [])
            .accessibilityValue(style.spokenStatus ?? "")
    }

    /// The icon of a row that has no title on screen: it names the row and carries its state.
    @ViewBuilder
    func sidebarRowName(_ name: String, style: SidebarRowStyle, isIconOnly: Bool) -> some View {
        if isIconOnly {
            accessibilityLabel(Text(verbatim: name))
                .sidebarRowAccessibility(style)
        } else {
            self
        }
    }

    /// Fills `shape` with the inverse fill of a current row and draws the content in the environment of that
    /// fill. A row that is not current is left as it is.
    func sidebarInverse<S: Shape>(_ ink: SidebarRowInk, in shape: S) -> some View {
        modifier(SidebarInverseRow(inverse: ink.inverse, shape: shape))
    }
}

private struct SidebarInverseRow<S: Shape>: ViewModifier {
    let inverse: SidebarRowInk.Inverse?
    let shape: S

    @Environment(\.colorScheme) private var scheme
    @Environment(\.chromeIsLight) private var isLight
    @Environment(\.chromeWash) private var wash

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, inverse?.scheme ?? scheme)
            .environment(\.chromeIsLight, inverse?.isLight ?? isLight)
            .environment(\.chromeWash, inverse?.wash ?? wash)
            .environment(\.ignoresControlOverride, inverse != nil)
            .background {
                if let inverse {
                    shape.fill(inverse.fill)
                }
            }
    }
}
