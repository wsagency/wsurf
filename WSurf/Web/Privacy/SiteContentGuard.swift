// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// WebKit fixes `mediaTypesRequiringUserActionForPlayback` when a web view is
/// made, so a per-website auto-play answer can only be kept in the page.
final class SiteContentGuard {
    static let shared = SiteContentGuard()

    private static let handlerName = "wsurfSiteGuard"

    @MainActor
    func install(in page: BrowserPage, permissions: SitePermissions, settings: BrowserSettings = .shared,
                 onPopupBlocked: @escaping (URL?) -> Void = { _ in }) {
        page.installScript(Self.script, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: .page) { [permissions, settings] message in
            guard let body = message.body as? [String: Any] else { return }
            if let blocked = body["blocked"] as? String {
                onPopupBlocked(URL(string: blocked))
                return
            }
            let origin = SitePermissions.origin(for: message.page.url ?? message.frameInfo.request.url)
            let autoplay = permissions.autoplay(for: origin) ?? settings.autoplay
            let popups = permissions.popups(for: origin)
                ?? (settings.blocksPopups ? PopupPolicy.blockAndNotify : .allow)
            let payload = ["autoplay": autoplay.rawValue, "popups": popups.rawValue]
            Task { @MainActor in
                _ = try? await message.page.callAsyncJavaScript(
                    "globalThis.__wsurfSiteGuard?.applyPolicy(policy);",
                    arguments: ["policy": payload], in: message.frameInfo, contentWorld: .page
                )
            }
        }
    }

    private static let script = #"""
    (() => {
      if (window.__wsurfSiteGuard) return;

      const send = globalThis.__wsurfSend;
      if (typeof send !== 'function') return;

      const state = { autoplay: null, popups: null, held: new Set() };
      window.__wsurfSiteGuard = state;

      let touched = false;
      const notice = () => { touched = true; };
      for (const kind of ['pointerdown', 'keydown', 'touchstart']) {
        document.addEventListener(kind, notice, { capture: true, passive: true });
      }
      const startedByHand = () => {
        const activation = navigator.userActivation;
        return activation ? activation.hasBeenActive : touched;
      };

      const guard = (event) => {
        const media = event.target;
        if (!(media instanceof HTMLMediaElement)) return;
        if (state.autoplay === 'allow' || startedByHand()) return;
        if (state.autoplay === null) {
          state.held.add(media);
          media.pause();
          return;
        }
        if (state.autoplay === 'block') {
          media.pause();
          return;
        }
        if (state.autoplay === 'silent' && !media.muted) {
          media.muted = true;
        }
      };
      document.addEventListener('play', guard, true);

      const release = () => {
        for (const media of state.held) {
          if (state.autoplay === 'block') continue;
          if (state.autoplay === 'silent') media.muted = true;
          const resumed = media.play();
          if (resumed && resumed.catch) resumed.catch(() => {});
        }
        state.held.clear();
      };

      const opener = window.open;
      window.open = function (...args) {
        const opened = opener.apply(window, args);
        if (!opened && state.popups === 'blockAndNotify') {
          try {
            const wanted = args[0] === undefined ? '' : String(args[0]);
            send('wsurfSiteGuard', { blocked: new URL(wanted, location.href).href });
          } catch (_) {
            try { send('wsurfSiteGuard', { blocked: '' }); } catch (_) {}
        }
        }
        return opened;
      };

      state.applyPolicy = (answer) => {
        state.autoplay = answer && answer.autoplay ? answer.autoplay : 'block';
        state.popups = answer && answer.popups ? answer.popups : 'allow';
        release();
      };
      send('wsurfSiteGuard', { ask: 'policy' });
    })();
    """#
}
