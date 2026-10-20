// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct NotificationShimTests {
    private final class Sink {
        var messages: [[String: Any]] = []
        var frame: BrowserFrame?
    }

    private func page() async -> BrowserPage {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(
            webKit: WKWebView(
                frame: .init(x: 0, y: 0, width: 400, height: 300),
                configuration: configuration
            ),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        page.loadHTMLString("<!doctype html><html><body>page</body></html>", baseURL: nil)
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        return page
    }

    private func run(_ script: String, in page: BrowserPage) async -> Any? {
        try? await page.evaluateJavaScript(script)
    }

    private func posted(_ sink: Sink) -> [[String: Any]] {
        sink.messages
    }

    private func armed() async -> (BrowserPage, Sink) {
        let page = await page()
        let sink = Sink()
        PageStandInRelay.install(NotificationBridge.scriptSource, name: NotificationBridge.handlerName, in: page) { message in
            sink.frame = message.frameInfo
            if let body = message.body as? [String: Any] {
                sink.messages.append(body)
            }
        }
        page.loadHTMLString("<!doctype html><html><body>page</body></html>", baseURL: nil)
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        return (page, sink)
    }

    /// What native says, through the relay, to the frame that spoke.
    private func answer(_ answer: [String: Any], to page: BrowserPage, _ sink: Sink) async {
        guard await waitUntil({ sink.frame != nil }), let frame = sink.frame else {
            Issue.record("the shim never spoke")
            return
        }
        await PageStandInRelay.answer(answer, name: NotificationBridge.handlerName, in: page, frame: frame)
    }

    // MARK: - Installing

    /// The relay leaves the page no channel of WSurf's: no message handler, so no `window.webkit`, and no global.
    @Test func thePageSeesTheShimButNoChannel() async {
        let (webView, _) = await armed()
        #expect(await run("typeof window.webkit", in: webView) as? String == "undefined")
        #expect(await run("typeof window.__wsurfNotify", in: webView) as? String == "undefined")
    }

    @Test func theShimAnnouncesItselfAsSoonAsItIsInstalled() async {
        let (webView, sink) = await armed()

        #expect(await waitUntil { !self.posted(sink).isEmpty })
        let messages = posted(sink)

        #expect(messages.first?["type"] as? String == "hello")
    }

    @Test func thePageGetsANotificationConstructor() async {
        let (webView, _) = await armed()
        #expect(await run("typeof window.Notification", in: webView) as? String == "function")
    }

    // MARK: - Permission

    @Test func permissionStartsUndecided() async {
        let (webView, _) = await armed()
        #expect(await run("Notification.permission", in: webView) as? String == "default")
    }

    @Test func theBrowserCanSetThePermissionWithoutBeingAsked() async {
        let (webView, sink) = await armed()

        await answer(["type": "permission", "value": "granted"], to: webView, sink)

        #expect(await run("Notification.permission", in: webView) as? String == "granted")
    }

    @Test func askingForPermissionPostsARequestCarryingItsOwnID() async {
        let (webView, sink) = await armed()

        _ = await run("window.__pending = Notification.requestPermission()", in: webView)

        let request = posted(sink).first { $0["type"] as? String == "request" }
        #expect(request != nil)
        #expect(request?["id"] as? Int == 1)
    }

    @Test func twoRequestsAreToldApartByTheirIDs() async {
        let (webView, sink) = await armed()

        _ = await run("Notification.requestPermission(); Notification.requestPermission();", in: webView)

        let ids = posted(sink)
            .filter { $0["type"] as? String == "request" }
            .compactMap { $0["id"] as? Int }
        #expect(ids == [1, 2])
    }

    @Test func answeringARequestSettlesItsPromise() async {
        let (webView, sink) = await armed()
        _ = await run("""
            window.__answer = null;
            Notification.requestPermission().then(function (v) { window.__answer = v; });
            true;
            """, in: webView)

        await answer(["type": "resolve", "id": 1, "value": "granted"], to: webView, sink)
        _ = await run("new Promise(function (r) { setTimeout(r, 0); })", in: webView)

        #expect(await run("window.__answer", in: webView) as? String == "granted")
        #expect(await run("Notification.permission", in: webView) as? String == "granted")
    }

    @Test func aRefusalIsRememberedAsARefusal() async {
        let (webView, sink) = await armed()
        _ = await run("Notification.requestPermission()", in: webView)

        await answer(["type": "resolve", "id": 1, "value": "denied"], to: webView, sink)

        #expect(await run("Notification.permission", in: webView) as? String == "denied")
    }

    @Test func anUndecidedAnswerLeavesAnEarlierDecisionStanding() async {
        let (webView, sink) = await armed()
        await answer(["type": "permission", "value": "granted"], to: webView, sink)
        _ = await run("Notification.requestPermission()", in: webView)

        await answer(["type": "resolve", "id": 1, "value": "default"], to: webView, sink)

        #expect(await run("Notification.permission", in: webView) as? String == "granted")
    }

    @Test func theOldCallbackFormIsAnsweredToo() async {
        let (webView, sink) = await armed()
        _ = await run("""
            window.__called = null;
            Notification.requestPermission(function (v) { window.__called = v; });
            true;
            """, in: webView)

        await answer(["type": "resolve", "id": 1, "value": "granted"], to: webView, sink)

        #expect(await run("window.__called", in: webView) as? String == "granted")
    }

    @Test func aCallbackThatThrowsStillLetsThePromiseSettle() async {
        let (webView, sink) = await armed()
        _ = await run("""
            window.__answer = null;
            Notification.requestPermission(function () { throw new Error('page bug'); })
              .then(function (v) { window.__answer = v; });
            true;
            """, in: webView)

        await answer(["type": "resolve", "id": 1, "value": "granted"], to: webView, sink)
        _ = await run("new Promise(function (r) { setTimeout(r, 0); })", in: webView)

        #expect(await run("window.__answer", in: webView) as? String == "granted")
    }

    @Test func aRequestsCallbackRunsOnlyOnce() async {
        let (webView, sink) = await armed()
        _ = await run("""
            window.__calls = 0;
            Notification.requestPermission(function () { window.__calls += 1; });
            true;
            """, in: webView)

        await answer(["type": "resolve", "id": 1, "value": "granted"], to: webView, sink)
        await answer(["type": "resolve", "id": 1, "value": "granted"], to: webView, sink)

        #expect(await run("window.__calls", in: webView) as? Int == 1)
    }

    @Test func anAnswerForAnotherRequestSettlesNothing() async {
        let (webView, sink) = await armed()
        _ = await run("""
            window.__answer = 'unsettled';
            Notification.requestPermission().then(function (v) { window.__answer = v; });
            true;
            """, in: webView)

        await answer(["type": "resolve", "id": 99, "value": "granted"], to: webView, sink)
        _ = await run("new Promise(function (r) { setTimeout(r, 0); })", in: webView)

        #expect(await run("window.__answer", in: webView) as? String == "unsettled")
    }

    // MARK: - Showing one

    @Test func showingANotificationPostsItsText() async {
        let (webView, sink) = await armed()

        _ = await run("new Notification('Title here', { body: 'Body here', tag: 'chat' })", in: webView)

        let shown = posted(sink).first { $0["type"] as? String == "show" }
        #expect(shown?["title"] as? String == "Title here")
        #expect(shown?["body"] as? String == "Body here")
        #expect(shown?["tag"] as? String == "chat")
    }

    @Test func aNotificationWithNoOptionsStillPosts() async {
        let (webView, sink) = await armed()

        _ = await run("new Notification('Bare')", in: webView)

        let shown = posted(sink).first { $0["type"] as? String == "show" }
        #expect(shown?["title"] as? String == "Bare")
        #expect(shown?["body"] as? String == "")
        #expect(shown?["tag"] as? String == "")
    }

    @Test func anythingPassedAsATitleIsSentAsText() async {
        let (webView, sink) = await armed()

        _ = await run("new Notification(42)", in: webView)

        #expect(posted(sink).first { $0["type"] as? String == "show" }?["title"] as? String == "42")
    }

    @Test func closingANotificationIsHarmless() async {
        let (webView, _) = await armed()

        let result = await run("var n = new Notification('x'); n.close(); 'survived';", in: webView)

        #expect(result as? String == "survived")
    }

}
