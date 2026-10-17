// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP
import Testing

@testable import WSurf

@MainActor
struct MCPToolCatalogTests {
    private typealias Scope = MCPBrowserSession.Scope

    /// The tools that existed before scopes moved into the catalog, in the order `tools/list` reported them.
    private static let originalScopes: [(name: String, scope: Scope?)] = [
        ("requestAccess", nil), ("listTabs", nil), ("readPage", .read), ("clickOnPage", .control), ("typeOnPage", .control),
        ("selectOption", .control), ("hoverOnPage", .control), ("pressKey", .control), ("fillFields", .control),
        ("inspectControl", .read), ("setChecked", .control), ("waitForPage", .read), ("screenshotPage", .read),
        ("scrollPage", .control), ("getDevelopmentInfo", .read), ("findElements", .development), ("inspectElement", .development),
        ("setViewport", .development), ("emulateDevice", .development), ("reloadPage", .development),
        ("resetDevelopment", .development), ("startDiagnostics", .development), ("readConsole", .development),
        ("readNetwork", .development), ("goBack", .control), ("navigate", .control), ("newTab", nil), ("switchTab", .control),
        ("closeTab", .control),
    ]

    private static let originalRefTools: Set<String> = [
        "clickOnPage", "typeOnPage", "selectOption", "fillFields", "inspectControl", "setChecked", "hoverOnPage", "pressKey",
        "inspectElement",
    ]

    @Test func everyCatalogEntryDeclaresItsScope() {
        let names = MCPToolCatalog.entries.map(\.name)
        #expect(Set(names).count == names.count)
        for entry in MCPToolCatalog.entries {
            let takesATab = entry.parameters.contains { $0.name == "tabID" }
            #expect((entry.scope != nil) == takesATab, "\(entry.name) must declare a scope exactly when it takes a tabID")
            #expect(!entry.usesRef || takesATab, "\(entry.name) uses a ref but takes no tab")
        }
    }

    @Test func existingToolsKeepTheirScopeRefUseAndOrder() throws {
        let original = Self.originalScopes.map(\.name)
        #expect(MCPToolCatalog.entries.map(\.name).filter(original.contains) == original)
        for (name, scope) in Self.originalScopes {
            let entry = try #require(MCPToolCatalog.entries.first { $0.name == name })
            #expect(entry.scope == scope, "\(name)")
            #expect(entry.usesRef == Self.originalRefTools.contains(name), "\(name)")
        }
    }

    @Test func lastActionTitleNamesDevelopmentTools() {
        for entry in MCPToolCatalog.entries {
            let title = MCPBrowserSession.actionTitle(forTool: entry.name)
            #expect(title?.isEmpty == false, "\(entry.name) has no activity title")
            #expect((title == String(localized: "Request Tab Access")) == (entry.name == "requestAccess"), "\(entry.name)")
        }
        #expect(MCPBrowserSession.actionTitle(forTool: "readConsole") == String(localized: "Read Console"))
        #expect(MCPBrowserSession.actionTitle(forTool: "setViewport") == String(localized: "Set Viewport"))
        #expect(MCPBrowserSession.actionTitle(forTool: "clickOnPage") == AgentToolCatalog.all.first { $0.id == "clickOnPage" }.map { String(localized: $0.title) })
        #expect(MCPBrowserSession.actionTitle(forTool: "noSuchTool") == nil)
    }

    // MARK: Reply options

    private func entry(_ name: String) throws -> MCPToolCatalog.Entry {
        try #require(MCPToolCatalog.entries.first { $0.name == name })
    }

    @Test func everyActionToolOffersTheReplyOptionsAndNeedsNoObservationID() throws {
        for name in MCPBrowserSession.feedbackActions {
            let entry = try entry(name)
            let names = Set(entry.parameters.map(\.name))
            #expect(names.isSuperset(of: ["result", "budget", "screenshotOnFailure"]), "\(name)")
            #expect(entry.parameters.filter { $0.name == "observationID" }.allSatisfy { !$0.required }, "\(name)")
            #expect(entry.parameters.filter { ["result", "budget", "screenshotOnFailure"].contains($0.name) }.allSatisfy { !$0.required }, "\(name)")
        }
        // An inspection ref names the findElements observation it came from.
        #expect(try entry("inspectElement").parameters.first { $0.name == "observationID" }?.required == true)
    }

    @Test func theReplyOptionsAreOptionalSoOldClientsKeepWorking() throws {
        let click = try entry("clickOnPage")
        try click.validate(["tabID": "t", "ref": 1])
        try click.validate(["tabID": "t", "observationID": "o", "ref": 1])
        try click.validate(["tabID": "t", "ref": 1, "result": "full", "screenshotOnFailure": "element", "budget": .object(["maxBytes": 8_000])])
    }

    @Test func choicesAndBudgetsAreCheckedBeforeAnythingRuns() throws {
        let click = try entry("clickOnPage")
        let base: [String: Value] = ["tabID": "t", "ref": 1]
        func rejects(_ extra: [String: Value]) -> Bool {
            (try? click.validate(base.merging(extra) { $1 })) == nil
        }
        #expect(rejects(["result": "everything"]))
        #expect(rejects(["screenshotOnFailure": "page"]))
        #expect(rejects(["budget": .object(["maxBytes": 999])]))
        #expect(rejects(["budget": .object(["maxBytes": 60_001])]))
        #expect(rejects(["budget": .object(["settleMs": 199])]))
        #expect(rejects(["budget": .object(["settleMs": 5_001])]))
        #expect(rejects(["budget": .object(["bytes": 2_000])]))
        #expect(rejects(["budget": "4000"]))
        #expect(!rejects(["budget": .object(["maxBytes": 1_000, "settleMs": 200])]))
        #expect(!rejects(["budget": .object(["maxBytes": 60_000, "settleMs": 5_000])]))
        #expect(FeedbackBudget() == FeedbackBudget(.object([:])))
        #expect(FeedbackBudget(.object(["maxBytes": 2_000])).settleMs == FeedbackBudget.defaultSettle)
    }

    @Test func screenshotOptionsAreBounded() throws {
        let shot = try entry("screenshotPage")
        try shot.validate(["tabID": "t", "maxWidth": 320, "fullPage": true])
        #expect((try? shot.validate(["tabID": "t", "maxWidth": 319])) == nil)
        #expect((try? shot.validate(["tabID": "t", "maxWidth": 2_049])) == nil)
        #expect(shot.parameters.first { $0.name == "observationID" }?.required == false)
    }

    @Test func theSchemaListsTheChoicesAndTheBudgetBounds() throws {
        let click = try entry("clickOnPage").tool.inputSchema.objectValue?["properties"]?.objectValue
        #expect(click?["result"]?.objectValue?["enum"] == ["delta", "full"])
        #expect(click?["screenshotOnFailure"]?.objectValue?["enum"] == ["element", "viewport"])
        let budget = click?["budget"]?.objectValue
        #expect(budget?["additionalProperties"] == false)
        #expect(budget?["properties"]?.objectValue?["maxBytes"]?.objectValue?["minimum"] == 1_000)
        #expect(budget?["properties"]?.objectValue?["settleMs"]?.objectValue?["maximum"] == 5_000)
    }
}
