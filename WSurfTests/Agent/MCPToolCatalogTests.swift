// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
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
}
