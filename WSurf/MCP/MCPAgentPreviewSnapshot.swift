// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP

/// The host bridge's fixed read-only snapshot. A human-owned tab never grants automation access.
@MainActor
extension MCPAgentWindowRegistry {
    func previewSnapshot(
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession,
        owner: AgentWindowOwner
    ) async throws -> [String: Any] {
        session.syncAgentWindowGeneration()
        if tab.mcpSecretWriteEpoch == tab.documentCommitEpoch, session.secrets.isEmpty {
            throw Self.protectedSnapshotError
        }
        func checkSite(_ url: URL) throws {
            tab.assistantAccess.pageChanged(url: url)
            let policy = tab.assistantAccess.explicitPolicy ?? coordinator.browser.sitePermissions.assistantRecord(for: SitePermissions.origin(for: url))
            if policy == .deny {
                throw MCPAgentWindowError(.forbidden, "Assistant access is off for this website.")
            }
            if policy == .ask {
                throw MCPAgentWindowError(.denied, "This website explicitly requires asking before assistant access.")
            }
        }
        if let url = Self.activeWebURL(of: tab) {
            try checkSite(url)
        }
        if owner == .agent {
            session.keepInWindow(tab)
            session.syncAgentWindowGrants()
        }
        let readGuard: PageAutomationGuard?
        let documentID: String?
        if owner == .human {
            guard let view = tab.liveView, let url = session.webURL(of: tab),
                  let generation = coordinator.browser.agentCompanion?.generation
            else {
                throw MCPAgentWindowError(.actionFailed, "The page is not ready. Try again.")
            }
            let pageGeneration = tab.pageGeneration
            let epoch = tab.documentCommitEpoch
            let origin = SitePermissions.origin(for: url)
            let guardScope = PageAutomationGuard(documentURL: url.absoluteString, snapshot: nil) { [weak self, weak record] in
                guard let self, let record, self.isActiveRecord(record),
                      session.agentWindowAccess(record.access.mcpAccess, at: url) != nil,
                      session.isConnected, session.available(), !Task.isCancelled,
                      coordinator.browser.agentCompanion?.owner == .human,
                      coordinator.browser.agentCompanion?.generation == generation,
                      !tab.isPrivate, tab.isLive(view, generation: pageGeneration),
                      tab.documentCommitEpoch == epoch, session.webURL(of: tab) == url
                else { return false }
                let policy = coordinator.browser.sitePermissions.assistantRecord(for: origin)
                let tabPolicy = tab.assistantAccess.explicitPolicy
                return policy != .deny && policy != .ask && tabPolicy != .deny && tabPolicy != .ask
            }
            documentID = try await protectedSnapshotCheck(tab: tab, view: view, guardScope: guardScope)
            readGuard = guardScope
        } else {
            if tab.isMCPCredentialTainted {
                throw Self.protectedSnapshotError
            }
            readGuard = nil
            documentID = nil
        }
        var readArgs: [String: Value] = ["tabID": .string(tab.id.uuidString)]
        if let scope = opParams["scope"] as? String, !scope.isEmpty {
            readArgs["scope"] = .string(scope)
        }
        let pageResult = try await snapshotRead("readPage", arguments: readArgs, tab: tab, session: session, guardScope: readGuard)
        if pageResult.isError == true {
            throw MCPAgentWindowError(.actionFailed, Self.extractText(from: pageResult))
        }
        var a11yArgs: [String: Value] = ["tabID": .string(tab.id.uuidString)]
        if let offset = opParams["offset"] as? Int {
            a11yArgs["offset"] = .int(offset)
        }
        if let scope = opParams["scope"] as? String, !scope.isEmpty {
            a11yArgs["scope"] = .string(scope)
        }
        let a11yResult = try await snapshotRead("readAccessibility", arguments: a11yArgs, tab: tab, session: session, guardScope: readGuard)
        let viewportSize = tab.liveView?.bounds.size ?? coordinator.nativeWindow?.contentLayoutRect.size ?? MicroWindowMetrics.defaultSize
        let pageObject = pageResult.structuredContent?.objectValue ?? [:]
        var response: [String: Any] = [
            "tabId": tab.id.uuidString,
            "engine": effectiveEngine(of: tab).rawValue,
            "owner": (coordinator.browser.agentCompanion?.owner ?? .agent).rawValue,
            "generation": coordinator.browser.agentCompanion?.generation ?? 1,
            "page": pageObject["content"]?.stringValue ?? Self.extractText(from: pageResult),
            "accessibilityTree": a11yResult.structuredContent?.objectValue?["content"]?.stringValue ?? Self.extractText(from: a11yResult),
            "viewport": [
                "width": Int(viewportSize.width.rounded()),
                "height": Int(viewportSize.height.rounded()),
            ],
        ]
        if opParams["includeImage"] as? Bool == true, session.secrets.isEmpty {
            var shotArgs: [String: Value] = ["tabID": .string(tab.id.uuidString)]
            if let maxWidth = opParams["maxWidth"] as? Int {
                shotArgs["maxWidth"] = .int(maxWidth)
            }
            let shotResult = try await snapshotRead("screenshotPage", arguments: shotArgs, tab: tab, session: session, guardScope: readGuard)
            if shotResult.isError != true {
                for block in shotResult.content {
                    if case .image(let data, let mimeType, _, _) = block {
                        response["imageBase64"] = data
                        response["imageMimeType"] = mimeType
                        break
                    }
                }
            }
        }
        if let readGuard {
            guard let view = tab.liveView,
                  try await protectedSnapshotCheck(tab: tab, view: view, guardScope: readGuard) == documentID
            else {
                throw MCPAgentWindowError(.actionFailed, "The page changed before the snapshot could be returned.")
            }
        }
        response["observationId"] = session.observations[tab.id]?.id
        try protectSnapshotReply(&response, tab: tab, record: record, session: session)
        return response
    }

    private func protectSnapshotReply(
        _ response: inout [String: Any], tab: BrowserTab, record: Record, session: MCPBrowserSession
    ) throws {
        guard !tab.isMCPCredentialTainted else { throw Self.protectedSnapshotError }
        if !session.secrets.isEmpty {
            response["imageBase64"] = nil
            response["imageMimeType"] = nil
        } else if tab.mcpSecretWriteEpoch == tab.documentCommitEpoch {
            throw Self.protectedSnapshotError
        }
        response["url"] = previewMetadata(tab.urlString, tab: tab, record: record)
        response["title"] = previewMetadata(tab.title, tab: tab, record: record)
        for key in ["page", "accessibilityTree"] {
            if let text = response[key] as? String {
                response[key] = session.scrubbed(text)
            }
        }
    }

    private static let protectedSnapshotError = MCPAgentWindowError(
        .protectedSecretPresent, "The snapshot is blocked while a protected password or sensitive field is present on this document.")

    private func protectedSnapshotCheck(tab: BrowserTab, view: BrowserPage, guardScope: PageAutomationGuard) async throws -> String {
        guard guardScope.validate() else {
            throw MCPAgentWindowError(.denied, "Page access changed before the snapshot could be returned.")
        }
        guard !tab.isMCPCredentialTainted else { throw Self.protectedSnapshotError }
        let state = await PageAutomationGuard.$current.withValue(guardScope) {
            await PageDriver.protectedSecretState(in: view)
        }
        guard guardScope.validate() else {
            throw MCPAgentWindowError(.denied, "Page access changed before the snapshot could be returned.")
        }
        guard !tab.isMCPCredentialTainted, let state, !state.hasFilledSensitive else { throw Self.protectedSnapshotError }
        return state.documentID
    }

    private func snapshotRead(
        _ name: String, arguments: [String: Value], tab: BrowserTab, session: MCPBrowserSession, guardScope: PageAutomationGuard?
    ) async throws -> CallTool.Result {
        guard let guardScope else { return try await session.call(name: name, arguments: arguments) }
        guard let entry = MCPToolCatalog.entries.first(where: { $0.name == name && $0.scope == .read }) else {
            throw MCPAgentWindowError(.internalError, "Snapshot read tool unavailable.")
        }
        try entry.validate(arguments)
        let result = await PageDriver.$refusesFilledSecrets.withValue(true) {
            await session.usePage(entry, arguments: arguments, tab: tab, capability: .read, previewRead: guardScope)
        }
        if result.structuredContent?.objectValue?["code"]?.stringValue == MCPFailureCode.protectedSecretPresent.rawValue {
            throw Self.protectedSnapshotError
        }
        return session.finished(result)
    }
}
