// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

/// Untrusted page messages (WebKit hook) and CDP events (Chromium) become bounded records here, or nothing.
struct PageDiagnosticsIngestTests {
    private func entry(_ body: Any) -> PageDiagnostics.Entry? { PageDiagnosticsHook.entry(from: body) }

    // MARK: WebKit hook messages

    @Test func acceptsAWellFormedConsoleMessage() {
        let result = entry(["k": "console", "level": "error", "text": "boom", "url": "https://a.test/app.js?v=secret#x", "line": 12])
        #expect(result == .init(stream: .console, fields: ["level": "error", "text": "boom", "url": "https://a.test/app.js", "line": "12", "source": "webkit-hook"]))
    }

    @Test(arguments: ["log", "info", "warn", "error", "debug"])
    func acceptsOnlyKnownLevels(level: String) {
        #expect(entry(["k": "console", "level": level, "text": "x"])?.fields["level"] == level)
    }

    @Test func rejectsMalformedConsoleMessages() {
        let bodies: [[String: Any]] = [
            ["k": "console", "level": "<script>", "text": "x"],
            ["k": "console", "level": "error"],
            ["k": "console", "level": "error", "text": 5],
            ["k": "other", "level": "error", "text": "x"],
            ["level": "error", "text": "x"],
        ]
        for body in bodies { #expect(entry(body) == nil) }
    }

    @Test func rejectsNonDictionaryBodies() {
        for body in [Any?.none as Any, "text" as Any, 5 as Any, ["a"] as Any] { #expect(entry(body) == nil) }
    }

    @Test func clipsConsoleTextAndIgnoresExtraKeys() throws {
        let long = String(repeating: "é", count: 5_000)
        let result = try #require(entry(["k": "console", "level": "log", "text": long, "cookie": "hunter2", "stack": "at x"]))
        #expect(try #require(result.fields["text"]).count <= 2_000)
        #expect(result.fields["cookie"] == nil)
        #expect(result.fields["stack"] == nil)
    }

    @Test func networkMessageSanitizesAndValidatesEveryField() {
        let result = entry([
            "k": "net", "via": "fetch", "method": "post", "url": "https://u:hunter2@api.test/v1/x?token=hunter2#f",
            "status": 404, "ms": 12.6, "outcome": "completed",
        ])
        #expect(result == .init(stream: .network, fields: [
            "method": "POST", "url": "https://api.test/v1/x", "status": "404", "durationMs": "13", "outcome": "completed", "source": "webkit-fetch",
        ]))
    }

    @Test func missingStatusAndTimingStayUnknownNeverZero() {
        let result = entry(["k": "net", "via": "xhr", "method": "GET", "url": "https://a.test/", "outcome": "failed"])
        #expect(result?.fields["status"] == nil)
        #expect(result?.fields["durationMs"] == nil)
        #expect(result?.fields["outcome"] == "failed")
        #expect(result?.fields["source"] == "webkit-xhr")
    }

    @Test(arguments: [99, 600, -1, 0, 1_000_000])
    func outOfRangeStatusIsDropped(status: Int) {
        #expect(entry(["k": "net", "via": "fetch", "method": "GET", "url": "https://a.test/", "outcome": "completed", "status": status])?.fields["status"] == nil)
    }

    @Test func wrongTypedFieldsAreDroppedAndOutcomeFallsBackToUnknown() {
        let result = entry(["k": "net", "via": "fetch", "method": "G E T", "url": 5, "outcome": "exploded", "status": "200", "ms": -3])
        #expect(result?.fields["method"] == nil)
        #expect(result?.fields["url"] == nil)
        #expect(result?.fields["status"] == nil)
        #expect(result?.fields["durationMs"] == nil)
        #expect(result?.fields["outcome"] == "unknown")
    }

    @Test func unknownTransportIsRejected() {
        #expect(entry(["k": "net", "via": "beacon", "method": "GET", "url": "https://a.test/", "outcome": "completed"]) == nil)
    }

    // MARK: Chromium events

    private func console(_ type: String, _ args: [[String: Any]]) -> PageDiagnostics.Entry? {
        let mapper = ChromiumDiagnosticsMapper()
        return mapper.entry(method: "Runtime.consoleAPICalled", params: ["type": type, "args": args])
    }

    @Test func mapsConsoleTypesAndPrimitiveArguments() {
        let result = console("warning", [["type": "string", "value": "slow"], ["type": "number", "value": 3], ["type": "boolean", "value": true], ["type": "undefined"]])
        #expect(result == .init(stream: .console, fields: ["level": "warn", "text": "slow 3 true undefined", "source": "cdp"]))
        #expect(console("error", [["type": "string", "value": "x"]])?.fields["level"] == "error")
    }

    @Test func opaqueObjectsAreOmittedAndErrorsKeepOnlyTheirFirstLine() {
        let result = console("error", [
            ["type": "object", "className": "Object", "description": "Object", "objectId": "1"],
            ["type": "function", "description": "function secret() { return 'hunter2' }"],
            ["type": "object", "subtype": "error", "description": "TypeError: bad\n    at https://a.test/app.js:1:1"],
            ["type": "object", "subtype": "null"],
        ])
        #expect(result?.fields["text"] == "[object omitted] [function] TypeError: bad null")
    }

    @Test(arguments: ["clear", "dir", "table", "trace", "startGroup", "profile"])
    func ignoresNonMessageConsoleTypes(type: String) {
        #expect(console(type, [["type": "string", "value": "x"]]) == nil)
    }

    @Test func mapsExceptionsWithSanitizedLocation() {
        let mapper = ChromiumDiagnosticsMapper()
        let result = mapper.entry(method: "Runtime.exceptionThrown", params: [
            "exceptionDetails": ["text": "Uncaught", "url": "https://a.test/app.js?token=hunter2", "lineNumber": 41,
                "exception": ["type": "object", "subtype": "error", "description": "ReferenceError: nope is not defined\n    at x"]],
        ])
        #expect(result?.fields["text"] == "ReferenceError: nope is not defined")
        #expect(result?.fields["url"] == "https://a.test/app.js")
        #expect(result?.fields["line"] == "42")  // CDP line numbers are 0-based
        #expect(result?.fields["level"] == "error")
    }

    @Test func correlatesANetworkRequestAcrossEventsWithoutTouchingHeaders() throws {
        let mapper = ChromiumDiagnosticsMapper()
        #expect(mapper.entry(method: "Network.requestWillBeSent", params: [
            "requestId": "1", "timestamp": 100.0,
            "request": ["url": "https://u:pw@a.test/x?token=hunter2", "method": "PUT", "headers": ["Authorization": "Bearer hunter2"], "postData": "hunter2"],
        ]) == nil)
        #expect(mapper.entry(method: "Network.responseReceived", params: ["requestId": "1", "response": ["status": 201, "headers": ["Set-Cookie": "hunter2"]]]) == nil)
        let done = try #require(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "1", "timestamp": 100.25, "encodedDataLength": 1]))
        #expect(done == .init(stream: .network, fields: [
            "method": "PUT", "url": "https://a.test/x", "status": "201", "durationMs": "250", "outcome": "completed", "source": "cdp",
        ]))
        #expect(!String(describing: done).contains("hunter2"))
        #expect(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "1", "timestamp": 101.0]) == nil)  // already reported
    }

    @Test func failuresAndCancellationsAreDistinguishedAndLeaveStatusUnknown() throws {
        let mapper = ChromiumDiagnosticsMapper()
        for id in ["a", "b"] {
            _ = mapper.entry(method: "Network.requestWillBeSent", params: ["requestId": id, "timestamp": 1.0, "request": ["url": "https://a.test/", "method": "GET"]])
        }
        let failed = try #require(mapper.entry(method: "Network.loadingFailed", params: ["requestId": "a", "timestamp": 1.5, "errorText": "net::ERR_CONNECTION_REFUSED"]))
        #expect(failed.fields["outcome"] == "failed")
        #expect(failed.fields["status"] == nil)
        let aborted = try #require(mapper.entry(method: "Network.loadingFailed", params: ["requestId": "b", "timestamp": 1.5, "canceled": true]))
        #expect(aborted.fields["outcome"] == "aborted")
    }

    @Test func eventsWithoutAStartedRequestAreNotInvented() {
        let mapper = ChromiumDiagnosticsMapper()
        #expect(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "ghost", "timestamp": 1.0]) == nil)
        #expect(mapper.entry(method: "Network.loadingFailed", params: ["requestId": "ghost", "timestamp": 1.0]) == nil)
        #expect(mapper.entry(method: "Network.responseReceived", params: ["requestId": "ghost", "response": ["status": 200]]) == nil)
    }

    @Test func aRedirectReportsThePreviousHopAndTracksTheNext() throws {
        let mapper = ChromiumDiagnosticsMapper()
        _ = mapper.entry(method: "Network.requestWillBeSent", params: ["requestId": "r", "timestamp": 10.0, "request": ["url": "https://a.test/old", "method": "GET"]])
        let hop = try #require(mapper.entry(method: "Network.requestWillBeSent", params: [
            "requestId": "r", "timestamp": 10.1, "request": ["url": "https://a.test/new", "method": "GET"],
            "redirectResponse": ["status": 302, "url": "https://a.test/old"],
        ]))
        #expect(hop.fields["url"] == "https://a.test/old")
        #expect(hop.fields["status"] == "302")
        let final = try #require(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "r", "timestamp": 10.3]))
        #expect(final.fields["url"] == "https://a.test/new")
    }

    @Test func inFlightTrackingIsBounded() {
        let mapper = ChromiumDiagnosticsMapper()
        for index in 0..<1_000 {
            _ = mapper.entry(method: "Network.requestWillBeSent", params: ["requestId": "\(index)", "timestamp": 1.0, "request": ["url": "https://a.test/\(index)", "method": "GET"]])
        }
        #expect(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "0", "timestamp": 2.0]) == nil)  // evicted
        #expect(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "999", "timestamp": 2.0]) != nil)
    }

    @Test func malformedEventsAreIgnoredWithoutCrashing() {
        let mapper = ChromiumDiagnosticsMapper()
        let malformed: [(String, [String: Any])] = [
            ("Runtime.consoleAPICalled", [:]), ("Runtime.consoleAPICalled", ["type": 5, "args": "x"]),
            ("Runtime.exceptionThrown", ["exceptionDetails": 3]),
            ("Network.requestWillBeSent", ["requestId": 7, "request": "x"]), ("Network.loadingFinished", ["requestId": ["a"]]),
            ("Page.frameNavigated", [:]), ("", [:]),
        ]
        for (method, params) in malformed { #expect(mapper.entry(method: method, params: params) == nil) }
    }
}
