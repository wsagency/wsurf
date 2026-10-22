// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserSettings {
    /// The whole page address in the address bar instead of the website name. App-wide, off by default.
    var showsFullAddress: Bool {
        get { globalValue(\.showsFullAddress, storage: storedShowsFullAddress) }
        set {
            setGlobal(\BrowserSettings.showsFullAddress, storage: \BrowserSettings.storedShowsFullAddress,
                      value: newValue, key: Key.fullAddress)
        }
    }

    func resetWindowStyle() {
        showsFullAddress = false
    }
}
