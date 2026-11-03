// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import WebKit

@testable import WSurf

/// Headless automation must keep JavaScript and layout active between actions.
@MainActor
func interactiveWebViewConfiguration() -> WKWebViewConfiguration {
    let configuration = WebViewPool.makeConfiguration()
    configuration.preferences.inactiveSchedulingPolicy = .none
    return configuration
}
