// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// The window's shadow and border. The rule is checked without a window; the rest opens the browser's own windows in all
/// three shells and reads what they hold: the shadow flag, and the border view with its line, its corner and its colour.
/// Nothing is compared as a picture.
@MainActor
@Suite(.serialized)
struct WindowEdgeTests {
    // MARK: - The rule

    @Test func aFullScreenWindowDrawsNoBorder() {
        for border in WindowBorder.allCases {
            for shadow in [true, false] {
                for contrast in [true, false] {
                    #expect(border.drawn(shadow: shadow, increaseContrast: contrast, isFullScreen: true) == .none,
                            "\(border) shadow \(shadow) contrast \(contrast)")
                }
            }
        }
    }

    @Test func aFlatWindowGetsTheSubtleBorderUnderIncreaseContrast() {
        #expect(WindowBorder.none.drawn(shadow: false, increaseContrast: true, isFullScreen: false) == .subtle)
        #expect(WindowBorder.none.drawn(shadow: true, increaseContrast: true, isFullScreen: false) == .none,
                "the shadow is an edge already")
        #expect(WindowBorder.none.drawn(shadow: false, increaseContrast: false, isFullScreen: false) == .none,
                "a flat window is a choice, until Increase Contrast is on")
    }

    @Test(arguments: [WindowBorder.subtle, .accent, .custom])
    func aChosenBorderIsDrawnAsChosen(border: WindowBorder) {
        for shadow in [true, false] {
            for contrast in [true, false] {
                #expect(border.drawn(shadow: shadow, increaseContrast: contrast, isFullScreen: false) == border)
            }
        }
    }

    // MARK: - The windows

    enum Shell: CaseIterable {
        case standard
        case minimal
        case micro
    }

    /// The windows a test opened, and the app-wide choices as they were. `finish` closes the windows and puts the choices back.
    private final class Rig {
        let app = BrowserApplication()
        private var coordinators: [AppCoordinator] = []
        private let settings = BrowserSettings.application
        private let saved: Saved

        private struct Saved {
            let shadow: Bool
            let border: WindowBorder
            let color: UInt32
            let style: BrowserWindowStyle
            let theme: String
        }

        /// Starts from the defaults: shadow on, no border, the Standard window and theme.
        init() {
            let settings = BrowserSettings.application
            saved = Saved(
                shadow: settings.windowShadow, border: settings.windowBorder, color: settings.windowBorderColor,
                style: settings.windowStyle, theme: settings.themeID
            )
            settings.windowShadow = true
            settings.windowBorder = .none
            settings.windowBorderColor = WindowBorder.defaultColor
            settings.windowStyle = .standard
            settings.themeID = "standard"
        }

        func open(_ shell: Shell = .standard) throws -> NSWindow {
            let browser = BrowserModel(windowID: UUID(), database: .temporary())
            switch shell {
            case .standard:
                settings.windowStyle = .standard
            case .minimal:
                settings.windowStyle = .minimal
            case .micro:
                settings.windowStyle = .standard
                browser.windowKind = .micro
            }
            let coordinator = AppCoordinator(browser: browser)
            app.register(coordinator)
            coordinators.append(coordinator)
            coordinator.showBrowser(activate: false)
            return try #require(coordinator.nativeWindow)
        }

        func finish() {
            coordinators.forEach { $0.closeWindow() }
            settings.windowShadow = saved.shadow
            settings.windowBorder = saved.border
            settings.windowBorderColor = saved.color
            settings.windowStyle = saved.style
            settings.themeID = saved.theme
        }
    }

    private func outlineView(of window: NSWindow) throws -> WindowOutlineView {
        try #require(window.contentView?.subviews.last as? WindowOutlineView)
    }

    private func browserHost(of window: NSWindow) throws -> BrowserHost {
        try #require(window.delegate as? BrowserHost)
    }

    private func line(of outline: WindowOutlineView) -> NSColor? {
        outline.layer?.borderColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
    }

    /// `color` as `appearance` draws it.
    private func resolved(_ color: Color, in appearance: NSAppearance) -> NSColor {
        var result = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        }
        return result
    }

    private func isClose(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01 && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }

    @Test(.boundedWebViews, arguments: Shell.allCases)
    func byDefaultAWindowKeepsItsShadowAndHasNoBorder(shell: Shell) throws {
        let rig = Rig()
        defer { rig.finish() }
        let window = try rig.open(shell)
        let outline = try outlineView(of: window)

        #expect(window.hasShadow)
        #expect(outline.isHidden, "no border until one is chosen")
        #expect(window.styleMask.contains(.titled))
    }

    @Test(.boundedWebViews)
    func theBorderIsTheTopmostViewAndNeverTakesAClick() throws {
        let rig = Rig()
        defer { rig.finish() }
        BrowserSettings.application.windowBorder = .custom
        let window = try rig.open()
        let root = try #require(window.contentView)
        let outline = try outlineView(of: window)
        #expect(!outline.isHidden)

        for point in [
            NSPoint(x: root.bounds.midX, y: root.bounds.midY), NSPoint(x: 1, y: 1),
            NSPoint(x: root.bounds.maxX - 1, y: root.bounds.maxY - 1),
        ] {
            #expect(outline.hitTest(point) == nil, "a click at \(point) goes to what is under the line")
            #expect(root.hitTest(point) !== outline)
        }
        #expect(!outline.isAccessibilityElement())
    }

    @Test(.boundedWebViews, arguments: Shell.allCases)
    func everyWindowFollowsTheShadowSettingLive(shell: Shell) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = try rig.open(shell)
        let second = try rig.open(shell)
        let settings = BrowserSettings.application
        #expect(first.hasShadow && second.hasShadow)

        settings.windowShadow = false
        #expect(await waitUntil { !first.hasShadow && !second.hasShadow }, "both windows lose the shadow, no reopening")
        #expect(first.styleMask.contains(.titled) && second.styleMask.contains(.titled))

        settings.windowShadow = true
        #expect(await waitUntil { first.hasShadow && second.hasShadow })

        settings.windowShadow = false
        let third = try rig.open(shell)
        #expect(!third.hasShadow, "a window opened later starts the way the setting is")
    }

    @Test(.boundedWebViews, arguments: Shell.allCases)
    func theBorderFollowsTheSettingLiveInEveryShell(shell: Shell) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let window = try rig.open(shell)
        let root = try #require(window.contentView)
        let outline = try outlineView(of: window)
        let settings = BrowserSettings.application
        let corners = SystemWindowShape.radius(of: window)
        #expect(outline.isHidden)

        settings.windowBorderColor = 0xFF0000
        settings.windowBorder = .custom
        #expect(await waitUntil { !outline.isHidden }, "choosing a border draws it in the open window")
        #expect(isClose(line(of: outline), NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), "Custom is the colour that was picked")
        #expect(outline.layer?.borderWidth == 1)
        #expect(outline.layer?.cornerCurve == .continuous)
        #expect(outline.layer?.cornerRadius == root.layer?.cornerRadius, "the line follows the corner the content is clipped to")
        #expect((outline.layer?.cornerRadius ?? 0) > 0)
        #expect(outline.frame == root.bounds, "the line is on the outermost points")

        settings.windowBorderColor = 0x00FF00
        #expect(await waitUntil { isClose(line(of: outline), NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)) },
                "picking another colour changes the line at once")

        settings.windowBorder = .none
        #expect(await waitUntil { outline.isHidden })

        #expect(SystemWindowShape.radius(of: window) == corners, "the border never changes the window's own corner")
        #expect(window.styleMask.contains(.titled))
        #expect(window.hasShadow, "the border does not touch the shadow")
    }

    @Test(.boundedWebViews)
    func theShadowDoesNotTouchTheBorder() async throws {
        let rig = Rig()
        defer { rig.finish() }
        BrowserSettings.application.windowBorder = .accent
        let window = try rig.open()
        let outline = try outlineView(of: window)
        #expect(!outline.isHidden)

        BrowserSettings.application.windowShadow = false
        #expect(await waitUntil { !window.hasShadow })
        #expect(!outline.isHidden && outline.border == .accent)
    }

    @Test(.boundedWebViews)
    func subtleFollowsLightAndDarkAndIsFirmerUnderIncreaseContrast() async throws {
        let rig = Rig()
        defer { rig.finish() }
        BrowserSettings.application.windowBorder = .subtle
        let window = try rig.open()
        let outline = try outlineView(of: window)
        let host = try browserHost(of: window)
        #expect(outline.border == .subtle)

        window.appearance = NSAppearance(named: .aqua)
        #expect(await waitUntil { (line(of: outline)?.redComponent ?? 1) < 0.3 }, "dark ink on a light window")
        let light = try #require(line(of: outline))
        window.appearance = NSAppearance(named: .darkAqua)
        #expect(await waitUntil { (line(of: outline)?.redComponent ?? 0) > 0.7 }, "light ink on a dark window")
        let dark = try #require(line(of: outline))
        for ink in [light, dark] {
            #expect(ink.alphaComponent > 0.05 && ink.alphaComponent < 0.2, "a faint line: \(ink.alphaComponent)")
        }

        host.applyWindowEdge(to: window, increaseContrast: true)
        let firmer = try #require(line(of: outline))
        #expect(firmer.alphaComponent > dark.alphaComponent, "Increase Contrast strengthens the line")
    }

    @Test(.boundedWebViews)
    func accentFollowsTheThemeInLightAndDark() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let settings = BrowserSettings.application
        settings.themeID = "catppuccin"
        settings.windowBorder = .accent
        let window = try rig.open()
        let outline = try outlineView(of: window)

        func accent(_ name: NSAppearance.Name) throws -> NSColor {
            resolved(Theme.accent, in: try #require(NSAppearance(named: name)))
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            let expected = try accent(name)
            #expect(await waitUntil { isClose(line(of: outline), expected) }, "\(name.rawValue) draws the theme's accent")
        }

        let before = try accent(.darkAqua)
        settings.themeID = "nord"
        let after = try accent(.darkAqua)
        #expect(!isClose(before, after), "the two themes differ")
        #expect(await waitUntil { isClose(line(of: outline), after) }, "switching theme changes the line in the open window")
    }

    @Test(.boundedWebViews)
    func customIsOneColourInLightAndDark() async throws {
        let rig = Rig()
        defer { rig.finish() }
        BrowserSettings.application.windowBorderColor = 0x336699
        BrowserSettings.application.windowBorder = .custom
        let window = try rig.open()
        let outline = try outlineView(of: window)
        let expected = NSColor(srgbRed: 0x33 / 255.0, green: 0x66 / 255.0, blue: 0x99 / 255.0, alpha: 1)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            #expect(await waitUntil { isClose(line(of: outline), expected) }, "\(name.rawValue)")
        }
    }

    @Test(.boundedWebViews)
    func aFlatWindowGetsTheSubtleBorderWhenIncreaseContrastIsOn() throws {
        let rig = Rig()
        defer { rig.finish() }
        BrowserSettings.application.windowShadow = false
        let window = try rig.open()
        let outline = try outlineView(of: window)
        let host = try browserHost(of: window)
        #expect(!window.hasShadow && outline.isHidden, "flat and borderless stays so by choice")

        host.applyWindowEdge(to: window, increaseContrast: true)
        #expect(!outline.isHidden && outline.border == .subtle, "Increase Contrast gives the flat window an edge")

        host.applyWindowEdge(to: window, increaseContrast: false)
        #expect(outline.isHidden)

        BrowserSettings.application.windowShadow = true
        host.applyWindowEdge(to: window, increaseContrast: true)
        #expect(window.hasShadow && outline.isHidden, "a window with a shadow has an edge already")
    }

    @Test(.boundedWebViews)
    func theBorderIsHiddenInFullScreen() throws {
        let rig = Rig()
        defer { rig.finish() }
        BrowserSettings.application.windowBorder = .custom
        let window = try rig.open()
        let outline = try outlineView(of: window)
        let host = try browserHost(of: window)
        #expect(!outline.isHidden)

        host.applyWindowEdge(to: window, isFullScreen: true)
        #expect(outline.isHidden, "a full-screen window has no edge to draw on")

        host.applyWindowEdge(to: window, isFullScreen: false)
        #expect(!outline.isHidden && outline.border == .custom, "leaving full screen draws it again")
    }
}
