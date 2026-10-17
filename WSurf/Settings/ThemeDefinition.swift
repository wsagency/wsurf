// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI

/// One appearance of a theme, light or dark. A nil color means "the Standard theme's own value", which is how
/// Standard keeps its exact pixels and the macOS accent color.
struct ThemeVariant: Codable, Equatable {
    var window: UInt32?
    var sidebar: UInt32?
    var surface: UInt32?
    /// nil: the system blue.
    var accent: UInt32?
    /// The color of assistant activity. nil: the accent.
    var assistant: UInt32?
    /// Text and icons on the chrome. nil: black in a light variant, white in a dark one.
    var text: UInt32?
    /// Derives the window, sidebar, surface and accent colors from one hue.
    var primary: UInt32?
    /// Turns every derived color around the color wheel, -0.5...0.5.
    var hue: Double = 0
    /// Loaded tabs: a color (nil: `text`) and an opacity.
    var sidebarText = SidebarTextStyle()
    var unloadedText = SidebarTextStyle(opacity: Self.unloadedOpacity)
    var icons = SidebarTextStyle()
    var url = SidebarTextStyle()

    static let unloadedOpacity = 0.55

    func bounded() -> Self {
        var result = self
        func hex(_ value: UInt32?) -> UInt32? {
            value.flatMap { $0 <= 0xFFFFFF ? $0 : nil }
        }
        result.window = hex(window)
        result.sidebar = hex(sidebar)
        result.surface = hex(surface)
        result.accent = hex(accent)
        result.assistant = hex(assistant)
        result.text = hex(text)
        result.primary = hex(primary)
        result.hue = hue.isFinite ? min(max(hue, -0.5), 0.5) : 0
        result.sidebarText = sidebarText.bounded(defaultOpacity: 1)
        result.unloadedText = unloadedText.bounded(defaultOpacity: Self.unloadedOpacity)
        result.icons = icons.bounded(defaultOpacity: 1)
        result.url = url.bounded(defaultOpacity: 1)
        return result
    }
}

extension ThemeVariant {
    /// A value that is missing or malformed decodes to its default, so one bad field never costs the theme.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            window: container.lenient(.window, nil), sidebar: container.lenient(.sidebar, nil),
            surface: container.lenient(.surface, nil), accent: container.lenient(.accent, nil),
            assistant: container.lenient(.assistant, nil), text: container.lenient(.text, nil),
            primary: container.lenient(.primary, nil), hue: container.lenient(.hue, 0),
            sidebarText: container.lenient(.sidebarText, SidebarTextStyle()),
            unloadedText: container.lenient(.unloadedText, SidebarTextStyle(opacity: Self.unloadedOpacity)),
            icons: container.lenient(.icons, SidebarTextStyle()), url: container.lenient(.url, SidebarTextStyle())
        )
    }
}

/// How the ground behind the chrome is drawn. These are the render paths the app had before themes.
enum ThemeGround: String, Codable {
    /// Vibrancy under a wash of the page's color.
    case pageTinted
    /// Vibrancy under a mostly opaque wash: the Calm look.
    case softTinted
    /// One opaque color.
    case solid
}

enum ThemeMaterial: String, Codable {
    case plain
    case glass
}

/// How a page or a row edge is drawn. Used by the layout options.
enum FrameStyle: String, Codable {
    case standard
    case hairline
    case none
}

enum FaviconStyle: String, Codable {
    case mono
    case color
}

/// The colors of a theme: its identity. Built-in themes are read-only; changing their colors makes a copy.
struct ThemeDefinition: Codable, Equatable, Identifiable {
    /// A built-in theme has a fixed word for an id; a saved theme has a UUID string.
    var id: String
    var name: String
    /// The built-in theme a copy came from, which Reset Colors restores.
    var basedOn: String?
    var ground: ThemeGround
    var light = ThemeVariant()
    var dark = ThemeVariant()

    static let nameLimit = 60

    func variant(_ scheme: ColorScheme) -> ThemeVariant {
        scheme == .dark ? dark : light
    }

    mutating func setVariant(_ variant: ThemeVariant, for scheme: ColorScheme) {
        if scheme == .dark {
            dark = variant
        } else {
            light = variant
        }
    }

    func bounded() -> Self {
        var result = self
        result.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        result.light = light.bounded()
        result.dark = dark.bounded()
        return result
    }
}

extension ThemeDefinition {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: container.lenient(.name, ""),
            basedOn: container.lenient(.basedOn, nil),
            ground: container.lenient(.ground, .pageTinted),
            light: container.lenient(.light, ThemeVariant()),
            dark: container.lenient(.dark, ThemeVariant())
        )
    }
}

/// The knobs of a theme. They are editable on any theme, built-in or not, and never make a copy: colors are the
/// theme, knobs are yours. A saved or duplicated theme carries them along.
struct ThemeAdjustment: Codable, Equatable {
    var material: ThemeMaterial = .plain
    /// How much of the desktop shows through a glass window, 0...1. 0.5 was the default of the old Transparency slider.
    var glassOpacity = 0.5
    /// Lightens or darkens the colors of each variant, -0.5...0.5.
    var lightBrightness = 0.0
    var darkBrightness = 0.0
    var pageFrame = FrameStyle.standard
    var rowFrame = FrameStyle.standard
    /// Scales the corner radius of rows and the page, 0...1.5.
    var cornerScale = 1.0
    var loadedFavicons = FaviconStyle.mono

    func brightness(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? darkBrightness : lightBrightness
    }

    mutating func setBrightness(_ value: Double, for scheme: ColorScheme) {
        if scheme == .dark {
            darkBrightness = value
        } else {
            lightBrightness = value
        }
    }

    func bounded() -> Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        var result = self
        result.glassOpacity = clamp(glassOpacity, 0...1, default: 0.5)
        result.lightBrightness = clamp(lightBrightness, -0.5...0.5, default: 0)
        result.darkBrightness = clamp(darkBrightness, -0.5...0.5, default: 0)
        result.cornerScale = clamp(cornerScale, 0...1.5, default: 1)
        return result
    }
}

extension ThemeAdjustment {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            material: container.lenient(.material, .plain),
            glassOpacity: container.lenient(.glassOpacity, 0.5),
            lightBrightness: container.lenient(.lightBrightness, 0),
            darkBrightness: container.lenient(.darkBrightness, 0),
            pageFrame: container.lenient(.pageFrame, .standard),
            rowFrame: container.lenient(.rowFrame, .standard),
            cornerScale: container.lenient(.cornerScale, 1),
            loadedFavicons: container.lenient(.loadedFavicons, .mono)
        )
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is missing or cannot be decoded.
    fileprivate func lenient<Value: Decodable>(_ key: Key, _ fallback: Value) -> Value {
        (try? decode(Value.self, forKey: key)) ?? fallback
    }
}
