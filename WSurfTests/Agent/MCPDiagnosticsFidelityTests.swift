// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// What a client reads from `readConsole` and `readNetwork` on a live page of each engine: redacted query values, resource
/// facts, stacks, filters, and the events of a navigation that no read ever preceded.
@MainActor
struct MCPDiagnosticsFidelityTests {
    private struct Rig {
        let server: HTTPFixtureServer
        let browser: BrowserModel
        let tab: BrowserTab
        let window: NSWindow
        let subject: MCPBrowserSession
    }

    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") ?? Data()

    private static func routes(_ extra: [String: HTTPFixtureServer.Response]) -> [String: HTTPFixtureServer.Response] {
        let base: [String: HTTPFixtureServer.Response] = [
            "/": .html("<!doctype html><title>Home</title><p>home</p>"),
            "/api": .bytes(Data("{\"ok\":true}".utf8), contentType: "application/json"),
            "/pic.png": .bytes(png, contentType: "image/png"),
            "/app.js": .bytes(Data("window.__loaded = true;".utf8), contentType: "application/javascript"),
            "/site.css": .bytes(Data("body { color: #123456 }".utf8), contentType: "text/css"),
            "/old": .init(status: "302 Found", headers: ["Location": "/api?hop=1"], body: Data()),
        ]
        return base.merging(extra) { $1 }
    }

    /// A tab in a window, on the engine asked for, with development access and nothing captured yet.
    private func makeRig(_ engine: BrowserEngine, routes extra: [String: HTTPFixtureServer.Response] = [:]) async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: Self.routes(extra))
        let url = try server.url()
        let permissions = SitePermissions(storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDiag-\(UUID().uuidString).json"))
        if engine == .chromium {
            permissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let tab = browser.newTab(url: url)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        try #require(await PageSettle.untilIdle(tab.page))
        try #require(await waitUntil { tab.page.mainDocumentID != nil }, "the page registered its main document")
        try #require(tab.page.engine == engine)
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        let subject = MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in .development })
        _ = try await subject.call(name: "requestAccess", arguments: ["development": true])
        return Rig(server: server, browser: browser, tab: tab, window: window, subject: subject)
    }

    private func close(_ rig: Rig) {
        rig.window.contentView = nil
        rig.window.close()
    }

    private func call(_ rig: Rig, _ name: String, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        try await rig.subject.call(name: name, arguments: arguments.merging(["tabID": .string(rig.tab.id.uuidString)]) { $1 })
    }

    private func status(_ result: CallTool.Result) -> String? {
        result.structuredContent?.objectValue?["status"]?.stringValue
    }

    private func records(_ result: CallTool.Result) -> [[String: Value]] {
        result.structuredContent?.objectValue?["records"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    private func everything(_ result: CallTool.Result) -> String {
        result.content.compactMap {
            if case .text(let text, _, _) = $0 {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func start(_ rig: Rig) async throws {
        #expect(status(try await call(rig, "startDiagnostics")) == "ok")
    }

    /// Reads the stream until a record satisfies `matches`, returning every record read.
    private func read(
        _ rig: Rig, _ tool: String, _ arguments: [String: Value] = [:], until matches: ([String: Value]) -> Bool
    ) async throws -> [[String: Value]] {
        var all: [[String: Value]] = []
        _ = try await waitUntil {
            all = records(try await call(rig, tool, arguments))
            return all.contains(where: matches)
        }
        return all
    }

    private func text(_ record: [String: Value], _ key: String) -> String? {
        record[key]?.stringValue
    }

    // MARK: Query values

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func plainNamesStayAndEveryValueIsConcealed(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig)
        let secret = DiagnosticsTestKey.secret
        _ = try await rig.tab.page.evaluateJavaScript(
            "fetch('/api?token=hunter2&page=2&sid=\(secret)&again=\(secret)&x=https%3A%2F%2Fevil.test%2F%3Fk%3Dhunter2#fragsecret99').catch(() => {}); 0")
        let network = try await read(rig, "readNetwork") { ($0["url"]?.stringValue ?? "").contains("/api?") }
        let record = try #require(network.first { ($0["url"]?.stringValue ?? "").contains("/api?") })
        let url = try #require(text(record, "url"))
        let query = try #require(url.split(separator: "?").last).split(separator: "&").map(String.init)
        #expect(query.map { String($0.split(separator: "=")[0]) } == ["token", "page", "sid", "again", "x"], "names stay, in order: \(url)")
        let shown = query.map { String($0.split(separator: "=", maxSplits: 1)[1]) }
        #expect(shown[0] == "*short" && shown[1] == "*short" && shown[4] == "*medium", "guessable values show only a length class: \(shown)")
        #expect(shown[2].count == 17 && shown[2].hasPrefix("~") && shown[2].dropFirst().allSatisfy(\.isHexDigit), "\(shown)")
        #expect(shown[2] == shown[3], "equal generated values share a tag inside one document")
        let whole = everything(try await call(rig, "readNetwork"))
        #expect(!whole.contains("hunter2") && !whole.contains("evil.test") && !whole.contains(secret), "no query value reaches the client")
        #expect(!whole.contains("fragsecret99"))
    }

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func aTagMatchesNothingInAnotherDocumentOrAfterTheKeyChanges(engine: BrowserEngine) async throws {
        let secret = DiagnosticsTestKey.secret
        let second = "<!doctype html><title>Second</title><script>fetch('/api?sid=\(secret)').catch(() => {});</script><p>second</p>"
        let rig = try await makeRig(engine, routes: ["/second": .html(second)])
        defer { close(rig) }
        try await start(rig)
        func tags(_ network: [[String: Value]]) -> [String] {
            network.compactMap { record in
                let url = record["url"]?.stringValue ?? ""
                return url.contains("/api?sid=") ? url.split(separator: "=").last.map(String.init) : nil
            }
        }
        // The page's own request, then one the agent had the page make with a value it chose.
        _ = try await rig.tab.page.evaluateJavaScript("fetch('/api?sid=\(secret)').catch(() => {}); fetch('/api?sid=\(DiagnosticsTestKey.otherSecret)').catch(() => {}); 0")
        _ = try await waitUntil { tags(records(try await call(rig, "readNetwork"))).count == 2 }
        let first = tags(records(try await call(rig, "readNetwork")))
        #expect(first.count == 2 && first[0] != first[1], "a different value has a different tag: \(first)")
        // A key change inside the document: the same secret now has another tag, and the old tag no longer identifies it.
        try #require(rig.tab.developmentOwner?.diagnostics).rotateQueryKey()
        _ = try await rig.tab.page.evaluateJavaScript("fetch('/api?sid=\(secret)').catch(() => {}); 0")
        _ = try await waitUntil { tags(records(try await call(rig, "readNetwork"))).count == 3 }
        let rotated = tags(records(try await call(rig, "readNetwork")))
        #expect(rotated.count == 3 && rotated[2] != rotated[0], "the key changed: \(rotated)")
        // The next document: the same secret, supplied again, has yet another tag.
        rig.tab.page.load(URLRequest(url: try rig.server.url("/second")))
        try #require(await PageSettle.untilIdle(rig.tab.page))
        _ = try await waitUntil { !tags(records(try await call(rig, "readNetwork"))).isEmpty }
        let next = tags(records(try await call(rig, "readNetwork")))
        #expect(next.count == 1 && !first.contains(next[0]) && !rotated.contains(next[0]), "\(next) against \(rotated)")
    }

    // MARK: Resource facts

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func resourceLoadsCarryTypeStatusSizeAndTiming(engine: BrowserEngine) async throws {
        let page =
            "<!doctype html><title>Res</title><link rel=stylesheet href=/site.css?v=7><script src=/app.js></script><img src=/pic.png?size=1><p>x</p>"
        let rig = try await makeRig(engine, routes: ["/res": .html(page)])
        defer { close(rig) }
        try await start(rig)
        rig.tab.page.load(URLRequest(url: try rig.server.url("/res")))
        func has(_ type: String, _ path: String) -> ([String: Value]) -> Bool {
            { $0["type"]?.stringValue == type && ($0["url"]?.stringValue ?? "").contains(path) }
        }
        _ = try await waitUntil {
            let now = records(try await call(rig, "readNetwork"))
            return now.contains(where: has("stylesheet", "/site.css")) && now.contains(where: has("script", "/app.js")) && now.contains(where: has("image", "/pic.png"))
        }
        let all = records(try await call(rig, "readNetwork"))
        let image = try #require(all.first(where: has("image", "/pic.png")), "\(all)")
        #expect(all.contains(where: has("stylesheet", "/site.css")) && all.contains(where: has("script", "/app.js")))
        #expect((image["transferBytes"]?.intValue ?? 0) > 0, "a same-origin resource exposes its size: \(image)")
        #expect(image["durationMs"]?.intValue != nil)
        #expect(!(text(image, "url") ?? "").contains("size=1"))
        if engine == .chromium {
            #expect(image["status"]?.intValue == 200 && text(image, "mimeType") == "image/png" && text(image, "method") == "GET")
        } else {
            #expect(text(image, "source") == "webkit-resource")
            #expect(image["mimeType"] == .null && image["method"] == .null, "a resource entry names neither: unknown is null, never guessed")
        }
    }

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func fetchRecordsCarryTheMediaTypeAndRedirectsAreReported(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig)
        _ = try await rig.tab.page.evaluateJavaScript("fetch('/old').catch(() => {}); 0")
        let network = try await read(rig, "readNetwork") { $0["mimeType"]?.stringValue == "application/json" }
        let final = try #require(network.first { $0["mimeType"]?.stringValue == "application/json" })
        #expect(final["status"]?.intValue == 200 && text(final, "type") == "fetch", "\(final)")
        if engine == .chromium {
            let hop = try #require(network.first { ($0["url"]?.stringValue ?? "").hasSuffix("/old") })
            #expect(hop["status"]?.intValue == 302)
            #expect((text(hop, "redirectTo") ?? "").contains("/api?hop="), "\(hop)")
            #expect(!(text(hop, "redirectTo") ?? "").contains("hop=1"))
        } else {
            #expect(!network.contains { ($0["url"]?.stringValue ?? "").hasSuffix("/old") && $0["status"]?.intValue == 302 }, "WebKit does not see redirect hops")
        }
    }

    // MARK: Stacks

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func errorsCarryTheirLocationAndAStackThatNamesTheCallers(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig)
        _ = try await rig.tab.page.evaluateJavaScript(
            """
            function inner() { console.error(new RangeError('range-message')); }
            function outer() { inner(); }
            outer();
            setTimeout(function explode() { throw new TypeError('uncaught-message'); }, 0);
            console.log('plain'); 0
            """)
        let console = try await read(rig, "readConsole") { ($0["text"]?.stringValue ?? "").contains("uncaught-message") }
        let logged = try #require(console.first { ($0["text"]?.stringValue ?? "").contains("range-message") })
        #expect(text(logged, "text") == "RangeError: range-message")
        let stack = try #require(text(logged, "stack"), "\(logged)")
        #expect(stack.contains("inner") && stack.contains("outer"))
        #expect(stack.split(separator: "\n").count <= PageDiagnostics.maxStackFrames && stack.utf8.count <= PageDiagnostics.maxStackBytes)
        let uncaught = try #require(console.first { ($0["text"]?.stringValue ?? "").contains("uncaught-message") })
        #expect(uncaught["level"]?.stringValue == "error")
        #expect(text(uncaught, "stack")?.contains("explode") == true, "\(uncaught)")
        let plain = try #require(console.first { $0["text"]?.stringValue == "plain" })
        #expect(plain["stack"] == nil, "a log carries no stack")
    }

    // MARK: Filters

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func filtersAndSeqThroughTheTools(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig)
        _ = try await rig.tab.page.evaluateJavaScript(
            """
            console.log('l1'); console.warn('w1'); console.error('e1'); console.error('e2'); console.log('l2');
            fetch('/api?a=1').catch(() => {}); fetch('/missing').catch(() => {}); fetch('/api?b=2').catch(() => {}); 0
            """)
        _ = try await read(rig, "readConsole") { $0["text"]?.stringValue == "l2" }
        _ = try await read(rig, "readNetwork") { ($0["url"]?.stringValue ?? "").contains("b=") }
        let errors = records(try await call(rig, "readConsole", ["level": "error"]))
        #expect(errors.compactMap { $0["text"]?.stringValue } == ["e1", "e2"])
        // A page of one error, then the next from its cursor: the skipped records are not offered again.
        let first = try await call(rig, "readConsole", ["level": "error", "limit": 1])
        #expect(records(first).compactMap { $0["text"]?.stringValue } == ["e1"])
        let cursor = try #require(first.structuredContent?.objectValue?["nextCursor"]?.stringValue)
        let second = try await call(rig, "readConsole", ["level": "error", "limit": 1, "cursor": .string(cursor)])
        #expect(records(second).compactMap { $0["text"]?.stringValue } == ["e2"])
        #expect(second.structuredContent?.objectValue?["skipped"]?.intValue != nil)
        // Chromium may also ask for /favicon.ico, so the exact record is picked by its URL as well.
        let failing = records(try await call(rig, "readNetwork", ["minStatus": 400]))
        #expect(!failing.isEmpty && failing.allSatisfy { ($0["status"]?.intValue ?? 0) >= 400 })
        let missing = records(try await call(rig, "readNetwork", ["minStatus": 400, "urlContains": "/missing"]))
        #expect(missing.count == 1 && (text(missing[0], "url") ?? "").hasSuffix("/missing"))
        let api = records(try await call(rig, "readNetwork", ["urlContains": "/api", "type": "fetch", "outcome": "completed"]))
        #expect(api.count == 2)
        // One record by sequence number.
        let seq = try #require(api.first?["seq"]?.intValue)
        let one = try await call(rig, "readNetwork", ["seq": .int(seq)])
        #expect(records(one).count == 1 && records(one).first?["seq"]?.intValue == seq)
        let notYet = try await call(rig, "readNetwork", ["seq": 100_000])
        #expect(status(notYet) == "invalidInput" && notYet.isError == true)
        // Mistakes are errors with a message, never silently ignored.
        let mistakes: [(String, [String: Value])] = [
            ("readConsole", ["level": "fatal"]), ("readNetwork", ["outcome": "exploded"]), ("readNetwork", ["type": "font-ish"]),
            ("readNetwork", ["seq": 1, "limit": 5]), ("readConsole", ["seq": 1, "level": "error"]),
        ]
        for (tool, arguments) in mistakes {
            let result = try await call(rig, tool, arguments)
            #expect(status(result) == "invalidInput" && result.isError == true, "\(tool) \(arguments)")
        }
        // A filter the tool does not declare is refused before the tool runs.
        await #expect(throws: (any Error).self) { try await call(rig, "readNetwork", ["level": "error"]) }
        await #expect(throws: (any Error).self) { try await call(rig, "readConsole", ["minStatus": 400]) }
    }

    // MARK: The gap before the hook attaches

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func earlyEventsAfterANavigationAreCaptured(engine: BrowserEngine) async throws {
        let boot =
            "<!doctype html><title>Boot</title><script>console.warn('early-boot'); fetch('/api?early=hunter2').catch(() => {}); console.log('second-boot');</script><p>boot</p>"
        let rig = try await makeRig(engine, routes: ["/boot": .html(boot)])
        defer { close(rig) }
        try await start(rig)
        rig.tab.page.load(URLRequest(url: try rig.server.url("/boot")))
        try #require(await PageSettle.untilIdle(rig.tab.page))
        // Nothing has read the capture since the navigation: the new document's first script ran before any hook could have
        // been installed by a follow-up, so these come from what was in place at document start.
        let console = try await read(rig, "readConsole") { $0["text"]?.stringValue == "second-boot" }
        let texts = console.compactMap { $0["text"]?.stringValue }
        #expect(texts.contains("early-boot") && texts.contains("second-boot"), "\(texts)")
        let order = [texts.firstIndex(of: "early-boot"), texts.firstIndex(of: "second-boot")].compactMap { $0 }
        #expect(order == order.sorted() && order.count == 2, "in the order the page produced them")
        let network = try await read(rig, "readNetwork") { ($0["url"]?.stringValue ?? "").contains("/api?early=") }
        #expect(network.contains { ($0["url"]?.stringValue ?? "").contains("/api?early=*short") })
        let result = try await call(rig, "readConsole")
        #expect(!everything(result).contains("hunter2"))
        if engine == .webKit {
            #expect(result.structuredContent?.objectValue?["lostEarly"]?.intValue == 0)
        }
    }

    @Test(.boundedWebViews)
    func aStartUpBurstBeyondTheBufferIsReportedNotSilentlyLost() async throws {
        let burst = "<!doctype html><title>Burst</title><script>for (let i = 0; i < 300; i++) console.log('burst ' + i); console.log('burst-done');</script>"
        let rig = try await makeRig(.webKit, routes: ["/burst": .html(burst)])
        defer { close(rig) }
        try await start(rig)
        rig.tab.page.load(URLRequest(url: try rig.server.url("/burst")))
        let console = try await read(rig, "readConsole", ["limit": 100]) { $0["text"]?.stringValue == "burst-done" }
        let result = try await call(rig, "readConsole", ["limit": 100])
        // The page logged 301 messages before anything could attach: the newest 128 are delivered, the other 173 are counted.
        #expect(result.structuredContent?.objectValue?["lostEarly"]?.intValue == 173, "\(console.count) read")
        let first = try #require(records(result).first)
        #expect(text(first, "text") == "burst 173")
    }

    @Test(.boundedWebViews)
    func stopRemovesTheDocumentStartScript() async throws {
        let rig = try await makeRig(.webKit, routes: ["/probe": .html("<!doctype html><title>Probe</title><p>probe</p>")])
        defer { close(rig) }
        let controller = try #require(rig.tab.page.webKit).configuration.userContentController
        #expect(!controller.userScripts.contains { $0.source.contains("wsurf-diag-") })
        try await start(rig)
        let installed = controller.userScripts.filter { $0.source.contains("wsurf-diag-") }
        #expect(installed.count == 1)
        #expect(installed.first?.injectionTime == .atDocumentStart && installed.first?.isForMainFrameOnly == true)
        #expect(status(try await call(rig, "resetDevelopment")) == "ok")
        #expect(!controller.userScripts.contains { $0.source.contains("wsurf-diag-") })
        // A document that starts afterwards has the platform's own console.
        rig.tab.page.load(URLRequest(url: try rig.server.url("/probe")))
        try #require(await PageSettle.untilIdle(rig.tab.page))
        let native = try await rig.tab.page.evaluateJavaScript("console.warn.toString().includes('[native code]')") as? Bool
        #expect(native == true)
    }

    @Test(.boundedWebViews)
    func aPopupSharingTheControllerNeverRelays() async throws {
        let rig = try await makeRig(.webKit, routes: ["/popup": .html("<!doctype html><title>Popup</title><script>console.warn('from-popup');</script>")])
        defer { close(rig) }
        try await start(rig)
        let owner = try #require(rig.tab.page.webKit)
        // A window the page opens is built on a copy of its configuration, which shares the content controller.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: owner.configuration)
        #expect(popup.configuration.userContentController === owner.configuration.userContentController)
        popup.load(URLRequest(url: try rig.server.url("/popup")))
        #expect(await waitUntil { !popup.isLoading && popup.url?.path == "/popup" })
        let native = try await popup.evaluateJavaScript("console.warn.toString().includes('[native code]')") as? Bool
        #expect(native == false, "the buffering hook runs in the popup")
        _ = try await rig.tab.page.evaluateJavaScript("console.warn('from-owner'); 0")
        let console = try await read(rig, "readConsole") { $0["text"]?.stringValue == "from-owner" }
        #expect(!console.contains { $0["text"]?.stringValue == "from-popup" }, "nothing a popup logs reaches the capture")
    }

    // MARK: Hostile pages

    @Test(.boundedWebViews)
    func aPageThatPatchesTheBuiltinsAfterTheHookCannotRunCodeInIt() async throws {
        let hostile =
            """
            <!doctype html><title>Hostile</title><script>
            window.__trap = []; const trap = key => { __trap[__trap.length] = key; };
            for (const [target, key] of [[PerformanceEntry.prototype, 'name'], [PerformanceEntry.prototype, 'duration'],
                [PerformanceResourceTiming.prototype, 'initiatorType'], [PerformanceResourceTiming.prototype, 'transferSize'],
                [Response.prototype, 'headers'], [Response.prototype, 'status']]) {
              Object.defineProperty(target, key, { get() { trap(key); return 'x'; }, configurable: true });
            }
            Object.defineProperty(Headers.prototype, 'get', { value() { trap('Headers.get'); return 'text/evil'; }, configurable: true });
            // Other scripts of the page world may call these, so they are not traps: the hook is shown to have kept its own copies
            // by the records below staying intact.
            Object.defineProperty(Array.prototype, 'push', { value() { return 0; }, configurable: true });
            Object.defineProperty(JSON, 'stringify', { value() { return '{}'; }, configurable: true });
            fetch('/api?hostile=1').catch(() => {});
            new Image().src = '/pic.png?hostile=1';
            </script><p>hostile</p>
            """
        let rig = try await makeRig(.webKit, routes: ["/hostile": .html(hostile)])
        defer { close(rig) }
        try await start(rig)
        rig.tab.page.load(URLRequest(url: try rig.server.url("/hostile")))
        let network = try await read(rig, "readNetwork") { ($0["url"]?.stringValue ?? "").contains("/pic.png") }
        let fetched = try #require(network.first { ($0["url"]?.stringValue ?? "").contains("/api?") })
        #expect(fetched["status"]?.intValue == 200 && text(fetched, "mimeType") == "application/json", "\(fetched)")
        let image = try #require(network.first { ($0["url"]?.stringValue ?? "").contains("/pic.png") })
        #expect(image["type"]?.stringValue == "image" && (image["transferBytes"]?.intValue ?? 0) > 0, "\(image)")
        let trapped = try await rig.tab.page.evaluateJavaScript("window.__trap.join(',')")
        #expect(trapped as? String == "", "the page's own code ran inside the hook: \(trapped ?? "nil")")
    }
}
