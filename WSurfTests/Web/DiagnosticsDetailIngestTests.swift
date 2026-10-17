// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// How Chromium DevTools events and WebKit hook messages become detail: only for a request to a developer site, only while the
/// tier holds, and with credentials replaced as soon as an event is read. Synthetic events, no engine.
struct DiagnosticsDetailIngestTests {
    private static let hidden = PageDiagnostics.Redaction.hidden
    private static let site = "http://127.0.0.1:3000"

    private func policy(
        tier: Bool = true, headers: Bool = true, bodies: Bool = true, clear: Bool = false, console: Bool = false
    ) -> PageDiagnostics.DetailPolicy {
        PageDiagnostics.DetailPolicy(
            options: .init(headers: headers, bodies: bodies, console: console, clearQueries: clear), tier: tier, anyPortHosts: ["127.0.0.1"],
            isDeveloperSite: { MCPDeveloperAccess.matches($0, sites: [], includesThisMac: true) })
    }

    private func mapper(_ policy: PageDiagnostics.DetailPolicy) -> ChromiumDiagnosticsMapper {
        let mapper = ChromiumDiagnosticsMapper(queryValues: DiagnosticsTestKey.values)
        mapper.detail = policy
        return mapper
    }

    private func send(
        _ mapper: ChromiumDiagnosticsMapper, id: String = "1", url: String, method: String = "POST", headers: [String: String] = [:],
        postData: String? = nil, redirect: [String: Any]? = nil
    ) -> PageDiagnostics.Entry? {
        var request: [String: Any] = ["url": url, "method": method, "headers": headers]
        if let postData { request["postData"] = postData }
        var params: [String: Any] = ["requestId": id, "timestamp": 100.0, "request": request, "type": "Fetch", "loaderId": "doc", "frameId": "main"]
        if let redirect { params["redirectResponse"] = redirect }
        return mapper.entry(method: "Network.requestWillBeSent", params: params)
    }

    private func respond(
        _ mapper: ChromiumDiagnosticsMapper, id: String = "1", status: Int = 200, mime: String = "application/json", headers: [String: String] = [:]
    ) {
        _ = mapper.entry(method: "Network.responseReceived", params: [
            "requestId": id, "type": "Fetch", "response": ["status": status, "mimeType": mime, "headers": headers],
        ])
    }

    private func finish(_ mapper: ChromiumDiagnosticsMapper, id: String = "1", bytes: Int = 40) -> PageDiagnostics.Entry? {
        mapper.entry(method: "Network.loadingFinished", params: ["requestId": id, "timestamp": 100.25, "encodedDataLength": bytes])
    }

    private func text(_ entry: PageDiagnostics.Entry?, _ key: String) -> String? {
        guard case .text(let value)? = entry?.fields[key] else { return nil }
        return value
    }

    // MARK: Chromium

    @Test func aDeveloperSiteRequestKeepsRedactedHeadersAndItsBodyForTheOwner() throws {
        let mapper = mapper(policy())
        #expect(send(mapper, url: "\(Self.site)/api?x=1", headers: [
            "Authorization": "Bearer hunter2", "Content-Type": "application/json", "X-Trace": "ok", "Cookie": "sid=cookie-value-1",
        ], postData: "{\"password\":\"p4ss\",\"a\":1}") == nil)
        _ = mapper.entry(method: "Network.requestWillBeSentExtraInfo", params: ["requestId": "1", "headers": ["Cookie": "sid=cookie-value-2", "Accept": "*/*"]])
        respond(mapper, headers: ["Content-Type": "application/json", "Set-Cookie": "sid=set-cookie-value", "X-Server": "demo"])
        _ = mapper.entry(method: "Network.responseReceivedExtraInfo", params: ["requestId": "1", "headers": ["set-cookie": "sid=another-value"]])
        let entry = try #require(finish(mapper))

        let detail = try #require(entry.detail)
        let request = Dictionary(uniqueKeysWithValues: try #require(detail.requestHeaders).map { ($0.name, $0.value) })
        #expect(request["authorization"] == Self.hidden && request["cookie"] == Self.hidden)
        #expect(request["content-type"] == "application/json" && request["x-trace"] == "ok" && request["accept"] == "*/*", "extra headers are merged")
        let response = Dictionary(uniqueKeysWithValues: try #require(detail.responseHeaders).map { ($0.name, $0.value) })
        #expect(response["set-cookie"] == Self.hidden && response["x-server"] == "demo")
        // No credential value is held anywhere in the entry, before the owner has made a record of it.
        let held = String(describing: entry.detail?.requestHeaders) + String(describing: entry.detail?.responseHeaders)
        for secret in ["hunter2", "cookie-value", "set-cookie-value", "another-value"] {
            #expect(!held.contains(secret), "\(secret) is held in \(held)")
        }
        #expect(entry.bodyFetch == .init(requestID: "1", response: true, requestPost: false, mimeType: "application/json"))
        var budget = PageDiagnostics.Redaction.captureBodyBytes
        var input = detail
        input.responseBody = .init(text: "{\"token\":\"t\",\"ok\":true}", contentType: "application/json")
        let fields = PageDiagnostics.detailFields(input, options: policy().options, budget: &budget, scrub: { $0 }).fields
        #expect(fields["requestBody"] == .text("{\"a\":1,\"password\":\"\(Self.hidden)\"}"))
        #expect(fields["responseBody"] == .text("{\"ok\":true,\"token\":\"\(Self.hidden)\"}"))
    }

    @Test func aThirdPartyRequestKeepsNothingAndFetchesNothing() throws {
        let mapper = mapper(policy(clear: true))
        _ = send(mapper, url: "https://example.com/api?token=hunter2", headers: ["Authorization": "Bearer hunter2"], postData: "{\"a\":1}")
        respond(mapper)
        let entry = try #require(finish(mapper))
        #expect(entry.detail == nil && entry.bodyFetch == nil)
        #expect(text(entry, "url") == "https://example.com/api?token=*short", "a third party's query stays concealed, even when clear values were asked for")
    }

    @Test(arguments: ["no tier", "no options"])
    func withoutTheTierOrTheOptInNothingIsKept(scenario: String) throws {
        let mapper = mapper(scenario == "no tier" ? policy(tier: false) : policy(headers: false, bodies: false))
        _ = send(mapper, url: "\(Self.site)/api", headers: ["Authorization": "Bearer hunter2"], postData: "{\"a\":1}")
        respond(mapper)
        let entry = try #require(finish(mapper))
        #expect(entry.detail == nil && entry.bodyFetch == nil)
    }

    @Test func aRedirectOffTheDeveloperSitesEndsWhatIsKept() throws {
        let mapper = mapper(policy())
        _ = send(mapper, url: "\(Self.site)/go", headers: ["Content-Type": "application/json", "Authorization": "Bearer hunter2"], postData: "{\"a\":1}")
        let hop = try #require(
            send(
                mapper, url: "https://example.com/landing?token=abc123", method: "POST", headers: ["Authorization": "Bearer hunter2", "X-Leak": "leak-value"],
                postData: "{\"leak\":1}",
                redirect: ["status": 302, "mimeType": "text/html", "headers": ["Location": "https://example.com/landing?token=abc123", "Set-Cookie": "sid=hop-cookie"]]))
        // The hop is a response of the developer site: its own side is recorded, and the address it redirects to is concealed.
        let detail = try #require(hop.detail)
        #expect(detail.url == "\(Self.site)/go")
        #expect(detail.requestBody?.text == "{\"a\":1}")
        let location = detail.responseHeaders?.first { $0.name == "location" }?.value
        #expect(location == "https://example.com/landing?token=*short", "\(location ?? "nil")")
        #expect(text(hop, "redirectTo") == "https://example.com/landing?token=*short")
        #expect(!String(describing: hop).contains("leak-value") && !String(describing: hop).contains("hop-cookie"))
        // What the redirect led to is a request to another site: nothing of it is kept, nor fetched.
        respond(mapper, mime: "application/json", headers: ["X-Third": "party"])
        let landing = try #require(finish(mapper))
        #expect(landing.detail == nil && landing.bodyFetch == nil)
        #expect(!String(describing: landing).contains("leak"))
        #expect(text(landing, "url") == "https://example.com/landing?token=*short")
    }

    @Test func queryValuesAreClearOnlyForDeveloperSites() throws {
        let mapper = mapper(policy(headers: false, bodies: false, clear: true))
        _ = send(mapper, id: "1", url: "\(Self.site)/api?x=hello&t=a1B2c3D4e5F6g7H8i9J0", method: "GET")
        _ = send(mapper, id: "2", url: "https://example.com/api?x=hello", method: "GET")
        let own = try #require(finish(mapper, id: "1"))
        let other = try #require(finish(mapper, id: "2"))
        #expect(text(own, "url") == "\(Self.site)/api?x=hello&t=a1B2c3D4e5F6g7H8i9J0")
        #expect(text(other, "url") == "https://example.com/api?x=*short")
        #expect(own.detail == nil, "clear values are not headers or bodies")
    }

    @Test func largeBinaryAndInlineMissingBodiesAreSummarizedOrFetched() throws {
        let mapper = mapper(policy())
        _ = send(mapper, id: "1", url: "\(Self.site)/pic.png", method: "GET")
        respond(mapper, id: "1", mime: "image/png")
        let image = try #require(finish(mapper, id: "1", bytes: 900))
        #expect(image.bodyFetch == nil)
        #expect(image.detail?.responseBody == .init(contentType: "image/png", size: 900, binary: true))

        _ = send(mapper, id: "2", url: "\(Self.site)/huge", method: "GET")
        respond(mapper, id: "2", mime: "application/json")
        let huge = try #require(finish(mapper, id: "2", bytes: ChromiumDiagnosticsMapper.maxFetchedBodyBytes + 1))
        #expect(huge.bodyFetch == nil)
        #expect(huge.detail?.responseBody?.note == "not captured: larger than 1 MiB")

        let params: [String: Any] = [
            "requestId": "3", "timestamp": 1.0, "type": "Fetch", "loaderId": "doc", "frameId": "main",
            "request": ["url": "\(Self.site)/upload", "method": "POST", "headers": ["Content-Type": "application/json"], "hasPostData": true],
        ]
        _ = mapper.entry(method: "Network.requestWillBeSent", params: params)
        respond(mapper, id: "3")
        let upload = try #require(finish(mapper, id: "3"))
        #expect(upload.bodyFetch == .init(requestID: "3", response: true, requestPost: true, mimeType: "application/json"))
        #expect(upload.detail?.requestBody?.contentType == "application/json", "the type is kept for the body the owner fetches")
    }

    @Test func aFailedRequestIsRecordedWithItsHeadersButNoBodyFetch() throws {
        let mapper = mapper(policy())
        _ = send(mapper, url: "\(Self.site)/api", headers: ["X-Trace": "ok"], postData: "{\"a\":1}")
        let failed = try #require(mapper.entry(method: "Network.loadingFailed", params: ["requestId": "1", "timestamp": 100.1, "canceled": false]))
        #expect(failed.detail?.requestHeaders?.first { $0.name == "x-trace" }?.value == "ok")
        #expect(failed.bodyFetch == nil)
    }

    // MARK: Console previews

    @Test func theFullConsoleTakesAPreviewFromDevToolsAndNeverTheStackOfALogOtherwise() throws {
        let preview: [String: Any] = [
            "type": "object", "overflow": false,
            "properties": [
                ["name": "user", "type": "string", "value": "ann"],
                ["name": "password", "type": "string", "value": "hunter2"],
                ["name": "count", "type": "number", "value": "3"],
                ["name": "later", "type": "accessor"],
                [
                    "name": "nested", "type": "object", "value": "Object",
                    "valuePreview": ["type": "object", "overflow": true, "properties": [["name": "a", "type": "boolean", "value": "true"]]],
                ],
            ],
        ]
        let args: [[String: Any]] = [["type": "string", "value": "hi"], ["type": "object", "className": "Object", "preview": preview]]
        let trace: [String: Any] = ["callFrames": [["functionName": "logIt", "url": "http://127.0.0.1:3000/app.js", "lineNumber": 4, "columnNumber": 2]]]
        let params: [String: Any] = ["type": "log", "args": args, "stackTrace": trace]

        let full = try #require(mapper(policy(console: true)).entry(method: "Runtime.consoleAPICalled", params: params))
        let json = try #require(text(full, "preview"))
        let list = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        let object = try #require(list.last as? [String: Any])
        #expect(list.first as? String == "hi")
        #expect(object["user"] as? String == "ann" && object["count"] as? Int == 3 && object["later"] as? String == "[getter]")
        #expect(object["password"] as? String == Self.hidden)
        #expect((object["nested"] as? [String: Any])?["a"] as? Bool == true)
        #expect(!json.contains("hunter2"))
        #expect(text(full, "stack")?.contains("logIt") == true, "every call has a stack in the full console")
        #expect(full.fields["text"] == .text("hi [object omitted]"), "the plain text is as before")

        let plain = try #require(mapper(policy()).entry(method: "Runtime.consoleAPICalled", params: params))
        #expect(plain.fields["preview"] == nil && plain.fields["stack"] == nil, "without the opt-in a log carries neither")
        let noTier = try #require(mapper(policy(tier: false, console: true)).entry(method: "Runtime.consoleAPICalled", params: params))
        #expect(noTier.fields["preview"] == nil && noTier.fields["stack"] == nil)
    }

    @Test func aPreviewIsBoundedInDepthAndSize() throws {
        func nested(_ depth: Int) -> [String: Any] {
            depth == 0
                ? ["type": "object", "properties": [["name": "leaf", "type": "number", "value": "1"]]]
                : ["type": "object", "properties": [["name": "next", "type": "object", "value": "Object", "valuePreview": nested(depth - 1)]]]
        }
        let params: [String: Any] = ["type": "log", "args": [["type": "object", "preview": nested(6)] as [String: Any]]]
        let entry = try #require(mapper(policy(console: true)).entry(method: "Runtime.consoleAPICalled", params: params))
        let json = try #require(text(entry, "preview"))
        #expect(json == "[{\"next\":{\"next\":{\"next\":\"[object]\"}}}]", "\(json)")

        let many = (0..<200).map { ["name": "k\($0)", "type": "string", "value": String(repeating: "v", count: 300)] as [String: Any] }
        let wide: [String: Any] = ["type": "log", "args": [["type": "object", "preview": ["type": "object", "overflow": true, "properties": many]] as [String: Any]]]
        let big = try #require(mapper(policy(console: true)).entry(method: "Runtime.consoleAPICalled", params: wide))
        let bounded = try #require(text(big, "preview"))
        #expect(bounded.utf8.count <= PageDiagnostics.Redaction.maxPreviewBytes)
        #expect(big.truncated)
    }

    // MARK: WebKit hook messages

    private func net(_ detail: [String: Any]?, url: String = "\(site)/api?x=1", via: String = "fetch") -> [String: Any] {
        var body: [String: Any] = ["k": "net", "via": via, "method": "POST", "url": url, "status": 200, "outcome": "completed", "mime": "application/json", "ms": 12.0]
        if let detail { body["rd"] = detail }
        return body
    }

    private static let readable: [String: Any] = [
        "reqH": [["Authorization", "Bearer hunter2"], ["Content-Type", "application/json"], ["X-Api-Key", "k-1"]],
        "reqB": ["t": "{\"password\":\"p\",\"a\":1}", "ct": "application/json", "size": 22],
        "resH": [["Content-Type", "application/json"], ["X-Server", "demo"]],
        "resB": ["t": "{\"ok\":true}", "ct": "application/json"],
        "fin": "\(site)/api?x=1",
    ]

    @Test func theHookDetailOfADeveloperSiteRequestIsRedactedAtIngest() throws {
        let entry = try #require(PageDiagnosticsHook.entry(from: net(Self.readable), queryValues: DiagnosticsTestKey.values, detail: policy()))
        let detail = try #require(entry.detail)
        let names = Dictionary(uniqueKeysWithValues: try #require(detail.requestHeaders).map { ($0.name, $0.value) })
        #expect(names["authorization"] == Self.hidden && names["x-api-key"] == Self.hidden && names["content-type"] == "application/json")
        #expect(!String(describing: detail.requestHeaders).contains("hunter2"))
        #expect(detail.requestBody?.text == "{\"password\":\"p\",\"a\":1}", "bodies hide their credentials when the owner makes the record")
        #expect(detail.responseBody?.contentType == "application/json")
        #expect(text(entry, "url") == "\(Self.site)/api?x=*short")
    }

    @Test func theHookDetailIsDroppedWhenTheRequestIsNotOnADeveloperSite() {
        let off = policy()
        func entry(_ body: [String: Any], _ policy: PageDiagnostics.DetailPolicy) -> PageDiagnostics.Entry? {
            PageDiagnosticsHook.entry(from: body, queryValues: DiagnosticsTestKey.values, detail: policy)
        }
        #expect(entry(net(Self.readable, url: "https://example.com/api"), off)?.detail == nil, "a third-party address")
        #expect(entry(net(Self.readable.merging(["fin": "https://example.com/landing"]) { $1 }), off)?.detail == nil, "a redirect that left the developer sites")
        #expect(entry(net(["off": true]), off)?.detail == nil, "the page reported that the request left")
        #expect(entry(net(Self.readable), policy(tier: false))?.detail == nil, "no tier")
        #expect(entry(net(Self.readable), .off)?.detail == nil, "no opt-in")
        #expect(entry(net(Self.readable, via: "resource"), off)?.detail == nil, "resource loads carry no headers or bodies")
        #expect(entry(net(Self.readable), policy(headers: false, bodies: true))?.detail?.requestHeaders == nil, "headers were not asked for")
        #expect(entry(net(Self.readable), policy(headers: true, bodies: false))?.detail?.requestBody == nil, "bodies were not asked for")
    }

    @Test func aHookConsolePreviewNeedsTheFullConsoleAndTheTier() throws {
        let body: [String: Any] = ["k": "console", "level": "log", "text": "hi [object]", "pv": "[\"hi\",{\"password\":\"hunter2\",\"n\":1}]", "stack": "logIt@http://127.0.0.1:3000/a.js:1:1"]
        let full = try #require(PageDiagnosticsHook.entry(from: body, queryValues: DiagnosticsTestKey.values, detail: policy(console: true)))
        #expect(text(full, "preview") == "[\"hi\",{\"n\":1,\"password\":\"\(Self.hidden)\"}]")
        #expect(text(full, "stack")?.contains("logIt") == true)
        for none in [policy(), policy(tier: false, console: true)] {
            let plain = try #require(PageDiagnosticsHook.entry(from: body, queryValues: DiagnosticsTestKey.values, detail: none))
            #expect(plain.fields["preview"] == nil)
        }
    }
}
