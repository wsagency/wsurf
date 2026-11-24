// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Observation

/// Scope attached to an `MCPBrowserSession` bound exclusively to an Agent Micro Window via a `windowToken`.
@MainActor
final class MCPAgentWindowScope {
    let windowId: UUID
    let threadId: String
    let access: MCPAccessConsent.Access
    let isActive: () -> Bool
    let isAgentOwned: () -> Bool
    let onWorkingChanged: (Bool) -> Void

    init(
        windowId: UUID,
        threadId: String,
        access: MCPAccessConsent.Access,
        isActive: @escaping () -> Bool,
        isAgentOwned: @escaping () -> Bool,
        onWorkingChanged: @escaping (Bool) -> Void
    ) {
        self.windowId = windowId
        self.threadId = threadId
        self.access = access
        self.isActive = isActive
        self.isAgentOwned = isAgentOwned
        self.onWorkingChanged = onWorkingChanged
    }
}

/// Tracks detached Agent Micro Windows owned by authenticated external hosts, mints and validates per-window tokens,
/// enforces ownership/generation transitions, cancels in-flight automation on Take Over / Stop / Close, and emits events.
@MainActor
@Observable
final class MCPAgentWindowRegistry {
    final class Record {
        let windowId: UUID
        let hostId: UUID
        let pairedClientId: UUID
        let hostName: String
        let threadId: String
        let windowToken: String
        let windowTokenHash: Data
        let access: AgentWindowAccess
        weak var coordinator: AppCoordinator?
        var previewSession: MCPBrowserSession?
        var activeOperations: [UUID: Task<Void, Never>] = [:]
        var activeWorkingCount = 0

        init(
            windowId: UUID,
            hostId: UUID,
            pairedClientId: UUID,
            hostName: String,
            threadId: String,
            windowToken: String,
            access: AgentWindowAccess,
            coordinator: AppCoordinator
        ) {
            self.windowId = windowId
            self.hostId = hostId
            self.pairedClientId = pairedClientId
            self.hostName = hostName
            self.threadId = threadId
            self.windowToken = windowToken
            windowTokenHash = MCPPairing.hash(windowToken)
            self.access = access
            self.coordinator = coordinator
        }
    }

    typealias WindowOpener = @MainActor (
        _ profile: Profile,
        _ companion: AgentCompanionInfo,
        _ url: URL?,
        _ engine: BrowserEngine,
        _ floatOnTop: Bool,
        _ open: Bool
    ) -> AppCoordinator

    @ObservationIgnored private var records: [UUID: Record] = [:]
    @ObservationIgnored private let trustStore: MCPTrustStore
    @ObservationIgnored private let opener: WindowOpener
    @ObservationIgnored private let profileCatalog: () -> ProfileStore
    @ObservationIgnored private let disconnectMCP: (BrowserModel) -> Void
    @ObservationIgnored private let cancelMCPCalls: (BrowserModel) -> Void
    @ObservationIgnored var onEvent: ((_ hostId: UUID, _ event: String, _ payload: [String: Any]) -> Void)?

    init(
        trustStore: MCPTrustStore,
        profileCatalog: @escaping () -> ProfileStore = { .shared },
        opener: @escaping WindowOpener,
        disconnectMCP: @escaping (BrowserModel) -> Void = { _ in },
        cancelMCPCalls: @escaping (BrowserModel) -> Void = { _ in }
    ) {
        self.trustStore = trustStore
        self.profileCatalog = profileCatalog
        self.opener = opener
        self.disconnectMCP = disconnectMCP
        self.cancelMCPCalls = cancelMCPCalls
    }

    var hasActiveWindows: Bool {
        pruneDeadRecords()
        return !records.isEmpty
    }

    func isActiveRecord(_ record: Record) -> Bool {
        records[record.windowId] === record
    }

    func activeRecords() -> [Record] {
        pruneDeadRecords()
        return Array(records.values)
    }

    // MARK: - Token Resolution for browser.sock

    /// Resolves a `windowToken` presented during `browser.sock` hello authentication.
    /// Compares against every active record in constant time and verifies the paired client matches the window owner.
    func resolve(windowToken: String, pairedClientId: UUID) -> (coordinator: AppCoordinator, scope: MCPAgentWindowScope)? {
        pruneDeadRecords()
        guard MCPPairing.isWellFormed(windowToken) else { return nil }
        let presentedHash = MCPPairing.hash(windowToken)
        var matched: Record?
        for record in records.values where MCPPairing.constantTimeEquals(record.windowTokenHash, presentedHash) {
            matched = record
        }
        guard let record = matched,
              record.pairedClientId == pairedClientId,
              let coordinator = record.coordinator,
              !coordinator.isClosed,
              coordinator.isAgentMicro,
              !coordinator.profiles.isPrivate
        else {
            return nil
        }
        return (coordinator, makeScope(for: record))
    }

    func makeScope(for record: Record) -> MCPAgentWindowScope {
        let windowId = record.windowId
        return MCPAgentWindowScope(
            windowId: windowId,
            threadId: record.threadId,
            access: record.access.mcpAccess,
            isActive: { [weak self, weak record] in
                guard let self, let record,
                      self.records[windowId] === record,
                      let coordinator = record.coordinator,
                      !coordinator.isClosed,
                      coordinator.isAgentMicro,
                      !coordinator.profiles.isPrivate
                else {
                    return false
                }
                return true
            },
            isAgentOwned: { [weak record] in
                record?.coordinator?.browser.agentCompanion?.owner == .agent
            },
            onWorkingChanged: { [weak self, weak record] working in
                guard let self, let record else { return }
                self.setWorking(working, for: record)
            }
        )
    }

    // MARK: - Host Bridge Operations

    func openAgentWindow(
        hostId: UUID,
        pairedClientId: UUID,
        hostName: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        pruneDeadRecords()
        guard let rawThreadId = params["threadId"] as? String else {
            throw MCPAgentWindowError(.invalidParams, "threadId is required.")
        }
        let threadId = MCPAgentBridgeProtocol.cleanText(rawThreadId, maxLength: 128)
        guard !threadId.isEmpty else {
            throw MCPAgentWindowError(.invalidParams, "threadId cannot be empty.")
        }
        let title = (params["title"] as? String).map { MCPAgentBridgeProtocol.cleanText($0, maxLength: 120) }
        let requestedEngine = try parseEngine(params["engine"], defaultEngine: .chromium)
        let explicitEngine = params["engine"] != nil
        let access = try parseAccess(params["access"])
        let floatOnTop = params["floatOnTop"] as? Bool
        let open = params["open"] as? Bool ?? false
        let reuseExisting = params["reuseExistingTab"] as? Bool ?? true
        let requestedURL = try parseOptionalURL(params["url"])

        if let existing = record(hostId: hostId, threadId: threadId),
           let coordinator = existing.coordinator,
           !coordinator.isClosed {
            let options = ReuseOptions(
                title: title,
                url: requestedURL,
                engine: requestedEngine,
                explicitEngine: explicitEngine,
                floatOnTop: floatOnTop,
                open: open,
                reuseExisting: reuseExisting
            )
            return try await reuseOrAddTab(in: existing, coordinator: coordinator, options: options)
        }

        let profile = try resolveProfile(params["profileId"] as? String)
        let windowToken: String
        do {
            windowToken = try MCPPairing.makeToken()
        } catch {
            throw MCPAgentWindowError(.internalError, "Could not mint window token.")
        }
        let companion = AgentCompanionInfo(
            hostName: hostName,
            threadId: threadId,
            threadTitle: title,
            owner: .agent,
            generation: 1,
            isWorking: false,
            allowsMultipleTabs: true,
            defaultEngine: requestedEngine,
            access: access
        )
        let coordinator = opener(profile, companion, requestedURL, requestedEngine, floatOnTop ?? false, open)
        let record = Record(
            windowId: coordinator.windowID,
            hostId: hostId,
            pairedClientId: pairedClientId,
            hostName: hostName,
            threadId: threadId,
            windowToken: windowToken,
            access: access,
            coordinator: coordinator
        )
        records[record.windowId] = record
        let tab = coordinator.browser.activeTab ?? coordinator.browser.newTab(url: requestedURL, transition: .agent, engine: requestedEngine)
        ensureTabEngine(tab, engine: requestedEngine)
        ensurePreviewSession(for: record)
        if open {
            showAgentWindow(coordinator)
        }
        return windowDescriptor(record: record, coordinator: coordinator, tab: tab)
    }

    func closeAgentWindow(hostId: UUID, threadId: String?, windowId: UUID?) throws -> [String: Any] {
        pruneDeadRecords()
        guard threadId != nil || windowId != nil else {
            throw MCPAgentWindowError(.invalidParams, "Provide threadId or windowId.")
        }
        guard let record = findRecord(hostId: hostId, threadId: threadId, windowId: windowId) else {
            throw MCPAgentWindowError(.notFound, "No matching Agent Micro Window found.")
        }
        let coordinator = record.coordinator
        teardown(record, clearCompanion: true, emitClosed: true)
        coordinator?.closeWindow()
        return ["closed": true]
    }

    func setOwner(hostId: UUID, tabId: UUID, owner: AgentWindowOwner) throws -> [String: Any] {
        pruneDeadRecords()
        guard let (record, coordinator, tab) = findTab(hostId: hostId, tabId: tabId) else {
            throw MCPAgentWindowError(.notFound, "No matching tab found.")
        }
        let generation = transitionOwner(record: record, coordinator: coordinator, to: owner, tabId: tab.id)
        return [
            "tabId": tab.id.uuidString,
            "owner": owner.rawValue,
            "generation": generation,
        ]
    }

    func listTabs(hostId: UUID, threadId: String?) -> [String: Any] {
        pruneDeadRecords()
        var items: [[String: Any]] = []
        let matching = records.values
            .filter { $0.hostId == hostId && (threadId == nil || $0.threadId == threadId) }
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
        for record in matching {
            guard let coordinator = record.coordinator, !coordinator.isClosed,
                  let companion = coordinator.browser.agentCompanion
            else {
                continue
            }
            for tab in coordinator.browser.tabs where !tab.isClosed {
                items.append(tabDescriptor(record: record, coordinator: coordinator, companion: companion, tab: tab))
            }
        }
        return ["tabs": items]
    }

    // MARK: - UI Controls (Take Over / Hand Back / Stop / Close)

    func takeOver(window browser: BrowserModel) {
        guard let record = records[browser.windowID],
              let coordinator = record.coordinator,
              !coordinator.isClosed
        else {
            if var companion = browser.agentCompanion {
                companion.owner = .human
                companion.generation += 1
                companion.isWorking = false
                browser.agentCompanion = companion
            }
            return
        }
        _ = transitionOwner(record: record, coordinator: coordinator, to: .human, tabId: browser.activeTab?.id)
    }

    func handBack(window browser: BrowserModel) {
        guard let record = records[browser.windowID],
              let coordinator = record.coordinator,
              !coordinator.isClosed
        else {
            if var companion = browser.agentCompanion {
                companion.owner = .agent
                companion.generation += 1
                browser.agentCompanion = companion
            }
            return
        }
        _ = transitionOwner(record: record, coordinator: coordinator, to: .agent, tabId: browser.activeTab?.id)
    }

    func stop(window browser: BrowserModel) {
        guard let record = records[browser.windowID] else {
            browser.agentCompanion = nil
            disconnectMCP(browser)
            return
        }
        teardown(record, clearCompanion: true, emitClosed: true)
    }

    func windowDidClose(_ coordinator: AppCoordinator) {
        guard let record = records[coordinator.windowID] else { return }
        teardown(record, clearCompanion: true, emitClosed: true)
    }

    func notifyTabsChanged(for browser: BrowserModel) {
        guard let record = records[browser.windowID],
              let coordinator = record.coordinator,
              !coordinator.isClosed,
              let companion = browser.agentCompanion
        else {
            return
        }
        let tabs = browser.tabs.filter { !$0.isClosed }.map { tab in
            tabDescriptor(record: record, coordinator: coordinator, companion: companion, tab: tab)
        }
        onEvent?(record.hostId, "tabsChanged", [
            "windowId": record.windowId.uuidString,
            "threadId": record.threadId,
            "tabs": tabs,
        ])
    }

    func revokeClient(_ clientId: UUID) {
        let matching = records.values.filter { $0.pairedClientId == clientId }
        for record in matching {
            teardown(record, clearCompanion: true, emitClosed: true)
        }
    }

    func disconnectHost(_ hostId: UUID) {
        let matching = records.values.filter { $0.hostId == hostId }
        for record in matching {
            cancelOperations(in: record)
        }
    }

    // MARK: - Internal Helpers for Preview Execution

    func record(hostId: UUID, threadId: String) -> Record? {
        records.values.first { $0.hostId == hostId && $0.threadId == threadId && $0.coordinator?.isClosed == false }
    }

    func findRecord(hostId: UUID, threadId: String?, windowId: UUID?) -> Record? {
        records.values.first { record in
            guard record.hostId == hostId, record.coordinator?.isClosed == false else { return false }
            if let windowId, record.windowId != windowId {
                return false
            }
            if let threadId, record.threadId != threadId {
                return false
            }
            return true
        }
    }

    func findTab(hostId: UUID, tabId: UUID) -> (Record, AppCoordinator, BrowserTab)? {
        for record in records.values where record.hostId == hostId {
            guard let coordinator = record.coordinator, !coordinator.isClosed else { continue }
            if let tab = coordinator.browser.tabs.first(where: { $0.id == tabId && !$0.isClosed }) {
                return (record, coordinator, tab)
            }
        }
        return nil
    }

    @discardableResult
    func ensurePreviewSession(for record: Record) -> MCPBrowserSession? {
        if let existing = record.previewSession, existing.isConnected {
            return existing
        }
        guard let coordinator = record.coordinator, !coordinator.isClosed else { return nil }
        let scope = makeScope(for: record)
        let session = MCPBrowserSession(
            browser: coordinator.browser,
            trust: trustStore,
            available: { [weak scope] in scope?.isActive() == true },
            consent: { _, _, _ in nil },
            openConsent: { _, _ in false },
            sensitiveConsent: { _, _ in false }
        )
        session.clientName = record.hostName
        session.pairedClient = trustStore.client(id: record.pairedClientId)
        session.agentWindowScope = scope
        session.syncAgentWindowGrants()
        record.previewSession = session
        return session
    }

    func registerOperation(_ task: Task<Void, Never>, in record: Record) -> UUID {
        let operationId = UUID()
        record.activeOperations[operationId] = task
        return operationId
    }

    func unregisterOperation(_ operationId: UUID, in record: Record) {
        record.activeOperations.removeValue(forKey: operationId)
    }

    func setWorking(_ working: Bool, for record: Record) {
        if working {
            record.activeWorkingCount += 1
        } else {
            record.activeWorkingCount = max(0, record.activeWorkingCount - 1)
        }
        let isWorking = record.activeWorkingCount > 0
        if var companion = record.coordinator?.browser.agentCompanion, companion.isWorking != isWorking {
            companion.isWorking = isWorking
            record.coordinator?.browser.agentCompanion = companion
        }
    }

    func windowDescriptor(record: Record, coordinator: AppCoordinator, tab: BrowserTab) -> [String: Any] {
        let companion = coordinator.browser.agentCompanion
        return [
            "windowId": record.windowId.uuidString,
            "tabId": tab.id.uuidString,
            "threadId": record.threadId,
            "generation": companion?.generation ?? 1,
            "owner": (companion?.owner ?? .agent).rawValue,
            "engine": effectiveEngine(of: tab).rawValue,
            "url": tab.urlString,
            "title": tab.title,
            "windowToken": record.windowToken,
            "backend": MCPAgentBridgeProtocol.backendName,
            "mcpAllowed": true,
            "capabilities": MCPAgentBridgeProtocol.windowCapabilities(),
        ]
    }

    func tabDescriptor(
        record: Record,
        coordinator: AppCoordinator,
        companion: AgentCompanionInfo,
        tab: BrowserTab
    ) -> [String: Any] {
        [
            "tabId": tab.id.uuidString,
            "windowId": record.windowId.uuidString,
            "threadId": record.threadId,
            "url": tab.urlString,
            "title": tab.title,
            "owner": companion.owner.rawValue,
            "generation": companion.generation,
            "engine": effectiveEngine(of: tab).rawValue,
            "loading": tab.isLoading,
            "active": coordinator.browser.activeTabID == tab.id,
        ]
    }

    func effectiveEngine(of tab: BrowserTab) -> BrowserEngine {
        tab.loadedEngine ?? tab.engineOverride ?? tab.engine
    }

    func ensureTabEngine(_ tab: BrowserTab, engine: BrowserEngine) {
        tab.engineOverride = engine
        if !tab.isMaterialised {
            tab.engine = engine
        }
    }

    func showAgentWindow(_ coordinator: AppCoordinator) {
        coordinator.showBrowser(activate: !AppDatabase.isRunningTests)
    }

    func parseEngine(_ raw: Any?, defaultEngine: BrowserEngine) throws -> BrowserEngine {
        guard let raw else { return defaultEngine }
        guard let value = raw as? String, let engine = BrowserEngine(rawValue: value.lowercased()) else {
            throw MCPAgentWindowError(.invalidParams, "engine must be chromium or webkit.")
        }
        return engine
    }

    func parseOptionalURL(_ raw: Any?) throws -> URL? {
        guard let raw else { return nil }
        guard let text = raw as? String else {
            throw MCPAgentWindowError(.invalidParams, "url must be an HTTP(S) string.")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard let url = MCPAgentBridgeProtocol.parseWebURL(text) else {
            throw MCPAgentWindowError(.invalidParams, "url must be a valid HTTP(S) URL without credentials.")
        }
        return url
    }

    // MARK: - Private

    private struct ReuseOptions {
        let title: String?
        let url: URL?
        let engine: BrowserEngine
        let explicitEngine: Bool
        let floatOnTop: Bool?
        let open: Bool
        let reuseExisting: Bool
    }

    private func reuseOrAddTab(
        in record: Record,
        coordinator: AppCoordinator,
        options: ReuseOptions
    ) async throws -> [String: Any] {
        if var companion = coordinator.browser.agentCompanion {
            if let title = options.title {
                companion.threadTitle = title
            }
            coordinator.browser.agentCompanion = companion
        }
        if let floatOnTop = options.floatOnTop {
            coordinator.floatsOnTop = floatOnTop
        }
        let owner = coordinator.browser.agentCompanion?.owner ?? .agent
        let tab: BrowserTab
        if !options.reuseExisting {
            if owner == .human {
                throw MCPAgentWindowError(.humanControl, "Window is under human control.")
            }
            tab = coordinator.browser.newTab(url: options.url, activate: true, transition: .agent, engine: options.engine)
            ensureTabEngine(tab, engine: options.engine)
            notifyTabsChanged(for: coordinator.browser)
        } else {
            tab = coordinator.browser.activeTab
                ?? coordinator.browser.tabs.first
                ?? coordinator.browser.newTab(url: options.url, activate: true, transition: .agent, engine: options.engine)
            if owner != .human {
                if options.explicitEngine, effectiveEngine(of: tab) != options.engine {
                    tab.engineOverride = options.engine
                    if tab.isMaterialised {
                        _ = await tab.switchEngine(to: options.engine)
                    } else {
                        tab.engine = options.engine
                    }
                }
                if let url = options.url {
                    tab.load(url, transition: .agent)
                }
            }
        }
        ensurePreviewSession(for: record)?.syncAgentWindowGrants()
        if options.open {
            showAgentWindow(coordinator)
        }
        return windowDescriptor(record: record, coordinator: coordinator, tab: tab)
    }

    private func transitionOwner(
        record: Record,
        coordinator: AppCoordinator,
        to owner: AgentWindowOwner,
        tabId: UUID?
    ) -> Int {
        var companion = coordinator.browser.agentCompanion ?? AgentCompanionInfo(
            hostName: record.hostName,
            threadId: record.threadId
        )
        companion.owner = owner
        companion.generation += 1
        if owner != .agent {
            companion.isWorking = false
            record.activeWorkingCount = 0
        }
        coordinator.browser.agentCompanion = companion
        if owner != .agent {
            cancelOperations(in: record)
            cancelMCPCalls(coordinator.browser)
            for tab in coordinator.browser.tabs {
                tab.setExternalAutomationWorking(false)
            }
        }
        let resolvedTabId = (tabId ?? coordinator.browser.activeTab?.id)?.uuidString ?? ""
        onEvent?(record.hostId, "ownerChanged", [
            "windowId": record.windowId.uuidString,
            "tabId": resolvedTabId,
            "threadId": record.threadId,
            "owner": owner.rawValue,
            "generation": companion.generation,
        ])
        return companion.generation
    }

    private func teardown(_ record: Record, clearCompanion: Bool, emitClosed: Bool) {
        guard records.removeValue(forKey: record.windowId) === record else { return }
        cancelOperations(in: record)
        record.activeWorkingCount = 0
        record.previewSession?.revoke()
        record.previewSession = nil
        if let coordinator = record.coordinator {
            cancelMCPCalls(coordinator.browser)
            disconnectMCP(coordinator.browser)
            for tab in coordinator.browser.tabs {
                tab.setExternalAutomationWorking(false)
            }
            if clearCompanion {
                coordinator.browser.agentCompanion = nil
            }
        }
        if emitClosed {
            onEvent?(record.hostId, "windowClosed", [
                "windowId": record.windowId.uuidString,
                "threadId": record.threadId,
            ])
        }
    }

    private func cancelOperations(in record: Record) {
        let tasks = Array(record.activeOperations.values)
        record.activeOperations.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func parseAccess(_ raw: Any?) throws -> AgentWindowAccess {
        guard let raw else { return .development }
        guard let value = raw as? String, let access = AgentWindowAccess(rawValue: value.lowercased()) else {
            throw MCPAgentWindowError(.invalidParams, "access must be control or development.")
        }
        return access
    }

    private func resolveProfile(_ profileId: String?) throws -> Profile {
        let catalog = profileCatalog()
        guard let profileId, !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let current = catalog.current
            if !current.isPrivate {
                return current
            }
            return catalog.profiles.first(where: { !$0.isPrivate }) ?? .original()
        }
        if profileId.lowercased() == "private" || UUID(uuidString: profileId) == Profile.privateID {
            throw MCPAgentWindowError(.forbidden, "Agent Micro Windows cannot use private browsing.")
        }
        if let uuid = UUID(uuidString: profileId),
           let matched = catalog.profiles.first(where: { $0.id == uuid && !$0.isPrivate }) {
            return matched
        }
        if let matched = catalog.profiles.first(where: { $0.name.caseInsensitiveCompare(profileId) == .orderedSame && !$0.isPrivate }) {
            return matched
        }
        throw MCPAgentWindowError(.notFound, "Profile not found.")
    }

    private func pruneDeadRecords() {
        for (windowId, record) in records where record.coordinator == nil || record.coordinator?.isClosed == true {
            records.removeValue(forKey: windowId)
            cancelOperations(in: record)
            record.previewSession?.revoke()
            record.previewSession = nil
        }
    }
}
