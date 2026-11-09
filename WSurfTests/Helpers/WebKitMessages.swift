// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import WebKit

@testable import WSurf

/// Resolves once a message posted to the page now has been delivered, which is after every message posted to it before.
private let pendingMessagesScript = """
await new Promise(resolve => {
    const done = event => {
        if (event.source !== window || event.data !== marker) return;
        window.removeEventListener('message', done);
        resolve();
    };
    window.addEventListener('message', done);
    window.postMessage(marker, '*');
});
return true;
"""

extension BrowserPage {
    func finishPendingPageMessages() async throws {
        _ = try await callAsyncJavaScript(
            pendingMessagesScript,
            arguments: ["marker": UUID().uuidString],
            in: nil,
            contentWorld: .page
        )
    }
}

extension WKWebView {
    /// The same as `BrowserPage.finishPendingPageMessages`, for a bare web view: returns once a message posted now has been
    /// delivered, which is after every message posted to the page before it.
    func finishPendingPageMessages() async throws {
        _ = try await callAsyncJavaScript(
            pendingMessagesScript,
            arguments: ["marker": UUID().uuidString],
            in: nil,
            contentWorld: .page
        )
    }
}
