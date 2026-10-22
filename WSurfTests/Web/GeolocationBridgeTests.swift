// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

struct GeolocationBridgeTests {
    @Test func parsesWellFormedMessage() {
        let parsed = GeolocationBridge.parse(["type": "get", "id": 3])
        #expect(parsed?.type == "get")
        #expect(parsed?.jsID == 3)
    }

    @Test func parsesWatchAndClear() {
        #expect(GeolocationBridge.parse(["type": "watch", "id": 1])?.type == "watch")
        #expect(GeolocationBridge.parse(["type": "clear", "id": 7])?.type == "clear")
    }

    @Test func ignoresExtraKeys() {
        let parsed = GeolocationBridge.parse(["type": "get", "id": 2, "junk": "x"])
        #expect(parsed?.jsID == 2)
    }

    @Test func rejectsMissingType() {
        #expect(GeolocationBridge.parse(["id": 3]) == nil)
    }

    @Test func rejectsMissingID() {
        #expect(GeolocationBridge.parse(["type": "get"]) == nil)
    }

    @Test func rejectsStringID() {
        #expect(GeolocationBridge.parse(["type": "get", "id": "3"]) == nil)
    }

    @Test func rejectsNonDictionaryBody() {
        #expect(GeolocationBridge.parse("get") == nil)
        #expect(GeolocationBridge.parse([1, 2, 3]) == nil)
        #expect(GeolocationBridge.parse(NSNull()) == nil)
    }

    @Test func rejectsWrongValueTypes() {
        #expect(GeolocationBridge.parse(["type": 4, "id": 3]) == nil)
    }
}

/// The page's `navigator.geolocation` is WSurf's stand-in. It reaches native, and native reaches it, only through the
/// isolated relay: the page world gets no message handler and no global of WSurf's.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct GeolocationStandInTests {
    private final class Sink {
        var messages: [[String: Any]] = []
        var frame: BrowserFrame?
    }

    private func armed() async -> (BrowserPage, Sink) {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(
            webKit: WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: configuration),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        let sink = Sink()
        PageStandInRelay.install(GeolocationBridge.scriptSource, name: GeolocationBridge.handlerName, in: page) { message in
            sink.frame = message.frameInfo
            if let body = message.body as? [String: Any] {
                sink.messages.append(body)
            }
        }
        page.loadHTMLString("<!doctype html><html><body>page</body></html>", baseURL: nil)
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        return (page, sink)
    }

    private func ask(_ call: String, in page: BrowserPage, _ sink: Sink) async throws -> Int {
        _ = try await page.evaluateJavaScript("""
            window.__seen = null;
            navigator.geolocation.\(call)(p => { window.__seen = p.coords.latitude + ',' + p.timestamp; },
                                          e => { window.__seen = 'error ' + e.code + ' ' + e.message; });
            true
            """)
        #expect(await waitUntil { !sink.messages.isEmpty })
        return try #require(sink.messages.last?["id"] as? Int)
    }

    private func answer(_ answer: [String: Any], in page: BrowserPage, _ sink: Sink) async throws {
        await PageStandInRelay.answer(answer, name: GeolocationBridge.handlerName, in: page, frame: try #require(sink.frame))
    }

    @Test func aPositionReachesTheCallerThatAsked() async throws {
        let (page, sink) = await armed()
        let id = try await ask("getCurrentPosition", in: page, sink)
        #expect(sink.messages.last?["type"] as? String == "get")

        try await answer(["type": "position", "id": id, "coords": ["latitude": 45.5, "longitude": 16.0], "timestamp": 7],
                         in: page, sink)

        #expect(try await page.evaluateJavaScript("window.__seen") as? String == "45.5,7")
        let channel = try await page.evaluateJavaScript("typeof window.webkit + ',' + typeof window.__wsurfGeo")
        #expect(channel as? String == "undefined,undefined")
    }

    @Test func aRefusalReachesTheCallerAsAnError() async throws {
        let (page, sink) = await armed()
        let id = try await ask("watchPosition", in: page, sink)
        #expect(sink.messages.last?["type"] as? String == "watch")

        try await answer(["type": "failure", "id": id, "code": 1, "message": "Permission denied"], in: page, sink)

        #expect(try await page.evaluateJavaScript("window.__seen") as? String == "error 1 Permission denied")
    }

    @Test func anAnswerForAnotherRequestReachesNoOne() async throws {
        let (page, sink) = await armed()
        let id = try await ask("getCurrentPosition", in: page, sink)

        try await answer(["type": "position", "id": id + 1, "coords": ["latitude": 1], "timestamp": 1], in: page, sink)

        #expect(try await page.evaluateJavaScript("window.__seen === null") as? Bool == true)
    }
}
