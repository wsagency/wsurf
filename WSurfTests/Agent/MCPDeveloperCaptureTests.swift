// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Header, body and full-console capture on a live page of each engine, driven through `startDiagnostics` and read through
/// `readNetwork` and `readConsole`: who may ask, what is hidden, what is cut, and what happens to a request that leaves the
/// developer sites. The app under test is a loopback server that is the one developer site; a second loopback server on another
/// port is "another site".
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPDeveloperCaptureTests {
    private static let secret = "Zx9-test-Pa$$word!"
    private static let hidden = PageDiagnostics.Redaction.hidden

    private static let page = """
        <!doctype html><title>App</title><p>app</p>
        <script>
          function logIt() {
            const loop = { name: 'loop' };
            loop.self = loop;
            console.log('hello', { a: { b: { c: { d: 1 } } }, password: 'hunter2-secret', list: Array.from({ length: 100 }, (_, i) => i), loop });
            console.info('plain', 1);
          }
        </script>
        """

    private struct Rig {
        let app: HTTPFixtureServer
        let other: HTTPFixtureServer
        let browser: BrowserModel
        let trust: MCPTrustStore
        let session: MCPBrowserSession
        let tab: BrowserTab
        var window: NSWindow?
    }

    private static let cors = [
        "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "*",
    ]

    /// A tab on the app, whose only developer site is the app's own address and port (nothing else counts, not even the other
    /// server on the same host). `standing` is the paired client's level; with `.off` the Developer tier comes from the sheet.
    private func makeRig(
        _ engine: BrowserEngine, standing: PairedClient.Standing = .developer, answer: MCPAccessConsent.Access? = .developer,
        extra: [String: HTTPFixtureServer.Response] = [:]
    ) async throws -> Rig {
        let other = try await HTTPFixtureServer.start(routes: [
            "/data": .init(status: "200 OK", headers: Self.cors.merging(["Content-Type": "application/json"]) { $1 }, body: Data("{\"third\":\"party-body\"}".utf8)),
        ])
        let echo = HTTPFixtureServer.Response(
            status: "200 OK",
            headers: ["Content-Type": "application/json", "Set-Cookie": "sid=cookie-value-0123456789; HttpOnly", "X-Server": "demo"],
            body: Data("{\"ok\":true,\"name\":\"ann\",\"password\":\"srv-secret\"}".utf8))
        let routes: [String: HTTPFixtureServer.Response] = [
            "/": .html(Self.page), "/api": .bytes(Data("{\"ok\":true}".utf8), contentType: "application/json"), "/echo": echo, "/echo-xhr": echo,
            "/big": .bytes(Data(String(repeating: "x", count: 100_000).utf8), contentType: "text/plain"),
            "/go": .redirect(to: try other.url("/data")),
        ]
        let app = try await HTTPFixtureServer.start(routes: routes.merging(extra) { $1 })
        let url = try app.url()
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(standing, for: client.id)
        try trust.setDeveloperProfile(Profile.originalID)
        try trust.setIncludesThisMac(false)
        let port = try #require(url.port)
        try trust.addDeveloperSite("127.0.0.1:\(port)")
        let permissions = SitePermissions(storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPCapture-\(UUID().uuidString).json"))
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
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true }, consent: { _, _, _ in answer }, openConsent: { _, _ in false })
        session.pairedClient = trust.client(id: client.id)
        _ = try await session.call(name: "requestAccess", arguments: ["development": true, "developer": true])
        return Rig(app: app, other: other, browser: browser, trust: trust, session: session, tab: tab, window: window)
    }

    private func close(_ rig: Rig) {
        rig.session.revoke()
        rig.window?.contentView = nil
        rig.window?.close()
        withExtendedLifetime((rig.app, rig.other)) {}
    }

    private func call(_ rig: Rig, _ name: String, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        try await rig.session.call(name: name, arguments: arguments.merging(["tabID": .string(rig.tab.id.uuidString)]) { $1 })
    }

    private func status(_ result: CallTool.Result) -> String? {
        result.structuredContent?.objectValue?["status"]?.stringValue
    }

    private func records(_ result: CallTool.Result) -> [[String: Value]] {
        result.structuredContent?.objectValue?["records"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    private func everything(_ result: CallTool.Result) -> String {
        let blocks = result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }
        let structured = result.structuredContent.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? ""
        return (blocks + [structured]).joined(separator: "\n")
    }

    private func start(_ rig: Rig, _ options: [String: Value] = [:]) async throws {
        let result = try await call(rig, "startDiagnostics", options)
        try #require(status(result) == "ok", "\(everything(result))")
    }

    /// Runs `script` in the page without returning its promise.
    private func run(_ rig: Rig, _ script: String) async throws {
        _ = try await rig.tab.page.evaluateJavaScript(script + "; 0")
    }

    /// Reads `tool` until a record satisfies `matches`, and returns every record read.
    private func read(_ rig: Rig, _ tool: String = "readNetwork", until matches: ([String: Value]) -> Bool) async throws -> [[String: Value]] {
        var all: [[String: Value]] = []
        _ = try await waitUntil {
            all = records(try await call(rig, tool))
            return all.contains(where: matches)
        }
        return all
    }

    private func record(_ all: [[String: Value]], path: String) throws -> [String: Value] {
        try #require(all.first { ($0["url"]?.stringValue ?? "").contains(path) }, "no record for \(path) in \(all)")
    }

    private func text(_ record: [String: Value], _ key: String) -> String {
        record[key]?.stringValue ?? ""
    }

    private let detailKeys = ["requestHeaders", "responseHeaders", "requestBody", "responseBody", "requestBodyNote", "responseBodyNote", "requestBodyBytes", "responseBodyBytes"]

    private static let post = """
        fetch('/echo?x=hello', { method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer abc.def', 'X-Api-Key': 'key-123', 'X-Trace': 'trace-ok' },
          body: JSON.stringify({ user: 'ann', password: 'hunter2', nested: { token: 'tok-xyz', n: 1 } }) }).catch(() => {})
        """

    // MARK: Opt-in and tier

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func headersAndBodiesNeedTheOptInAndTheDeveloperTier(engine: BrowserEngine) async throws {
        // Development access is not the Developer tier: the options are refused, nothing is started and no lease is taken.
        let development = try await makeRig(engine, standing: .development, answer: .development)
        defer { close(development) }
        #expect(!development.session.permits(development.tab, capability: .developer))
        for option in ["headers", "bodies", "fullConsole", "clearQueries"] {
            let refused = try await call(development, "startDiagnostics", [option: true])
            #expect(status(refused) == "denied" && refused.isError == true, "\(option): \(everything(refused))")
            #expect(development.tab.developmentOwner == nil, "\(option): a refusal takes no lease")
        }
        try await start(development)
        try await run(development, Self.post)
        let plain = try record(try await read(development) { ($0["url"]?.stringValue ?? "").contains("/echo") }, path: "/echo")
        for key in detailKeys {
            #expect(plain[key] == nil, "\(key) needs the Developer tier")
        }

        // In the Developer tier, a capture started without the options still records metadata only.
        let developer = try await makeRig(engine)
        defer { close(developer) }
        #expect(developer.session.permits(developer.tab, capability: .developer))
        try await start(developer)
        try await run(developer, Self.post)
        let metadata = try record(try await read(developer) { ($0["url"]?.stringValue ?? "").contains("/echo") }, path: "/echo")
        for key in detailKeys + ["detail"] {
            #expect(metadata[key] == nil, "\(key) is opt-in")
        }
        #expect(metadata["status"]?.intValue == 200)
    }

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func detailStopsWhenTheTierEndsMidCapture(engine: BrowserEngine) async throws {
        // The Developer tier comes from the sheet here, so removing the pairing lowers the grant to Development and keeps the lease.
        let rig = try await makeRig(engine, standing: .off, answer: .developer)
        defer { close(rig) }
        try #require(rig.session.permits(rig.tab, capability: .developer))
        try await start(rig, ["headers": true, "bodies": true])
        try await run(rig, Self.post)
        let first = try record(try await read(rig) { ($0["url"]?.stringValue ?? "").contains("/echo") }, path: "/echo")
        #expect(first["requestHeaders"] != nil)

        rig.session.pairedClient = nil
        #expect(!rig.session.permits(rig.tab, capability: .developer) && rig.session.permits(rig.tab, capability: .development))
        try await run(rig, "fetch('/api?second=1', { method: 'POST', headers: { 'X-Trace': 'later' }, body: 'later-body' }).catch(() => {})")
        let all = try await read(rig) { ($0["url"]?.stringValue ?? "").contains("/api?") }
        let second = try record(all, path: "/api?")
        for key in detailKeys {
            #expect(second[key] == nil, "\(key) is never recorded once the tier is gone")
        }
        #expect(text(second, "detail").contains("Developer access"))
        let info = try await call(rig, "readNetwork")
        #expect(info.structuredContent?.objectValue?["detail"]?.objectValue?["active"]?.boolValue == false)
    }

    // MARK: What is hidden

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func credentialsAreHiddenInHeadersAndBodiesAndTheRestIsShown(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig, ["headers": true, "bodies": true])
        try await run(rig, Self.post)
        let all = try await read(rig) { ($0["url"]?.stringValue ?? "").contains("/echo") && $0["responseBody"] != nil }
        let echo = try record(all, path: "/echo")

        let requestHeaders = text(echo, "requestHeaders")
        #expect(requestHeaders.contains("authorization: \(Self.hidden)") && requestHeaders.contains("x-api-key: \(Self.hidden)"), "\(requestHeaders)")
        #expect(requestHeaders.contains("x-trace: trace-ok") && requestHeaders.contains("content-type: application/json"), "\(requestHeaders)")
        let requestBody = text(echo, "requestBody")
        #expect(requestBody.contains("\"user\":\"ann\"") && requestBody.contains("\"n\":1"), "\(requestBody)")
        #expect(requestBody.contains("\"password\":\"\(Self.hidden)\"") && requestBody.contains("\"token\":\"\(Self.hidden)\""), "\(requestBody)")
        let responseHeaders = text(echo, "responseHeaders")
        #expect(responseHeaders.contains("x-server: demo") && responseHeaders.contains("content-type: application/json"), "\(responseHeaders)")
        let responseBody = text(echo, "responseBody")
        #expect(responseBody.contains("\"name\":\"ann\"") && responseBody.contains("\"password\":\"\(Self.hidden)\""), "\(responseBody)")
        #expect(echo["detail"] == nil)

        // No hidden value is anywhere in what a client reads: not in the records, not in the reply around them.
        let reply = everything(try await call(rig, "readNetwork"))
        for leaked in ["abc.def", "key-123", "hunter2", "tok-xyz", "srv-secret", "cookie-value-0123456789"] {
            #expect(!reply.contains(leaked), "\(leaked) is in the reply")
        }
        if engine == .chromium {
            #expect(responseHeaders.contains("set-cookie: \(Self.hidden)"), "Chromium reports the cookie it was sent as a name only: \(responseHeaders)")
        }
        // Query values stay concealed unless clear values were asked for.
        #expect(!text(echo, "url").contains("hello"))
    }

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func formBodiesAndXMLHttpRequestsAreHiddenLikeJson(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig, ["headers": true, "bodies": true])
        try await run(
            rig,
            """
            fetch('/echo', { method: 'POST', body: new URLSearchParams({ user: 'ann', password: 'hunter2', 'card_number': '4111' }) }).catch(() => {});
            const xhr = new XMLHttpRequest();
            xhr.open('POST', '/echo-xhr');
            xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.setRequestHeader('Authorization', 'Bearer abc.def');
            xhr.setRequestHeader('X-Trace', 'xhr-ok');
            xhr.send(JSON.stringify({ user: 'bob', otp: '123456' }))
            """)
        var all: [[String: Value]] = []
        try #require(
            await waitUntil {
                all = records(try await call(rig, "readNetwork"))
                func done(_ path: String) -> Bool {
                    all.contains { ($0["url"]?.stringValue ?? "").hasSuffix(path) && $0["responseBody"] != nil && $0["requestBody"] != nil }
                }
                return done("/echo") && done("/echo-xhr")
            })
        let sent = all.filter { $0["requestBody"] != nil }
        let form = try #require(sent.first { text($0, "requestBody").contains("user=ann") || text($0, "requestBody").contains("card_number") }, "\(sent)")
        #expect(text(form, "requestBody").contains("user=ann") && text(form, "requestBody").contains("password=\(Self.hidden)"), "\(text(form, "requestBody"))")
        #expect(text(form, "requestBody").contains("card_number=\(Self.hidden)") && !text(form, "requestBody").contains("4111"))
        let xhr = try #require(sent.first { text($0, "requestBody").contains("bob") }, "\(sent)")
        #expect(text(xhr, "requestBody").contains("\"otp\":\"\(Self.hidden)\"") && text(xhr, "requestBody").contains("\"user\":\"bob\""), "\(text(xhr, "requestBody"))")
        #expect(text(xhr, "requestHeaders").contains("authorization: \(Self.hidden)") && text(xhr, "requestHeaders").contains("x-trace: xhr-ok"), "\(text(xhr, "requestHeaders"))")
        #expect(text(xhr, "responseBody").contains("\"name\":\"ann\""), "\(text(xhr, "responseBody"))")
        let reply = everything(try await call(rig, "readNetwork"))
        for leaked in ["hunter2", "123456", "abc.def", "4111"] {
            #expect(!reply.contains(leaked), "\(leaked) is in the reply")
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func aSecretTheConnectionTypedNeverReachesABodyOrAHeader(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        rig.session.secrets.register(Self.secret)
        try await start(rig, ["headers": true, "bodies": true])
        let encoded = Self.secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        try await run(
            rig,
            """
            fetch('/echo', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Note': 'typed \(Self.secret)' },
              body: JSON.stringify({ note: '\(Self.secret)', other: '\(encoded)' }) }).catch(() => {})
            """)
        let all = try await read(rig) { ($0["url"]?.stringValue ?? "").contains("/echo") && $0["requestBody"] != nil }
        let echo = try record(all, path: "/echo")
        let shown = [text(echo, "requestBody"), text(echo, "requestHeaders")].joined(separator: "\n")
        #expect(shown.contains(MCPSecretScrubber.replacement), "\(shown)")
        #expect(!everything(try await call(rig, "readNetwork")).contains("Pa$$"), "the secret is not in the reply")
        for form in [Self.secret, encoded, "Pa%24%24"] {
            #expect(!shown.contains(form), "\(form) is in \(shown)")
        }
    }

    // MARK: Developer sites only

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func thirdPartyRequestsNeverExposeBodies(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig, ["headers": true, "bodies": true, "clearQueries": true])
        let target = try rig.other.url("/data?x=hello").absoluteString
        try await run(rig, "fetch('\(target)', { method: 'POST', headers: { 'X-Trace': 'other', 'Content-Type': 'text/plain' }, body: 'other-request-body' }).catch(() => {})")
        let all = try await read(rig) { ($0["url"]?.stringValue ?? "").contains("/data") }
        let other = try record(all, path: "/data")
        for key in detailKeys {
            #expect(other[key] == nil, "\(key) belongs to a request to a developer site only")
        }
        #expect(text(other, "detail").hasPrefix("not captured"), "the record says why: \(text(other, "detail"))")
        #expect(!text(other, "url").contains("hello"), "another site's query values stay concealed even when clear values were asked for: \(text(other, "url"))")
        let reply = everything(try await call(rig, "readNetwork"))
        #expect(!reply.contains("party-body") && !reply.contains("other-request-body"))
    }

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func aRedirectThatLeavesTheDeveloperSitesIsDroppedAtTheBoundary(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig, ["headers": true, "bodies": true])
        try await run(rig, "fetch('/go', { method: 'POST', body: 'sent-body' }).catch(() => {})")
        let all = try await read(rig) { record in
            let address = record["url"]?.stringValue ?? ""
            return address.contains("/data") || (address.contains("/go") && record["status"]?.intValue == 200)
        }
        let reply = everything(try await call(rig, "readNetwork"))
        #expect(!reply.contains("party-body"), "nothing the other site answered is recorded")
        if engine == .chromium {
            // The hop is the developer site's own response: its side is recorded, and the address it points to is not given away.
            let hop = try record(all, path: "/go")
            #expect(text(hop, "requestBody") == "sent-body")
            let landed = try record(all, path: "/data")
            for key in detailKeys {
                #expect(landed[key] == nil, "\(key) of the request after the redirect")
            }
            #expect(text(landed, "detail").hasPrefix("not captured"), "\(text(landed, "detail"))")
        } else {
            // WebKit reports the call as the page made it. The page saw that its answer came from elsewhere and kept nothing.
            let redirected = try record(all, path: "/go")
            for key in detailKeys {
                #expect(redirected[key] == nil, "\(key) of a call that was redirected away")
            }
            #expect(text(redirected, "detail").hasPrefix("not captured"), "\(text(redirected, "detail"))")
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func queryValuesAreClearOnlyForDeveloperSites(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig, ["clearQueries": true])
        let other = try rig.other.url("/data?x=elsewhere").absoluteString
        try await run(rig, "fetch('/api?x=hello&n=5').catch(() => {}); fetch('\(other)').catch(() => {})")
        var all: [[String: Value]] = []
        try #require(
            await waitUntil {
                all = records(try await call(rig, "readNetwork"))
                let addresses = all.compactMap { $0["url"]?.stringValue }
                return addresses.contains { $0.contains("/api") } && addresses.contains { $0.contains("/data") }
            })
        let own = try record(all, path: "/api")
        #expect(text(own, "url").hasSuffix("/api?x=hello&n=5"), "\(text(own, "url"))")
        let elsewhere = try record(all, path: "/data")
        #expect(!text(elsewhere, "url").contains("elsewhere"), "\(text(elsewhere, "url"))")
        for key in detailKeys {
            #expect(own[key] == nil, "clear values are not headers or bodies")
        }
    }

    // MARK: Limits

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func aBodyIsCutAtItsLimitAndSaysSo(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig, ["bodies": true])
        try await run(rig, "fetch('/big').catch(() => {})")
        let all = try await read(rig) { ($0["url"]?.stringValue ?? "").contains("/big") && $0["responseBody"] != nil }
        let big = try record(all, path: "/big")
        #expect(text(big, "responseBody").utf8.count == PageDiagnostics.Redaction.maxBodyBytes)
        #expect(text(big, "responseBodyNote").hasPrefix("truncated"), "\(text(big, "responseBodyNote"))")
        #expect(big["truncated"]?.boolValue == true)
        #expect(everything(try await call(rig, "readNetwork")).utf8.count < 250_000, "a reply stays inside one transport line")
    }

    // MARK: Console

    @Test(.timeLimit(.minutes(3)), arguments: [BrowserEngine.webKit, BrowserEngine.chromium])
    func consolePreviewsAreBounded(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { close(rig) }
        try await start(rig, ["fullConsole": true])
        try await run(rig, "logIt()")
        let all = try await read(rig, "readConsole") { $0["text"]?.stringValue?.hasPrefix("plain") == true }
        let hello = try #require(all.first { $0["text"]?.stringValue?.hasPrefix("hello") == true }, "\(all)")
        let preview = text(hello, "preview")
        #expect(!preview.isEmpty && preview.utf8.count <= PageDiagnostics.Redaction.maxPreviewBytes, "\(preview.utf8.count) bytes")
        #expect(preview.contains("\"a\"") && preview.contains(Self.hidden), "\(preview)")
        #expect(!preview.contains("hunter2-secret"), "\(preview)")
        #expect(!preview.contains("\"d\":1"), "an object deeper than three levels is replaced: \(preview)")
        #expect(text(hello, "stack").contains("logIt"), "every call carries a stack: \(text(hello, "stack"))")
        #expect(text(try #require(all.first { $0["text"]?.stringValue?.hasPrefix("plain") == true }), "stack").contains("logIt"))
        #expect(!everything(try await call(rig, "readConsole")).contains("hunter2-secret"))

        // Without the opt-in the same call carries neither.
        let plain = try await makeRig(engine)
        defer { close(plain) }
        try await start(plain)
        try await run(plain, "logIt()")
        let basic = try await read(plain, "readConsole") { $0["text"]?.stringValue?.hasPrefix("plain") == true }
        let bare = try #require(basic.first { $0["text"]?.stringValue?.hasPrefix("hello") == true })
        #expect(bare["preview"] == nil && bare["stack"] == nil)
    }
}
