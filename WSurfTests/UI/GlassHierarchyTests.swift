// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

@MainActor
struct GlassHierarchyTests {
    private let fill = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)

    private func bitmap(of view: some View, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard))
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    private func expectColor(_ actual: NSColor, _ expected: NSColor) {
        let actual = actual.usingColorSpace(.sRGB) ?? actual
        let expected = expected.usingColorSpace(.sRGB) ?? expected
        #expect(actual.alphaComponent == 1)
        // AppKit's display bitmap can shift a few levels when converted back to sRGB.
        #expect(abs(actual.redComponent - expected.redComponent) < 0.03)
        #expect(abs(actual.greenComponent - expected.greenComponent) < 0.03)
        #expect(abs(actual.blueComponent - expected.blueComponent) < 0.03)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func nestedGlassPaintsItsOpaqueFill(scheme: ColorScheme) throws {
        let surface = Color.clear
            .frame(width: 40, height: 30)
            .chromeGlass(fill: Color(nsColor: fill), in: Rectangle())
            .padding(15)
            .chromeGlass(in: Rectangle())
        let image = try bitmap(of: surface, scheme: scheme)

        expectColor(try #require(image.colorAt(x: 40, y: 30)), fill)
    }

    /// The Update banner puts a lifted Settings control inside its glass card. Its inner surface must draw the
    /// same solid center as the accessibility stand-in, not another system glass effect.
    @Test(arguments: [ColorScheme.light, .dark], [true, false])
    func aControlInsideGlassUsesItsSolidStandIn(scheme: ColorScheme, isActive: Bool) throws {
        let control = Color.clear
            .frame(width: 40, height: 30)
            .controlGlassSurface(isActive: isActive, isLifted: true, in: Rectangle())
        let nested = try bitmap(
            of: control.padding(15).chromeGlass(in: Rectangle()),
            scheme: scheme
        )
        let solid = try bitmap(
            of: control.padding(15).environment(\._accessibilityReduceTransparency, true),
            scheme: scheme
        )

        expectColor(
            try #require(nested.colorAt(x: 40, y: 30)),
            try #require(solid.colorAt(x: 40, y: 30))
        )
    }

    @Test func onlyRealGlassMarksItsOwnContent() throws {
        let surfaces = HStack(spacing: 0) {
            GlassContextProbe().chromeGlass(in: Rectangle())
            GlassContextProbe().chromeGlass(.identity, in: Rectangle())
            GlassContextProbe()
                .chromeGlass(in: Rectangle())
                .environment(\._accessibilityReduceTransparency, true)
            GlassContextProbe()
        }
        let image = try bitmap(of: surfaces, scheme: .light)

        expectColor(try #require(image.colorAt(x: 10, y: 30)), .white)
        for x in [30, 50, 70] {
            expectColor(try #require(image.colorAt(x: x, y: 30)), .black)
        }
    }

    @Test func identityInsideGlassRemainsUnpainted() throws {
        let surface = Color.clear
            .frame(width: 40, height: 30)
            .chromeGlass(.identity, fill: .white, in: Rectangle())
            .padding(15)
            .background(Color(nsColor: fill))
            .chromeGlass(in: Rectangle())
        let image = try bitmap(of: surface, scheme: .light)

        expectColor(try #require(image.colorAt(x: 40, y: 30)), fill)
    }
}

private struct GlassContextProbe: View {
    @Environment(\.chromeHasGlassBackground) private var hasGlassBackground

    var body: some View {
        (hasGlassBackground ? Color.white : Color.black)
            .frame(width: 20, height: 60)
    }
}
