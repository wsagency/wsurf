// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import WebKit

enum NativeApplePay {
    static func apply(to preferences: WKPreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setApplePayEnabled:")) else { return }
        preferences.setValue(false, forKey: "applePayEnabled")
    }
}
