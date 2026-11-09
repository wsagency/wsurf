// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension BrowserSettings {
    /// Minutes a background tab may sit before it unloads. 0 keeps today's behavior: unload only under memory pressure.
    var sleepAfterMinutes: Int {
        get { globalValue(\.sleepAfterMinutes, storage: storedSleepAfterMinutes) }
        set {
            setGlobal(\BrowserSettings.sleepAfterMinutes, storage: \BrowserSettings.storedSleepAfterMinutes,
                      value: Self.clampedSleepMinutes(Double(newValue)), key: Key.sleepAfterMinutes,
                      didChange: { $0.onSleepPolicyChanged?() })
        }
    }

    /// Whether Favorites stay loaded when tabs sleep or memory runs low. On by default: that is what they always did.
    var sleepSparesFavorites: Bool {
        get { globalValue(\.sleepSparesFavorites, storage: storedSleepSparesFavorites) }
        set {
            setGlobal(\BrowserSettings.sleepSparesFavorites, storage: \BrowserSettings.storedSleepSparesFavorites,
                      value: newValue, key: Key.sleepSparesFavorites, didChange: { $0.onSleepPolicyChanged?() })
        }
    }

    /// Whether pinned tabs stay loaded when tabs sleep or memory runs low. Off by default.
    var sleepSparesPinned: Bool {
        get { globalValue(\.sleepSparesPinned, storage: storedSleepSparesPinned) }
        set {
            setGlobal(\BrowserSettings.sleepSparesPinned, storage: \BrowserSettings.storedSleepSparesPinned,
                      value: newValue, key: Key.sleepSparesPinned, didChange: { $0.onSleepPolicyChanged?() })
        }
    }

    /// The upper bound is the app's own `Int32` minute limit (about 4,000 years); it keeps stored values sane.
    static func clampedSleepMinutes(_ minutes: Double) -> Int {
        Int(min(max(minutes, 0), Double(Int32.max)))
    }
}
