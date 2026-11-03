// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

extension BrowserSettings {
    /// How long a background tab may sit unused before it moves to the archive. Never until the person chooses.
    /// Archiving shares the sleep policy callback: both are idle-tab timers that each window re-applies together.
    var archiveTabsAfter: TabArchiveDelay {
        get { globalValue(\.archiveTabsAfter, storage: storedArchiveTabsAfter) }
        set {
            setGlobal(\BrowserSettings.archiveTabsAfter, storage: \BrowserSettings.storedArchiveTabsAfter,
                      value: newValue, key: Key.archiveTabsAfter, encode: { $0.rawValue },
                      didChange: { $0.onSleepPolicyChanged?() })
        }
    }
}
