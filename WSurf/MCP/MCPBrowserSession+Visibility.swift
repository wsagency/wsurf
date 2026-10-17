// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP

/// What the window shows about a connection (the badge and its popover) and what the connection writes to Agent Activity.
@MainActor
extension MCPBrowserSession {
    /// The tab, target and note one call is logged with. Taken before the call runs: a call can close its tab.
    struct LogSubject {
        let tab: BrowserTab?
        let target: String?
        let detail: String?
    }

    /// The name the user knows the client by. `MCPAccessConsent` shows the same name in its sheets.
    var displayName: String {
        clientName == "codex-mcp-client" ? "Codex" : clientName
    }

    /// The tabs of this window the connection holds a grant for, in tab order.
    var sharedTabs: [BrowserTab] {
        browser.tabs.filter { grants[$0.id] != nil }
    }

    /// Whether the connection can still act in its window: it holds a grant for a tab or a development lease. The badge
    /// is shown for exactly this, so a lease never runs without it.
    var isControlling: Bool {
        isConnected && (!sharedTabs.isEmpty || !developmentTabs.isEmpty)
    }

    /// Whether a call is working on one of the connection's tabs right now.
    var isWorking: Bool {
        sharedTabs.contains { $0.processState.isExternalAutomationWorking }
    }

    /// The widest access the connection holds in this window.
    var tier: MCPAccessConsent.Access? {
        grants.values.map(\.access).max { $0.rank < $1.rank }
    }

    func logSubject(for tool: String, arguments: [String: Value]) -> LogSubject {
        let tab = (arguments["tabID"] ?? arguments["tabA"])?.stringValue.flatMap(UUID.init(uuidString:)).flatMap { id in
            browser.tabs.first { $0.id == id }
        }
        // The host says where the connection went; the path and query can carry data and are not kept.
        let host = ["navigate", "newTab", "openComparison"].contains(tool) ? arguments["url"]?.stringValue.flatMap { URL(string: $0)?.host() } : nil
        return LogSubject(tab: tab, target: arguments["ref"]?.intValue.map { String(localized: "element \($0)") }, detail: host)
    }

    func logCall(_ tool: String, subject: LogSubject, result: CallTool.Result, since start: ContinuousClock.Instant) {
        let outcome: ExternalActivityLog.Entry.Outcome =
            Task.isCancelled || !isConnected ? .stopped : result.isError == true ? .failed : .succeeded
        activity.client = displayName
        activity.record(
            tool: tool, tab: subject.tab, target: subject.target, outcome: outcome, detail: subject.detail,
            milliseconds: Int((ContinuousClock.now - start) / .milliseconds(1)), bytes: ExternalActivityLog.bytes(of: result),
            scrub: scrubbedForAudit)
    }

    func recordStop() {
        activity.client = displayName
        activity.recordStop()
    }
}

extension MCPAccessConsent.Access {
    /// Exhaustive on purpose: a new access level must be named here. `rank` is in MCPDeveloperAccess.swift.
    var tierTitle: LocalizedStringResource {
        switch self {
        case .readOnly:
            "Read only"
        case .control:
            "Control"
        case .development:
            "Development"
        case .developer:
            "Developer"
        }
    }
}
