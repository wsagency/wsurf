// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// How a page-world stand-in (an API WebKit gives an embedding app no way to provide) reaches native: the stand-in and an
/// isolated relay talk over two `document` events carrying JSON text, `<name>` out and `<name>-answer` back, so the page
/// world gets no message handler, no `__wsurfSend` and no global of WSurf's. The page can dispatch the same events, but
/// only as the stand-in already lets it: native checks every request as before, and a forged answer reaches only the page
/// that forged it.
@MainActor
enum PageStandInRelay {
    /// Main frame only: the relay first, so the stand-in's first message already has a listener.
    static func install(
        _ standIn: String, name: String, in page: BrowserPage, handler: @escaping (BrowserScriptMessage) -> Void
    ) {
        page.installScript(relay(name), in: page.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        page.installScript(standIn, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        page.addScriptMessageHandler(name: name, in: page.servicesWorld, handler: handler)
    }

    /// Hands `answer` to the stand-in in `frame`.
    static func answer(_ answer: [String: Any], name: String, in page: BrowserPage, frame: BrowserFrame) async {
        guard let data = try? JSONSerialization.data(withJSONObject: answer),
              let detail = String(data: data, encoding: .utf8) else { return }
        _ = try? await page.callAsyncJavaScript(
            "document.dispatchEvent(new CustomEvent(type, {detail}));",
            arguments: ["type": name + "-answer", "detail": detail], in: frame, contentWorld: page.servicesWorld
        )
    }

    static func relay(_ name: String) -> String {
        """
        document.addEventListener('\(name)', event => {
          if (typeof event.detail !== 'string' || event.detail.length > 65536) return;
          try { globalThis.__wsurfSend('\(name)', JSON.parse(event.detail)); } catch (_) {}
        });
        """
    }
}
