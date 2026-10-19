// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Custom glass does not adapt to Reduce Transparency or Increase Contrast on its own. These tests cover the rule,
/// the window that follows it, and what each surface draws when the rule says "solid".
@MainActor
struct GlassPolicyTests {
    /// A gray, because a saturated color shifts between the display's color space and sRGB.
    private let fill = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)

    // MARK: - The rule

    @Test func glassFallsBackToSolidUnderReduceTransparency() {
        #expect(GlassPolicy.fallsBack(reduceTransparency: true, contrast: .standard))
        #expect(!GlassPolicy.fallsBack(reduceTransparency: false, contrast: .standard))
    }

    @Test func glassFallsBackToSolidUnderIncreaseContrast() {
        #expect(GlassPolicy.fallsBack(reduceTransparency: false, contrast: .increased))
        #expect(GlassPolicy.fallsBack(reduceTransparency: true, contrast: .increased))
    }

    private func alpha(of color: Color) -> Double {
        Double(NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? -1)
    }

    @Test func increaseContrastStrengthensGlassBorders() {
        let standard = GlassPolicy.borderOpacity(contrast: .standard)
        let increased = GlassPolicy.borderOpacity(contrast: .increased)

        // The wash colors scale the primary ink, which is itself a little transparent, so compare the ratios.
        let washes = alpha(of: Theme.Wash.strong) / alpha(of: Theme.Wash.emphasis)

        #expect(increased > standard)
        #expect(abs(standard / increased - washes) < 0.001)
    }

    // MARK: - The window

    @Test func theWindowIsOpaqueUnderReduceTransparency() {
        #expect(WindowOpacity.isOpaque(reduceTransparency: true, increaseContrast: false))
    }

    @Test func theWindowIsOpaqueUnderIncreaseContrast() {
        #expect(WindowOpacity.isOpaque(reduceTransparency: false, increaseContrast: true))
    }

    @Test func theWindowStaysTranslucentWhenNeitherIsOn() {
        #expect(!WindowOpacity.isOpaque(reduceTransparency: false, increaseContrast: false))
    }

    /// Re-applying the preference is what the system notification triggers, so an opaque window turns
    /// translucent again without a relaunch, and neither state touches the titled frame.
    @Test(.boundedWebViews)
    func theHostsWindowFollowsTheDisplayOptionsLive() throws {
        let app = BrowserApplication()
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        app.register(coordinator)
        defer { coordinator.closeWindow() }
        coordinator.showBrowser(activate: false)
        let window = try #require(coordinator.nativeWindow)
        let host = try #require(window.delegate as? BrowserHost)
        let corners = SystemWindowShape.radius(of: window)
        let hadShadow = window.hasShadow

        host.applyTransparencyPreference(to: window, isOpaque: true)
        #expect(window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 1)
        #expect(window.styleMask.contains(.titled))
        #expect(window.hasShadow == hadShadow)
        #expect(SystemWindowShape.radius(of: window) == corners)

        host.applyTransparencyPreference(to: window, isOpaque: false)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 0)

        // The notification re-reads the system settings, which are off in the test host.
        host.applyTransparencyPreference(to: window, isOpaque: true)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
        #expect(window.isOpaque == WindowOpacity.isOpaqueNow)
    }

    // MARK: - What a solid surface draws

    /// The pixels of `view` as AppKit draws them in an unshown window, top left first.
    private func bitmap(
        of view: some View,
        width: CGFloat,
        height: CGFloat,
        scheme: ColorScheme = .dark
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func isClose(_ a: NSColor, _ b: NSColor) -> Bool {
        let a = a.usingColorSpace(.sRGB) ?? a
        let b = b.usingColorSpace(.sRGB) ?? b
        // A bitmap is in the display's space, so a color shifts by a few levels on the way back to sRGB.
        return abs(a.redComponent - b.redComponent) < 0.03
            && abs(a.greenComponent - b.greenComponent) < 0.03
            && abs(a.blueComponent - b.blueComponent) < 0.03
    }

    private func makeSettings(material: ThemeMaterial) -> (BrowserSettings, UserDefaults, String) {
        let suite = "GlassPolicy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = BrowserSettings(defaults: defaults)
        settings.themeMaterial = material
        return (settings, defaults, suite)
    }

    @Test(arguments: [ThemeMaterial.plain, .glass], [true, false])
    func aReducedTransparencyBackdropIsOneSolidColor(material: ThemeMaterial, isFloating: Bool) throws {
        let (settings, defaults, suite) = makeSettings(material: material)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backdrop = LoomBackdrop(sampledPageColor: nil, settings: settings, isFloating: isFloating, fallsBack: true)

        for scheme in [ColorScheme.light, .dark] {
            let expected = LoomChrome.sampledColor(nil, scheme: scheme, isFloating: isFloating)
            let image = try bitmap(of: backdrop, width: 48, height: 32, scheme: scheme)

            var wrong = 0
            var first = "none"
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    let pixel = try #require(image.colorAt(x: x, y: y))
                    if pixel.alphaComponent != 1 || !isClose(pixel, expected) {
                        if wrong == 0 {
                            first = "(\(x), \(y)) \(pixel)"
                        }
                        wrong += 1
                    }
                }
            }
            #expect(wrong == 0, "\(wrong) pixels are not the opaque \(expected) in \(scheme); first \(first)")
        }
    }

    /// The same backdrops reached the way the window reaches them: through the environment the system fills in.
    @Test func theWindowBackdropsGoSolidWhenTheEnvironmentAsksForIt() throws {
        let (settings, defaults, suite) = makeSettings(material: .glass)
        defer { defaults.removePersistentDomain(forName: suite) }

        let ambient = LoomAmbientBackdrop(sampledPageColor: nil, settings: settings)
            .environment(\._accessibilityReduceTransparency, true)
        let floating = LoomFloatingFill(sampledPageColor: nil, settings: settings)
            .environment(\._colorSchemeContrast, .increased)

        let ambientPixel = try #require(bitmap(of: ambient, width: 24, height: 24).colorAt(x: 12, y: 12))
        let floatingPixel = try #require(bitmap(of: floating, width: 24, height: 24).colorAt(x: 12, y: 12))

        let ambientColor = LoomChrome.sampledColor(nil, scheme: .dark)
        let floatingColor = LoomChrome.sampledColor(nil, scheme: .dark, isFloating: true)
        #expect(ambientPixel.alphaComponent == 1)
        #expect(floatingPixel.alphaComponent == 1)
        #expect(isClose(ambientPixel, ambientColor), "\(ambientPixel) is not \(ambientColor)")
        #expect(isClose(floatingPixel, floatingColor), "\(floatingPixel) is not \(floatingColor)")
    }

    @Test func aGlassStandInPaintsItsFillAndAnEdge() throws {
        let surface = Color.clear
            .frame(width: 40, height: 30)
            .chromeGlass(fill: Color(nsColor: fill), in: Rectangle())
            .environment(\._accessibilityReduceTransparency, true)

        let image = try bitmap(of: surface, width: 40, height: 30, scheme: .light)
        let middle = try #require(image.colorAt(x: 20, y: 15))
        let edge = try #require(image.colorAt(x: 20, y: 0))

        #expect(isClose(middle, fill), "\(middle) is not the fill")
        #expect(!isClose(edge, fill), "the 1 pt border should tint the edge row")
    }

    @Test func increaseContrastDrawsAFirmerEdgeThanReduceTransparencyAlone() throws {
        let surface = Color.clear
            .frame(width: 40, height: 30)
            .chromeGlass(fill: Color(nsColor: fill), in: Rectangle())

        let reduced = try bitmap(
            of: surface.environment(\._accessibilityReduceTransparency, true),
            width: 40, height: 30, scheme: .light
        )
        let contrasted = try bitmap(
            of: surface.environment(\._colorSchemeContrast, .increased),
            width: 40, height: 30, scheme: .light
        )

        // A darker edge over the fill leaves a darker pixel.
        let calmEdge = try #require(reduced.colorAt(x: 20, y: 0)).brightnessComponent
        let firmEdge = try #require(contrasted.colorAt(x: 20, y: 0)).brightnessComponent
        #expect(firmEdge < calmEdge)
    }

    @Test func anIdentityGlassIsNotPaintedEvenWhenSolid() throws {
        let surface = Color.clear
            .frame(width: 40, height: 30)
            .chromeGlass(.identity, fill: Color(nsColor: fill), in: Rectangle())
            .environment(\._accessibilityReduceTransparency, true)

        let image = try bitmap(of: surface, width: 40, height: 30)
        let middle = try #require(image.colorAt(x: 20, y: 15))

        #expect(middle.alphaComponent == 0)
    }

    // MARK: - Grouping

    private func fittingSize(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    private func glassRows() -> some View {
        VStack(spacing: 2) {
            ForEach(0..<6) { index in
                Text(verbatim: "Row \(index)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 24 + CGFloat(index))
                    .chromeGlass(index.isMultiple(of: 2) ? .regular : .identity, in: Rectangle())
            }
        }
    }

    /// A container only changes how glass is sampled. Sidebar rows and cards must keep the size they had.
    @Test func groupingGlassLeavesLayoutAlone() {
        #expect(fittingSize(glassRows().frame(width: 200)) == fittingSize(glassRows().glassGroup().frame(width: 200)))
        #expect(fittingSize(glassRows()) == fittingSize(glassRows().glassGroup()))
        #expect(fittingSize(glassRows().fixedSize()) == fittingSize(glassRows().glassGroup().fixedSize()))
    }
}
