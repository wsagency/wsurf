// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

enum PageActivityKind: String {
    case editedForm
    case screenShare
}

struct PageActivitySignal: Equatable {
    let kind: PageActivityKind
    let token: String
    let isActive: Bool
}

final class PageActivityMonitor {
    static let shared = PageActivityMonitor()

    private static let handlerName = "wsurfPageActivity"
    private static let maximumTokenLength = 100

    /// Installs through the owning page so Chromium receives the same callback. Edited forms only: screen sharing comes from
    /// the engines themselves (WebKit's `DisplayCaptureObservation`, Chromium's media access report), so pages keep their
    /// own `getDisplayMedia`.
    @MainActor
    func install(in page: BrowserPage, onActivity: @escaping (PageActivitySignal) -> Void) {
        page.installScript(Self.script, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: BrowserPage.servicesWorld) { message in
            guard let body = message.body as? [String: Any],
                  let rawKind = body["kind"] as? String,
                  let kind = PageActivityKind(rawValue: rawKind),
                  let token = body["token"] as? String, !token.isEmpty,
                  token.count <= Self.maximumTokenLength,
                  let isActive = body["active"] as? Bool
            else { return }
            onActivity(PageActivitySignal(kind: kind, token: token, isActive: isActive))
        }
    }

    private static let script = #"""
    (() => {
      if (window.__wsurfPageActivity) return;

      const send = globalThis.__wsurfSend;
      if (typeof send !== 'function') return;

      const token = globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
      const baselines = new WeakMap();
      const dirtyControls = new Set();
      let reportedDirty = false;

      const post = (kind, active) => {
        try { send('wsurfPageActivity', { kind, token, active: Boolean(active) }); }
        catch (_) {}
      };

      const controlFor = (target) => {
        if (!(target instanceof Element)) return null;
        return target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])');
      };

      const signature = (control) => {
        if (control instanceof HTMLInputElement) {
          if (control.type === 'checkbox' || control.type === 'radio') return `c:${control.checked}`;
          if (control.type === 'file') return `f:${control.files?.length || 0}`;
          return `v:${control.value}`;
        }
        if (control instanceof HTMLTextAreaElement) return `v:${control.value}`;
        if (control instanceof HTMLSelectElement) {
          return Array.from(control.options, option => option.selected ? '1' : '0').join('');
        }
        return `t:${control.textContent || ''}`;
      };

      const remember = (control) => {
        if (control && !baselines.has(control)) baselines.set(control, signature(control));
      };

      const reportDirty = () => {
        for (const control of dirtyControls) {
          if (!control.isConnected) dirtyControls.delete(control);
        }
        const active = dirtyControls.size > 0;
        if (active === reportedDirty) return;
        reportedDirty = active;
        post('editedForm', active);
      };

      const update = (control) => {
        if (!control) return;
        remember(control);
        if (signature(control) === baselines.get(control)) dirtyControls.delete(control);
        else dirtyControls.add(control);
        reportDirty();
      };

      addEventListener('focusin', event => remember(controlFor(event.target)), true);
      addEventListener('beforeinput', event => remember(controlFor(event.target)), true);
      addEventListener('input', event => update(controlFor(event.target)), true);
      addEventListener('change', event => update(controlFor(event.target)), true);

      addEventListener('reset', event => {
        const form = event.target;
        setTimeout(() => {
          if (!(form instanceof HTMLFormElement)) return;
          for (const control of form.querySelectorAll('input, textarea, select, [contenteditable]')) {
            baselines.set(control, signature(control));
            dirtyControls.delete(control);
          }
          reportDirty();
        });
      }, true);

      addEventListener('submit', event => {
        queueMicrotask(() => {
          if (event.defaultPrevented || !(event.target instanceof HTMLFormElement)) return;
          for (const control of event.target.querySelectorAll('input, textarea, select, [contenteditable]')) {
            dirtyControls.delete(control);
          }
          reportDirty();
        });
      }, true);

      addEventListener('pagehide', () => post('editedForm', false));
      addEventListener('pageshow', () => post('editedForm', dirtyControls.size > 0));

      window.__wsurfPageActivity = true;
    })();
    """#
}

/// WebKit's own report that a page captures the screen (`_displayCaptureState`, SPI, key-value observable), so sharing
/// protects the tab without wrapping `getDisplayMedia` in the page. Nil where WebKit does not offer it.
final class DisplayCaptureObservation: NSObject {
    static let token = "webkit-display-capture"
    private static let key = "_displayCaptureState"
    private let webView: WKWebView
    private let onChange: (Bool) -> Void

    init?(_ webView: WKWebView, onChange: @escaping (Bool) -> Void) {
        guard webView.responds(to: NSSelectorFromString(Self.key)) else { return nil }
        self.webView = webView
        self.onChange = onChange
        super.init()
        webView.addObserver(self, forKeyPath: Self.key, options: [.initial, .new], context: nil)
    }

    isolated deinit {
        webView.removeObserver(self, forKeyPath: Self.key)
    }

    // The key is SPI, so there is no key path for the block-based API.
    // swiftlint:disable:next block_based_kvo
    nonisolated override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        let state = (change?[.newKey] as? NSNumber)?.intValue ?? WKMediaCaptureState.none.rawValue
        MainActor.assumeIsolated { onChange(state != WKMediaCaptureState.none.rawValue) }
    }
}

final class ScrollPositionMonitor {
    static let shared = ScrollPositionMonitor()

    private static let handlerName = "wsurfScrollPosition"
    @MainActor
    func install(in page: BrowserPage, onScroll: @escaping (Double, URL?) -> Void) {
        page.installScript(Self.script, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        page.addScriptMessageHandler(name: Self.handlerName, in: BrowserPage.servicesWorld) { message in
            guard message.frameInfo.isMainFrame,
                  let y = (message.body as? NSNumber)?.doubleValue,
                  y.isFinite, y >= 0 else { return }
            onScroll(y, message.frameInfo.request.url)
        }
    }

    private static let script = #"""
    (() => {
      if (window.__wsurfScrollPosition) return;

      const send = globalThis.__wsurfSend;
      if (typeof send !== 'function') return;

      let reported = -1;
      let scheduled = false;
      const report = () => {
        scheduled = false;
        const y = window.scrollY;
        if (y === reported) return;
        reported = y;
        try { send('wsurfScrollPosition', y); } catch (_) {}
      };
      addEventListener('scroll', () => {
        if (scheduled) return;
        scheduled = true;
        setTimeout(report, 120);
      }, { passive: true });

      window.__wsurfScrollPosition = true;
    })();
    """#
}

nonisolated struct ScrollReturnMemory {
    static let topThreshold: Double = 1

    private var offsets: [String: Double] = [:]
    private let capacity: Int

    init(capacity: Int = 400) {
        self.capacity = capacity
    }

    mutating func remember(_ y: Double, leaving url: String?) {
        guard let url, !url.isEmpty else { return }
        if offsets.count >= capacity, offsets[url] == nil {
            offsets.removeAll()
        }
        offsets[url] = y
    }

    func offset(returningTo url: String?) -> Double? {
        guard let url, let y = offsets[url], y > Self.topThreshold else { return nil }
        return y
    }
}
