// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// A website's auto-play and pop-up answers. WebKit keeps both itself, so nothing runs in its pages: the tab's navigation
/// delegate sets the auto-play policy for each main-frame document (`apply(_:to:)`) and decides each pop-up as WebKit asks
/// for its window. Chromium's auto-play setting is browser-wide, so its pages still keep the answer with this script.
final class SiteContentGuard {
    static let shared = SiteContentGuard()

    private static let handlerName = "wsurfSiteGuard"

    @MainActor
    func install(in page: BrowserPage, permissions: SitePermissions, settings: BrowserSettings,
                 onPopupBlocked: @escaping (URL?) -> Void = { _ in }) {
        guard page.webKit == nil else { return }
        installPageScript(in: page, permissions: permissions, settings: settings, onPopupBlocked: onPopupBlocked)
    }

    static func autoplay(for url: URL?, permissions: SitePermissions, settings: BrowserSettings) -> AutoplayPolicy {
        permissions.autoplay(for: SitePermissions.origin(for: url)) ?? settings.autoplay
    }

    private static let policySetter = NSSelectorFromString("_setAutoplayPolicy:")
    private static let quirksSetter = NSSelectorFromString("_setAllowedAutoplayQuirks:")

    /// `_WKWebsiteAutoplayPolicy` and `_WKWebsiteAutoplayQuirk` (SPI on `WKWebpagePreferences`). WebKit enforces the
    /// policy for every player in every frame of the document, including one never attached to the page. Inherited user
    /// gestures make any earlier interaction with the page count as starting it by hand, as
    /// `navigator.userActivation.hasBeenActive` did. "Muted" is WebKit's own: a player that would make a sound waits for
    /// the person, a muted one plays.
    static func apply(_ policy: AutoplayPolicy, to preferences: WKWebpagePreferences) {
        typealias SetInteger = @convention(c) (AnyObject, Selector, Int) -> Void
        guard preferences.responds(to: policySetter), preferences.responds(to: quirksSetter) else { return }
        let inheritedUserGestures = 1 << 1
        let (value, quirks) = switch policy {
        case .allow:
            (1, 0)
        case .silent:
            (2, inheritedUserGestures)
        case .block:
            (3, inheritedUserGestures)
        }
        unsafeBitCast(preferences.method(for: policySetter), to: SetInteger.self)(preferences, policySetter, value)
        unsafeBitCast(preferences.method(for: quirksSetter), to: SetInteger.self)(preferences, quirksSetter, quirks)
    }

    /// The page-world script Chromium runs. Tests drive it on WebKit too: its JavaScript is the same on both.
    @MainActor
    func installPageScript(in page: BrowserPage, permissions: SitePermissions, settings: BrowserSettings,
                           onPopupBlocked: @escaping (URL?) -> Void) {
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
      // A player never attached to the page fires no `play` the document can hear.
      const watched = new WeakSet();
      const nativePlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        if (!this.isConnected && !watched.has(this)) {
          watched.add(this);
          this.addEventListener('play', (event) => {
            if (!this.isConnected) guard(event);
          });
        }
        return nativePlay.apply(this, arguments);
      };

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
