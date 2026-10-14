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

    /// The pending WebKit call must not keep a page that never answers alive: the busy
    /// web-content process would then outlive the tab that wanted it.
    @Test func aPageThatNeverAnswersIsGivenUpOnAndNotHeld() async {
        weak var releasedPage: BrowserPage?
        weak var releasedView: WKWebView?
        var answer: String? = "unset"
        var waited = Duration.zero
        do {
            let view = await page()
            releasedPage = view
            releasedView = view.webKit
            let began = ContinuousClock.now
            answer = await view.evaluateJavaScript(
                "(() => { while (true) {} })()", within: .milliseconds(300), as: String.self
            )
            waited = began.duration(to: .now)
        }

        #expect(answer == nil)
        #expect(waited < .seconds(3), "the caller waited for the page, not the ceiling")
        #expect(await waitUntil { releasedPage == nil && releasedView == nil }, "the pending call kept the page")
    }

    @Test func aCancelledCallerIsReleasedWithoutWaitingForTheCeiling() async {
        let view = await page()
        let began = ContinuousClock.now
        let caller = Task { @MainActor in
            await view.evaluateJavaScript(
                "(() => { const end = Date.now() + 2000; while (Date.now() < end) {} return 'late'; })()",
                within: .seconds(30), as: String.self
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        caller.cancel()

        #expect(await caller.value == nil)
        #expect(began.duration(to: .now) < .seconds(1.5))
    }

    @Test func anAnswerOfAnotherTypeIsNothing() async {
        let view = await page()

        let answer = await view.evaluateJavaScript("42", within: .seconds(10), as: String.self)

        #expect(answer == nil)
    }
}
