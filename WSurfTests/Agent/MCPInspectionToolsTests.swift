// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// `readAccessibility` and `readPerformance` through the MCP session, on both engines.
@MainActor
struct MCPInspectionToolsTests {
    private static let pixel = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7") ?? Data()

    private static let page = """
        <!doctype html><title>Inspect</title>
        <link rel="stylesheet" href="/style.css">
        <header><a href="/next">Home</a></header>
        <main><h1>Dashboard</h1><p>Prose is not part of the outline.</p>
        <form aria-label="Login"><label for="u">User</label><input id="u">
        <label for="p">Password</label><input id="p" type="password" value="hunter2-secret">
        <button type="button" onclick="document.body.dataset.clicked='yes'">Save</button></form>
        <ul><li>One</li><li>Two</li></ul>
        <div hidden><button>Never shown</button></div><div aria-hidden="true"><button>Masked</button></div></main>
        <img src="/pixel.gif?session=secret-token#frag" alt="Pixel" width="4" height="4">
        <script src="/app.js?token=secret-token#frag"></script>
        """

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/style.css": .bytes(Data("body { margin: 0 }".utf8), contentType: "text/css"),
        "/app.js": .bytes(Data("window.appLoaded = true".utf8), contentType: "text/javascript"),
        "/pixel.gif": .bytes(pixel, contentType: "image/gif"),
        "/next": .html("<p>Next page</p>"),
    ]

    /// A Chromium page loads only once a window hosts it, as in the app.
    private func host(_ tab: BrowserTab) async -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = WebViewContainer(page: tab.page)
        window.contentView = container
        window.orderBack(nil)
        #expect(await waitUntil { tab.page.superview === container }, "the page is hosted")
        return window
    }

    private func withFixture(
        _ html: String = MCPInspectionToolsTests.page, engine: BrowserEngine, _ body: (BrowserModel, BrowserTab) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(html)].merging(Self.routes) { $1 })
        defer { withExtendedLifetime(server) {} }
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPInspect-\(UUID().uuidString).json")))
        let url = try server.url()
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
            browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        }
        let tab = browser.newTab(url: url)
        let window = engine == .chromium ? await host(tab) : nil
        defer {
            window?.contentView = nil
            window?.close()
        }
        #expect(tab.page.engine == engine)
        #expect(await PageSettle.untilIdle(tab.page))
        #expect(await waitUntil { tab.page.mainDocumentID != nil }, "the page registered its main document")
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        try await body(browser, tab)
    }

    private func session(_ browser: BrowserModel, access: MCPAccessConsent.Access = .development) -> MCPBrowserSession {
        MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in access })
    }

    private func call(
        _ session: MCPBrowserSession, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]
    ) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await session.call(name: name, arguments: arguments)
    }

    /// The page text of a reply, with the untrusted wrapper's escaping undone.
    private func content(_ result: CallTool.Result) -> String {
        (result.structuredContent?.objectValue?["content"]?.stringValue ?? "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    private func observationID(_ result: CallTool.Result) -> String? { result.structuredContent?.objectValue?["observationID"]?.stringValue }

    /// The report object of a `readPerformance` reply.
    private func report(_ result: CallTool.Result) throws -> [String: Any] {
        let body = try #require(content(result).components(separatedBy: "PERFORMANCE:\n").last)
        let json = try #require(body.components(separatedBy: "\nobservationID:").first?.components(separatedBy: "\n</page-content>").first)
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func ref(of line: String, in text: String) throws -> Int {
        let row = try #require(text.split(separator: "\n").first { $0.contains(line) }, "\(line) in \(text)")
        let digits = try #require(row.firstMatch(of: /\[(\d+)\]/)?.1)
        return try #require(Int(digits))
    }

    // MARK: The accessibility outline

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func treeShowsLandmarksHeadingsListsTablesAndControls(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser, access: .readOnly)
            _ = try await call(subject, "requestAccess")
            let read = try await call(subject, "readAccessibility", tab)
            #expect(read.isError == false, "\(content(read))")
            let text = content(read)
            #expect(text.contains("<page-content untrusted=\"true\">"))
            for expected in [
                "ACCESSIBILITY TREE (nodes 1-", "banner", "link \"Home\"", "main", "heading \"Dashboard\" level=1", "form \"Login\"",
                "textbox \"User\"", "textbox \"Password\" sensitive", "button \"Save\"", "list items=2", "listitem \"One\"", "img \"Pixel\"",
            ] {
                #expect(text.contains(expected), "\(expected) in \(text)")
            }
            #expect(!text.contains("Prose is not part"), "plain text belongs to readPage")
            #expect(observationID(read) != nil)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func hiddenInertAndAriaHiddenNodesAreLeftOut(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            _ = try await tab.page.evaluateJavaScript(
                "document.body.insertAdjacentHTML('beforeend', '<div inert><button>Inert</button></div><div style=\"display:none\"><button>None</button></div>'); 0")
            let subject = session(browser, access: .readOnly)
            _ = try await call(subject, "requestAccess")
            let text = content(try await call(subject, "readAccessibility", tab))
            for hidden in ["Never shown", "Masked", "Inert", "None"] {
                #expect(!text.contains(hidden), "\(hidden) must not be listed: \(text)")
            }
            #expect(text.contains("button \"Save\""))
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func sensitiveFieldsShowRoleAndNameOnly(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            _ = try await tab.page.evaluateJavaScript("document.getElementById('u').value = 'typed-value'; 0")
            let subject = session(browser, access: .readOnly)
            _ = try await call(subject, "requestAccess")
            let read = try await call(subject, "readAccessibility", tab)
            let everything = content(read) + String(describing: read.structuredContent)
            #expect(!everything.contains("hunter2-secret"))
            #expect(!everything.contains("typed-value"), "no field value is listed, sensitive or not")
            #expect(content(read).contains("textbox \"Password\" sensitive"))
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func treeRefsCanBeClicked(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser, access: .control)
            _ = try await call(subject, "requestAccess")
            let read = try await call(subject, "readAccessibility", tab)
            let id = try #require(observationID(read))
            let save = try ref(of: "button \"Save\"", in: content(read))
            let clicked = try await call(subject, "clickOnPage", tab, ["observationID": .string(id), "ref": .int(save)])
            #expect(clicked.isError == false, "\(content(clicked))")
            #expect(try await tab.page.evaluateJavaScript("document.body.dataset.clicked || ''") as? String == "yes")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aRefOfAnotherReadIsRefusedAfterTheTreeWasRead(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser, access: .control)
            _ = try await call(subject, "requestAccess")
            let first = try await call(subject, "readAccessibility", tab)
            let staleID = try #require(observationID(first))
            let save = try ref(of: "button \"Save\"", in: content(first))
            _ = try await call(subject, "readPage", tab)
            let stale = try await call(subject, "clickOnPage", tab, ["observationID": .string(staleID), "ref": .int(save)])
            #expect(stale.isError == true)
            #expect(try await tab.page.evaluateJavaScript("document.body.dataset.clicked || ''") as? String == "")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func readOnlyGrantCanReadTheTreeButNotActOrMeasure(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser, access: .readOnly)
            _ = try await call(subject, "requestAccess")
            let read = try await call(subject, "readAccessibility", tab)
            #expect(read.isError == false)
            let save = try ref(of: "button \"Save\"", in: content(read))
            let id = try #require(observationID(read))
            #expect(try await call(subject, "clickOnPage", tab, ["observationID": .string(id), "ref": .int(save)]).isError == true)
            #expect(try await call(subject, "readPerformance", tab).isError == true)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func treeIsBoundedAndPages(engine: BrowserEngine) async throws {
        let items = (0..<1_000).map { "<li><a href='/next?i=\($0)'>Item \($0) &amp; more</a></li>" }.joined()
        try await withFixture("<!doctype html><title>Long</title><main><ul>\(items)</ul></main>", engine: engine) { browser, tab in
            let subject = session(browser, access: .readOnly)
            _ = try await call(subject, "requestAccess")
            var offset = 0
            var listed = 0
            var replies = 0
            while true {
                let read = try await call(subject, "readAccessibility", tab, offset == 0 ? [:] : ["offset": .int(offset)])
                #expect(read.isError == false, "\(content(read))")
                #expect(MCPBrowserSession.replyBytes(read) < MCPMessageFramer.maximumBytes)
                let text = content(read)
                let rows = text.split(separator: "\n").filter { $0.contains("link \"Item") }
                #expect(rows.count <= PageAccessibility.maxNodes)
                listed += rows.count
                replies += 1
                guard let next = text.firstMatch(of: /readAccessibility offset=(\d+)/)?.1 else { break }
                offset = try #require(Int(next))
            }
            // main, list and the 1,000 links make 1,002 nodes (each unnamed item is folded into its link): three replies.
            #expect(listed == 1_000)
            #expect(replies == 3)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func scopeLimitsTheOutlineAndUnsafeOrMissingScopesAreRefused(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser, access: .readOnly)
            _ = try await call(subject, "requestAccess")
            let scoped = try await call(subject, "readAccessibility", tab, ["scope": "form"])
            #expect(scoped.isError == false, "\(content(scoped))")
            #expect(content(scoped).contains("button \"Save\"") && !content(scoped).contains("link \"Home\""))
            for scope in ["#missing", "input[type=hidden][value^=a]", "div[", String(repeating: "a", count: 3_000)] {
                let refused = try await call(subject, "readAccessibility", tab, ["scope": .string(scope)])
                #expect(refused.isError == true, "\(scope.prefix(40))")
                #expect(!content(refused).contains("ACCESSIBILITY TREE"))
            }
        }
    }

    @Test func catalogBoundsOffsetScopeAndArguments() throws {
        let tab: Value = .string(UUID().uuidString)
        let tree = try #require(MCPToolCatalog.entries.first { $0.name == "readAccessibility" })
        try tree.validate(["tabID": tab, "offset": 0, "scope": "main"])
        try tree.validate(["tabID": tab])
        #expect(throws: (any Error).self) { try tree.validate(["tabID": tab, "offset": -1]) }
        #expect(throws: (any Error).self) { try tree.validate(["tabID": tab, "offset": 100_001]) }
        #expect(throws: (any Error).self) { try tree.validate(["tabID": tab, "scope": 3]) }
        #expect(throws: (any Error).self) { try tree.validate(["tabID": tab, "depth": 3]) }
        #expect(throws: (any Error).self) { try tree.validate([:]) }
        let performance = try #require(MCPToolCatalog.entries.first { $0.name == "readPerformance" })
        try performance.validate(["tabID": tab])
        #expect(throws: (any Error).self) { try performance.validate(["tabID": tab, "offset": 0]) }
        #expect(tree.readOnly && performance.readOnly)
    }

    // MARK: The performance summary

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func performanceReportsNavigationAndPaintTimings(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser)
            _ = try await call(subject, "requestAccess", nil, ["development": true])
            let result = try await call(subject, "readPerformance", tab)
            #expect(result.isError == false, "\(content(result))")
            let report = try self.report(result)
            #expect(report["engine"] as? String == engine.rawValue)
            let navigation = try #require(report["navigation"] as? [String: Any])
            #expect(navigation["type"] as? String == "navigate")
            #expect((navigation["ttfbMs"] as? Double ?? 0) > 0)
            #expect((navigation["domContentLoadedMs"] as? Double ?? 0) > 0)
            #expect((navigation["loadMs"] as? Double ?? 0) >= (navigation["domContentLoadedMs"] as? Double ?? 1))
            #expect((navigation["transferBytes"] as? Int ?? 0) > 0)
            let paint = try #require(report["paint"] as? [String: Any])
            // First paint needs a rendered frame, which a window nobody sees may never produce: a number or null, never zero.
            if let fcp = paint["firstContentfulPaintMs"] as? Double { #expect(fcp > 0) }
            let resources = try #require(report["resources"] as? [String: Any])
            #expect((resources["count"] as? Int ?? 0) >= 3, "style, script and image")
            let byType = try #require(resources["byType"] as? [String: [String: Any]])
            #expect(byType["script"]?["count"] as? Int == 1 && byType["link"]?["count"] as? Int == 1 && byType["img"]?["count"] as? Int == 1, "\(byType)")
            #expect(((resources["slowest"] as? [Any])?.count ?? 0) <= PagePerformance.slowestCount)
            #expect((resources["transferBytes"] as? Int ?? 0) > 0)
            let text = content(result)
            for leak in ["secret-token", "#frag", "?token", "?session"] {
                #expect(!text.contains(leak), "query values and fragments never leave the page: \(leak)")
            }
            #expect(text.utf8.count < 4_096, "a summary, not a trace: \(text.utf8.count) bytes")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func unsupportedMetricsAreNullAndListed(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser)
            _ = try await call(subject, "requestAccess", nil, ["development": true])
            let supported = try #require(
                try await tab.page.evaluateJavaScript("Array.from(PerformanceObserver.supportedEntryTypes)") as? [String])
            let report = try self.report(try await call(subject, "readPerformance", tab))
            let listed = try #require(report["unsupported"] as? [String])
            let expected = ["navigation", "paint", "resource", "largest-contentful-paint", "layout-shift", "longtask"].filter { !supported.contains($0) }
            #expect(Set(listed.filter { $0 != "runtime" }) == Set(expected), "listed \(listed), page supports \(supported)")
            let nullWhenUnsupported: [(type: String, isNull: Bool)] = [
                ("navigation", report["navigation"] is NSNull), ("resource", report["resources"] is NSNull),
                ("layout-shift", report["layout"] is NSNull), ("longtask", report["longTasks"] is NSNull),
            ]
            for entry in nullWhenUnsupported {
                #expect(entry.isNull == listed.contains(entry.type), "\(entry.type): null must mean unsupported")
            }
            if listed.contains("largest-contentful-paint"), let paint = report["paint"] as? [String: Any] {
                #expect(paint["largestContentfulPaintMs"] is NSNull)
            }
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func runtimeMetricsComeOnlyFromChromium(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser)
            _ = try await call(subject, "requestAccess", nil, ["development": true])
            let report = try self.report(try await call(subject, "readPerformance", tab))
            let listed = try #require(report["unsupported"] as? [String])
            if engine == .chromium {
                let runtime = try #require(report["runtime"] as? [String: Int], "\(report)")
                #expect((runtime["domNodes"] ?? 0) > 0 && (runtime["jsHeapUsedBytes"] ?? 0) > 0 && (runtime["documents"] ?? 0) > 0)
                #expect(!listed.contains("runtime"))
            } else {
                #expect(report["runtime"] is NSNull)
                #expect(listed.contains("runtime"))
            }
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func longTasksAreCountedWhereTheEngineExposesThem(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser)
            _ = try await call(subject, "requestAccess", nil, ["development": true])
            _ = try await tab.page.evaluateJavaScript("setTimeout(() => { const t = performance.now(); while (performance.now() - t < 150); }, 0); 0")
            let supported = try await tab.page.evaluateJavaScript("PerformanceObserver.supportedEntryTypes.includes('longtask')") as? Bool == true
            var seen: [String: Any]?
            let observed = await waitUntil {
                let report = try? self.report(try await self.call(subject, "readPerformance", tab))
                seen = report?["longTasks"] as? [String: Any]
                return !supported || (seen?["count"] as? Int ?? 0) >= 1
            }
            #expect(observed)
            if supported {
                #expect((seen?["maxMs"] as? Double ?? 0) >= 100)
            } else {
                #expect(seen == nil)
            }
        }
    }

    @Test(.boundedWebViews) func performanceNeedsDevelopmentAccess() async throws {
        try await withFixture(engine: .webKit) { browser, tab in
            let subject = session(browser, access: .control)
            _ = try await call(subject, "requestAccess")
            let denied = try await call(subject, "readPerformance", tab)
            #expect(denied.isError == true)
            #expect(!content(denied).contains("PERFORMANCE:"))
            #expect(MCPToolCatalog.entries.first { $0.name == "readPerformance" }?.scope == .development)
            #expect(MCPToolCatalog.entries.first { $0.name == "readAccessibility" }?.scope == .read)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func readingPerformanceKeepsTheCurrentObservationUsable(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine) { browser, tab in
            let subject = session(browser)
            _ = try await call(subject, "requestAccess", nil, ["development": true])
            let read = try await call(subject, "readAccessibility", tab)
            let id = try #require(observationID(read))
            let save = try ref(of: "button \"Save\"", in: content(read))
            let measured = try await call(subject, "readPerformance", tab)
            #expect(observationID(measured) == id)
            let clicked = try await call(subject, "clickOnPage", tab, ["observationID": .string(id), "ref": .int(save)])
            #expect(clicked.isError == false, "\(content(clicked))")
        }
    }
}
