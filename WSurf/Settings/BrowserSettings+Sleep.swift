// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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

    /// The upper bound is the app's own `Int32` minute limit (about 4,000 years); it keeps stored values sane.
    static func clampedSleepMinutes(_ minutes: Double) -> Int {
        Int(min(max(minutes, 0), Double(Int32.max)))
    }
}
