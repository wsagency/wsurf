// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import WebKit

extension BrowserTab {
    var isShowingRealPage: Bool {
        guard let scheme = page.url?.scheme else { return false }
        return scheme != "about" && scheme != SystemPages.scheme
    }

    var backList: [PageHistoryItem] {
        guard isMaterialised else { return [] }
        return page.backForwardList.backList
    }

    func goBack() {
        page.stopLoading()
        page.goBack()
    }

    func goForward() {
        page.stopLoading()
        page.goForward()
    }

    var zoomLevel: CGFloat {
        _ = zoomChanges
        return page.pageZoom
    }

    var isZoomed: Bool {
        _ = zoomChanges
        return abs(page.pageZoom - context.settings.pageZoom) > 0.005
            || abs(page.magnification - 1) > 0.005
    }

    func zoomIn() {
        setPageZoom(page.pageZoom + TabWebView.zoomStep)
    }

    func zoomOut() {
        setPageZoom(page.pageZoom - TabWebView.zoomStep)
    }

    func resetZoom() {
        page.magnification = 1
        page.pageZoom = context.settings.pageZoom
        zoomDidChange()
    }

    private func setPageZoom(_ value: CGFloat) {
        page.pageZoom = min(
            max(value, TabWebView.zoomRange.lowerBound),
            TabWebView.zoomRange.upperBound
        )
        zoomDidChange()
    }

    static func applyObscuredInsets(to page: BrowserPage, isUnderTopBar: Bool = false) {
        let top: CGFloat = page.isFullscreen || !isUnderTopBar ? 0 : Theme.topBarHeight
        if let native = page.webKit {
            native.obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        } else {
            page.topBarInset = top
        }
    }

    static func restoreScrollScript(to y: Double) -> String {
        """
        (() => {
          const target = \(y);
          if (window.scrollY > 1 && Math.abs(window.scrollY - target) > 1) return;
          let expected = window.scrollY;
          let tries = 20;
          let timer;
          const events = ['wheel', 'keydown', 'pointerdown', 'touchstart', 'pagehide'];
          const stop = () => {
            clearTimeout(timer);
            for (const event of events) removeEventListener(event, stop, true);
          };
          const step = () => {
            // A process swap can reset to zero after didFinish, even after a
            // successful scrollTo. Keep watching briefly, but yield to input
            // or a page choosing another nonzero position.
            if (window.scrollY > 1 && Math.abs(window.scrollY - expected) > 1) {
              stop();
              return;
            }
            if (Math.abs(window.scrollY - target) > 1) window.scrollTo(0, target);
            expected = window.scrollY;
            if (--tries <= 0) {
              stop();
              return;
            }
            timer = setTimeout(step, 60);
          };
          for (const event of events) addEventListener(event, stop, { capture: true, passive: true });
          step();
        })();
        """
    }

    static func wouldFlash(painting color: NSColor?, inDark: Bool) -> Bool {
        guard let painted = color?.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * painted.redComponent
            + 0.7152 * painted.greenComponent
            + 0.0722 * painted.blueComponent
        return inDark ? luminance > 0.5 : luminance < 0.5
    }
}
