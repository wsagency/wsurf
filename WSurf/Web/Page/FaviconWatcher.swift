// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

final class FaviconWatcher {
    static let shared = FaviconWatcher()

    private static let handlerName = "wsurfFavicon"

    @MainActor
    func install(in page: BrowserPage, onChange: @escaping () -> Void) {
        page.installScript(Self.script, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        page.addScriptMessageHandler(name: Self.handlerName, in: .page) { message in
            guard message.frameInfo.isMainFrame else { return }
            onChange()
        }
    }

    private static let script = #"""
    (() => {
      if (window.__wsurfFavicon) return;
      window.__wsurfFavicon = true;

      const send = globalThis.__wsurfSend;
      if (typeof send !== 'function') return;

      const isIcon = node =>
        node?.tagName === 'LINK' && /(^|\s)(icon|apple-touch-icon)(\s|$)/i.test(node.rel || '');

      let pending = 0;
      const report = () => {
        clearTimeout(pending);
        pending = setTimeout(() => send('wsurfFavicon', 1), 60);
      };

      const observer = new MutationObserver(records => {
        for (const record of records) {
          if (record.type === 'attributes' && isIcon(record.target)) { report(); return; }
          for (const node of record.addedNodes) {
            if (isIcon(node)) { report(); return; }
          }
        }
      });

      const start = () => observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['href', 'rel', 'media', 'sizes'],
      });

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start, { once: true });
      } else {
        start();
      }
    })()
    """#
}
