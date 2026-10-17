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

/// The dot on a new tab, ringed in the sidebar color. Its middle is on the icon's trailing edge, 2 pt below the top
/// of the icon, so the ring reaches 2 pt above it and stays inside the row at the shortest height.
private struct SidebarNewMark: View {
    let color: Color
    let ring: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background { Circle().fill(ring).padding(-1) }
            .offset(x: 3, y: -1)
            .accessibilityHidden(true)
    }
}

/// Holds one title so that the middle of its letters is the middle of the layout. An alignment guide would move the
/// title, but the row would still center the bounds of everything in it, and those are lopsided once the title is
/// moved. Here the bounds are balanced around the middle of the letters, so the row centers that.
private struct SidebarTitleLayout: Layout {
    /// How far above the baseline the middle of the letters is. `nil` keeps the title centered on its own box.
    let midline: CGFloat?

    private func measure(_ subview: LayoutSubview, in proposal: ProposedViewSize) -> (size: CGSize, middle: CGFloat) {
        let dimensions = subview.dimensions(in: proposal)
        let middle = midline.map { dimensions[.firstTextBaseline] - $0 } ?? dimensions.height / 2
        return (CGSize(width: dimensions.width, height: dimensions.height), middle)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let (size, middle) = measure(subview, in: proposal)
        return CGSize(width: size.width, height: 2 * max(middle, size.height - middle))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let (size, middle) = measure(subview, in: proposal)
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY - middle),
            proposal: ProposedViewSize(width: bounds.width, height: size.height)
        )
    }
}

extension View {
    /// Centers a title on the middle of its letters instead of on its line box, which is centered on the capitals
    /// and leaves lowercase text low. Put it on the title in a row, so the icon beside it meets that middle.
    /// A column that grows a second line keeps the center of both lines (`applies: false`).
    func sidebarTitleCentered(_ applies: Bool = true) -> some View {
        SidebarTitleLayout(midline: applies ? BrowserSettings.application.sidebarTitleMidline : nil) { self }
    }

    /// The new-tab dot on the top trailing edge of an icon. A row that is not new is left as it is.
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
