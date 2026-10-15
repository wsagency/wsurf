// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension BrowserSettings {
    /// A named color preset. While set it replaces the manual theme and its
    /// customizations, which stay stored and apply again once it is cleared.
    var themePreset: ThemePreset? {
        get { globalValue(\.themePreset, storage: storedThemePreset) }
        set {
            setGlobal(\BrowserSettings.themePreset, storage: \BrowserSettings.storedThemePreset, value: newValue,
                      key: Key.themePreset, encode: { $0?.rawValue ?? "" }) { $0.applyAppearance() }
        }
    }

    /// The mode that drives the window: a preset forces the mode it was designed for.
    var resolvedAppearance: AppearanceMode {
        themePreset.map { $0.isDark ? .dark : .light } ?? appearance
    }

    /// Minutes a background tab may sit before it unloads. 0 keeps today's behavior: unload only under memory pressure.
    var sleepAfterMinutes: Int {
        get { globalValue(\.sleepAfterMinutes, storage: storedSleepAfterMinutes) }
        set {
            setGlobal(\BrowserSettings.sleepAfterMinutes, storage: \BrowserSettings.storedSleepAfterMinutes,
                      value: Self.clampedSleepMinutes(Double(newValue)), key: Key.sleepAfterMinutes,
                      didChange: { $0.onSleepPolicyChanged?() })
        }
    }

    /// The upper bound is the app's own `Int32` minute limit (about 4,000 years); it keeps stored values sane.
    static func clampedSleepMinutes(_ minutes: Double) -> Int {
        Int(min(max(minutes, 0), Double(Int32.max)))
    }
}
