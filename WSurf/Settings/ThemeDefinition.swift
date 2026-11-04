// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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

extension ThemeVariant {
    /// True when the window, sidebar or surface color is not `other`'s: the three colors that make a ground.
    func groundColorsDiffer(from other: ThemeVariant) -> Bool {
        window != other.window || sidebar != other.sidebar || surface != other.surface
    }
}

extension ThemeDefinition {
    /// The ground the window draws. A tinted theme (Standard, Calm) takes its look from the page, which would hide
    /// the window, sidebar and surface colors a copy of it sets; such a copy draws them on a solid ground instead.
    /// Nothing is stored for this, so putting the original colors back puts the tint back, and a copy that only
    /// changed hue, text or accent keeps its tint.
    var drawnGround: ThemeGround {
        guard ground != .solid, let origin = basedOn.flatMap(ThemeCatalog.builtIn), origin.ground == ground else {
            return ground
        }
        return light.groundColorsDiffer(from: origin.light) || dark.groundColorsDiffer(from: origin.dark) ? .solid : ground
    }
}

/// The knobs of a theme. They are editable on any theme, built-in or not, and never make a copy: colors are the
/// theme, knobs are yours. A saved or duplicated theme carries them along.
struct ThemeAdjustment: Codable, Equatable {
    var material: ThemeMaterial = .plain
    /// How much of the desktop shows through a glass window, 0...1. 0.5 was the default of the old Transparency slider.
    var glassOpacity = 0.5
    /// Lightens or darkens the colors of each variant, within `brightnessRange`.
    var lightBrightness = 0.0
    var darkBrightness = 0.0
    var pageFrame = FrameStyle.standard
    var rowFrame = FrameStyle.standard
    /// Scales the corner radius of rows and the page, 0...1.5.
    var cornerScale = 1.0
    var loadedFavicons = FaviconStyle.mono
    /// Points between the page and the window or sidebar. 0 puts the page flush with them.
    var pageSpacing = 6.0
    /// Points between the sidebar's rows and the window edge.
    var sidebarMargin = 6.0
    /// Points between a sidebar row's edge and its icon.
    var rowPadding = 9.0
    /// Points.
    var tabIconSize = 16.0
    /// How strongly folder colors draw, 0.2...1: the folder icon, the outline and wash of an open folder, its hover, and
    /// the icons it tints. 1 is the look folders always had.
    var folderColorOpacity = 1.0
    /// Points an open folder moves its tabs and subfolders in from its own row, for each level of folders: level 1 is
    /// the rows directly inside a top-level folder, level 2 the rows inside a folder that is inside one, and level 3 every
    /// level below. 0 keeps them under the folder's icon, as folders always were. A theme saved with the single Folder
    /// indent that came before reads it as all three, so its folders look as they did.
    var folderIndentLevel1 = 0.0
    var folderIndentLevel2 = 0.0
    var folderIndentLevel3 = 0.0

    /// -100 % to 100 %. Text, icons and accent text keep their contrast through `ThemeReadability` at either end.
    static let brightnessRange = -1.0...1.0
    static let pageSpacingRange = 0.0...8.0
    /// A row flush with the window edge looks clipped, so the margin never reaches 0.
    static let sidebarMarginRange = 1.0...8.0
    static let rowPaddingRange = 1.0...12.0
    static let tabIconSizeRange = 12.0...24.0
    static let folderColorOpacityRange = 0.2...1.0
    static let folderColorOpacityStep = 0.05
    static let folderIndentRange = 0.0...24.0
    static let folderIndentStep = 2.0

    /// The step that the rows inside a folder at `level` take: level 1 is the rows directly inside a top-level folder,
    /// and every level from 3 on takes the third step.
    func folderIndent(level: Int) -> Double {
        switch level {
        case ..<2:
            folderIndentLevel1
        case 2:
            folderIndentLevel2
        default:
            folderIndentLevel3
        }
    }

    /// How far a row at `depth` starts in from where it starts with no indent: the steps of every level down to its
    /// depth. A top-level row has depth 0 and no step.
    func folderInset(depth: Int) -> Double {
        (0..<max(depth, 0)).reduce(0) { $0 + folderIndent(level: $1 + 1) }
    }

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
        result.lightBrightness = clamp(lightBrightness, Self.brightnessRange, default: 0)
        result.darkBrightness = clamp(darkBrightness, Self.brightnessRange, default: 0)
        result.cornerScale = clamp(cornerScale, 0...1.5, default: 1)
        // Whole points keep favicons crisp and rows on the pixel grid.
        result.pageSpacing = clamp(pageSpacing.rounded(), Self.pageSpacingRange, default: 6)
        result.sidebarMargin = clamp(sidebarMargin.rounded(), Self.sidebarMarginRange, default: 6)
        result.rowPadding = clamp(rowPadding.rounded(), Self.rowPaddingRange, default: 9)
        result.tabIconSize = clamp(tabIconSize.rounded(), Self.tabIconSizeRange, default: 16)
        let opacity = clamp(folderColorOpacity, Self.folderColorOpacityRange, default: 1)
        let steps = (1 / Self.folderColorOpacityStep).rounded()
        result.folderColorOpacity = (opacity * steps).rounded() / steps
        func indent(_ points: Double) -> Double {
            (clamp(points, Self.folderIndentRange, default: 0) / Self.folderIndentStep).rounded() * Self.folderIndentStep
        }
        result.folderIndentLevel1 = indent(folderIndentLevel1)
        result.folderIndentLevel2 = indent(folderIndentLevel2)
        result.folderIndentLevel3 = indent(folderIndentLevel3)
        return result
    }
}

/// The key of the one Folder indent that every level shares in a theme saved before there was one for each.
private enum LegacyFolderIndentKey: String, CodingKey {
    case folderIndent
}

extension ThemeAdjustment {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let single = (try? decoder.container(keyedBy: LegacyFolderIndentKey.self))?.lenient(.folderIndent, 0.0) ?? 0
        self.init(
            material: container.lenient(.material, .plain),
            glassOpacity: container.lenient(.glassOpacity, 0.5),
            lightBrightness: container.lenient(.lightBrightness, 0),
            darkBrightness: container.lenient(.darkBrightness, 0),
            pageFrame: container.lenient(.pageFrame, .standard),
            rowFrame: container.lenient(.rowFrame, .standard),
            cornerScale: container.lenient(.cornerScale, 1),
            loadedFavicons: container.lenient(.loadedFavicons, .mono),
            pageSpacing: container.lenient(.pageSpacing, 6),
            sidebarMargin: container.lenient(.sidebarMargin, 6),
            rowPadding: container.lenient(.rowPadding, 9),
            tabIconSize: container.lenient(.tabIconSize, 16),
            folderColorOpacity: container.lenient(.folderColorOpacity, 1),
            folderIndentLevel1: container.lenient(.folderIndentLevel1, single),
            folderIndentLevel2: container.lenient(.folderIndentLevel2, single),
            folderIndentLevel3: container.lenient(.folderIndentLevel3, single)
        )
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is missing or cannot be decoded.
    fileprivate func lenient<Value: Decodable>(_ key: Key, _ fallback: Value) -> Value {
        (try? decode(Value.self, forKey: key)) ?? fallback
    }
}
