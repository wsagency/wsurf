// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import MCP

/// Fewer turns: `waitAndRead` on `newTab` and `navigate`, and `runSteps`.
@MainActor
extension MCPBrowserSession {
    /// How long `waitAndRead` waits for the page to commit and load before it answers with the tab alone.
    nonisolated static let waitAndReadTimeout: Duration = .seconds(10)

    // MARK: waitAndRead

    /// `started` (the reply of `newTab` or `navigate`) with the page's first observation added, once the page has loaded. A page
    /// that does not load in time, or cannot be read, still returns its tab: the tab is never lost. The read is a `readPage` of
    /// its own, with every rule that tool has (and the call's secret scrubbing).
    func waitingAndReading(_ started: CallTool.Result, arguments: [String: Value], previousDocument: String? = nil) async -> CallTool.Result {
        guard arguments["waitAndRead"]?.boolValue ?? true, started.isError != true else { return started }
        let opened = started.structuredContent?.objectValue
        // An agent-opened tab or a navigation in place reports no tabID of its own: the tab is the one navigated.
        let tabText = opened?["tabID"]?.stringValue ?? Self.openedTabID(in: started) ?? arguments["tabID"]?.stringValue
        guard let id = tabText.flatMap(UUID.init(uuidString:)), grants[id] != nil,
            let tab = browser.tabs.first(where: { $0.id == id })
        else { return started }
        var fields = opened ?? [:]
        fields["tabID"] = .string(id.uuidString)
        if fields["message"] == nil {
            fields["message"] = .string(Self.text(of: started))
        }
        let previous = opened?["openedNewTab"]?.boolValue == true ? nil : previousDocument
        guard await loaded(tab, after: previous) else {
            fields["status"] = "loading"
            fields["message"] = .string((fields["message"]?.stringValue ?? "") + " The page is still loading; call readPage when it is ready.")
            return reply(fields)
        }
        if let open = dialogRefusal(for: tab) {
            fields["status"] = "dialogPending"
            fields["page"] = open.structuredContent ?? .string(Self.text(of: open))
            return reply(fields)
        }
        guard sharedTab(id) === tab, let entry = MCPToolCatalog.entries.first(where: { $0.name == "readPage" }) else {
            fields["status"] = "opened"
            return reply(fields)
        }
        let read = await usePage(entry, arguments: ["tabID": .string(id.uuidString)], tab: tab, capability: .read)
        guard read.isError != true, let page = read.structuredContent?.objectValue else {
            fields["status"] = "opened"
            fields["readError"] = .string(Self.text(of: read))
            return reply(fields)
        }
        fields["status"] = "ready"
        for key in ["content", "observationID", "vaultHint", "url"] where page[key] != nil {
            fields[key] = page[key]
        }
        return reply(fields)
    }

    /// Whether `tab`'s page committed a document other than `previous` and finished loading within `waitAndReadTimeout`.
    private func loaded(_ tab: BrowserTab, after previous: String?) async -> Bool {
        let deadline = ContinuousClock.now + Self.waitAndReadTimeout
        // The page loads once it exists, as a call that uses it would make it (`usePage`), also with no window to keep it in.
        tab.realizeDeferredSession()
        _ = tab.page
        while ContinuousClock.now < deadline, !Task.isCancelled, isConnected {
            // A dialog (a beforeunload question) blocks the page: the caller reports it instead of waiting it out.
            if tab.dialogs.hasOpenDialog {
                return true
            }
            let view = tab.page
            if let document = view.mainDocumentID, document != previous, !view.isLoading, view.url != nil {
                return true
            }
            // ponytail: polls every 50 ms; a commit observer would answer sooner.
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func openedTabID(in result: CallTool.Result) -> String? {
        let text = Self.text(of: result)
        guard let range = text.range(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    nonisolated static func text(of result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private func reply(_ fields: [String: Value], isError: Bool = false) -> CallTool.Result {
        let value: Value = .object(fields)
        return CallTool.Result(content: [.text(text: encoded(value), annotations: nil, _meta: nil)], structuredContent: Optional.some(value), isError: isError)
    }

    // MARK: runSteps

    /// Runs each step as its own tool call on `tab`, through `execute`, so every rule of that tool applies. Stops at the first
    /// step that fails, and before the next one when the tab opened a dialog, left its website, or is no longer this
    /// connection's to drive.
    func runSteps(_ arguments: [String: Value], tab: BrowserTab) async -> CallTool.Result {
        let steps = arguments["steps"]?.arrayValue ?? []
        guard (1...MCPToolCatalog.maximumSteps).contains(steps.count) else {
            return failure("Give one to \(MCPToolCatalog.maximumSteps) steps.")
        }
        let origin = webURL(of: tab).map(SitePermissions.origin(for:))
        var summaries: [Value] = []
        var last: CallTool.Result?
        func finish(failedAt index: Int?, _ error: String?) -> CallTool.Result {
            var fields: [String: Value] = [
                "tabID": .string(tab.id.uuidString), "completedSteps": .int(index ?? steps.count), "steps": .array(summaries),
            ]
            if let index {
                fields["failedStepIndex"] = .int(index)
            }
            if let error {
                fields["error"] = .string(error)
            }
            if let last {
                fields["result"] = last.structuredContent ?? .string(Self.text(of: last))
                if let observation = last.structuredContent?.objectValue?["observationID"] {
                    fields["observationID"] = observation
                }
            }
            return reply(fields, isError: index != nil)
        }
        for (index, item) in steps.enumerated() {
            guard case .object(let step) = item, let name = step["tool"]?.stringValue, let tool = MCPToolCatalog.stepTools[name],
                let entry = MCPToolCatalog.entries.first(where: { $0.name == tool })
            else { return finish(failedAt: index, "Unknown step. Use \(MCPToolCatalog.stepTools.keys.sorted().joined(separator: ", ")).") }
            var stepArguments = step["arguments"]?.objectValue ?? [:]
            guard stepArguments["tabID"] == nil else { return finish(failedAt: index, "Steps act on the runSteps tab. Leave tabID out of a step.") }
            stepArguments["tabID"] = .string(tab.id.uuidString)
            do {
                try entry.validate(stepArguments)
            } catch {
                return finish(failedAt: index, "Step \(index) (\(name)) has invalid arguments: \(error.localizedDescription)")
            }
            if let stop = stepInterruption(tab, origin: origin) {
                return finish(failedAt: index, stop)
            }
            let result = await execute(entry, arguments: stepArguments)
            last = result
            let text = Self.text(of: result)
            summaries.append(
                .object([
                    "index": .int(index), "tool": .string(tool), "status": .string(result.isError == true ? "failed" : "ok"),
                    "summary": .string(PageOutputBudget.prefix(Self.stepSummary(result) ?? text, fitting: 300)),
                ]))
            if result.isError == true {
                return finish(failedAt: index, PageOutputBudget.prefix(Self.stepSummary(result) ?? text, fitting: 600))
            }
            // A step that opened a dialog reports success with dialogOpened: the page is blocked until it is answered.
            if result.structuredContent?.objectValue?["status"]?.stringValue == "dialogOpened" || tab.dialogs.hasOpenDialog {
                return finish(failedAt: index + 1 < steps.count ? index + 1 : nil, "A dialog opened. Answer it with handleDialog before going on.")
            }
            if index + 1 < steps.count, let stop = stepInterruption(tab, origin: origin) {
                return finish(failedAt: index + 1, stop)
            }
        }
        return finish(failedAt: nil, nil)
    }

    /// Why the next step must not run, or nil.
    private func stepInterruption(_ tab: BrowserTab, origin: String?) -> String? {
        guard isConnected, !Task.isCancelled else { return "The call was cancelled or the connection ended." }
        guard grants[tab.id] != nil, !takenBack.contains(tab.id), sharedTab(tab.id) === tab else {
            return "The user took over this tab, or access to it ended."
        }
        if let scope = agentWindowScope, !scope.isAgentOwned() {
            return "humanControl: This Agent Micro Window is under human control."
        }
        if tab.dialogs.hasOpenDialog {
            return "A dialog is open. Answer it with handleDialog before going on."
        }
        if let origin, webURL(of: tab).map(SitePermissions.origin(for:)) != origin {
            return "The page left its website. Read the new page before acting on it."
        }
        return nil
    }

    /// The status line of a step's reply: the delta's own status and action, without the page text.
    private static func stepSummary(_ result: CallTool.Result) -> String? {
        guard let object = result.structuredContent?.objectValue else { return nil }
        let content = object["content"]?.stringValue.map { $0.split(separator: "\n").prefix(3).joined(separator: " ") }
        return [object["action"]?.stringValue, object["status"]?.stringValue, content].compactMap { $0 }.joined(separator: ": ")
    }
}
