// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import WebKit

@MainActor
enum WebViewSnapshot {
    static func capture(_ page: BrowserPage, width: CGFloat = 480) async -> NSImage? {
        try? await page.capture(width: width)
    }
}
