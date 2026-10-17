// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP
import Observation
import WebKit

@MainActor
@Observable
final class MCPBrowserSession: Identifiable {
    struct Grant {
        let origin: String
        let access: MCPAccessConsent.Access
    }

    struct PageObservation {
        let id: String
        let snapshot: String
        let documentURL: String
    }

    /// What a tool needs from the connection's grant and the site's Assistant Access setting.
    nonisolated enum Scope {
        case read, control
        /// Control plus DOM inspection, diagnostics, and viewport/device emulation.
        case development
    }

    let id = UUID()
    var clientName = String(localized: "External Connection")
    /// The user-paired client behind this connection, set by the server once its hello is verified. An unpaired
    /// connection is nil and keeps asking for consent.
    var pairedClient: PairedClient?
    private(set) var isConnected = true
    private(set) var lastTool = ""
    private(set) var completedCalls = 0
    var grants: [UUID: Grant] = [:]
    @ObservationIgnored let browser: BrowserModel
    @ObservationIgnored let available: () -> Bool
    @ObservationIgnored let consent: (String, [MCPAccessConsent.Page], Bool) async -> MCPAccessConsent.Access?
    @ObservationIgnored let openConsent: (String, URL) async -> Bool
    @ObservationIgnored private let actionPolicy = AgentActionPolicy(storage: MCPActionGrantStorage())
    @ObservationIgnored private let consentWindow: ExtensionWindowAdapter?
    @ObservationIgnored var observations: [UUID: PageObservation] = [:]
    @ObservationIgnored var feedback = MCPActionFeedbackState()
    /// Cleanup index only: the tab owns the lease, this lets disconnect find the tabs this connection holds.
    @ObservationIgnored var developmentTabs: [UUID: (tab: BrowserTab, owner: DevelopmentOwner)] = [:]
    @ObservationIgnored var destinations: Set<String> = []
    @ObservationIgnored var hasReadContent = false
    @ObservationIgnored var accessWasRequested = false
    @ObservationIgnored private var busy = false
    /// Every call this connection ran, for Agent Activity. Never holds arguments or results.
    @ObservationIgnored let activity = ExternalActivityLog()

    var lastActionTitle: String? {
        lastTool.isEmpty ? nil : Self.actionTitle(forTool: lastTool)
    }

    /// The assistant's own name for a tool it shares with MCP, else the catalog entry's title.
    static func actionTitle(forTool name: String) -> String? {
        if let descriptor = AgentToolCatalog.all.first(where: { $0.id == name }) {
            return String(localized: descriptor.title)
        }
        return MCPToolCatalog.entries.first { $0.name == name }?.title.map { String(localized: $0) }
    }

    init(
        browser: BrowserModel,
        available: @escaping () -> Bool,
        consent: @escaping (String, [MCPAccessConsent.Page], Bool) async -> MCPAccessConsent.Access? = { client, pages, development in
            await MCPAccessConsent.share(client: client, pages: pages, development: development, in: nil)
        },
        openConsent: @escaping (String, URL) async -> Bool = { client, url in
            await MCPAccessConsent.open(client: client, url: url, in: nil)
        }
    ) {
        self.browser = browser
        self.available = available
        self.consent = consent
        self.openConsent = openConsent
        consentWindow = browser.context.extensions.adapter(for: browser)
    }
    func isBound(to browser: BrowserModel) -> Bool {
        self.browser === browser
    }

    func revoke() {
        isConnected = false
        pairedClient = nil
        for (tab, owner) in Array(developmentTabs.values) {
            tab.releaseDevelopment(owner, reason: .disconnect)
        }
        developmentTabs = [:]
        grants = [:]
        observations = [:]
        destinations = []
        actionPolicy.revokeAll()
    }

    func call(name: String, arguments: [String: Value]) async throws -> CallTool.Result {
        guard let entry = MCPToolCatalog.entries.first(where: { $0.name == name }) else {
            throw MCPError.invalidParams("Unknown tool.")
        }
        try entry.validate(arguments)
        guard isConnected, available(), !Task.isCancelled else {
            return failure("Connection is unavailable. Reconnect after leaving private browsing or after the assistant finishes.")
        }
        guard !busy else { return failure("Another operation is running. Wait for its result.") }
        busy = true
        lastTool = name
        defer {
            busy = false
            completedCalls += 1
        }
        let started = ContinuousClock.now
        let subject = logSubject(for: name, arguments: arguments)
        let result = await AgentActionConsent.$scopedPolicy.withValue(actionPolicy) {
            await AgentActionConsent.$externalClientName.withValue(clientName) {
                await AgentActionConsent.$scopedWindow.withValue(consentWindow) {
                    await execute(entry, arguments: arguments)
                }
            }
        }
        logCall(name, subject: subject, result: result, since: started)
        return result
    }

    private func execute(_ entry: MCPToolCatalog.Entry, arguments: [String: Value]) async -> CallTool.Result {
        releaseUnauthorizedDevelopment()
        let name = entry.name
        switch name {
        case "requestAccess":
            return await requestAccess(development: arguments["development"]?.boolValue ?? false)
        case "listTabs":
            return tabList()
        case "newTab":
            return await openNewTab(arguments["url"]?.stringValue ?? "")
        default:
            break
        }
        guard let id = arguments["tabID"]?.stringValue.flatMap(UUID.init(uuidString:)),
            let tab = sharedTab(id), let grant = grants[id]
        else { return failure("This tab is not shared with this connection.") }
        guard let capability = entry.scope else { return failure("This tool does not act on a tab.") }
        guard mayProceed(tab, capability: capability) else {
            return failure("This action is blocked by the connection’s access or the website’s Assistant Access setting.")
        }
        if name == "switchTab" { return switchTab(tab) }
        if name == "closeTab" { return closeTab(tab) }
        if capability == .control, !onScreen(tab) {
            return failure("Use switchTab before controlling this shared tab.")
        }
        if name == "navigate" {
            return await navigate(arguments["url"]?.stringValue ?? "", tab: tab, grant: grant)
        }
        if name == "goBack", let refusal = goBackRefusal(tab, grant: grant) { return refusal }
        if Self.developmentCalls.contains(name) {
            return await developmentCall(name: name, arguments: arguments, tab: tab)
        }
        return await usePage(entry, arguments: arguments, tab: tab, capability: capability)
    }

    /// Whether this connection's grant and the site's policy allow `capability` now. Persistent: never depends on the calling task.
    func permits(_ tab: BrowserTab, capability: Scope) -> Bool {
        guard sharedTab(tab.id) === tab, let grant = grants[tab.id] else { return false }
        let writable = tab.assistantAccess.effectivePolicy != .readOnly
        switch capability {
        case .read:
            return true
        case .control:
            return (grant.access == .control || grant.access == .development) && writable
        case .development:
            return grant.access == .development && writable
        }
    }

    /// `permits` for the request this task is running: also false once the request itself was cancelled, so a cancelled
    /// request neither continues nor returns contents. Use at request entry and after each await of that request, never to
    /// decide the fate of a lease.
    func mayProceed(_ tab: BrowserTab, capability: Scope) -> Bool {
        !Task.isCancelled && permits(tab, capability: capability)
    }

    func webURL(of tab: BrowserTab) -> URL? {
        guard !tab.isShowingSystemPage else { return nil }
        let url = tab.isMaterialised ? tab.page.url : URL(string: tab.urlString)
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func onScreen(_ tab: BrowserTab) -> Bool {
        browser.activeTabID == tab.id || browser.splitPanes?.contains(where: { $0 === tab }) == true
    }

    func encoded(_ value: Value) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The image share of a reply. Its base64 form is 200,000 bytes, which leaves about 60 KB of the transport line for
    /// the text block, the structured copy of it and the JSON-RPC envelope.
    nonisolated static let screenshotBytes = 150_000

    /// Size of the reply line as `MCP.Server` writes it: sorted keys, unescaped slashes, plus 256 bytes for the JSON-RPC
    /// envelope. The relay issues every backend request with the SDK's `ID.random` (a 36-byte UUID string), which the
    /// envelope (`jsonrpc`, `id`, `result`) fits in with room to spare. A client that connects to the socket directly and
    /// picks a very long request id can push its own reply over the line limit; only that client loses the reply.
    nonisolated static func replyBytes(_ result: CallTool.Result) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(result) else { return .max }
        return body.count + 256
    }

    func success(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    func failure(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
    }
}
