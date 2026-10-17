// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// A real WKWebView with the hook in the page world and a stand-in for the capture's native handler behind the relay, so the
/// hook's buffering, adoption and error description are checked as the capture uses them.
@MainActor
final class HookRelayHarness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let event = "wsurf-diag-relay-test"
    static let token = "relay-token"
    static let handler = "wsurfDiagTest"
    private static let world = WKContentWorld.world(name: "WSurfDiagRelayTest")

    let webView: WKWebView
    private(set) var bodies: [[String: Any]] = []
    private var loaded: CheckedContinuation<Void, Never>?

    init(html: String = "<p>hook</p>") async {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, contentWorld: Self.world, name: Self.handler)
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish()
    }

    private func finish() {
        loaded?.resume()
        loaded = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            bodies.append(body)
        }
    }

    @discardableResult
    func installHook() async throws -> Bool {
        try await webView.evaluateJavaScript(PageDiagnosticsHook.pageHook(event: Self.event), in: nil, contentWorld: .page) as? Bool == true
    }

    @discardableResult
    func installRelay() async throws -> Bool {
        let script = PageDiagnosticsHook.relay(event: Self.event, token: Self.token, handler: Self.handler)
        return try await webView.evaluateJavaScript(script, in: nil, contentWorld: Self.world) as? Bool == true
    }

    func page(_ body: String) async throws -> [String: Any] {
        let value = try await webView.callAsyncJavaScript(body, in: nil, contentWorld: .page)
        let raw = try #require(value as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    /// Messages arrive from the web process after the script that caused them returned.
    func messages(_ count: Int, kind: String? = nil) async -> [[String: Any]] {
        _ = await waitUntil { bodies.filter { kind == nil || $0["k"] as? String == kind }.count >= count }
        return bodies.filter { kind == nil || $0["k"] as? String == kind }
    }

    func off() async throws {
        _ = try await webView.evaluateJavaScript(PageDiagnosticsHook.off(event: Self.event), in: nil, contentWorld: .page)
    }
}

struct PageDiagnosticsHookRelayTests {
    @Test(.boundedWebViews)
    @MainActor
    func theHookHoldsEventsUntilTheRelayAnnouncesItselfThenDeliversThemInOrder() async throws {
        let harness = await HookRelayHarness()
        try #require(await harness.installHook())
        _ = try await harness.page("console.log('first'); console.warn('second'); return JSON.stringify({});")
        // The page world has produced its events, but no relay is listening yet, and nothing has been posted.
        #expect(harness.bodies.isEmpty)
        try #require(await harness.installRelay())
        let delivered = await harness.messages(2, kind: "console")
        #expect(delivered.compactMap { $0["text"] as? String } == ["first", "second"])
        #expect(delivered.allSatisfy { $0["t"] as? String == HookRelayHarness.token })
        // From then on events flow straight through.
        _ = try await harness.page("console.error('third'); return JSON.stringify({});")
        #expect(await harness.messages(3, kind: "console").last?["text"] as? String == "third")
        try await harness.off()
    }

    @Test(.boundedWebViews)
    @MainActor
    func theStartUpBufferKeepsTheNewestHundredTwentyEightAndSaysWhatItDropped() async throws {
        let harness = await HookRelayHarness()
        try #require(await harness.installHook())
        _ = try await harness.page("for (let i = 0; i < 200; i++) console.log('event ' + i); return JSON.stringify({});")
        try #require(await harness.installRelay())
        let lost = await harness.messages(1, kind: "lost")
        #expect(lost.first?["n"] as? Int == 72)
        #expect(PageDiagnosticsHook.lostEarly(from: try #require(lost.first)) == 72)
        let texts = await harness.messages(128, kind: "console").compactMap { $0["text"] as? String }
        #expect(texts.count == 128)
        #expect(texts.first == "event 72" && texts.last == "event 199")
        #expect(harness.bodies.first?["k"] as? String == "lost", "the report of the older events comes before the events that followed them")
        try await harness.off()
    }

    @Test(.boundedWebViews)
    @MainActor
    func installingTwiceNeitherWrapsNorRelaysTwice() async throws {
        let harness = await HookRelayHarness()
        try #require(await harness.installHook())
        try #require(await harness.installHook(), "a second install of the same event reports success")
        try #require(await harness.installRelay())
        try #require(await harness.installRelay())
        _ = try await harness.page("console.log('once'); await fetch('data:text/plain,hi'); return JSON.stringify({});")
        _ = await harness.messages(2)
        #expect(harness.bodies.filter { $0["text"] as? String == "once" }.count == 1, "the relay forwards each event once")
        #expect(harness.bodies.filter { $0["k"] as? String == "net" }.count == 1, "fetch is recorded once")
        try await harness.off()
        // Off restores the platform's own console.
        let after = try await harness.page("return JSON.stringify({ native: console.log.toString().includes('[native code]') });")
        #expect(after["native"] as? Bool == true)
    }

    @Test(.boundedWebViews)
    @MainActor
    func webkitStacksNeverRunPageGetters() async throws {
        let harness = await HookRelayHarness()
        // The platform's console converts its arguments to text, which runs a fixture's accessors whether or not the hook reads
        // them. A stub takes its place first, so the hook wraps it and a trap can only come from the hook.
        _ = try await harness.page("console.error = function () {}; return JSON.stringify({});")
        try #require(await harness.installHook())
        try #require(await harness.installRelay())
        let probe = try await harness.page("return JSON.stringify({ isError: typeof Error.isError === 'function' });")
        let result = try await harness.page(
            """
            const trap = window.__trap = [];
            Error.prepareStackTrace = function () { trap.push('prepareStackTrace'); return 'x'; };
            const accessor = new Error('accessor-message');
            Object.defineProperty(accessor, 'stack', { get() { trap.push('stack getter'); return 'hostile@https://evil.test/x.js:1:1'; } });
            const named = new Error('named');
            Object.defineProperty(named, 'name', { get() { trap.push('name getter'); return 'Named'; } });
            const forged = { __proto__: Error.prototype, message: 'forged', stack: 'forged@https://evil.test/f.js:1:1' };
            const proxy = new Proxy(new Error('proxied'), {
              get() { trap.push('proxy get'); }, has() { trap.push('proxy has'); }, ownKeys() { trap.push('proxy keys'); return []; },
              getOwnPropertyDescriptor() { trap.push('proxy descriptor'); }, getPrototypeOf() { trap.push('proxy prototype'); return Error.prototype; },
            });
            function inner() { console.error(new TypeError('real-message')); }
            function outer() { inner(); }
            outer();
            console.error(accessor);
            console.error(named);
            console.error(forged, proxy);
            return JSON.stringify({ trap: trap.slice() });
            """)
        #expect(result["trap"] as? [String] == [], "page code ran: \(result["trap"] ?? "nil")")
        let bodies = await harness.messages(4, kind: "console")
        try #require(bodies.count == 4)
        let entries = try bodies.map { try #require(PageDiagnosticsHook.entry(from: $0, queryValues: DiagnosticsTestKey.values)) }
        // A genuine Error is described by its name and message, and its stack names the functions that logged it.
        #expect(entries[0].fields["text"] == "TypeError: real-message")
        guard case .text(let stack)? = entries[0].fields["stack"] else {
            Issue.record("a genuine Error carries its stack: \(bodies[0])")
            return
        }
        #expect(stack.contains("inner") && stack.contains("outer"), "\(stack)")
        // Accessors, forgeries and Proxies are never called: an accessor stack is not read, a forged or Proxy value is `[object]`.
        let supported = probe["isError"] as? Bool == true
        #expect(entries[1].fields["text"] == (supported ? "Error: accessor-message" : "[object]"))
        #expect(entries[1].fields["stack"] == nil, "the only stack on offer was an accessor")
        #expect(entries[2].fields["text"] == (supported ? "Error: named" : "[object]"), "an accessor name is not read")
        #expect(entries[3].fields["text"] == "[object] [object]")
        #expect(entries[3].fields["stack"] == nil)
        try await harness.off()
    }

    @Test(.boundedWebViews)
    @MainActor
    func uncaughtErrorsAndRejectionsCarryTheirStackThroughCapturedGetters() async throws {
        let harness = await HookRelayHarness()
        try #require(await harness.installHook())
        try #require(await harness.installRelay())
        // Patched after the hook was installed: the hook reads `ErrorEvent.error` and `PromiseRejectionEvent.reason` through
        // the getters it captured, so these never run.
        _ = try await harness.page(
            """
            window.__trap = [];
            Object.defineProperty(ErrorEvent.prototype, 'error', { get() { window.__trap.push('error'); return 1; }, configurable: true });
            Object.defineProperty(PromiseRejectionEvent.prototype, 'reason', { get() { window.__trap.push('reason'); return 1; }, configurable: true });
            setTimeout(function explode() { throw new RangeError('uncaught-range'); }, 0);
            setTimeout(function reject() { Promise.reject(new TypeError('rejected-type')); }, 0);
            return JSON.stringify({});
            """)
        let bodies = await harness.messages(2, kind: "console")
        let entries = bodies.compactMap { PageDiagnosticsHook.entry(from: $0, queryValues: DiagnosticsTestKey.values) }
        let uncaught = try #require(entries.first { $0.fields["line"] != nil }, "\(bodies)")
        #expect(uncaught.fields["column"] != nil)
        let rejection = try #require(entries.first { $0.fields["text"] == "Unhandled rejection: TypeError: rejected-type" }, "\(bodies)")
        #expect(rejection.fields["stack"] != nil)
        let trap = try await harness.page("return JSON.stringify({ trap: window.__trap });")
        #expect(trap["trap"] as? [String] == [], "page code ran: \(trap["trap"] ?? "nil")")
        try await harness.off()
    }
}
