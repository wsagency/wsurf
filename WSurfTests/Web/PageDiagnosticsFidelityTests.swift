// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// Filters, single-record reads, resource facts and stacks: what a diagnostics record says beyond its text and status.
@MainActor
struct PageDiagnosticsFidelityTests {
    private let connection = UUID()

    private func buffer(maxRecords: Int = 1_024) -> PageDiagnostics.Buffer {
        PageDiagnostics.Buffer(connection: connection, tab: "tab-1", documentID: "doc-1", maxRecords: maxRecords)
    }

    @discardableResult
    private func add(_ buffer: PageDiagnostics.Buffer, _ stream: PageDiagnostics.Stream, _ fields: [String: PageDiagnostics.Field]) -> Bool {
        buffer.append(stream: stream, timestamp: Date(timeIntervalSince1970: 0), documentID: "doc-1", fields: fields)
    }

    private func network(_ status: Int?, _ url: String, outcome: String = "completed", type: String = "fetch") -> [String: PageDiagnostics.Field] {
        var fields: [String: PageDiagnostics.Field] = ["url": .text(url), "outcome": .text(outcome), "type": .text(type)]
        fields["status"] = status.map { .number($0) }
        return fields
    }

    // MARK: Filters

    @Test func filtersSkipButCursorsStayStable() throws {
        let buffer = buffer()
        for index in 0..<10 {
            add(buffer, .network, network(index % 3 == 0 ? 500 : 200, "https://a.test/\(index)"))
        }
        add(buffer, .console, ["level": "error", "text": "other stream"])
        var filter = PageDiagnostics.Filter()
        filter.minStatus = 500
        let first = try buffer.read(stream: .network, cursor: nil, limit: 2, filter: filter)
        #expect(first.records.map(\.seq) == [0, 3])
        #expect(first.skipped == 2, "records 1 and 2 were passed over on the way")
        // The page filled, so the cursor follows the last match and the skipped tail is still ahead of it.
        let second = try buffer.read(stream: .network, cursor: first.nextCursor, limit: 2, filter: filter)
        #expect(second.records.map(\.seq) == [6, 9])
        // The scan reached the end of the stream without filling the page: the cursor moves to the end.
        let third = try buffer.read(stream: .network, cursor: second.nextCursor, limit: 2, filter: filter)
        #expect(third.records.isEmpty)
        add(buffer, .network, network(503, "https://a.test/late"))
        let fourth = try buffer.read(stream: .network, cursor: third.nextCursor, limit: 2, filter: filter)
        #expect(fourth.records.map(\.seq) == [10])
        #expect(fourth.gap == 0)
    }

    @Test func aFilterMatchesEveryNamedFieldAndOnlyThose() throws {
        let buffer = buffer()
        add(buffer, .network, network(200, "https://a.test/app.js", type: "script"))
        add(buffer, .network, network(404, "https://a.test/missing.png", type: "image"))
        add(buffer, .network, network(nil, "https://a.test/api/save", outcome: "failed"))
        add(buffer, .console, ["level": "warn", "text": "w", "url": "https://a.test/app.js"])
        add(buffer, .console, ["level": "error", "text": "e", "url": "https://a.test/other.js"])
        func seqs(_ stream: PageDiagnostics.Stream, _ configure: (inout PageDiagnostics.Filter) -> Void) throws -> [UInt64] {
            var filter = PageDiagnostics.Filter()
            configure(&filter)
            return try buffer.read(stream: stream, cursor: nil, limit: 100, filter: filter).records.map(\.seq)
        }
        #expect(try seqs(.network) { $0.type = "image" } == [1])
        #expect(try seqs(.network) { $0.outcome = "failed" } == [2])
        #expect(try seqs(.network) { $0.minStatus = 400 } == [1], "an unknown status never matches minStatus")
        #expect(try seqs(.network) { $0.urlContains = "/api/" } == [2])
        #expect(try seqs(.network) { $0.type = "script"; $0.minStatus = 400 }.isEmpty, "every filter must match")
        #expect(try seqs(.console) { $0.level = "error" } == [1])
        #expect(try seqs(.console) { $0.urlContains = "app.js" } == [0])
        #expect(try seqs(.network) { _ in } == [0, 1, 2])
        #expect(PageDiagnostics.Filter().isEmpty)
    }

    @Test func aRecordCanBeReadBySeqUntilEvicted() {
        let buffer = buffer(maxRecords: 3)
        for index in 0..<5 {
            add(buffer, .network, network(200, "https://a.test/\(index)"))
        }
        #expect(buffer.lookup(stream: .network, seq: 0) == .evicted)
        #expect(buffer.lookup(stream: .network, seq: 1) == .evicted)
        guard case .found(let record) = buffer.lookup(stream: .network, seq: 3) else {
            Issue.record("the retained record must be found")
            return
        }
        #expect(record.fields["url"] == "https://a.test/3")
        #expect(buffer.lookup(stream: .network, seq: 5) == .notCaptured)
        #expect(buffer.lookup(stream: .console, seq: 0) == .notCaptured, "streams count separately")
    }

    // MARK: Tool arguments

    @Test func selectionParsesEveryFilter() throws {
        guard case .success(.page(let filter)) = MCPDevelopmentTools.selection(
            ["minStatus": 400, "outcome": "failed", "type": "script", "urlContains": "/api", "level": "warn"])
        else {
            Issue.record("filters must parse")
            return
        }
        #expect(filter == PageDiagnostics.Filter(level: "warn", minStatus: 400, urlContains: "/api", outcome: "failed", type: "script"))
        guard case .success(.page(let none)) = MCPDevelopmentTools.selection(["cursor": "c", "limit": 5]) else {
            Issue.record("paging alone is not a filter")
            return
        }
        #expect(none.isEmpty)
    }

    @Test func theCatalogRefusesAFilterTheToolDoesNotHave() throws {
        func entry(_ name: String) throws -> MCPToolCatalog.Entry {
            try #require(MCPToolCatalog.entries.first { $0.name == name })
        }
        let tab: Value = .string(UUID().uuidString)
        try entry("readNetwork").validate(["tabID": tab, "minStatus": 400, "outcome": "failed", "type": "script", "urlContains": "/api", "seq": 3])
        try entry("readConsole").validate(["tabID": tab, "level": "warn", "urlContains": "app.js", "limit": 10, "cursor": "c"])
        let foreign: [(String, [String: Value])] = [
            ("readConsole", ["minStatus": 400]), ("readConsole", ["outcome": "failed"]), ("readConsole", ["type": "script"]),
            ("readNetwork", ["level": "warn"]), ("readNetwork", ["minStatus": 99]), ("readNetwork", ["minStatus": 600]),
            ("readConsole", ["seq": -1]),
        ]
        for (name, arguments) in foreign {
            #expect(throws: (any Error).self, "\(name) \(arguments)") { try entry(name).validate(arguments.merging(["tabID": tab]) { $1 }) }
        }
    }

    @Test func selectionRejectsBadValuesAndSeqCombinations() throws {
        let bad: [[String: Value]] = [
            ["level": "fatal"], ["level": 3], ["minStatus": 99], ["minStatus": 600], ["minStatus": "500"], ["outcome": "exploded"],
            ["type": "font-ish"], ["urlContains": ""], ["urlContains": .string(String(repeating: "a", count: 257))],
            ["seq": -1], ["seq": "3"], ["seq": 3, "cursor": "x"], ["seq": 3, "limit": 5], ["seq": 3, "minStatus": 400],
        ]
        for arguments in bad {
            #expect(throws: (any Error).self, "\(arguments)") { _ = try MCPDevelopmentTools.selection(arguments).get() }
        }
        guard case .success(.record(let seq)) = MCPDevelopmentTools.selection(["seq": 7]) else {
            Issue.record("a lone seq reads one record")
            return
        }
        #expect(seq == 7)
        #expect(PageDiagnostics.resourceTypes.contains("font") && PageDiagnostics.resourceTypes.contains("xhr"))
    }

    // MARK: Chromium records

    private let mapper = ChromiumDiagnosticsMapper(queryValues: DiagnosticsTestKey.values)

    private func tag(_ value: String) -> String {
        DiagnosticsTestKey.tag(value)
    }

    @Test func chromiumRecordsCarryTypeMimeSizeAndRedirects() throws {
        _ = mapper.entry(method: "Network.requestWillBeSent", params: [
            "requestId": "1", "timestamp": 10.0, "type": "Document", "request": ["url": "https://a.test/old?next=/x", "method": "GET"],
        ])
        let hop = try #require(mapper.entry(method: "Network.requestWillBeSent", params: [
            "requestId": "1", "timestamp": 10.1, "type": "Document", "request": ["url": "https://a.test/new?session=abc", "method": "GET"],
            "redirectResponse": ["status": 302, "mimeType": "text/html; charset=utf-8", "encodedDataLength": 210.0, "url": "https://a.test/old"],
        ]))
        #expect(hop.fields["url"] == .text("https://a.test/old?next=\(tag("/x"))"))
        #expect(hop.fields["redirectTo"] == .text("https://a.test/new?session=\(tag("abc"))"))
        #expect(hop.fields["status"] == 302 && hop.fields["type"] == "document" && hop.fields["transferBytes"] == 210)
        #expect(hop.fields["mimeType"] == "text/html", "a media type has no parameters")
        _ = mapper.entry(method: "Network.responseReceived", params: [
            "requestId": "1", "type": "Document", "response": ["status": 200, "mimeType": "TEXT/HTML"],
        ])
        let final = try #require(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "1", "timestamp": 10.3, "encodedDataLength": 1_532.0]))
        #expect(final.fields["redirectTo"] == nil, "only a redirect hop has a target")
        #expect(final.fields["mimeType"] == "text/html" && final.fields["transferBytes"] == 1_532 && final.fields["type"] == "document")
        #expect(final.fields["durationMs"] == 200 && final.fields["status"] == 200)
    }

    @Test(arguments: [
        ("Script", "script"), ("XHR", "xhr"), ("Fetch", "fetch"), ("Image", "image"), ("Preflight", "preflight"), ("Brand New Kind", "other"),
    ])
    func chromiumResourceTypesAreLowercasedAndClosed(raw: String, expected: String) throws {
        _ = mapper.entry(method: "Network.requestWillBeSent", params: [
            "requestId": "t", "timestamp": 1.0, "type": raw, "request": ["url": "https://a.test/", "method": "GET"],
        ])
        let done = try #require(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "t", "timestamp": 2.0]))
        #expect(done.fields["type"] == .text(expected))
        #expect(PageDiagnostics.resourceTypes.contains(expected))
    }

    @Test func aFailedRequestHasNoSizeAndNoMediaTypeInvented() throws {
        _ = mapper.entry(method: "Network.requestWillBeSent", params: ["requestId": "f", "timestamp": 1.0, "request": ["url": "https://a.test/", "method": "GET"]])
        let failed = try #require(mapper.entry(method: "Network.loadingFailed", params: ["requestId": "f", "timestamp": 2.0, "errorText": "net::ERR_FAILED"]))
        #expect(failed.fields["transferBytes"] == nil && failed.fields["mimeType"] == nil && failed.fields["type"] == nil)
    }

    @Test(arguments: ["text", "a/b/c", "/json", "application/", "text/ht ml", "text/<script>", String(repeating: "a", count: 300) + "/b"])
    func aMalformedMediaTypeIsUnknown(raw: String) throws {
        _ = mapper.entry(method: "Network.requestWillBeSent", params: ["requestId": "m", "timestamp": 1.0, "request": ["url": "https://a.test/", "method": "GET"]])
        _ = mapper.entry(method: "Network.responseReceived", params: ["requestId": "m", "response": ["status": 200, "mimeType": raw]])
        let done = try #require(mapper.entry(method: "Network.loadingFinished", params: ["requestId": "m", "timestamp": 2.0]))
        #expect(done.fields["mimeType"] == nil)
    }

    // MARK: Stacks

    private func frames(_ count: Int, url: String = "https://a.test/app.js?v=build42") -> [[String: Any]] {
        (0..<count).map { ["functionName": "fn\($0)", "url": url, "lineNumber": $0, "columnNumber": 4] }
    }

    @Test func chromiumStacksAreBoundedAndSanitized() throws {
        let result = try #require(mapper.entry(method: "Runtime.consoleAPICalled", params: [
            "type": "error", "args": [["type": "string", "value": "boom"]], "stackTrace": ["callFrames": frames(40)],
        ]))
        guard case .text(let stack)? = result.fields["stack"] else {
            Issue.record("an error carries a stack")
            return
        }
        let lines = stack.split(separator: "\n")
        #expect(lines.count == PageDiagnostics.maxStackFrames)
        #expect(lines.first == "fn0 (https://a.test/app.js?v=\(tag("build42")):1:5)", "lines and columns are 1-based")
        #expect(!stack.contains("build42"))
        #expect(stack.utf8.count <= PageDiagnostics.maxStackBytes)
        #expect(result.truncated, "frames were left out")
        // The top frame is also the record's own location.
        #expect(result.fields["url"] == .text("https://a.test/app.js?v=\(tag("build42"))") && result.fields["line"] == 1 && result.fields["column"] == 5)
    }

    @Test func aStackOfHugeFramesStaysInItsByteBound() throws {
        let huge = (0..<10).map { ["functionName": String(repeating: "f", count: 5_000), "url": "https://a.test/" + String(repeating: "p", count: 5_000), "lineNumber": $0, "columnNumber": 0] as [String: Any] }
        let result = try #require(mapper.entry(method: "Runtime.exceptionThrown", params: [
            "exceptionDetails": ["text": "Uncaught", "stackTrace": ["callFrames": huge], "lineNumber": 3, "columnNumber": 9],
        ]))
        guard case .text(let stack)? = result.fields["stack"] else {
            Issue.record("an exception carries a stack")
            return
        }
        #expect(stack.utf8.count <= PageDiagnostics.maxStackBytes)
        #expect(result.truncated)
        #expect(result.fields["column"] == 10, "CDP columns are 0-based")
    }

    @Test func onlyWarningsAndErrorsCarryAStackAndNonsenseFramesAreIgnored() {
        let log = mapper.entry(method: "Runtime.consoleAPICalled", params: ["type": "log", "args": [["type": "string", "value": "x"]], "stackTrace": ["callFrames": frames(2)]])
        #expect(log?.fields["stack"] == nil && log?.fields["url"] == nil)
        let warn = mapper.entry(method: "Runtime.consoleAPICalled", params: ["type": "warning", "args": [["type": "string", "value": "x"]], "stackTrace": ["callFrames": frames(2)]])
        #expect(warn?.fields["stack"] != nil)
        let traces: [Any] = [3, "x", [String: Any](), ["callFrames": "no"], ["callFrames": [[String: Any]]()], ["callFrames": [5]]]
        for trace in traces {
            let result = mapper.entry(method: "Runtime.consoleAPICalled", params: ["type": "error", "args": [["type": "string", "value": "x"]], "stackTrace": trace])
            #expect(result != nil && result?.fields["stack"] == nil)
        }
    }

    @Test func aFunctionNameIsPageTextSoControlCharactersAreBlanked() throws {
        let stack = try #require(PageDiagnostics.stack([.init(function: "a\nb\u{0}c", url: "https://a.test/x.js", line: 3, column: 4)], queryValues: DiagnosticsTestKey.values))
        #expect(stack.text == "a b c (https://a.test/x.js:3:4)")
    }

    // MARK: WebKit hook messages

    private func entry(_ body: [String: Any]) -> PageDiagnostics.Entry? {
        PageDiagnosticsHook.entry(from: body, queryValues: DiagnosticsTestKey.values)
    }

    @Test func aWebKitErrorStackIsParsedBoundedAndSanitized() throws {
        let raw = (0..<30).map { "fn\($0)@https://a.test/app.js?v=build42:\($0 + 1):7" }.joined(separator: "\n") + "\n@https://a.test/top.js:1:1\n[native code]"
        let result = try #require(entry(["k": "console", "level": "error", "text": "boom", "stack": raw, "col": 7]))
        guard case .text(let stack)? = result.fields["stack"] else {
            Issue.record("a stack was sent")
            return
        }
        let lines = stack.split(separator: "\n")
        #expect(lines.count == PageDiagnostics.maxStackFrames)
        #expect(lines.first == "fn0 (https://a.test/app.js?v=\(tag("build42")):1:7)")
        #expect(!stack.contains("build42"))
        #expect(result.truncated)
        #expect(result.fields["column"] == 7)
        let short = try #require(entry(["k": "console", "level": "error", "text": "x", "stack": "@https://a.test/top.js:1:1\nrun@https://a.test/b.js:9:3\n[native code]"]))
        #expect(short.fields["stack"] == .text("https://a.test/top.js:1:1\nrun (https://a.test/b.js:9:3)"))
        #expect(short.truncated == false)
    }

    @Test(arguments: ["", "   \n  ", "no location here", String(repeating: "x", count: 10_000)])
    func nonsenseStacksAreDropped(stack: String) {
        let result = entry(["k": "console", "level": "error", "text": "x", "stack": stack])
        #expect(result?.fields["stack"] == nil)
        #expect(entry(["k": "console", "level": "error", "text": "x", "stack": 5])?.fields["stack"] == nil)
    }

    @Test func webKitNetworkRecordsCarryTypeMediaTypeAndSize() throws {
        let fetch = try #require(entry([
            "k": "net", "via": "fetch", "method": "GET", "url": "https://a.test/api?q=1", "status": 200, "ms": 4.0, "outcome": "completed",
            "mime": "Application/JSON; charset=utf-8",
        ]))
        #expect(fetch.fields["type"] == "fetch" && fetch.fields["mimeType"] == "application/json" && fetch.fields["transferBytes"] == nil)
        let xhr = try #require(entry(["k": "net", "via": "xhr", "method": "POST", "url": "https://a.test/", "outcome": "failed"]))
        #expect(xhr.fields["type"] == "xhr" && xhr.fields["mimeType"] == nil)
        let image = try #require(entry([
            "k": "net", "via": "resource", "rtype": "img", "url": "https://a.test/pic.png?cache=zz", "bytes": 2_048, "ms": 8.5, "outcome": "completed",
        ]))
        #expect(image.fields["type"] == "image" && image.fields["transferBytes"] == 2_048 && image.fields["source"] == "webkit-resource")
        #expect(image.fields["url"] == .text("https://a.test/pic.png?cache=\(tag("zz"))"))
        #expect(image.fields["method"] == nil, "a resource entry does not say how it was requested")
        let unexposed = try #require(entry(["k": "net", "via": "resource", "rtype": "script", "url": "https://cdn.test/a.js", "outcome": "completed"]))
        #expect(unexposed.fields["transferBytes"] == nil, "a size the page cannot see is unknown, never 0")
    }

    @Test(arguments: [
        ("img", "https://a.test/x", "image"), ("script", "https://a.test/x", "script"), ("iframe", "https://a.test/x", "document"),
        ("video", "https://a.test/x", "media"), ("beacon", "https://a.test/x", "ping"), ("link", "https://a.test/site.css?v=1", "stylesheet"),
        ("link", "https://a.test/app.mjs", "script"), ("css", "https://a.test/f.woff2", "font"), ("css", "https://a.test/bg.PNG", "image"),
        ("link", "https://a.test/feed", "other"), ("something-new", "https://a.test/x", "other"),
    ])
    func resourceEntriesMapTheirInitiatorToATypeAndRefineLinksByExtension(initiator: String, url: String, expected: String) throws {
        let result = try #require(entry(["k": "net", "via": "resource", "rtype": initiator, "url": url, "outcome": "completed"]))
        #expect(result.fields["type"] == .text(expected))
    }

    @Test func theEarlyBufferReportsWhatItDropped() {
        #expect(PageDiagnosticsHook.lostEarly(from: ["k": "lost", "n": 12]) == 12)
        let bodies: [Any] = [["k": "lost", "n": 0], ["k": "lost", "n": -1], ["k": "lost", "n": "3"], ["k": "console", "n": 3], 5, ["k": "lost", "n": 10_000_000]]
        for body in bodies {
            #expect(PageDiagnosticsHook.lostEarly(from: body) == nil)
        }
    }
}
