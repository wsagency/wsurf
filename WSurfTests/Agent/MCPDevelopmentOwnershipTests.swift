// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Development access, the one-owner-per-tab lease, and the events that must release it.
@MainActor
@Suite(.boundedWebViews)
struct MCPDevelopmentOwnershipTests {
    private func fixture() async throws -> (HTTPFixtureServer, BrowserModel, BrowserTab) {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Dev</title><p id=a class=x>Hello</p><button class=x>Go</button>"),
        ])
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDev-\(UUID().uuidString).json")))
        let url = try server.url()
        let tab = browser.newTab(url: url)
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        return (server, browser, tab)
    }

    private func session(
        _ browser: BrowserModel, answer: MCPAccessConsent.Access = .development, asked: ((Bool) -> Void)? = nil
    ) -> MCPBrowserSession {
        MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, development in
            asked?(development)
            return answer
        })
    }

    private func call(
        _ session: MCPBrowserSession, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]
    ) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await session.call(name: name, arguments: arguments)
    }

    private func status(_ result: CallTool.Result) -> String? { result.structuredContent?.objectValue?["status"]?.stringValue }

    private let phone: [String: Value] = ["width": 400, "height": 700]

    @Test func developmentIsOnlyGrantedWhenRequested() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        var asked: Bool?
        let subject = session(browser, asked: { asked = $0 })
        _ = try await call(subject, "requestAccess")
        #expect(asked == false)
        let denied = try await call(subject, "setViewport", tab, phone)
        #expect(denied.isError == true)
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(asked == true)
        #expect(try await call(subject, "setViewport", tab, phone).isError == false)
    }

    @Test func controlGrantCannotUseDevelopmentTools() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser, answer: .control)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        for name in ["setViewport", "startDiagnostics", "readConsole", "readNetwork", "reloadPage", "resetDevelopment"] {
            let result = try await call(subject, name, tab, name == "setViewport" ? phone : [:])
            #expect(result.isError == true, "\(name)")
        }
        #expect(tab.developmentOwner == nil)
    }

    @Test func onlyOneConnectionOwnsATab() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let first = session(browser), second = session(browser)
        _ = try await call(first, "requestAccess", nil, ["development": true])
        _ = try await call(second, "requestAccess", nil, ["development": true])
        #expect(status(try await call(first, "setViewport", tab, phone)) == "ok")
        let size = try #require(tab.page.developmentViewport)
        #expect(status(try await call(second, "setViewport", tab, ["width": 800, "height": 600])) == "ownershipConflict")
        #expect(status(try await call(second, "startDiagnostics", tab)) == "ownershipConflict")
        #expect(status(try await call(second, "resetDevelopment", tab)) == "ownershipConflict")
        #expect(status(try await call(second, "reloadPage", tab)) == "ownershipConflict")
        #expect(tab.page.developmentViewport == size, "a rejected request must not change the owner's viewport")
        #expect(tab.developmentRelation(of: first.id) == .own)
        // Reads stay available to the non-owner and report who holds the lease.
        let info = try await call(second, "getDevelopmentInfo", tab)
        #expect(info.structuredContent?.objectValue?["owner"]?.stringValue == "other")
        #expect(status(try await call(first, "resetDevelopment", tab)) == "ok")
        #expect(status(try await call(first, "resetDevelopment", tab)) == "ok", "reset is idempotent")
        #expect(tab.page.developmentViewport == nil)
        #expect(status(try await call(second, "setViewport", tab, phone)) == "ok")
    }

    @Test func disconnectReleasesTheLease() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(status(try await call(subject, "setViewport", tab, phone)) == "ok")
        await subject.revoke()
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
    }

    @Test func policyDowngradeReleasesTheLeaseOnTheNextCall() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(status(try await call(subject, "setViewport", tab, phone)) == "ok")
        tab.assistantAccess.set(.readOnly)
        _ = try await call(subject, "getDevelopmentInfo", tab)
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
        #expect(try await call(subject, "setViewport", tab, phone).isError == true)
    }

    @Test func rejectedRequestsLeaveTheSlotFreeAndTheTabUntouched() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(status(try await call(subject, "setViewport", tab, ["width": 10, "height": 700])) == "invalidInput")
        #expect(status(try await call(subject, "emulateDevice", tab, ["profile": "nope", "orientation": "portrait"])) == "invalidInput")
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
    }

    @Test func findingElementsNeedsDevelopmentAccessAndReturnsRefsForInspection() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let plain = session(browser, answer: .control)
        _ = try await call(plain, "requestAccess")
        #expect(try await call(plain, "findElements", tab, ["selector": ".x"]).isError == true)
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        let found = try await call(subject, "findElements", tab, ["selector": ".x"])
        #expect(found.isError == false)
        #expect(try await call(subject, "findElements", tab, ["selector": ".x", "limit": 101]).isError == true)
        let observation = try #require(found.structuredContent?.objectValue?["observationID"]?.stringValue)
        let inspected = try await call(subject, "inspectElement", tab, ["observationID": .string(observation), "ref": 1])
        #expect(inspected.isError == false)
    }

    @Test func viewportIsMeasuredInThePageAndResetRestoresIt() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        let applied = try await call(subject, "setViewport", tab, phone)
        #expect(status(applied) == "ok")
        let measured = try #require(applied.structuredContent?.objectValue?["viewport"]?.objectValue)
        #expect(measured["innerWidth"]?.intValue == 400)
        #expect(measured["innerHeight"]?.intValue == 700)
        #expect(try await tab.page.evaluateJavaScript("window.innerWidth") as? Int == 400)
        _ = try await call(subject, "resetDevelopment", tab)
        #expect(try await tab.page.evaluateJavaScript("window.innerWidth") as? Int != 400)
    }

    @Test func diagnosticsCaptureOnlyAfterStartAndStopOnReset() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        _ = try await tab.page.evaluateJavaScript("console.log('before-start'); 0")
        #expect(status(try await call(subject, "readConsole", tab)) == "invalidInput", "reading needs a running capture")
        #expect(status(try await call(subject, "startDiagnostics", tab)) == "ok")
        _ = try await tab.page.evaluateJavaScript("console.log('after-start'); 0")
        var records: [Value] = []
        for _ in 0..<50 where records.isEmpty {
            let read = try await call(subject, "readConsole", tab)
            records = read.structuredContent?.objectValue?["records"]?.arrayValue ?? []
            if records.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        let text = records.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
        #expect(text.contains("after-start"))
        #expect(!text.contains("before-start"))
        let bad = try await call(subject, "readConsole", tab, ["cursor": "not-a-cursor"])
        #expect(status(bad) == "invalidInput")
        _ = try await call(subject, "resetDevelopment", tab)
        #expect(tab.developmentOwner == nil)
        #expect(status(try await call(subject, "readConsole", tab)) == "invalidInput")
    }

    @Test func catalogBoundsReadsAndPaging() throws {
        func entry(_ name: String) throws -> MCPToolCatalog.Entry { try #require(MCPToolCatalog.entries.first { $0.name == name }) }
        let tab: Value = .string(UUID().uuidString)
        let find = try entry("findElements")
        try find.validate(["tabID": tab, "selector": ".x", "offset": 10_000, "limit": 100])
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "limit": 101]) }
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "limit": 0]) }
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "offset": 10_001]) }
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "offset": -1]) }
        let console = try entry("readConsole")
        try console.validate(["tabID": tab, "limit": 100])
        #expect(throws: (any Error).self) { try console.validate(["tabID": tab, "limit": 101]) }
        try entry("requestAccess").validate(["development": true])
        #expect(throws: (any Error).self) { try entry("requestAccess").validate(["development": "yes"]) }
        #expect(throws: (any Error).self) { try entry("setViewport").validate(["tabID": tab, "width": 63, "height": 700]) }
    }
}
