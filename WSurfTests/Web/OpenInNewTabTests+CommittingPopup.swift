// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// A Chromium pop-up whose first page is still committing while WSurf sets it up.
extension OpenInNewTabTests {
    /// `/held`: the opener on 127.0.0.1, and in its frame the same page on `localhost`. The link makes the frame's renderer busy for
    /// 5 s and, 300 ms later (the click still counts), opens a pop-up of `localhost`, which commits its first page in that renderer.
    /// The frame cannot say when it is busy: a message it posts leaves only after the loop.
    static let held = """
        <!doctype html><title>Held</title><style>body { margin: 0 }</style>
        <a id="held" href="#" style="position: absolute; left: 20px; top: 10px; width: 240px; height: 30px; display: block">held</a>
        <script>
          window.__messages = [];
          if (window === top) {
            const frame = document.createElement('iframe');
            frame.src = 'http://localhost:' + location.port + '/held';
            frame.style = 'position: absolute; left: 300px; top: 10px; width: 300px; height: 200px; border: 0';
            document.body.append(frame);
            addEventListener('message', event => window.__messages.push(JSON.stringify(event.data)));
            document.getElementById('held').onclick = () => {
              frame.contentWindow.postMessage('hold', '*');
              setTimeout(() => { window.__popup = window.open('http://localhost:' + location.port + '/popup', 'held', 'width=400,height=300'); }, 300);
              return false;
            };
          } else {
            parent.postMessage('frame-ready', '*');
            addEventListener('message', event => {
              if (event.data !== 'hold') return;
              const end = Date.now() + 5000;
              while (Date.now() < end) {}
            });
          }
        </script>
        """

    /// Until the pop-up's first page commits, its DevTools session points at that page, not active yet, and Chromium refuses the
    /// commands it answers itself ("Not attached to an active page"): `Security.enable`, which the pop-up's start-up sends, among
    /// them. The session waits for the commit instead of failing, so WSurf's scripts still reach the page that committed.
    @Test func aChromiumPopupWhoseFirstPageCommitsLateGetsWSurfsScripts() async throws {
        try await withRig(.chromium, path: "/held") { rig in
            try #require(await waitUntil { try await rig.messages().contains("\"frame-ready\"") }, "the frame is in")
            rig.showOpenedTabs()
            try await rig.click("held")
            let landed = try #require(await waitForAnyTab(in: rig), "a tab opened for the pop-up")
            let popup = try #require(landed.page.chromium)
            try #require(await waitUntil { rig.server.lastRequestHead(for: "/popup") != nil && popup.withBrowser { _ in true } == true },
                         "the pop-up asked for its first page")
            // The answer is on its way; its commit waits for the busy renderer.
            try await Task.sleep(for: .milliseconds(300))
            let sent = ContinuousClock.now
            _ = try await popup.command("Security.enable")
            #expect(sent.duration(to: .now) > .seconds(1), "answered once the first page committed, not refused before")
            try #require(await waitUntil { landed.page.url?.path == "/popup" && !landed.page.isLoading }, "the pop-up's first page loaded")
            let page = "location.origin + ' ' + typeof globalThis.__wsurfPasswords?.pickFill"
            #expect(try await landed.page.evaluateJavaScript(page, in: nil, contentWorld: PasswordAutofill.world) as? String
                == "http://localhost:\(rig.url.port ?? 0) function", "password autofill is in the page that committed")
            let passkey = "String(PublicKeyCredential.isConditionalMediationAvailable).includes('[native code]')"
            #expect(try await landed.page.evaluateJavaScript(passkey) as? Bool == false, "and so is the passkey script")
        }
    }
}
