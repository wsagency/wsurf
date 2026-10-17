// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing

@testable import WSurf

/// What a comparison report says about two tabs, built from records and numbers: no page, no engine.
@MainActor
struct MCPCompareToolsTests {
    private typealias Tools = MCPCompareTools

    private func console(_ level: String, _ text: String, seq: UInt64 = 0) -> PageDiagnostics.Record {
        PageDiagnostics.Record(
            seq: seq, timestamp: Date(timeIntervalSince1970: 0), documentID: "doc", stream: .console,
            fields: ["level": .text(level), "text": .text(text)], truncated: false)
    }

    private func request(_ url: String, method: String? = "GET", status: Int? = nil, outcome: String = "completed") -> PageDiagnostics.Record {
        var fields: [String: PageDiagnostics.Field] = ["url": .text(url), "outcome": .text(outcome)]
        if let method { fields["method"] = .text(method) }
        if let status { fields["status"] = .number(status) }
        return PageDiagnostics.Record(
            seq: 0, timestamp: Date(timeIntervalSince1970: 0), documentID: "doc", stream: .network, fields: fields, truncated: false)
    }

    private func report(_ a: Tools.Observed, _ b: Tools.Observed) throws -> [String: Value] {
        try #require(Tools.differences(a, b).objectValue)
    }

    private func strings(_ value: Value?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    // MARK: Console

    @Test func onlyWarningsAndErrorsAreComparedAndTheOthersAreIgnored() throws {
        let a = Tools.observed(console: [console("log", "hello"), console("info", "x"), console("debug", "y"), console("error", "boom")], network: [])
        let b = Tools.observed(console: [console("log", "different")], network: [])
        let log = try #require(try report(a, b)["console"]?.objectValue)
        let onlyA = try #require(log["onlyA"]?.arrayValue)
        #expect(onlyA.count == 1)
        #expect(onlyA.first?.objectValue?["level"]?.stringValue == "error")
        #expect(onlyA.first?.objectValue?["text"]?.stringValue == "boom")
        #expect(log["onlyB"]?.arrayValue?.isEmpty == true)
    }

    @Test func aMessageBothTabsLogIsNotADifferenceEvenWithOtherNumbers() throws {
        let a = Tools.observed(console: [console("error", "Request 1234567 failed\n    at stack line")], network: [])
        let b = Tools.observed(console: [console("error", "Request   7654321 failed")], network: [])
        let log = try #require(try report(a, b)["console"]?.objectValue)
        #expect(log["onlyA"]?.arrayValue?.isEmpty == true)
        #expect(log["onlyB"]?.arrayValue?.isEmpty == true)
        #expect(log["inBoth"]?.intValue == 1)
    }

    @Test func theSameTextAtAnotherLevelIsADifference() throws {
        let a = Tools.observed(console: [console("error", "slow")], network: [])
        let b = Tools.observed(console: [console("warn", "slow")], network: [])
        let log = try #require(try report(a, b)["console"]?.objectValue)
        #expect(log["onlyA"]?.arrayValue?.count == 1)
        #expect(log["onlyB"]?.arrayValue?.count == 1)
    }

    @Test func repeatedMessagesAreCountedOnce() throws {
        let a = Tools.observed(console: (0..<5).map { console("error", "again", seq: UInt64($0)) }, network: [])
        let item = try #require(try report(a, Tools.Observed())["console"]?.objectValue?["onlyA"]?.arrayValue?.first?.objectValue)
        #expect(item["count"]?.intValue == 5)
    }

    @Test func messagesAreBoundedAndTheRestIsCounted() throws {
        let many = (0..<(Tools.maxItems + 7)).map { console("error", "failure kind \(String(repeating: "x", count: $0 + 1))", seq: UInt64($0)) }
        let fields = try report(Tools.observed(console: many, network: []), Tools.Observed())
        #expect(fields["console"]?.objectValue?["onlyA"]?.arrayValue?.count == Tools.maxItems)
        #expect(fields["more"]?.intValue == 7)
        let long = Tools.observed(console: [console("error", String(repeating: "w", count: 5_000))], network: [])
        let text = try #require(try report(long, Tools.Observed())["console"]?.objectValue?["onlyA"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.count == Tools.textLimit)
    }

    // MARK: Network

    @Test func requestsAreKeyedByHostAndPathAndQueriesAreIgnored() throws {
        let a = Tools.observed(
            console: [],
            network: [request("http://127.0.0.1:8080/app.js?v=~k1", status: 200), request("http://127.0.0.1:8080/only-a.css", status: 200)])
        let b = Tools.observed(
            console: [],
            network: [request("http://127.0.0.1:8080/app.js?v=~k2", status: 200), request("http://127.0.0.1:8080/only-b.png", status: 200)])
        let network = try #require(try report(a, b)["network"]?.objectValue)
        #expect(strings(network["onlyA"]) == ["127.0.0.1:8080/only-a.css GET"])
        #expect(strings(network["onlyB"]) == ["127.0.0.1:8080/only-b.png GET"])
        #expect(network["different"]?.arrayValue?.isEmpty == true)
    }

    @Test func aRequestThatFailedInOneTabOnlyIsADifference() throws {
        let a = Tools.observed(console: [], network: [request("https://cdn.test/lib.js", status: 404)])
        let b = Tools.observed(console: [], network: [request("https://cdn.test/lib.js", status: 200)])
        let different = try #require(try report(a, b)["network"]?.objectValue?["different"]?.arrayValue)
        #expect(different.count == 1)
        #expect(different.first?.objectValue?["request"]?.stringValue == "cdn.test/lib.js")
        #expect(different.first?.objectValue?["a"]?.stringValue == "404")
        #expect(different.first?.objectValue?["b"]?.stringValue == "200")
    }

    @Test func aRequestThatFailedOrWasAbortedInOneTabDiffersFromOneThatCompleted() throws {
        let a = Tools.observed(console: [], network: [request("https://x.test/a", outcome: "failed"), request("https://x.test/b", outcome: "aborted")])
        let b = Tools.observed(console: [], network: [request("https://x.test/a"), request("https://x.test/b")])
        let different = try #require(try report(a, b)["network"]?.objectValue?["different"]?.arrayValue)
        #expect(different.compactMap { $0.objectValue?["request"]?.stringValue } == ["x.test/a", "x.test/b"])
        #expect(different.first?.objectValue?["a"]?.stringValue == "failed")
        #expect(different.last?.objectValue?["a"]?.stringValue == "aborted")
    }

    @Test func requestsThatFailTheSameWayInBothAreCountedNotListed() throws {
        let both = [request("https://x.test/gone", status: 404), request("https://x.test/fine", status: 200)]
        let network = try #require(try report(Tools.observed(console: [], network: both), Tools.observed(console: [], network: both))["network"]?.objectValue)
        #expect(network["failedInBoth"]?.intValue == 1)
        #expect(network["different"]?.arrayValue?.isEmpty == true)
        #expect(network["onlyA"]?.arrayValue?.isEmpty == true)
    }

    @Test func aStatusOnlyOneEngineReportsDoesNotLookLikeADifference() throws {
        // WebKit's resource entries carry no status or method; Chromium's records do.
        let a = Tools.observed(console: [], network: [request("https://x.test/logo.png", method: nil)])
        let b = Tools.observed(console: [], network: [request("https://x.test/logo.png", status: 304)])
        let network = try #require(try report(a, b)["network"]?.objectValue)
        #expect(network["different"]?.arrayValue?.isEmpty == true)
        #expect(network["onlyA"]?.arrayValue?.isEmpty == true)
        #expect(network["onlyB"]?.arrayValue?.isEmpty == true)
    }

    @Test func manyRequestsToOneAddressAreReportedAsTheWorstOfThem() throws {
        let a = Tools.observed(
            console: [], network: [request("https://x.test/api", status: 200), request("https://x.test/api", status: 500), request("https://x.test/api", status: 200)])
        let b = Tools.observed(console: [], network: [request("https://x.test/api", status: 200)])
        let different = try #require(try report(a, b)["network"]?.objectValue?["different"]?.arrayValue)
        #expect(different.first?.objectValue?["a"]?.stringValue == "500")
    }

    @Test func networkListsAreBoundedAndTheRestIsCounted() throws {
        let many = (0..<(Tools.maxItems + 5)).map { request("https://x.test/asset-\($0)", status: 200) }
        let fields = try report(Tools.observed(console: [], network: many), Tools.Observed())
        #expect(fields["network"]?.objectValue?["onlyA"]?.arrayValue?.count == Tools.maxItems)
        #expect(fields["more"]?.intValue == 5)
        // Opaque addresses and records without one are skipped.
        let skipped = Tools.observed(console: [], network: [request("data:"), request("")])
        #expect(skipped.requests.isEmpty)
    }

    @Test func aSecretWithDigitsIsHiddenBeforeTheTextIsNormalized() throws {
        let scrubber = MCPSecretScrubber()
        #expect(scrubber.register("tk-482916-zzz") == .registered)
        let text = "token tk-482916-zzz rejected for user 55501234"
        // The premise: once digits are masked, the secret no longer matches and a scrubber run afterwards leaves a piece of it.
        #expect(scrubber.scrub(Tools.normalized(text)).contains("tk-#-zzz"))
        let seen = Tools.observed(
            console: [console("error", text)], network: [request("https://x.test/reset/tk-482916-zzz", status: 404)],
            scrub: { scrubber.scrub($0) })
        let report = try JSONEncoder().encode(Value.object(try report(seen, Tools.Observed())))
        let shown = String(decoding: report, as: UTF8.self)
        for hidden in ["482916", "tk-", "zzz"] {
            #expect(!shown.contains(hidden), "\(hidden) shows in \(shown)")
        }
        #expect(shown.contains(MCPSecretScrubber.replacement))
        // The rest of the line is still there, with its own digits masked.
        #expect(shown.contains("rejected for user #"))
    }

    @Test func theReportCarriesTheUntrustedNoteAndStaysSmall() throws {
        let busy = (0..<Tools.maxItems).map { console("error", "failure \($0) " + String(repeating: "x", count: 80), seq: UInt64($0)) }
        let fields = try report(Tools.observed(console: busy, network: []), Tools.Observed())
        #expect(fields["untrusted"]?.stringValue?.contains("data") == true)
        #expect(fields["compared"]?.boolValue == true)
        let value = Value.object(fields)
        #expect((try JSONEncoder().encode(value)).count < 6_000)
    }

    // MARK: Layout and the reply

    @Test func layoutNumbersComeFromThePageAndOnlyCompleteAnswersCount() throws {
        let answer: [String: Any] = ["vw": 500, "vh": 400, "dw": 500, "dh": 1_200, "els": 42, "imgs": 3, "broken": 1, "hscroll": false]
        let layout = try #require(Tools.Layout(answer))
        #expect(layout.documentHeight == 1_200 && layout.elements == 42 && layout.brokenImages == 1 && layout.horizontalScroll == false)
        var incomplete = answer
        incomplete["els"] = nil
        #expect(Tools.Layout(incomplete) == nil)
    }

    @Test func layoutDifferencesNameWhatDiffersWithinTheTolerance() {
        let base = Tools.Layout(viewportWidth: 500, viewportHeight: 400, documentWidth: 500, documentHeight: 1_200, elements: 42, images: 3, brokenImages: 0, horizontalScroll: false)
        var other = base
        other.documentHeight += Tools.sizeTolerance
        #expect(Tools.layoutDifferences(base, other).isEmpty, "rounding between engines is not a difference")
        other.documentHeight += 1
        other.brokenImages = 2
        other.horizontalScroll = true
        #expect(Tools.layoutDifferences(base, other) == ["documentHeight", "brokenImages", "horizontalScroll"])
    }

    @Test func viewportsMatchGiveOrTakeTheTolerance() {
        let a = Tools.Layout(viewportWidth: 500, viewportHeight: 400)
        #expect(Tools.sameViewport(a, Tools.Layout(viewportWidth: 502, viewportHeight: 398)))
        #expect(!Tools.sameViewport(a, Tools.Layout(viewportWidth: 503, viewportHeight: 400)))
        #expect(!Tools.sameViewport(a, Tools.Layout(viewportWidth: 500, viewportHeight: 397)))
    }

    @Test func aReplyIsAnErrorUnlessItIsOkAndCarriesTheImageAfterTheText() throws {
        let refused = Tools.result(.invalidInput, message: "no")
        #expect(refused.isError == true)
        #expect(refused.structuredContent?.objectValue?["status"]?.stringValue == "invalidInput")
        let image = Data([0xFF, 0xD8, 0xFF])
        let ok = Tools.result(.ok, ["layout": .object([:])], image: image)
        #expect(ok.isError == false)
        #expect(ok.content.count == 2)
        guard case .image(let data, let mime, _, _) = ok.content[1] else {
            Issue.record("the image block is missing")
            return
        }
        #expect(Data(base64Encoded: data) == image && mime == "image/jpeg")
    }

    // MARK: Catalog

    @Test func theCompareToolsDeclareNoTabScopeAndTheEngineIsAChoice() throws {
        for name in ["openComparison", "compareTabs"] {
            let entry = try #require(MCPToolCatalog.entries.first { $0.name == name })
            #expect(entry.scope == nil && !entry.usesRef, "\(name)")
            #expect(!entry.parameters.contains { $0.name == "tabID" }, "\(name)")
        }
        let compare = try #require(MCPToolCatalog.entries.first { $0.name == "compareTabs" })
        try compare.validate(["tabA": "x", "tabB": "y", "image": true, "diagnostics": false])
        #expect(throws: MCPError.self) { try compare.validate(["tabA": "x"]) }
        #expect(throws: MCPError.self) { try compare.validate(["tabA": "x", "tabB": "y", "image": "yes"]) }
        let newTab = try #require(MCPToolCatalog.entries.first { $0.name == "newTab" })
        try newTab.validate(["url": "https://example.test/", "engine": "chromium"])
        try newTab.validate(["url": "https://example.test/"])
        #expect(throws: MCPError.self) { try newTab.validate(["url": "https://example.test/", "engine": "gecko"]) }
        #expect(MCPBrowserSession.actionTitle(forTool: "compareTabs") == String(localized: "Compare Tabs"))
        #expect(MCPBrowserSession.actionTitle(forTool: "openComparison") == String(localized: "Open Comparison"))
    }
}
