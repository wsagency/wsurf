// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Draws the row ink through SwiftUI, so the parts that `SidebarRowStyleTests` cannot reach are covered: that a
/// row reads the sidebar ground from its environment, that the fill is painted, and that the content of an
/// inverse row sees the environment of the fill.
@MainActor
struct SidebarRowInkRenderTests {
    private final class Box<Value> {
        var value: Value?
    }

    private struct InkProbe: View {
        let style: SidebarRowStyle
        let box: Box<SidebarRowInk>
        private var source = SidebarRowInkSource()

        init(style: SidebarRowStyle, box: Box<SidebarRowInk>) {
            self.style = style
            self.box = box
        }

        var body: some View {
            box.value = source.ink(for: style)
            return Color.clear.frame(width: 4, height: 4)
        }
    }

    private struct Seen {
        var scheme: ColorScheme = .light
        var isLight = false
        var ignoresOverride = false
    }

    private struct EnvironmentProbe: View {
        let box: Box<Seen>
        @Environment(\.colorScheme) private var scheme
        @Environment(\.chromeIsLight) private var isLight
        @Environment(\.ignoresControlOverride) private var ignoresOverride

        var body: some View {
            box.value = Seen(scheme: scheme, isLight: isLight, ignoresOverride: ignoresOverride)
            return Color.clear.frame(width: 4, height: 4)
        }
    }

    private let darkGround = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.125, alpha: 1)
    private let lightGround = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.955, alpha: 1)
    private let blue = NSColor(srgbRed: 0, green: 0.35, blue: 1, alpha: 1)

    private func current() -> SidebarRowStyle {
        SidebarRowStyle.resolve(
            isCurrent: true, isMarked: false, isUnseen: false, paletteOpen: false, increasedContrast: false
        )
    }

    private func pixel(of view: some View, at point: CGPoint) throws -> NSColor {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try #require(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
        return color
    }

    @Test func aRowReadsTheSidebarGroundFromItsEnvironment() throws {
        let box = Box<SidebarRowInk>()
        let view = InkProbe(style: current(), box: box)
            .environment(\.chromeWash, .of(darkGround, isLight: false))
            .environment(\.colorScheme, .dark)
        _ = ImageRenderer(content: view).nsImage

        let colors = try #require(box.value?.colors)
        #expect(SidebarRowStyle.contrast(colors.content, darkGround) < 1.01, "the content is the sidebar ground")
        #expect(colors.fillIsLight, "dark text on a dark sidebar is white, so the fill is light")
        #expect(SidebarRowStyle.contrast(colors.fill, darkGround) > 10)
    }

    @Test func aLightSidebarGetsADarkFill() throws {
        let box = Box<SidebarRowInk>()
        let view = InkProbe(style: current(), box: box)
            .environment(\.chromeWash, .of(lightGround, isLight: true))
            .environment(\.colorScheme, .light)
        _ = ImageRenderer(content: view).nsImage

        let colors = try #require(box.value?.colors)
        #expect(!colors.fillIsLight)
        #expect(SidebarRowStyle.contrast(colors.fill, lightGround) > 10)
    }

    @Test func theCurrentRowIsPaintedWithItsFill() throws {
        let colors = SidebarRowStyle.colors(
            text: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), ground: darkGround, accent: blue
        )
        let ink = SidebarRowInk(style: current(), resting: .white, colors: colors)
        let view = Color.clear
            .frame(width: 40, height: 24)
            .sidebarInverse(ink, in: Rectangle())
            .environment(\.colorScheme, .dark)

        let painted = try pixel(of: view, at: CGPoint(x: 20, y: 12))

        #expect(painted.redComponent > 0.98 && painted.greenComponent > 0.98 && painted.blueComponent > 0.98)
    }

    @Test func aRowThatIsNotCurrentIsNotPainted() throws {
        let resting = SidebarRowStyle.resolve(
            isCurrent: false, isMarked: false, isUnseen: false, paletteOpen: false, increasedContrast: false
        )
        let ink = SidebarRowInk(style: resting, resting: .white, colors: nil)
        let view = Color.clear
            .frame(width: 40, height: 24)
            .sidebarInverse(ink, in: Rectangle())
            .background(Color(red: 0, green: 1, blue: 0))

        let painted = try pixel(of: view, at: CGPoint(x: 20, y: 12))

        #expect(painted.greenComponent > 0.4 && painted.redComponent < 0.1, "only the base shows through")
    }

    @Test func theContentOfTheCurrentRowSeesTheEnvironmentOfTheFill() throws {
        let colors = SidebarRowStyle.colors(
            text: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), ground: darkGround, accent: blue
        )
        let box = Box<Seen>()
        let ink = SidebarRowInk(style: current(), resting: .white, colors: colors)
        let view = EnvironmentProbe(box: box)
            .sidebarInverse(ink, in: Rectangle())
            .environment(\.colorScheme, .dark)
            .environment(\.chromeIsLight, false)
        _ = ImageRenderer(content: view).nsImage

        let seen = try #require(box.value)
        #expect(seen.scheme == .light, "a white fill is a light surface")
        #expect(seen.isLight)
        #expect(seen.ignoresOverride, "the saved control color was chosen for the sidebar, not for the fill")
    }

    @Test func theContentOfAnotherRowKeepsTheSidebarEnvironment() throws {
        let box = Box<Seen>()
        let resting = SidebarRowStyle.resolve(
            isCurrent: false, isMarked: true, isUnseen: false, paletteOpen: false, increasedContrast: false
        )
        let ink = SidebarRowInk(style: resting, resting: .white, colors: nil)
        let view = EnvironmentProbe(box: box)
            .sidebarInverse(ink, in: Rectangle())
            .environment(\.colorScheme, .dark)
            .environment(\.chromeIsLight, false)
        _ = ImageRenderer(content: view).nsImage

        let seen = try #require(box.value)
        #expect(seen.scheme == .dark)
        #expect(!seen.isLight)
        #expect(!seen.ignoresOverride)
    }

    @Test func theNewTabDotIsDrawnOnTheIconsTrailingEdge() throws {
        let colors = SidebarRowStyle.colors(
            text: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), ground: darkGround, accent: blue
        )
        let unseen = SidebarRowStyle.resolve(
            isCurrent: false, isMarked: false, isUnseen: true, paletteOpen: false, increasedContrast: false
        )
        let ink = SidebarRowInk(style: unseen, resting: .white, colors: colors, ground: Color(nsColor: darkGround))
        // The dot's middle is on the icon's trailing edge, 2 pt below its top: here (48, 10) in the frame of a
        // 40 x 40 padded canvas. Its ring reaches 2 pt above the icon, to y = 6.
        let view = Color.clear
            .frame(width: 40, height: 40)
            .sidebarNewMark(ink)
            .padding(8)
            .background(Color(red: 0, green: 1, blue: 0))

        let atMiddle = try pixel(of: view, at: CGPoint(x: 48, y: 10))
        let aboveRing = try pixel(of: view, at: CGPoint(x: 48, y: 5))
        let awayFromIt = try pixel(of: view, at: CGPoint(x: 28, y: 28))

        #expect(atMiddle.blueComponent > 0.9 && atMiddle.greenComponent < 0.5, "the dot is the accent blue")
        #expect(aboveRing.greenComponent > 0.4 && aboveRing.blueComponent < 0.1, "the dot stays near the icon")
        #expect(awayFromIt.greenComponent > 0.4 && awayFromIt.blueComponent < 0.1, "the rest of the icon is untouched")
    }

    @Test func aRowThatIsNotNewHasNoDot() throws {
        let resting = SidebarRowStyle.resolve(
            isCurrent: false, isMarked: false, isUnseen: false, paletteOpen: false, increasedContrast: false
        )
        let ink = SidebarRowInk(style: resting, resting: .white, colors: nil)
        let view = Color.clear
            .frame(width: 40, height: 40)
            .sidebarNewMark(ink)
            .padding(8)
            .background(Color(red: 0, green: 1, blue: 0))

        let corner = try pixel(of: view, at: CGPoint(x: 48, y: 8))
        #expect(corner.greenComponent > 0.4 && corner.redComponent < 0.1, "only the base shows through")
    }
}
