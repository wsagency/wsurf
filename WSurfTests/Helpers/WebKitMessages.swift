// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import WebKit

@testable import WSurf

extension BrowserPage {
    func finishPendingPageMessages() async throws {
        _ = try await callAsyncJavaScript(
            """
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
            """,
            arguments: ["marker": UUID().uuidString],
            in: nil,
            contentWorld: .page
        )
    }
}
