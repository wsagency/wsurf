// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import WebKit

final class PageClickWatcher {
    static let shared = PageClickWatcher()

    @MainActor var onClick: ((CGPoint) -> Void)?

    private static let handlerName = "wsurfClick"

    @MainActor
    func install(in page: BrowserPage, onClick: @escaping (CGPoint) -> Void) {
        page.installScript(Self.script, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        page.addScriptMessageHandler(name: Self.handlerName, in: .page) { [weak page] message in
            guard let page,
                  let point = message.body as? [Double], point.count == 2 else { return }
            let zoom = page.pageZoom
            let y = point[1] * zoom
            let inView = CGPoint(x: point[0] * zoom, y: page.isFlipped ? y : page.bounds.height - y)
            let inWindow = page.convert(inView, to: nil)
            guard let content = page.window?.contentView else { return }
            let inContent = CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
            onClick(inContent)
        }
    }

    private static let script = """
    (function () {
      if (window !== window.top) { return; }
      document.addEventListener('mousedown', function (event) {
        try { globalThis.__wsurfSend?.('wsurfClick', [event.clientX, event.clientY]); } catch (_) {}
      }, true);
    })();
    """
}
