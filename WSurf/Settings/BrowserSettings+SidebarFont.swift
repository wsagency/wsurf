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
        settings.sidebarLineHeightCache = (native.ascender - native.descender + native.leading).rounded(.up)
        settings.sidebarTitleMidlineCache = native.capHeight > 0 && native.xHeight > 0
            ? (native.capHeight + native.xHeight) / 4
            : (native.ascender + native.descender) / 2
        return resolved
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

    /// How far above the baseline the middle of the sidebar's text sits: halfway between the middle of a capital
    /// and the middle of a lowercase letter, which is where the weight of a title is.
    var sidebarTitleMidline: CGFloat {
        _ = sidebarFont
        return globalSettings.sidebarTitleMidlineCache
    }
}
