// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// A website's auto-play and pop-up answers. WebKit keeps both itself, so nothing runs in its pages: the tab's navigation
/// delegate sets the auto-play policy for each main-frame document (`apply(_:to:)`) and decides each pop-up as WebKit asks
/// for its window. Chromium decides pop-ups natively too (`on_before_popup`), but its auto-play setting is browser-wide, so
/// a script in WSurf's isolated world stops a player attached to the page that the website starts by itself. A player
/// never attached to the page is the browser-wide setting's alone there.
final class SiteContentGuard {
    static let shared = SiteContentGuard()

    private static let handlerName = "wsurfSiteGuard"

    @MainActor
    func install(in page: BrowserPage, permissions: SitePermissions, settings: BrowserSettings) {
        guard page.webKit == nil else { return }
        installScript(in: page, permissions: permissions, settings: settings)
    }

    static func autoplay(for url: URL?, permissions: SitePermissions, settings: BrowserSettings) -> AutoplayPolicy {
        permissions.autoplay(for: SitePermissions.origin(for: url)) ?? settings.autoplay
    }

    private static let policySetter = NSSelectorFromString("_setAutoplayPolicy:")
    private static let quirksSetter = NSSelectorFromString("_setAllowedAutoplayQuirks:")
    /// Whether this WebKit takes a website's answer per navigation (`apply(_:to:)`).
    static let decidesAutoplay = WKWebpagePreferences.instancesRespond(to: policySetter)
        && WKWebpagePreferences.instancesRespond(to: quirksSetter)

    /// `_WKWebsiteAutoplayPolicy` and `_WKWebsiteAutoplayQuirk` (SPI on `WKWebpagePreferences`). WebKit enforces the
    /// policy for every player in every frame of the document, including one never attached to the page. Inherited user
    /// gestures make any earlier interaction with the page count as starting it by hand, as
    /// `navigator.userActivation.hasBeenActive` did. "Muted" is WebKit's own: a player that would make a sound waits for
    /// the person, a muted one plays.
    static func apply(_ policy: AutoplayPolicy, to preferences: WKWebpagePreferences) {
        typealias SetInteger = @convention(c) (AnyObject, Selector, Int) -> Void
        guard decidesAutoplay else { return }
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

    /// The script Chromium runs. Tests drive it on WebKit too: its JavaScript is the same on both.
    @MainActor
    func installScript(in page: BrowserPage, permissions: SitePermissions, settings: BrowserSettings) {
        page.installScript(Self.script, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: BrowserPage.servicesWorld) { [permissions, settings] message in
            let origin = SitePermissions.origin(for: message.page.url ?? message.frameInfo.request.url)
            let autoplay = permissions.autoplay(for: origin) ?? settings.autoplay
            Task { @MainActor in
                _ = try? await message.page.callAsyncJavaScript(
                    "globalThis.__wsurfSiteGuard?.applyPolicy(policy);",
                    arguments: ["policy": ["autoplay": autoplay.rawValue]], in: message.frameInfo,
                    contentWorld: BrowserPage.servicesWorld
                )
            }
        }
    }

    private static let script = #"""
    (() => {
      if (window.__wsurfSiteGuard) return;

      const send = globalThis.__wsurfSend;
      if (typeof send !== 'function') return;

      const state = { autoplay: null, held: new Set() };
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

      state.applyPolicy = (answer) => {
        state.autoplay = answer && answer.autoplay ? answer.autoplay : 'block';
        release();
      };
      send('wsurfSiteGuard', { ask: 'policy' });
    })();
    """#
}
