// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

extension BrowserSettings {
    var sidebarFontFamily: String {
        get { globalValue(\.sidebarFontFamily, storage: storedSidebarFontFamily) }
        set {
            setGlobal(\BrowserSettings.sidebarFontFamily, storage: \BrowserSettings.storedSidebarFontFamily, value: newValue, key: Key.sidebarFontFamily, didChange: {
                $0.sidebarFontCache = nil
                $0.sidebarEmphasizedFontCache = nil
            })
        }
    }

    var sidebarFontSize: Double {
        get { globalValue(\.sidebarFontSize, storage: storedSidebarFontSize) }
        set {
            let value = newValue.isFinite ? min(max(newValue, 10), 20) : 12
            setGlobal(\BrowserSettings.sidebarFontSize, storage: \BrowserSettings.storedSidebarFontSize, value: value, key: Key.sidebarFontSize, didChange: {
                $0.sidebarFontCache = nil
                $0.sidebarEmphasizedFontCache = nil
            })
        }
    }

    var sidebarFontWeight: SidebarFontWeight {
        get { globalValue(\.sidebarFontWeight, storage: storedSidebarFontWeight) }
        set {
            setGlobal(\BrowserSettings.sidebarFontWeight, storage: \BrowserSettings.storedSidebarFontWeight, value: newValue, key: Key.sidebarFontWeight, encode: { $0.rawValue }) {
                $0.sidebarFontCache = nil
                $0.sidebarEmphasizedFontCache = nil
            }
        }
    }

    var sidebarRowSpacing: Double {
        get { globalValue(\.sidebarRowSpacing, storage: storedSidebarRowSpacing) }
        set {
            let value = newValue.isFinite ? min(max(newValue, 0), 8) : 1
            setGlobal(\BrowserSettings.sidebarRowSpacing, storage: \BrowserSettings.storedSidebarRowSpacing, value: value, key: Key.sidebarRowSpacing)
        }
    }

    var sidebarFolderTint: Double {
        get { globalValue(\.sidebarFolderTint, storage: storedSidebarFolderTint) }
        set {
            let value = newValue.isFinite ? min(max(newValue, 0), 1) : 0.35
            setGlobal(\BrowserSettings.sidebarFolderTint, storage: \BrowserSettings.storedSidebarFolderTint, value: value, key: Key.sidebarFolderTint)
        }
    }

    var sidebarFont: Font {
        let settings = globalSettings
        let family = sidebarFontFamily
        let size = CGFloat(sidebarFontSize)
        let weight = sidebarFontWeight
        if let font = settings.sidebarFontCache {
            return font
        }

        let native = Self.nativeSidebarFont(family: family, size: size, weight: weight)
        let resolved = Font(native)
        settings.sidebarFontCache = resolved
        settings.sidebarLineHeightCache = Self.lineHeight(of: native)
        settings.sidebarTitleMidlineCache = Self.titleMidline(of: native)
        return resolved
    }

    private static func lineHeight(of font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// The middle of a capital letter, above the baseline. SF Symbols, and the icons drawn to sit beside text, are
    /// centered on that line, so a title that shares it reads as level with its icon. Centering the title halfway
    /// between a capital and a lowercase letter put the capitals above the icon's middle: the icon looked low.
    private static func titleMidline(of font: NSFont) -> CGFloat {
        font.capHeight > 0 ? font.capHeight / 2 : (font.ascender + font.descender) / 2
    }

    /// The sidebar font at `scale` times its size, with the line height and title midline that go with it, for a
    /// row that draws a larger title. A scale of 1 is the shared sidebar font.
    func sidebarTitle(scale: CGFloat) -> (font: Font, lineHeight: CGFloat, midline: CGFloat) {
        guard scale != 1 else { return (sidebarFont, sidebarLineHeight, sidebarTitleMidline) }
        let native = Self.nativeSidebarFont(
            family: sidebarFontFamily, size: CGFloat(sidebarFontSize) * scale, weight: sidebarFontWeight
        )
        return (Font(native), Self.lineHeight(of: native), Self.titleMidline(of: native))
    }

    /// The sidebar font one step heavier, for the title of a new tab. The metrics match, so rows keep their height.
    var sidebarEmphasizedFont: Font {
        let settings = globalSettings
        let (family, size, weight) = (sidebarFontFamily, CGFloat(sidebarFontSize), sidebarFontWeight.emphasized)
        if let font = settings.sidebarEmphasizedFontCache {
            return font
        }
        let resolved = Font(Self.nativeSidebarFont(family: family, size: size, weight: weight))
        settings.sidebarEmphasizedFontCache = resolved
        return resolved
    }

    var sidebarLineHeight: CGFloat {
        _ = sidebarFont
        return globalSettings.sidebarLineHeightCache
    }

    /// How far above the baseline the middle of the sidebar's text sits: the middle of a capital letter, which is
    /// the line an icon beside a title is centered on.
    var sidebarTitleMidline: CGFloat {
        _ = sidebarFont
        return globalSettings.sidebarTitleMidlineCache
    }
}
