// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import MCP

/// Playwright MCP tool names as aliases. A call becomes a call of the WSurf tool it names, through `call(name:arguments:)`,
/// so that tool's validation, grant, scope, site setting, Developer tier, dialog rules, secret scrubbing and Agent Activity
/// entry apply exactly as if the client had called it. Nothing here reads a page or decides access.
@MainActor
extension MCPBrowserSession {
    /// What a Playwright call becomes.
    nonisolated enum PlaywrightStep: Equatable {
        /// Call this WSurf tool with these arguments, after waiting `delay` seconds.
        case call(String, [String: Value], delay: Double)
        /// `browser_tabs` select: the following calls act on this shared tab.
        case select(UUID)
        case refuse(String)
    }

    nonisolated static let noPlaywrightTab = "No tab is shared with this connection. Call requestAccess first, then retry."

    func callPlaywright(_ entry: MCPToolCatalog.Entry, arguments: [String: Value]) async throws -> CallTool.Result {
        try entry.validate(arguments)
        // The current tab: the one browser_tabs chose or opened, else the shared tab on screen, else the first shared tab.
        let tabs = browser.tabs.filter { sharedTab($0.id) != nil }
        let current = tabs.first { $0.id == playwrightTab } ?? tabs.first { onScreen($0) } ?? tabs.first
        let dialogID = entry.name == "browser_handle_dialog" ? current?.dialogs.pending(for: id).first?.id : nil
        switch Self.playwrightStep(entry.name, arguments, tabs: tabs.map(\.id), current: current?.id, dialogID: dialogID) {
        case .refuse(let message):
            return failure(message)
        case .select(let tab):
            playwrightTab = tab
            return try await call(name: "listTabs", arguments: [:])
        case .call(let name, let translated, let delay):
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            let held = Set(grants.keys)
            let result = try await call(name: name, arguments: translated)
            // As in Playwright, the tab browser_tabs new opened is the current one from now on.
            if name == "newTab", let opened = Set(grants.keys).subtracting(held).first {
                playwrightTab = opened
            }
            return result
        }
    }

    /// The WSurf call for Playwright tool `name`. `tabs` are the shared tabs in `listTabs` order (what `index` counts),
    /// `current` the tab the call acts on and `dialogID` the dialog open there. The arguments passed the alias entry's checks;
    /// the WSurf tool checks its own again.
    nonisolated static func playwrightStep(
        _ name: String, _ arguments: [String: Value], tabs: [UUID], current: UUID?, dialogID: String?
    ) -> PlaywrightStep {
        if let step = playwrightTabFreeStep(name, arguments, tabs: tabs) {
            return step
        }
        guard let current else { return .refuse(noPlaywrightTab) }
        var translated: [String: Value] = ["tabID": .string(current.uuidString)]
        if let text = arguments["ref"]?.stringValue {
            guard let parsed = playwrightRefNumber(text) else { return .refuse(badPlaywrightRef) }
            translated["ref"] = .int(parsed)
        }
        if let rename = playwrightRenames[name] {
            for (from, to) in rename.arguments {
                translated[to] = arguments[from]
            }
            return .call(rename.tool, translated, delay: 0)
        }
        return playwrightReshapedStep(name, arguments, translated: translated, dialogID: dialogID)
    }

    /// The aliases that only rename their tool and arguments (Playwright name: WSurf name); the tab and `ref` go to all.
    /// `browser_tabs` gets here only for close without index.
    nonisolated static let playwrightRenames: [String: (tool: String, arguments: [String: String])] = [
        "browser_navigate": ("navigate", ["url": "url"]),
        "browser_navigate_back": ("goBack", [:]),
        "browser_type": ("typeOnPage", ["text": "text", "submit": "submit"]),
        "browser_press_key": ("pressKey", ["key": "key"]),
        "browser_hover": ("hoverOnPage", [:]),
        "browser_snapshot": ("readAccessibility", [:]),
        "browser_take_screenshot": ("screenshotPage", ["fullPage": "fullPage"]),
        "browser_network_requests": ("readNetwork", [:]),
        "browser_tabs": ("closeTab", [:]),
        "browser_close": ("closeTab", [:]),
    ]

    /// The calls that need no current tab: the tab list, opening, choosing or closing a tab by index, and the file chooser.
    private nonisolated static func playwrightTabFreeStep(_ name: String, _ arguments: [String: Value], tabs: [UUID]) -> PlaywrightStep? {
        let action = arguments["action"]?.stringValue
        switch (name, action) {
        case ("browser_file_upload", _):
            return .refuse("WSurf never reads files from this Mac for a connection. Ask the user to choose the file in the page.")
        case ("browser_tabs", "list"):
            return .call("listTabs", [:], delay: 0)
        case ("browser_tabs", "new"):
            guard let url = arguments["url"] else {
                return .refuse("browser_tabs new needs url: WSurf opens a new tab at a webpage, behind the user's tab.")
            }
            return .call("newTab", ["url": url], delay: 0)
        case ("browser_tabs", _) where arguments["index"] != nil:
            guard let position = playwrightNumber(arguments["index"]).flatMap({ Int(exactly: $0) }), tabs.indices.contains(position) else {
                return .refuse("No shared tab has that index. browser_tabs list shows them in order, from 0.")
            }
            return action == "select" ? PlaywrightStep.select(tabs[position]) : PlaywrightStep.call("closeTab", ["tabID": .string(tabs[position].uuidString)], delay: 0)
        case ("browser_tabs", "select"):
            return .refuse("browser_tabs select needs index.")
        default:
            return nil
        }
    }

    /// The aliases whose arguments take another shape in their tool, or that refuse what WSurf does not do.
    private nonisolated static func playwrightReshapedStep(
        _ name: String, _ arguments: [String: Value], translated: [String: Value], dialogID: String?
    ) -> PlaywrightStep {
        var translated = translated
        switch name {
        case "browser_click":
            guard arguments["doubleClick"]?.boolValue != true, (arguments["button"]?.stringValue ?? "left") == "left",
                arguments["modifiers"]?.arrayValue?.isEmpty ?? true
            else { return .refuse("WSurf clicks once with the left button and no modifier keys. Nothing was clicked.") }
            return .call("clickOnPage", translated, delay: 0)
        case "browser_fill_form":
            var fields: [Value] = []
            for item in arguments["fields"]?.arrayValue ?? [] {
                guard let field = item.objectValue, let ref = field["ref"]?.stringValue.flatMap(playwrightRefNumber), let value = field["value"] else {
                    return .refuse(badPlaywrightRef)
                }
                // fillFields tells checkboxes, radios and dropdowns apart itself; select only asserts a dropdown.
                fields.append(.object(["ref": .int(ref), "value": value, "select": false]))
            }
            translated["fields"] = .array(fields)
            return .call("fillFields", translated, delay: 0)
        case "browser_select_option":
            guard let values = arguments["values"]?.arrayValue, values.count == 1 else {
                return .refuse("WSurf selects exactly one option. Pass one value.")
            }
            translated["option"] = values[0]
            return .call("selectOption", translated, delay: 0)
        case "browser_evaluate":
            guard translated["ref"] == nil else { return .refuse("WSurf runs the function on the page, not on an element. Pass no ref; nothing ran.") }
            translated["source"] = arguments["function"]
            return .call("evaluateScript", translated, delay: 0)
        case "browser_wait_for":
            let text = arguments["text"]
            let gone = arguments["textGone"]
            guard text == nil || gone == nil else { return .refuse("Pass text or textGone, not both.") }
            translated["condition"] = Value.string(text != nil ? "text" : gone != nil ? "textAbsent" : "ready")
            translated["value"] = text ?? gone ?? ""
            return .call("waitForPage", translated, delay: min(playwrightNumber(arguments["time"]) ?? 0, 15))
        case "browser_console_messages":
            let level = arguments["onlyErrors"]?.boolValue == true ? "error" : arguments["level"]?.stringValue.map { $0 == "warning" ? "warn" : $0 }
            translated["level"] = level.map(Value.string)
            return .call("readConsole", translated, delay: 0)
        case "browser_resize":
            translated["width"] = playwrightNumber(arguments["width"]).map { Value.int(Int($0)) }
            translated["height"] = playwrightNumber(arguments["height"]).map { Value.int(Int($0)) }
            return .call("setViewport", translated, delay: 0)
        case "browser_handle_dialog":
            let accept = arguments["accept"]?.boolValue == true
            translated["dialogID"] = dialogID.map(Value.string)
            translated["action"] = Value.string(accept ? "accept" : "dismiss")
            translated["text"] = accept ? arguments["promptText"] : nil
            return .call("handleDialog", translated, delay: 0)
        default:
            return .refuse("Unknown tool.")
        }
    }

    /// A JSON number, whole or not, when it is finite.
    private nonisolated static func playwrightNumber(_ value: Value?) -> Double? {
        switch value {
        case .int(let number)?:
            Double(number)
        case .double(let number)? where number.isFinite:
            number
        default:
            nil
        }
    }

    nonisolated static let badPlaywrightRef = "Use a ref browser_snapshot showed: the number in brackets, such as 12."

    /// A Playwright ref as text, 12 or e12, as WSurf's number. Out of range numbers are left to the tool's own check.
    nonisolated static func playwrightRefNumber(_ text: String) -> Int? {
        Int(text.hasPrefix("e") ? String(text.dropFirst()) : text)
    }
}
