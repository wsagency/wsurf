// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct AutofillFramePolicyTests {
    private final class Frames: NSObject, WKScriptMessageHandler {
        var values: [String: BrowserFrame] = [:]

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["action"] as? String == "ready",
                  let documentID = body["documentID"] as? String else { return }
            values[documentID] = BrowserFrame(webKit: message.frameInfo, documentID: documentID)
        }
    }

    @Test func passwordPolicyInSandboxedFrames() async throws {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let frames = Frames()
        configuration.userContentController.add(frames, contentWorld: PasswordAutofill.world, name: "wsurfPasswords")
        BrowserPage.installBridge(in: configuration.userContentController, world: PasswordAutofill.world)
        configuration.userContentController.addUserScript(WKUserScript(
            source: PasswordAutofillScript.source, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: PasswordAutofill.world
        ))
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let view = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration), context: context)
        view.loadHTMLString("""
        <!doctype html><input type="password">
        <iframe srcdoc="<input type='password'>"></iframe>
        <iframe sandbox="allow-scripts" srcdoc="<input type='password'>"></iframe>
        <iframe sandbox="allow-same-origin" srcdoc="<input type='password'>"></iframe>
        <iframe sandbox srcdoc="<input type='password'>"></iframe>
        """, baseURL: URL(string: "https://login.example/"))
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        try #require(await waitUntil { frames.values.count == 5 })
        #expect(frames.values.values.filter(\.isMainFrame).count == 1)
        for frame in frames.values.values {
            for enabled in [true, false] {
                do {
                    let installed = try await view.callAsyncJavaScript(
                        """
                        if (!globalThis.__wsurfPasswords) return false;
                        globalThis.__wsurfPasswords.setEnabled(enabled);
                        return true;
                        """, arguments: ["enabled": enabled], in: frame, contentWorld: PasswordAutofill.world
                    )
                    #expect(installed as? Bool == true)
                } catch {
                    AutofillDiagnostics.policyFailed(.password, error: error, isMainFrame: frame.isMainFrame)
                    Issue.record("Password policy delivery failed; mainFrame=\(frame.isMainFrame), enabled=\(enabled)")
                }
            }
        }
    }
}
