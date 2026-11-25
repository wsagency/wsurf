// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP

/// Executes `invokePreview` bridge operations against an Agent Micro Window's tabs using WSurf's native
/// `MCPBrowserSession`, `PageDriver`, `PageScripting`, and `BrowserTab` engine APIs.
@MainActor
extension MCPAgentWindowRegistry {
    func invokePreview(
        pairedClientId: UUID,
        hostName: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        guard let rawThreadId = params["threadId"] as? String else {
            throw MCPAgentWindowError(.invalidParams, "threadId is required.")
        }
        let threadId = MCPAgentBridgeProtocol.cleanText(rawThreadId, maxLength: 128)
        guard !threadId.isEmpty else {
            throw MCPAgentWindowError(.invalidParams, "threadId cannot be empty.")
        }
        guard let operation = params["operation"] as? String, !operation.isEmpty else {
            throw MCPAgentWindowError(.invalidParams, "operation is required.")
        }
        let opParams = params["params"] as? [String: Any] ?? [:]
        let expectedGeneration = params["expectedGeneration"] as? Int
        let requestedTabId: UUID?
        if let rawTabId = params["tabId"] as? String, !rawTabId.isEmpty {
            guard let parsed = UUID(uuidString: rawTabId) else {
                throw MCPAgentWindowError(.invalidParams, "tabId must be a valid UUID.")
            }
            requestedTabId = parsed
        } else {
            requestedTabId = nil
        }

        if operation == "open" {
            return try await handlePreviewOpen(
                pairedClientId: pairedClientId,
                hostName: hostName,
                threadId: threadId,
                tabId: requestedTabId,
                expectedGeneration: expectedGeneration,
                opParams: opParams
            )
        }

        let (record, coordinator, tab) = try resolvePreviewTarget(
            pairedClientId: pairedClientId,
            threadId: threadId,
            tabId: requestedTabId,
            operation: operation,
            expectedGeneration: expectedGeneration
        )
        if operation == "status" {
            return previewStatus(record: record, coordinator: coordinator, tab: tab)
        }
        guard let session = ensurePreviewSession(for: record) else {
            throw MCPAgentWindowError(.internalError, "Could not bind preview session.")
        }
        session.syncAgentWindowGrants()

        let generation = coordinator.browser.agentCompanion?.generation ?? 1
        return try await runCancellablePreview(in: record, coordinator: coordinator, expectedGeneration: generation) {
            try await self.dispatchPreviewOperation(
                operation: operation,
                opParams: opParams,
                record: record,
                coordinator: coordinator,
                tab: tab,
                session: session,
                startGeneration: generation
            )
        }
    }

    /// Refuses mutating or scripting operations when the tab's current website is marked Read Only, Ask, or Off (`deny`).
    func ensureSiteWritable(tab: BrowserTab, browser: BrowserModel) throws {
        guard let url = Self.activeWebURL(of: tab) else { return }
        tab.assistantAccess.pageChanged(url: url)
        let origin = SitePermissions.origin(for: url)
        let policy = tab.assistantAccess.explicitPolicy ?? browser.sitePermissions.assistantRecord(for: origin)
        if policy == .deny {
            throw MCPAgentWindowError(.forbidden, "Assistant access is off for this website.")
        }
        if policy == .ask {
            throw MCPAgentWindowError(.denied, "This website explicitly requires asking before assistant control.")
        }
        if policy == .readOnly {
            throw MCPAgentWindowError(.forbidden, "This website is set to Read Only for assistant access.")
        }
    }

    private static func activeWebURL(of tab: BrowserTab) -> URL? {
        for candidate in [tab.liveView?.url, URL(string: tab.urlString)].compactMap({ $0 }) {
            if let scheme = candidate.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Target Resolution & Ownership Validation

    private func handlePreviewOpen(
        pairedClientId: UUID,
        hostName: String,
        threadId: String,
        tabId: UUID?,
        expectedGeneration: Int?,
        opParams: [String: Any]
    ) async throws -> [String: Any] {
        if let tabId, let (existingRecord, _, _) = findTab(pairedClientId: pairedClientId, tabId: tabId),
           existingRecord.threadId != threadId {
            throw MCPAgentWindowError(.agentMismatch, "Tab belongs to another thread.")
        }
        if let existing = record(pairedClientId: pairedClientId, threadId: threadId),
           let companion = existing.coordinator?.browser.agentCompanion {
            if companion.owner != .agent {
                if companion.owner == .human {
                    throw MCPAgentWindowError(.humanControl, "Window is under human control.")
                }
                throw MCPAgentWindowError(.denied, "Window is unclaimed and not owned by the agent.")
            }
            if let expectedGeneration, companion.generation != expectedGeneration {
                throw MCPAgentWindowError(.staleGeneration, "Window generation \(companion.generation) does not match expected \(expectedGeneration).")
            }
        }
        var openParams = opParams
        openParams["threadId"] = threadId
        return try await openAgentWindow(
            pairedClientId: pairedClientId,
            hostName: hostName,
            params: openParams
        )
    }

    private func resolvePreviewTarget(
        pairedClientId: UUID,
        threadId: String,
        tabId: UUID?,
        operation: String,
        expectedGeneration: Int?
    ) throws -> (Record, AppCoordinator, BrowserTab) {
        let resolved: (Record, AppCoordinator, BrowserTab)
        if let tabId {
            guard let found = findTab(pairedClientId: pairedClientId, tabId: tabId) else {
                throw MCPAgentWindowError(.notFound, "Tab not found.")
            }
            guard found.0.threadId == threadId else {
                throw MCPAgentWindowError(.agentMismatch, "Tab belongs to another thread.")
            }
            resolved = found
        } else {
            guard let record = record(pairedClientId: pairedClientId, threadId: threadId),
                  let coordinator = record.coordinator,
                  !coordinator.isClosed,
                  let tab = coordinator.browser.activeTab ?? coordinator.browser.tabs.first(where: { !$0.isClosed })
            else {
                throw MCPAgentWindowError(.notFound, "No active Agent Micro Window for thread.")
            }
            resolved = (record, coordinator, tab)
        }
        guard let companion = resolved.1.browser.agentCompanion else {
            throw MCPAgentWindowError(.notFound, "Agent session is no longer active.")
        }
        if operation != "status", companion.owner != .agent {
            if companion.owner == .human {
                throw MCPAgentWindowError(.humanControl, "Tab is under human control.")
            }
            throw MCPAgentWindowError(.denied, "Tab is unclaimed and not owned by the agent.")
        }
        if let expectedGeneration, companion.generation != expectedGeneration {
            throw MCPAgentWindowError(.staleGeneration, "Tab generation \(companion.generation) does not match expected \(expectedGeneration).")
        }
        return resolved
    }

    private struct PreviewPayloadBox: @unchecked Sendable {
        let value: [String: Any]
    }

    private func runCancellablePreview(
        in record: Record,
        coordinator: AppCoordinator,
        expectedGeneration: Int,
        body: @escaping @MainActor () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        let workToken = beginWorking(for: record)
        defer { endWorking(workToken, for: record) }

        let task = Task<Result<PreviewPayloadBox, any Error>, Never> { @MainActor in
            do {
                return .success(PreviewPayloadBox(value: try await body()))
            } catch {
                return .failure(error)
            }
        }
        let cancelWrapper = Task<Void, Never> {
            await withTaskCancellationHandler {
                _ = await task.value
            } onCancel: {
                task.cancel()
            }
        }
        let opId = registerOperation(cancelWrapper, in: record)
        defer { unregisterOperation(opId, in: record) }

        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            cancelWrapper.cancel()
        }
        if Task.isCancelled {
            if coordinator.browser.agentCompanion?.owner == .human {
                throw MCPAgentWindowError(.humanControl, "Operation interrupted by human Take Over.")
            }
            throw MCPAgentWindowError(.cancelled, "Operation was cancelled.")
        }
        if let companion = coordinator.browser.agentCompanion,
           companion.owner != .agent {
            if companion.owner == .human {
                throw MCPAgentWindowError(.humanControl, "Operation interrupted by human Take Over.")
            }
            throw MCPAgentWindowError(.denied, "Window ownership changed to unclaimed while running.")
        }
        if let companion = coordinator.browser.agentCompanion,
           companion.generation != expectedGeneration {
            throw MCPAgentWindowError(.staleGeneration, "Window ownership generation changed while running.")
        }
        switch outcome {
        case .success(let box):
            return box.value
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Operation Dispatch

    private func dispatchPreviewOperation(
        operation: String,
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession,
        startGeneration: Int
    ) async throws -> [String: Any] {
        switch operation {
        case "navigate":
            return try await previewNavigate(opParams: opParams, record: record, coordinator: coordinator, tab: tab, session: session)
        case "snapshot":
            return try await previewSnapshot(opParams: opParams, record: record, coordinator: coordinator, tab: tab, session: session)
        case "act":
            return try await previewAct(opParams: opParams, coordinator: coordinator, tab: tab, session: session)
        case "evaluate":
            return try await previewEvaluate(
                opParams: opParams,
                record: record,
                coordinator: coordinator,
                tab: tab,
                session: session,
                startGeneration: startGeneration
            )
        case "wait_for":
            return try await previewWaitFor(opParams: opParams, coordinator: coordinator, tab: tab, session: session)
        case "resize":
            return try await previewResize(opParams: opParams, record: record, coordinator: coordinator, tab: tab, session: session)
        case "set_appearance":
            return try await previewSetAppearance(opParams: opParams, record: record, coordinator: coordinator, tab: tab, session: session)
        case "dialog":
            return try await previewDialog(opParams: opParams, coordinator: coordinator, tab: tab, session: session)
        case "set_engine":
            return try await previewSetEngine(opParams: opParams, record: record, coordinator: coordinator, tab: tab, session: session)
        case "close":
            return try previewClose(record: record, coordinator: coordinator, tab: tab)
        default:
            throw MCPAgentWindowError(.unknownOperation, "Unsupported preview operation: \(operation).")
        }
    }

    // MARK: - Individual Operations

    private func previewStatus(record: Record, coordinator: AppCoordinator, tab: BrowserTab) -> [String: Any] {
        let companion = coordinator.browser.agentCompanion
        let viewportSize = tab.liveView?.bounds.size ?? coordinator.nativeWindow?.contentLayoutRect.size ?? MicroWindowMetrics.defaultSize
        var result: [String: Any] = [
            "windowId": record.windowId.uuidString,
            "tabId": tab.id.uuidString,
            "threadId": record.threadId,
            "url": tab.urlString,
            "title": tab.title,
            "loading": tab.isLoading,
            "owner": (companion?.owner ?? .agent).rawValue,
            "generation": companion?.generation ?? 1,
            "engine": effectiveEngine(of: tab).rawValue,
            "viewport": [
                "width": Int(viewportSize.width.rounded()),
                "height": Int(viewportSize.height.rounded()),
            ],
            "mcpAllowed": true,
            "capabilities": MCPAgentBridgeProtocol.windowCapabilities(),
        ]
        if let pending = tab.dialogs.pending(for: record.previewSession?.id ?? record.windowId).first {
            result["pendingDialog"] = [
                "dialogID": pending.id,
                "type": pending.kind.rawValue,
                "message": pending.message,
            ]
        } else {
            result["pendingDialog"] = NSNull()
        }
        return result
    }

    private func previewNavigate(
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        try ensureSiteWritable(tab: tab, browser: coordinator.browser)
        guard let rawURL = opParams["url"] as? String,
              let url = MCPAgentBridgeProtocol.parseWebURL(rawURL)
        else {
            throw MCPAgentWindowError(.invalidParams, "navigate requires a valid HTTP(S) url.")
        }
        let destinationOrigin = SitePermissions.origin(for: url)
        try ensureDestinationAllowed(url, permissions: coordinator.browser.sitePermissions)
        session.keepInWindow(tab)
        session.observations[tab.id] = nil
        session.grants[tab.id] = MCPBrowserSession.Grant(
            origin: destinationOrigin,
            access: record.access.mcpAccess,
            source: .agentWindow
        )
        let immediate = tab.load(url, transition: .agent)
        _ = await tab.waitForPendingNavigation() ?? immediate
        let readiness = (opParams["readiness"] as? String) ?? "load"
        if readiness != "none" {
            let timeoutMs = min(max(opParams["timeoutMs"] as? Int ?? 15_000, 100), 30_000)
            await waitForTabLoad(tab, timeoutMs: timeoutMs)
        }
        session.syncAgentWindowGrants()
        notifyTabsChanged(for: coordinator.browser)
        return [
            "tabId": tab.id.uuidString,
            "url": tab.urlString,
            "title": tab.title,
            "loading": tab.isLoading,
            "engine": effectiveEngine(of: tab).rawValue,
            "generation": coordinator.browser.agentCompanion?.generation ?? 1,
        ]
    }

    private func previewSnapshot(
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        if let url = Self.activeWebURL(of: tab) {
            tab.assistantAccess.pageChanged(url: url)
            let policy = tab.assistantAccess.explicitPolicy ?? coordinator.browser.sitePermissions.assistantRecord(for: SitePermissions.origin(for: url))
            if policy == .deny {
                throw MCPAgentWindowError(.forbidden, "Assistant access is off for this website.")
            }
            if policy == .ask {
                throw MCPAgentWindowError(.denied, "This website explicitly requires asking before assistant access.")
            }
        }
        session.keepInWindow(tab)
        session.syncAgentWindowGrants()
        var readArgs: [String: Value] = ["tabID": .string(tab.id.uuidString)]
        if let scope = opParams["scope"] as? String, !scope.isEmpty {
            readArgs["scope"] = .string(scope)
        }
        let pageResult = try await session.call(name: "readPage", arguments: readArgs)
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
        let a11yResult = try await session.call(name: "readAccessibility", arguments: a11yArgs)
        let viewportSize = tab.liveView?.bounds.size ?? coordinator.nativeWindow?.contentLayoutRect.size ?? MicroWindowMetrics.defaultSize
        let pageObject = pageResult.structuredContent?.objectValue ?? [:]
        var response: [String: Any] = [
            "tabId": tab.id.uuidString,
            "url": tab.urlString,
            "title": tab.title,
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
        if let observationID = pageObject["observationID"]?.stringValue ?? session.observations[tab.id]?.id {
            response["observationId"] = observationID
        }
        if opParams["includeImage"] as? Bool == true {
            var shotArgs: [String: Value] = ["tabID": .string(tab.id.uuidString)]
            if let maxWidth = opParams["maxWidth"] as? Int {
                shotArgs["maxWidth"] = .int(maxWidth)
            }
            let shotResult = try await session.call(name: "screenshotPage", arguments: shotArgs)
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
        return response
    }

    private func previewAct(
        opParams: [String: Any],
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        try ensureSiteWritable(tab: tab, browser: coordinator.browser)
        guard let action = opParams["action"] as? String, !action.isEmpty else {
            throw MCPAgentWindowError(.invalidParams, "act requires action.")
        }
        let (toolName, arguments) = try Self.mapActToMCPTool(action: action, opParams: opParams, tabId: tab.id)
        let result = try await session.call(name: toolName, arguments: arguments)
        let text = Self.extractText(from: result)
        if result.isError == true {
            throw MCPAgentWindowError(.actionFailed, text)
        }
        var response: [String: Any] = [
            "ok": true,
            "action": action,
            "tabId": tab.id.uuidString,
            "generation": coordinator.browser.agentCompanion?.generation ?? 1,
            "output": result.structuredContent?.objectValue?["content"]?.stringValue ?? text,
        ]
        if let observationID = result.structuredContent?.objectValue?["observationID"]?.stringValue ?? session.observations[tab.id]?.id {
            response["observationId"] = observationID
        }
        return response
    }

    private func previewEvaluate(
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession,
        startGeneration: Int
    ) async throws -> [String: Any] {
        try ensureSiteWritable(tab: tab, browser: coordinator.browser)
        session.syncAgentWindowGrants()
        guard session.mayProceed(tab, capability: .developer) else {
            throw MCPAgentWindowError(.forbidden, MCPBrowserSession.developerRefusal)
        }
        let rawSource = (opParams["expression"] as? String) ?? (opParams["source"] as? String) ?? ""
        let source = MCPBrowserSession.scriptExpression(rawSource)
        guard !source.isEmpty else {
            throw MCPAgentWindowError(.invalidParams, "expression is required.")
        }
        guard source.utf8.count <= PageScripting.maximumSourceBytes else {
            throw MCPAgentWindowError(.invalidParams, "expression exceeds maximum allowed size.")
        }
        session.keepInWindow(tab)
        tab.realizeDeferredSession()
        let view = tab.page
        let pageGeneration = tab.pageGeneration
        guard tab.isLive(view, generation: pageGeneration),
              let url = session.webURL(of: tab)
        else {
            throw MCPAgentWindowError(.actionFailed, "The webpage is unavailable for scripting.")
        }
        if await PageSensitiveProbe.hasFilledSensitiveField(in: view) {
            throw MCPAgentWindowError(.forbidden, "Refused to evaluate script on a page with a filled sensitive or password field.")
        }
        if await session.isDocumentCredentialProtected(tab: tab, view: view) {
            throw MCPAgentWindowError(.forbidden, "Refused to evaluate script on a protected credential document.")
        }
        guard session.mayProceed(tab, capability: .developer),
              tab.isLive(view, generation: pageGeneration),
              session.webURL(of: tab) == url
        else {
            throw MCPAgentWindowError(.forbidden, MCPBrowserSession.developerRefusal)
        }
        let world = PageScripting.World(rawValue: (opParams["world"] as? String) ?? "page") ?? .page
        let timeoutMs = min(
            max(opParams["timeoutMs"] as? Int ?? PageScripting.defaultTimeoutMilliseconds, PageScripting.timeoutMilliseconds.lowerBound),
            PageScripting.timeoutMilliseconds.upperBound
        )
        let scope = PageAutomationGuard(
            documentURL: url.absoluteString,
            snapshot: nil,
            validate: { [weak self, weak record, weak coordinator, weak tab, weak view, weak session] in
                guard let self, let record, let coordinator, let tab, let view, let session,
                      self.isActiveRecord(record),
                      !coordinator.isClosed,
                      let companion = coordinator.browser.agentCompanion,
                      companion.owner == .agent,
                      companion.generation == startGeneration,
                      tab.isLive(view, generation: pageGeneration),
                      session.mayProceed(tab, capability: .developer)
                else {
                    return false
                }
                return true
            }
        )
        tab.setExternalAutomationWorking(true)
        defer { tab.setExternalAutomationWorking(false) }
        let started = ContinuousClock.now
        let outcome = await PageAutomationGuard.$current.withValue(scope) {
            await PageScripting.evaluate(source, world: world, timeout: timeoutMs, in: view, authorized: scope.validate)
        }
        let elapsedMs = Int((ContinuousClock.now - started) / .milliseconds(1))
        guard scope.validate() else {
            throw MCPAgentWindowError(.staleGeneration, "Page access changed while evaluating script.")
        }
        return try decodeEvaluateOutcome(outcome, tab: tab, world: world, elapsedMs: elapsedMs, session: session)
    }

    private func decodeEvaluateOutcome(
        _ outcome: PageScripting.Outcome,
        tab: BrowserTab,
        world: PageScripting.World,
        elapsedMs: Int,
        session: MCPBrowserSession
    ) throws -> [String: Any] {
        switch outcome {
        case .stale:
            throw MCPAgentWindowError(.staleGeneration, "The page changed while the script ran.")
        case .timedOut(let interrupted):
            throw MCPAgentWindowError(.timedOut, interrupted ? "Script timed out and was interrupted." : "Script timed out.")
        case .failed(let message):
            throw MCPAgentWindowError(.scriptError, message)
        case .completed(let text):
            let scrubbed = session.secrets.scrub(text)
            guard let data = scrubbed.data(using: .utf8),
                  let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                throw MCPAgentWindowError(.scriptError, "Could not decode script reply.")
            }
            if reply["ok"] as? Bool != true {
                let errObj = reply["error"] as? [String: Any] ?? [:]
                let message = (errObj["message"] as? String) ?? "Script threw an error."
                throw MCPAgentWindowError(.scriptError, message)
            }
            var response: [String: Any] = [
                "tabId": tab.id.uuidString,
                "world": world.rawValue,
                "elapsedMs": elapsedMs,
                "untrusted": true,
            ]
            for key in ["type", "value", "truncated", "redacted"] {
                if let field = reply[key] {
                    response[key] = field
                }
            }
            return response
        }
    }

    private func previewWaitFor(
        opParams: [String: Any],
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        let timeoutMs = min(max(opParams["timeoutMs"] as? Int ?? 15_000, 100), 30_000)
        if let urlIncludes = opParams["urlIncludes"] as? String, !urlIncludes.isEmpty {
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled else {
                    throw MCPAgentWindowError(.cancelled, "Wait cancelled.")
                }
                if tab.urlString.contains(urlIncludes) {
                    return [
                        "matched": true,
                        "tabId": tab.id.uuidString,
                        "url": tab.urlString,
                        "generation": coordinator.browser.agentCompanion?.generation ?? 1,
                    ]
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            throw MCPAgentWindowError(.timedOut, "Timed out waiting for URL containing \(urlIncludes).")
        }
        var args: [String: Value] = [
            "tabID": .string(tab.id.uuidString),
            "timeout": .int(max(1, min(15, (timeoutMs + 999) / 1_000))),
        ]
        if let condition = opParams["condition"] as? String, !condition.isEmpty {
            args["condition"] = .string(condition)
            if let value = opParams["value"] as? String {
                args["value"] = .string(value)
            }
        } else if let text = opParams["text"] as? String, !text.isEmpty {
            args["condition"] = .string("text")
            args["value"] = .string(text)
        } else {
            args["condition"] = .string("ready")
        }
        let result = try await session.call(name: "waitForPage", arguments: args)
        let text = Self.extractText(from: result)
        if result.isError == true {
            throw MCPAgentWindowError(.timedOut, text)
        }
        return [
            "matched": true,
            "tabId": tab.id.uuidString,
            "output": text,
            "generation": coordinator.browser.agentCompanion?.generation ?? 1,
        ]
    }

    private func previewResize(
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        try ensureSiteWritable(tab: tab, browser: coordinator.browser)
        guard let width = opParams["width"] as? Int, let height = opParams["height"] as? Int,
              width >= PageViewport.minAxis, width <= PageViewport.maxAxis,
              height >= PageViewport.minAxis, height <= PageViewport.maxAxis
        else {
            throw MCPAgentWindowError(.invalidParams, "resize requires integer width and height within valid viewport bounds.")
        }
        if let window = coordinator.nativeWindow {
            let clampedWidth = max(CGFloat(width), MicroWindowMetrics.minSize.width)
            let clampedHeight = max(CGFloat(height), MicroWindowMetrics.minSize.height)
            window.setContentSize(NSSize(width: clampedWidth, height: clampedHeight))
        }
        if session.mayProceed(tab, capability: .development), session.webURL(of: tab) != nil {
            let result = try await session.call(name: "setViewport", arguments: [
                "tabID": .string(tab.id.uuidString),
                "width": .int(width),
                "height": .int(height),
            ])
            if result.isError != true, let viewport = result.structuredContent?.objectValue?["viewport"]?.objectValue {
                return [
                    "tabId": tab.id.uuidString,
                    "width": viewport["innerWidth"]?.intValue ?? width,
                    "height": viewport["innerHeight"]?.intValue ?? height,
                    "generation": coordinator.browser.agentCompanion?.generation ?? 1,
                ]
            }
        }
        return [
            "tabId": tab.id.uuidString,
            "width": width,
            "height": height,
            "generation": coordinator.browser.agentCompanion?.generation ?? 1,
        ]
    }

    private func previewSetAppearance(
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        try ensureSiteWritable(tab: tab, browser: coordinator.browser)
        guard let rawScheme = opParams["colorScheme"] as? String,
              ["dark", "light", "system"].contains(rawScheme)
        else {
            throw MCPAgentWindowError(.invalidParams, "colorScheme must be dark, light, or system.")
        }
        guard record.access.mcpAccess.rank >= MCPAccessConsent.Access.development.rank else {
            throw MCPAgentWindowError(.forbidden, "set_appearance requires development or developer access.")
        }
        let targetScheme: DevelopmentMedia.ColorScheme? = rawScheme == "system"
            ? nil
            : DevelopmentMedia.ColorScheme(rawValue: rawScheme)
        if session.webURL(of: tab) != nil {
            guard session.mayProceed(tab, capability: .development) else {
                throw MCPAgentWindowError(.forbidden, "set_appearance requires development access on this page.")
            }
            session.keepInWindow(tab)
            session.digestCache[tab.id] = nil
            tab.realizeDeferredSession()
            let view = tab.page
            let owner = session.acquireDevelopment(tab, view: view)
            if let owner {
                let target = DevelopmentMedia(
                    colorScheme: targetScheme,
                    reducedMotion: owner.media?.media.reducedMotion,
                    offline: owner.media?.media.offline ?? false
                )
                _ = await view.applyDevelopmentMedia(target, owner: owner, tab: tab)
                session.releaseIfIdle(owner, tab: tab)
            }
        }
        return [
            "tabId": tab.id.uuidString,
            "colorScheme": rawScheme,
            "generation": coordinator.browser.agentCompanion?.generation ?? 1,
        ]
    }

    private func previewDialog(
        opParams: [String: Any],
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        try ensureSiteWritable(tab: tab, browser: coordinator.browser)
        var args: [String: Value] = ["tabID": .string(tab.id.uuidString)]
        let dialogID = (opParams["dialogID"] as? String) ?? tab.dialogs.pending(for: session.id).first?.id
        if let dialogID {
            args["dialogID"] = .string(dialogID)
        }
        if let action = opParams["action"] as? String {
            args["action"] = .string(action)
        } else if let accept = opParams["accept"] as? Bool {
            args["action"] = .string(accept ? "accept" : "dismiss")
        }
        if let promptText = (opParams["promptText"] as? String) ?? (opParams["text"] as? String) {
            args["text"] = .string(promptText)
        }
        let result = try await session.call(name: "handleDialog", arguments: args)
        let text = Self.extractText(from: result)
        if result.isError == true {
            throw MCPAgentWindowError(.actionFailed, text)
        }
        return [
            "ok": true,
            "tabId": tab.id.uuidString,
            "output": text,
        ]
    }

    private func previewSetEngine(
        opParams: [String: Any],
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab,
        session: MCPBrowserSession
    ) async throws -> [String: Any] {
        try ensureSiteWritable(tab: tab, browser: coordinator.browser)
        guard let rawEngine = opParams["engine"] as? String,
              let targetEngine = BrowserEngine(rawValue: rawEngine.lowercased())
        else {
            throw MCPAgentWindowError(.invalidParams, "engine must be chromium or webkit.")
        }
        let currentURL = Self.activeWebURL(of: tab)
        let origin = currentURL.map(SitePermissions.origin(for:)) ?? ""
        if targetEngine == .chromium, !origin.isEmpty, SitePermissions.webKitOnlyOrigins.contains(origin) {
            throw MCPAgentWindowError(.unsupported, "Origin \(origin) requires WebKit and cannot switch to Chromium.")
        }
        tab.engineOverride = nil
        tab.defaultEngineOverride = targetEngine
        session.observations[tab.id] = nil
        if tab.isMaterialised || !tab.urlString.isEmpty {
            if let currentURL {
                tab.noteNavigation(to: currentURL, startedByUser: true)
            }
            let switched = await tab.switchEngine(to: targetEngine)
            guard switched else {
                throw MCPAgentWindowError(.actionFailed, "Could not switch engine to \(targetEngine.rawValue).")
            }
        } else {
            tab.engine = targetEngine
        }
        notifyTabsChanged(for: coordinator.browser)
        return [
            "tabId": tab.id.uuidString,
            "engine": effectiveEngine(of: tab).rawValue,
            "url": tab.urlString,
            "generation": coordinator.browser.agentCompanion?.generation ?? 1,
        ]
    }

    private func previewClose(
        record: Record,
        coordinator: AppCoordinator,
        tab: BrowserTab
    ) throws -> [String: Any] {
        let isLastTab = coordinator.browser.tabs.filter { !$0.isClosed }.count <= 1
        if isLastTab {
            _ = try closeAgentWindow(pairedClientId: record.pairedClientId, threadId: record.threadId, windowId: record.windowId)
            return ["closed": true, "windowClosed": true]
        }
        coordinator.browser.close(tab, recordForReopening: false)
        notifyTabsChanged(for: coordinator.browser)
        return [
            "closed": true,
            "windowClosed": false,
            "remainingTabs": coordinator.browser.tabs.filter { !$0.isClosed }.count,
        ]
    }

    // MARK: - Helpers

    private func waitForTabLoad(_ tab: BrowserTab, timeoutMs: Int) async {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline, !Task.isCancelled, !tab.isClosed {
            if !tab.isLoading, tab.liveView?.mainDocumentID != nil {
                return
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    nonisolated static func mapActToMCPTool(
        action: String,
        opParams: [String: Any],
        tabId: UUID
    ) throws -> (tool: String, arguments: [String: Value]) {
        var args: [String: Value] = ["tabID": .string(tabId.uuidString)]
        if let obs = (opParams["observationId"] as? String) ?? (opParams["observationID"] as? String) {
            args["observationID"] = .string(obs)
        }
        applyTarget(from: opParams, refKey: "ref", selectorKey: "selector", locatorKey: "locator", into: &args)

        switch action {
        case "click":
            applyPoint(from: opParams, into: &args)
            if let button = opParams["button"] as? String {
                args["button"] = .string(button)
            }
            if let count = opParams["clickCount"] as? Int {
                args["clickCount"] = .int(count)
            }
            if let modifiers = parseModifiers(opParams["modifiers"]) {
                args["modifiers"] = .string(modifiers)
            }
            if let pointer = opParams["pointer"] as? Bool {
                args["pointer"] = .bool(pointer)
            }
            return ("clickOnPage", args)
        case "type":
            guard let text = opParams["text"] as? String else {
                throw MCPAgentWindowError(.invalidParams, "type requires text.")
            }
            args["text"] = .string(text)
            if let submit = opParams["submit"] as? Bool {
                args["submit"] = .bool(submit)
            }
            return ("typeOnPage", args)
        case "hover":
            applyPoint(from: opParams, into: &args)
            return ("hoverOnPage", args)
        case "select":
            let option: String? = (opParams["option"] as? String)
                ?? (opParams["values"] as? [String])?.first
            guard let option else {
                throw MCPAgentWindowError(.invalidParams, "select requires option or values.")
            }
            args["option"] = .string(option)
            return ("selectOption", args)
        case "drag":
            applyDragArguments(from: opParams, into: &args)
            return ("dragOnPage", args)
        case "press":
            guard let key = opParams["key"] as? String, !key.isEmpty else {
                throw MCPAgentWindowError(.invalidParams, "press requires key.")
            }
            args["key"] = .string(key)
            if let modifiers = parseModifiers(opParams["modifiers"]) {
                args["modifiers"] = .string(modifiers)
            }
            return ("pressKey", args)
        case "scroll":
            let direction = Self.scrollDirection(from: opParams)
            args["direction"] = .string(direction)
            applyPoint(from: opParams, into: &args)
            return ("scrollPage", args)
        default:
            throw MCPAgentWindowError(.invalidParams, "Unsupported act action: \(action).")
        }
    }

    private nonisolated static func applyDragArguments(from opParams: [String: Any], into args: inout [String: Value]) {
        if args["ref"] == nil, args["selector"] == nil {
            applyTarget(from: opParams, refKey: "sourceRef", selectorKey: "sourceSelector", locatorKey: "source", into: &args)
        }
        if let toRef = parseRef(opParams["toRef"] ?? opParams["target"]) {
            args["toRef"] = .int(toRef)
        } else if let toSelector = (opParams["toSelector"] as? String) ?? (opParams["target"] as? String) {
            args["toSelector"] = .string(toSelector)
        }
        if let dx = opParams["dx"] as? Int {
            args["dx"] = .int(dx)
        }
        if let dy = opParams["dy"] as? Int {
            args["dy"] = .int(dy)
        }
        if let pointer = opParams["pointer"] as? Bool {
            args["pointer"] = .bool(pointer)
        }
    }

    /// `x` and `y` in viewport CSS pixels, as background pointer input at that point (Chromium through DevTools).
    private nonisolated static func applyPoint(from params: [String: Any], into args: inout [String: Value]) {
        guard let x = (params["x"] as? NSNumber)?.doubleValue, let y = (params["y"] as? NSNumber)?.doubleValue,
            x.isFinite, y.isFinite
        else { return }
        args["x"] = .double(x)
        args["y"] = .double(y)
    }

    private nonisolated static func parseModifiers(_ raw: Any?) -> String? {
        if let modifiers = raw as? String, !modifiers.isEmpty {
            return modifiers
        }
        if let list = raw as? [String], !list.isEmpty {
            return list.map { $0.lowercased() }.joined(separator: "+")
        }
        return nil
    }

    private nonisolated static func applyTarget(
        from params: [String: Any],
        refKey: String,
        selectorKey: String,
        locatorKey: String,
        into args: inout [String: Value]
    ) {
        if let ref = parseRef(params[refKey]) {
            args["ref"] = .int(ref)
        } else if let selector = params[selectorKey] as? String, !selector.isEmpty {
            args["selector"] = .string(selector)
        } else if let locator = params[locatorKey] as? String, !locator.isEmpty {
            if let ref = parseRef(locator) {
                args["ref"] = .int(ref)
            } else {
                args["selector"] = .string(locator)
            }
        }
    }

    nonisolated static func parseRef(_ value: Any?) -> Int? {
        if let number = value as? Int, number > 0 {
            return number
        }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("aria-ref=") {
            let suffix = String(trimmed.dropFirst("aria-ref=".count))
            return parseRef(suffix)
        }
        if trimmed.hasPrefix("e"), let number = Int(trimmed.dropFirst()), number > 0 {
            return number
        }
        if let number = Int(trimmed), number > 0 {
            return number
        }
        return nil
    }

    private nonisolated static func scrollDirection(from params: [String: Any]) -> String {
        if let direction = params["direction"] as? String, !direction.isEmpty {
            return direction
        }
        let dy = (params["deltaY"] as? Double) ?? Double(params["deltaY"] as? Int ?? 0)
        let dx = (params["deltaX"] as? Double) ?? Double(params["deltaX"] as? Int ?? 0)
        if abs(dy) >= abs(dx) {
            return dy < 0 ? "up" : "down"
        }
        return dx < 0 ? "left" : "right"
    }

    private nonisolated static func extractText(from result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            if case .text(let text, _, _) = block {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }
}
