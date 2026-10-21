// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// How Reader sets an article. The choice holds for every article, tab, window and profile, so the application's settings keep it
/// (`BrowserSettings.readerTypeface`, `readerPalette` and `readerTextSize`).
nonisolated enum ReaderAppearance {
    nonisolated enum Typeface: String, CaseIterable, Identifiable {
        case athelas
        case charter
        case georgia
        case iowan
        case serif
        case palatino
        case system
        case seravek
        case times

        var id: Self {
            self
        }

        /// The font's own name, which is never translated.
        var name: String {
            switch self {
            case .athelas:
                "Athelas"
            case .charter:
                "Charter"
            case .georgia:
                "Georgia"
            case .iowan:
                "Iowan"
            case .serif:
                "New York"
            case .palatino:
                "Palatino"
            case .system:
                "San Francisco"
            case .seravek:
                "Seravek"
            case .times:
                "Times New Roman"
            }
        }

        /// The installed family behind the name. The two system designs have none.
        var family: String? {
            switch self {
            case .athelas:
                "Athelas"
            case .charter:
                "Charter"
            case .georgia:
                "Georgia"
            case .iowan:
                "Iowan Old Style"
            case .palatino:
                "Palatino"
            case .seravek:
                "Seravek"
            case .times:
                "Times New Roman"
            case .serif, .system:
                nil
            }
        }

        var cssFamily: String {
            switch self {
            case .system:
                "-apple-system, system-ui, sans-serif"
            case .serif:
                "ui-serif, \"New York\", Georgia, serif"
            case .seravek:
                "\"Seravek\", -apple-system, sans-serif"
            default:
                "\"\(family ?? name)\", ui-serif, Georgia, serif"
            }
        }

        func font(size: CGFloat) -> Font {
            switch self {
            case .system:
                .system(size: size)
            case .serif:
                .system(size: size, design: .serif)
            default:
                .custom(family ?? name, size: size)
            }
        }
    }

    nonisolated enum Palette: String, CaseIterable, Identifiable {
        case automatic
        case light
        case sepia
        case dark

        var id: Self {
            self
        }

        var title: LocalizedStringResource {
            switch self {
            case .automatic:
                "Automatic"
            case .light:
                "Light"
            case .sepia:
                "Sepia"
            case .dark:
                "Dark"
            }
        }

        /// Automatic follows the appearance of the window; the others are themselves.
        func resolved(isDark: Bool) -> Palette {
            guard self == .automatic else { return self }
            return isDark ? .dark : .light
        }

        /// The page's background. Automatic reads as light, because only a resolved palette is ever drawn.
        var background: NSColor {
            switch self {
            case .automatic, .light:
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            case .sepia:
                NSColor(srgbRed: 0.973, green: 0.945, blue: 0.890, alpha: 1)
            case .dark:
                NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1)
            }
        }
    }

    /// The sizes the text steps through, in points.
    static let textSizes = [15, 17, 19, 21, 24, 28, 32]
    static let textSizeRange = 15...32
    static let defaultTextSize = 19

    /// A stored value that is not a number, or is outside the range, is brought back to it.
    static func clampedTextSize(_ size: Double) -> Int {
        guard size.isFinite else { return defaultTextSize }
        return Int(min(max(size, Double(textSizeRange.lowerBound)), Double(textSizeRange.upperBound)).rounded())
    }

    /// The next step above `size`, which a stored value between two steps may be.
    static func larger(than size: Int) -> Int {
        textSizes.first { $0 > size } ?? textSizeRange.upperBound
    }

    static func smaller(than size: Int) -> Int {
        textSizes.last { $0 < size } ?? textSizeRange.lowerBound
    }
}
