// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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

    /// How fast Reader reads aloud, as a multiple of the voice's normal pace, between `ReaderSpeech.rateRange`, in tenths.
    var readerSpeechRate: Float {
        get { globalValue(\.readerSpeechRate, storage: storedReaderSpeechRate) }
        set {
            setGlobal(\BrowserSettings.readerSpeechRate, storage: \BrowserSettings.storedReaderSpeechRate,
                      value: ReaderSpeech.clampedRate(newValue), key: Key.readerSpeechRate)
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
