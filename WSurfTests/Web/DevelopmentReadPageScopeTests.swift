// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// readPage's `scope` reaches the page through `PageDriver.snapshot`; it must meet the same native bound as findElements,
/// and a refusal must not run the runtime (which would mint a snapshot). Needs the app target (`BrowserPage`), so it is not
/// part of the pure component package.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct DevelopmentReadPageScopeTests {
    @Test(arguments: [
        String(repeating: "a", count: 2_049), String(repeating: "a", count: 2_046) + "€", "  ", "a\u{0}b",
    ])
    func anOutOfBoundScopeIsRefusedBeforeTheRuntimeRuns(scope: String) async {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
        let page = BrowserPage(webKit: view, context: BrowserProfileContext(profile: .privateBrowsing()))
        page.loadHTMLString("<!doctype html><html><body><p>hello</p></body></html>", baseURL: nil)
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        let refused = await PageDriver.snapshot(page, scope: scope)
        #expect(refused.contains("scope selector"), "\(refused)")
        #expect(await PageDriver.automationSnapshot(in: page) == nil)
        // Control: a valid scope runs the runtime, so the probe above would have seen it.
        _ = await PageDriver.snapshot(page, scope: "body")
        #expect(await PageDriver.automationSnapshot(in: page) != nil)
    }
}

/// `wireFence` (the pure copy the delivered-bytes tests measure with) must stay identical to the real fence.
struct DevelopmentWireFenceTests {
    @Test func theTestFenceMatchesAgentToolkit() {
        let text = "a & b <c> / \"d\" é €"
        #expect(wireFence(text) == AgentToolkit.untrusted(text))
    }
}
