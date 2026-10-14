// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A page that stops answering must not hold its caller: the script is real, the page genuinely
/// busy, and the reply arrives long after the ceiling.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageReplyTests {
    private func page() async -> BrowserPage {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = BrowserPage(webKit: TabWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        ), context: BrowserProfileContext(profile: .privateBrowsing()))
        view.loadHTMLString("<!doctype html><title>Reply fixture</title>", baseURL: nil)
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(30)))
        return view
    }

    @Test func anAnswerInsideTheCeilingIsReturned() async {
        let view = await page()

        let answer = await view.evaluateJavaScript("'quick'", within: .seconds(10), as: String.self)

        #expect(answer == "quick")
    }

    @Test func aBusyPageIsGivenUpOnAtTheCeiling() async {
        let view = await page()
        let began = ContinuousClock.now

        let answer = await view.evaluateJavaScript(
            "(() => { const end = Date.now() + 3000; while (Date.now() < end) {} return 'late'; })()",
            within: .milliseconds(300),
            as: String.self
        )

        #expect(answer == nil)
        #expect(began.duration(to: .now) < .milliseconds(2500), "the caller waited for the page, not the ceiling")
    }

    @Test func anAnswerOfAnotherTypeIsNothing() async {
        let view = await page()

        let answer = await view.evaluateJavaScript("42", within: .seconds(10), as: String.self)

        #expect(answer == nil)
    }
}
