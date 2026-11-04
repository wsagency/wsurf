// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import MCP
import Testing

@testable import WSurf

/// The Playwright MCP names: each becomes a call of the WSurf tool it names, with arguments that tool accepts, so the tool's
/// own checks decide what runs and what is refused. `MCPBackgroundTabTests` runs them against real background tabs on both
/// engines and compares their refusals with the tools'.
@MainActor
struct MCPPlaywrightAliasTests {
    private typealias Step = MCPBrowserSession.PlaywrightStep

    private let tab = UUID()
    private let other = UUID()

    private func entry(_ name: String) throws -> MCPToolCatalog.Entry {
        try #require(MCPToolCatalog.playwrightEntries.first { $0.name == name }, "\(name)")
    }

    /// The step for a call on `tab` (the first of two shared tabs), after the alias entry accepted the arguments.
    private func step(_ name: String, _ arguments: [String: Value] = [:], shared: Bool = true, dialogID: String? = nil) throws -> Step {
        try entry(name).validate(arguments)
        return MCPBrowserSession.playwrightStep(name, arguments, tabs: shared ? [tab, other] : [], current: shared ? tab : nil, dialogID: dialogID)
    }

    /// Every alias with sample Playwright arguments and the WSurf call it must become.
    private var mappings: [(alias: String, arguments: [String: Value], call: (tool: String, arguments: [String: Value]))] {
        let current: Value = .string(tab.uuidString)
        return [
            ("browser_navigate", ["url": "https://example.com/"], ("navigate", ["tabID": current, "url": "https://example.com/"])),
            ("browser_navigate_back", [:], ("goBack", ["tabID": current])),
            ("browser_click", ["element": "Go button", "ref": "e3"], ("clickOnPage", ["tabID": current, "ref": 3])),
            ("browser_click", ["ref": "3", "doubleClick": false, "button": "left", "modifiers": []], ("clickOnPage", ["tabID": current, "ref": 3])),
            (
                "browser_type", ["element": "Name", "ref": "4", "text": "Ada", "submit": true, "slowly": true],
                ("typeOnPage", ["tabID": current, "ref": 4, "text": "Ada", "submit": true])
            ),
            (
                "browser_fill_form",
                ["fields": [["name": "Name", "type": "textbox", "ref": "e2", "value": "Ada"], ["name": "Agree", "type": "checkbox", "ref": "5", "value": "true"]]],
                ("fillFields", ["tabID": current, "fields": [["ref": 2, "value": "Ada", "select": false], ["ref": 5, "value": "true", "select": false]]])
            ),
            ("browser_press_key", ["key": "Enter", "ref": "e1"], ("pressKey", ["tabID": current, "key": "Enter", "ref": 1])),
            ("browser_press_key", ["key": "Enter"], ("pressKey", ["tabID": current, "key": "Enter"])),
            ("browser_hover", ["element": "Menu", "ref": "e7"], ("hoverOnPage", ["tabID": current, "ref": 7])),
            ("browser_select_option", ["ref": "e8", "values": ["Blue"]], ("selectOption", ["tabID": current, "ref": 8, "option": "Blue"])),
            ("browser_snapshot", [:], ("readAccessibility", ["tabID": current])),
            (
                "browser_take_screenshot", ["type": "png", "filename": "page.png", "ref": "e2", "fullPage": false],
                ("screenshotPage", ["tabID": current, "ref": 2, "fullPage": false])
            ),
            ("browser_evaluate", ["function": "() => document.title"], ("evaluateScript", ["tabID": current, "source": "() => document.title"])),
            ("browser_wait_for", ["text": "Done"], ("waitForPage", ["tabID": current, "condition": "text", "value": "Done"])),
            ("browser_wait_for", ["textGone": "Loading"], ("waitForPage", ["tabID": current, "condition": "textAbsent", "value": "Loading"])),
            ("browser_tabs", ["action": "list"], ("listTabs", [:])),
            ("browser_tabs", ["action": "new", "url": "https://example.com/"], ("newTab", ["url": "https://example.com/"])),
            ("browser_tabs", ["action": "close", "index": 1], ("closeTab", ["tabID": .string(other.uuidString)])),
            ("browser_tabs", ["action": "close"], ("closeTab", ["tabID": current])),
            ("browser_console_messages", ["level": "warning"], ("readConsole", ["tabID": current, "level": "warn"])),
            ("browser_console_messages", ["onlyErrors": true], ("readConsole", ["tabID": current, "level": "error"])),
            ("browser_network_requests", ["includeStatic": true], ("readNetwork", ["tabID": current])),
            ("browser_close", [:], ("closeTab", ["tabID": current])),
            ("browser_resize", ["width": 1280, "height": 800.0], ("setViewport", ["tabID": current, "width": 1280, "height": 800])),
            ("browser_handle_dialog", ["accept": false, "promptText": "Ada"], ("handleDialog", ["tabID": current, "dialogID": "d1", "action": "dismiss"])),
            (
                "browser_handle_dialog", ["accept": true, "promptText": "Ada"],
                ("handleDialog", ["tabID": current, "dialogID": "d1", "action": "accept", "text": "Ada"])
            ),
        ]
    }

    @Test func eachAliasBecomesItsToolWithArgumentsTheToolAccepts() throws {
        for mapping in mappings {
            let result = try step(mapping.alias, mapping.arguments, dialogID: "d1")
            #expect(result == .call(mapping.call.tool, mapping.call.arguments, delay: 0), "\(mapping.alias) \(mapping.arguments)")
            let tool = try #require(MCPToolCatalog.entries.first { $0.name == mapping.call.tool }, "\(mapping.call.tool)")
            do {
                try tool.validate(mapping.call.arguments)
            } catch {
                Issue.record("\(mapping.alias): \(mapping.call.tool) refuses the translated arguments: \(error)")
            }
        }
        // Every alias but the file chooser is covered above.
        let covered = Set(mappings.map(\.alias))
        #expect(Set(MCPToolCatalog.playwrightEntries.map(\.name)).subtracting(covered) == ["browser_file_upload"])
    }

    @Test func selectChoosesASharedTabByItsListPosition() throws {
        #expect(try step("browser_tabs", ["action": "select", "index": 1]) == .select(other))
        #expect(try step("browser_tabs", ["action": "select", "index": 2]) == .refuse("No shared tab has that index. browser_tabs list shows them in order, from 0."))
        guard case .refuse = try step("browser_tabs", ["action": "select"]) else {
            Issue.record("select without index must be refused")
            return
        }
    }

    @Test func aTimedWaitWaitsFirstAndReturnsAFreshObservation() throws {
        let current: Value = .string(tab.uuidString)
        #expect(try step("browser_wait_for", ["time": 2.5]) == .call("waitForPage", ["tabID": current, "condition": "ready", "value": ""], delay: 2.5))
        #expect(try step("browser_wait_for", ["time": 1, "text": "Done"]) == .call("waitForPage", ["tabID": current, "condition": "text", "value": "Done"], delay: 1))
        let wait = try entry("browser_wait_for")
        #expect((try? wait.validate(["time": 16])) == nil, "at most 15 seconds")
    }

    /// What WSurf does not do is refused before any tool runs: there is nothing for the tool's checks to decide.
    @Test func unsupportedShapesAreRefusedBeforeAnyToolRuns() throws {
        let refusals: [(String, [String: Value])] = [
            ("browser_click", ["ref": "e1", "doubleClick": true]),
            ("browser_click", ["ref": "e1", "button": "right"]),
            ("browser_click", ["ref": "e1", "modifiers": ["Shift"]]),
            ("browser_click", ["ref": "submit"]),
            ("browser_select_option", ["ref": "e1", "values": ["A", "B"]]),
            ("browser_evaluate", ["function": "(el) => el.id", "ref": "e1"]),
            ("browser_wait_for", ["text": "A", "textGone": "B"]),
            ("browser_fill_form", ["fields": [["ref": "name", "value": "Ada"]]]),
            ("browser_tabs", ["action": "new"]),
            ("browser_file_upload", ["paths": ["/etc/hosts"]]),
            ("browser_file_upload", [:]),
        ]
        for (name, arguments) in refusals {
            guard case .refuse = try step(name, arguments) else {
                Issue.record("\(name) \(arguments) must be refused")
                continue
            }
        }
    }

    @Test func withNothingSharedOnlyTheTabFreeCallsGoThrough() throws {
        for mapping in mappings where mapping.call.arguments["tabID"] != nil && mapping.arguments["index"] == nil {
            #expect(try step(mapping.alias, mapping.arguments, shared: false) == .refuse(MCPBrowserSession.noPlaywrightTab), "\(mapping.alias)")
        }
        #expect(try step("browser_tabs", ["action": "list"], shared: false) == .call("listTabs", [:], delay: 0))
        #expect(try step("browser_tabs", ["action": "new", "url": "https://example.com/"], shared: false) == .call("newTab", ["url": "https://example.com/"], delay: 0))
    }

    @Test func playwrightRefsAreTheSnapshotNumbers() {
        #expect(MCPBrowserSession.playwrightRefNumber("12") == 12)
        #expect(MCPBrowserSession.playwrightRefNumber("e12") == 12)
        #expect(MCPBrowserSession.playwrightRefNumber("button") == nil)
        #expect(MCPBrowserSession.playwrightRefNumber("") == nil)
    }

    // MARK: Catalog

    @Test func theAliasesAreListedAfterTheToolsWhoseNamesAndOrderStay() {
        let names = MCPToolCatalog.listed.map(\.name)
        #expect(Set(names).count == names.count, "no alias shadows a tool")
        #expect(Array(names.prefix(MCPToolCatalog.entries.count)) == MCPToolCatalog.entries.map(\.name))
        #expect(MCPToolCatalog.playwrightEntries.count == 19)
        for entry in MCPToolCatalog.playwrightEntries {
            #expect(entry.name.hasPrefix("browser_"), "\(entry.name)")
            #expect(entry.scope == nil, "\(entry.name) decides no access itself")
            #expect(!entry.parameters.contains { ["tabID", "secret", "selector", "observationID"].contains($0.name) }, "\(entry.name) adds no way around the tools' own targeting")
            #expect(entry.tool.inputSchema.objectValue?["additionalProperties"] == false)
        }
    }

    @Test func theReadOnlyHintFollowsTheTool() throws {
        for mapping in mappings {
            let alias = try entry(mapping.alias)
            let tool = try #require(MCPToolCatalog.entries.first { $0.name == mapping.call.tool })
            // browser_tabs list is read only, its other actions are not, so the alias claims nothing.
            if mapping.alias != "browser_tabs" {
                #expect(alias.readOnly == tool.readOnly, "\(mapping.alias)")
            }
        }
    }

    @Test func playwrightArgumentShapesAreChecked() throws {
        let form = try entry("browser_fill_form")
        #expect((try? form.validate(["fields": []])) == nil)
        #expect((try? form.validate(["fields": ["Ada"]])) == nil)
        let resize = try entry("browser_resize")
        #expect((try? resize.validate(["width": 63, "height": 400])) == nil)
        #expect((try? resize.validate(["width": Value.double(.infinity), "height": 400])) == nil)
        let click = try entry("browser_click")
        #expect((try? click.validate(["ref": "1", "button": "back"])) == nil)
        #expect((try? click.validate(["ref": 1])) == nil, "a ref is text, as in Playwright")
        let schema = try entry("browser_fill_form").tool.inputSchema.objectValue?["properties"]?.objectValue?["fields"]?.objectValue
        #expect(schema?["items"]?.objectValue?["required"] == ["ref", "value"])
    }
}
