// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension BrowserSettings {
    var readerTypeface: ReaderAppearance.Typeface {
        get { globalValue(\.readerTypeface, storage: storedReaderTypeface) }
        set {
            setGlobal(\BrowserSettings.readerTypeface, storage: \BrowserSettings.storedReaderTypeface,
                      value: newValue, key: Key.readerTypeface, encode: { $0.rawValue })
        }
    }

    var readerPalette: ReaderAppearance.Palette {
        get { globalValue(\.readerPalette, storage: storedReaderPalette) }
        set {
            setGlobal(\BrowserSettings.readerPalette, storage: \BrowserSettings.storedReaderPalette,
                      value: newValue, key: Key.readerTheme, encode: { $0.rawValue })
        }
    }

    /// Points, between `ReaderAppearance.textSizeRange`.
    var readerTextSize: Int {
        get { globalValue(\.readerTextSize, storage: storedReaderTextSize) }
        set {
            setGlobal(\BrowserSettings.readerTextSize, storage: \BrowserSettings.storedReaderTextSize,
                      value: ReaderAppearance.clampedTextSize(Double(newValue)), key: Key.readerTextSize)
        }
    }

    var isReaderAppearanceDefault: Bool {
        readerTypeface == .system && readerPalette == .automatic && readerTextSize == ReaderAppearance.defaultTextSize
    }

    func resetReaderAppearance() {
        readerTypeface = .system
        readerPalette = .automatic
        readerTextSize = ReaderAppearance.defaultTextSize
    }
}
