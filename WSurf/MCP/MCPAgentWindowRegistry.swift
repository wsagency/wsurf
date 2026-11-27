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
    let generation: () -> Int?
    let takeOver: (BrowserTab) -> Void
    let secrets: MCPSecretScrubber
    let onBeginWorking: () -> UUID
    let onEndWorking: (UUID) -> Void

    init(
        windowId: UUID,
        threadId: String,
        access: MCPAccessConsent.Access,
        isActive: @escaping () -> Bool,
        isAgentOwned: @escaping () -> Bool,
        generation: @escaping () -> Int?,
        takeOver: @escaping (BrowserTab) -> Void,
        secrets: MCPSecretScrubber,
        onBeginWorking: @escaping () -> UUID,
        onEndWorking: @escaping (UUID) -> Void
    ) {
        self.windowId = windowId
        self.threadId = threadId
        self.access = access
        self.isActive = isActive
        self.isAgentOwned = isAgentOwned
        self.generation = generation
        self.takeOver = takeOver
        self.secrets = secrets
        self.onBeginWorking = onBeginWorking
        self.onEndWorking = onEndWorking
    }
}

/// Tracks detached Agent Micro Windows owned by authenticated paired clients, mints and validates per-window tokens,
/// enforces ownership/generation transitions, cancels in-flight automation on Take Over / Stop / Close, and emits events.
@MainActor
@Observable
final class MCPAgentWindowRegistry {
    static let maxWindowsPerClient = 8

    final class Record {
        let windowId: UUID
        let pairedClientId: UUID
        let hostName: String
        let threadId: String
        let windowToken: String
        let windowTokenHash: Data
        let access: AgentWindowAccess
        let secrets = MCPSecretScrubber()
        weak var coordinator: AppCoordinator?
        var previewSession: MCPBrowserSession?
        var activeOperations: [UUID: Task<Void, Never>] = [:]
        var activeWorkingIDs: Set<UUID> = []
        /// Set when the user clicks Take Over; only user Hand Back clears it so the host cannot bounce through `unclaimed`.
        var lockedByHumanTakeOver = false

        init(
            windowId: UUID,
            pairedClientId: UUID,
            hostName: String,
            threadId: String,
            windowToken: String,
            access: AgentWindowAccess,
            coordinator: AppCoordinator
        ) {
            self.windowId = windowId
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
    /// Clients halted via MicroBar Stop during this app session: `true` if persisted paused in Keychain, `false` if the
    /// Keychain write failed (in which case the in-memory block stays active for the rest of the session).
    @ObservationIgnored private var stoppedClients: [UUID: Bool] = [:]
    @ObservationIgnored let trustStore: MCPTrustStore
    @ObservationIgnored private let opener: WindowOpener
    @ObservationIgnored private let profileCatalog: () -> ProfileStore
    @ObservationIgnored private let disconnectMCP: (BrowserModel) -> Void
    @ObservationIgnored private let cancelMCPCalls: (BrowserModel, UUID?) -> Void
    @ObservationIgnored private let showWindow: (AppCoordinator) -> Void
    @ObservationIgnored var onEvent: ((_ pairedClientId: UUID, _ event: String, _ payload: [String: Any]) -> Void)?
    @ObservationIgnored var onStopClient: ((_ pairedClientId: UUID) -> Void)?

    init(
        trustStore: MCPTrustStore,
        profileCatalog: @escaping () -> ProfileStore = { .shared },
        opener: @escaping WindowOpener,
        disconnectMCP: @escaping (BrowserModel) -> Void = { _ in },
        cancelMCPCalls: @escaping (BrowserModel, UUID?) -> Void = { _, _ in },
        showWindow: @escaping (AppCoordinator) -> Void = { $0.showBrowser(activate: !AppDatabase.isRunningTests) }
    ) {
        self.trustStore = trustStore
        self.profileCatalog = profileCatalog
        self.opener = opener
        self.disconnectMCP = disconnectMCP
        self.cancelMCPCalls = cancelMCPCalls
        self.showWindow = showWindow
        trustStore.onChange { [weak self] in
            self?.reconcileStoppedClients()
        }
    }

    func isClientStopped(_ clientId: UUID) -> Bool {
        stoppedClients[clientId] != nil
    }

    private func reconcileStoppedClients() {
        guard trustStore.isAvailable else { return }
        for (clientId, persistedInStore) in Array(stoppedClients) {
            guard let live = trustStore.client(id: clientId) else {
                stoppedClients.removeValue(forKey: clientId)
                continue
            }
            if persistedInStore, !live.paused {
                stoppedClients.removeValue(forKey: clientId)
            }
        }
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
        guard !isClientStopped(pairedClientId), MCPPairing.isWellFormed(windowToken) else { return nil }
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
              coordinator.browser.agentCompanion != nil,
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
                      coordinator.browser.agentCompanion != nil,
                      !coordinator.profiles.isPrivate
                else {
                    return false
                }
                return true
            },
            isAgentOwned: { [weak record] in
                record?.coordinator?.browser.agentCompanion?.owner == .agent
            },
            generation: { [weak record] in record?.coordinator?.browser.agentCompanion?.generation },
            takeOver: { [weak self, weak record] tab in
                guard let self, let record, self.isActiveRecord(record), let browser = record.coordinator?.browser else { return }
                self.takeOver(window: browser, tabId: tab.id, preservingCall: BrowserMCPServer.currentCallID)
            },
            secrets: record.secrets,
            onBeginWorking: { [weak self, weak record] in
                guard let self, let record else { return UUID() }
                return self.beginWorking(for: record)
            },
            onEndWorking: { [weak self, weak record] token in
                guard let self, let record else { return }
                self.endWorking(token, for: record)
            }
        )
    }

    // MARK: - Host Bridge Operations

    func openAgentWindow(
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
        let existing = record(pairedClientId: pairedClientId, threadId: threadId)
        if let existing, existing.lockedByHumanTakeOver || existing.coordinator?.browser.agentCompanion?.owner == .human {
            throw MCPAgentWindowError(.humanControl, "Window is under human control.")
        }
        let title = (params["title"] as? String).map { MCPAgentBridgeProtocol.cleanText($0, maxLength: 120) }
        let defaultEngine = trustStore.client(id: pairedClientId)?.policy.defaultEngine.engine ?? .chromium
        let requestedEngine = try parseEngine(params["engine"], defaultEngine: defaultEngine)
        let explicitEngine = params["engine"] != nil
        let access = try parseAccess(params["access"])
        try validateRequestedAccess(access, for: pairedClientId)
        let floatOnTop = params["floatOnTop"] as? Bool
        let open = params["open"] as? Bool
        let reuseExisting = params["reuseExistingTab"] as? Bool ?? true
        let requestedURL = try parseOptionalURL(params["url"])

        if let requestedURL, explicitEngine, requestedEngine == .chromium,
           SitePermissions.webKitOnlyOrigins.contains(SitePermissions.origin(for: requestedURL)) {
            throw MCPAgentWindowError(.unsupported, "This origin requires WebKit and cannot open in Chromium.")
        }

        if let existing,
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
            guard let generation = coordinator.browser.agentCompanion?.generation else {
                throw MCPAgentWindowError(.notFound, "Agent session is no longer active.")
            }
            return try await runCancellablePreview(in: existing, coordinator: coordinator, expectedGeneration: generation, owner: .agent) {
                try await self.reuseOrAddTab(in: existing, coordinator: coordinator, options: options, generation: generation)
            }
        }

        let openForClient = records.values.filter { $0.pairedClientId == pairedClientId }.count
        guard openForClient < Self.maxWindowsPerClient else {
            throw MCPAgentWindowError(.forbidden, "Maximum number of open Agent Micro Windows reached (\(Self.maxWindowsPerClient)).")
        }

        let profile = try resolveProfile(params["profileId"] as? String)
        if let requestedURL {
            let context = BrowserProfileContext.shared(for: profile, settingsOwner: profile)
            try ensureDestinationAllowed(requestedURL, permissions: context.sitePermissions)
        }
        let windowToken: String
        do {
            windowToken = try MCPPairing.makeToken()
        } catch {
            throw MCPAgentWindowError(.internalError, "Could not mint window token.")
        }
        let verifiedHostName = verifiedDisplayName(for: pairedClientId, fallback: hostName)
        let companion = AgentCompanionInfo(
            hostName: verifiedHostName,
            threadId: threadId,
            threadTitle: title,
            owner: .agent,
            generation: 1,
            isWorking: false,
            allowsMultipleTabs: true,
            defaultEngine: requestedEngine,
            access: access
        )
        let coordinator = opener(profile, companion, requestedURL, requestedEngine, floatOnTop ?? false, open ?? true)
        let record = Record(
            windowId: coordinator.windowID,
            pairedClientId: pairedClientId,
            hostName: verifiedHostName,
            threadId: threadId,
            windowToken: windowToken,
            access: access,
            coordinator: coordinator
        )
        records[record.windowId] = record
        let tab = coordinator.browser.activeTab ?? coordinator.browser.newTab(url: requestedURL, transition: .agent)
        configureTabEngine(tab, requested: requestedEngine, url: requestedURL)
        ensurePreviewSession(for: record)?.attributeAgentTab(tab)
        if open ?? true {
            showAgentWindow(coordinator)
        }
        return windowDescriptor(record: record, coordinator: coordinator, tab: tab)
    }

    func closeAgentWindow(pairedClientId: UUID, threadId: String?, windowId: UUID?) throws -> [String: Any] {
        pruneDeadRecords()
        guard threadId != nil || windowId != nil else {
            throw MCPAgentWindowError(.invalidParams, "Provide threadId or windowId.")
        }
        guard let record = findRecord(pairedClientId: pairedClientId, threadId: threadId, windowId: windowId) else {
            throw MCPAgentWindowError(.notFound, "No matching Agent Micro Window found.")
        }
        guard record.coordinator?.browser.agentCompanion?.owner != .human,
              !record.lockedByHumanTakeOver
        else {
            throw MCPAgentWindowError(.humanControl, "Window is under user control.")
        }
        let coordinator = record.coordinator
        teardown(record, clearCompanion: false, emitClosed: true)
        coordinator?.closeWindow()
        coordinator?.browser.agentCompanion = nil
        return ["closed": true]
    }

    func setOwner(pairedClientId: UUID, tabId: UUID, owner: AgentWindowOwner) throws -> [String: Any] {
        pruneDeadRecords()
        guard let (record, coordinator, tab) = findTab(pairedClientId: pairedClientId, tabId: tabId) else {
            throw MCPAgentWindowError(.notFound, "No matching tab found.")
        }
        let currentOwner = coordinator.browser.agentCompanion?.owner ?? .agent
        if currentOwner == .human || record.lockedByHumanTakeOver {
            throw MCPAgentWindowError(.humanControl, "Window is under human control. Only the user can Hand Back control.")
        }
        let generation = transitionOwner(record: record, coordinator: coordinator, to: owner, tabId: tab.id)
        return [
            "tabId": tab.id.uuidString,
            "owner": owner.rawValue,
            "generation": generation,
        ]
    }

    func listTabs(pairedClientId: UUID, threadId: String?) -> [String: Any] {
        pruneDeadRecords()
        var items: [[String: Any]] = []
        let matching = records.values
            .filter { $0.pairedClientId == pairedClientId && (threadId == nil || $0.threadId == threadId) }
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

    func takeOver(window browser: BrowserModel, tabId: UUID? = nil, preservingCall: UUID? = nil) {
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
        record.lockedByHumanTakeOver = true
        _ = transitionOwner(
            record: record, coordinator: coordinator, to: .human, tabId: tabId ?? browser.activeTab?.id, preservingCall: preservingCall)
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
        record.lockedByHumanTakeOver = false
        _ = transitionOwner(record: record, coordinator: coordinator, to: .agent, tabId: browser.activeTab?.id)
    }

    /// Kill switch from MicroBar Stop: revokes window access, pauses the paired client in `MCPTrustStore` (plus an
    /// in-memory fallback when Keychain writes fail), and closes its host-bridge connections so the client cannot
    /// immediately reopen windows until resumed by the user.
    func stop(window browser: BrowserModel) {
        guard let record = records[browser.windowID] else {
            browser.agentCompanion = nil
            disconnectMCP(browser)
            return
        }
        let clientId = record.pairedClientId
        teardown(record, clearCompanion: true, emitClosed: true)
        let persistedInStore: Bool
        do {
            try trustStore.setPaused(true, for: clientId)
            persistedInStore = true
        } catch {
            persistedInStore = false
        }
        stoppedClients[clientId] = persistedInStore
        onStopClient?(clientId)
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
        onEvent?(record.pairedClientId, "tabsChanged", [
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

    /// Cancels in-flight preview operations when a host drops its last socket, while keeping the window record alive
    /// under `pairedClientId` so the host can reconnect seamlessly.
    func cancelInFlightOperations(for pairedClientId: UUID) {
        let matching = records.values.filter { $0.pairedClientId == pairedClientId }
        for record in matching {
            cancelOperations(in: record)
        }
    }

    /// Tears down all active Agent Micro Window records and revokes every `windowToken` when the host bridge stops.
    func teardownAll() {
        for record in Array(records.values) {
            teardown(record, clearCompanion: true, emitClosed: true)
        }
    }

    // MARK: - Internal Helpers for Preview Execution

    func record(pairedClientId: UUID, threadId: String) -> Record? {
        records.values.first { $0.pairedClientId == pairedClientId && $0.threadId == threadId && $0.coordinator?.isClosed == false }
    }

    func findRecord(pairedClientId: UUID, threadId: String?, windowId: UUID?) -> Record? {
        records.values.first { record in
            guard record.pairedClientId == pairedClientId, record.coordinator?.isClosed == false else { return false }
            if let windowId, record.windowId != windowId {
                return false
            }
            if let threadId, record.threadId != threadId {
                return false
            }
            return true
        }
    }

    func findTab(pairedClientId: UUID, tabId: UUID) -> (Record, AppCoordinator, BrowserTab)? {
        for record in records.values where record.pairedClientId == pairedClientId {
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
            sensitiveConsent: { _, _ in false },
            loginConsent: { [weak coordinator] client, url, accounts, manual, reason in
                let window = coordinator.flatMap { $0.browser.context.extensions.adapter(for: $0.browser)?.nativeWindow }
                return await MCPAccessConsent.requestLogin(
                    client: client, url: url, accounts: accounts, allowsManualTakeOver: manual, reason: reason, in: window)
            }
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

    func beginWorking(for record: Record) -> UUID {
        let token = UUID()
        record.activeWorkingIDs.insert(token)
        syncWorkingState(for: record)
        return token
    }

    func endWorking(_ token: UUID, for record: Record) {
        record.activeWorkingIDs.remove(token)
        syncWorkingState(for: record)
    }

    private func syncWorkingState(for record: Record) {
        let isWorking = !record.activeWorkingIDs.isEmpty
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
            "visible": isWindowVisible(coordinator),
            "engine": effectiveEngine(of: tab).rawValue,
            "url": previewMetadata(tab.urlString, tab: tab, record: record),
            "title": previewMetadata(tab.title, tab: tab, record: record),
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
            "url": previewMetadata(tab.urlString, tab: tab, record: record),
            "title": previewMetadata(tab.title, tab: tab, record: record),
            "owner": companion.owner.rawValue,
            "generation": companion.generation,
            "engine": effectiveEngine(of: tab).rawValue,
            "loading": tab.isLoading,
            "active": coordinator.browser.activeTabID == tab.id,
        ]
    }

    func effectiveEngine(of tab: BrowserTab) -> BrowserEngine {
        if let loaded = tab.loadedEngine {
            return loaded
        }
        return tab.preferredEngine(for: URL(string: tab.urlString))
    }

    func isWindowVisible(_ coordinator: AppCoordinator) -> Bool {
        guard let window = coordinator.nativeWindow else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func configureTabEngine(_ tab: BrowserTab, requested: BrowserEngine, url: URL?) {
        tab.engineOverride = nil
        tab.defaultEngineOverride = requested
        if !tab.isMaterialised {
            tab.engine = tab.preferredEngine(for: url)
        }
    }

    func showAgentWindow(_ coordinator: AppCoordinator) {
        showWindow(coordinator)
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
        let open: Bool?
        let reuseExisting: Bool
    }

    private func reuseOrAddTab(
        in record: Record,
        coordinator: AppCoordinator,
        options: ReuseOptions,
        generation: Int
    ) async throws -> [String: Any] {
        let owner = coordinator.browser.agentCompanion?.owner ?? .agent
        guard owner == .agent else {
            if owner == .human {
                throw MCPAgentWindowError(.humanControl, "Window is under human control.")
            }
            throw MCPAgentWindowError(.denied, "Window is unclaimed and not owned by the agent.")
        }
        if let url = options.url {
            try ensureDestinationAllowed(url, permissions: coordinator.browser.sitePermissions)
        }
        if var companion = coordinator.browser.agentCompanion, let title = options.title {
            companion.threadTitle = title
            coordinator.browser.agentCompanion = companion
        }
        if let floatOnTop = options.floatOnTop {
            coordinator.floatsOnTop = floatOnTop
        }
        let tab: BrowserTab
        if !options.reuseExisting {
            tab = coordinator.browser.newTab(url: options.url, transition: .agent, defaultEngine: options.engine)
            ensurePreviewSession(for: record)?.attributeAgentTab(tab)
            notifyTabsChanged(for: coordinator.browser)
        } else {
            tab = coordinator.browser.activeTab
                ?? coordinator.browser.tabs.first
                ?? {
                    let opened = coordinator.browser.newTab(transition: .agent, defaultEngine: options.engine)
                    ensurePreviewSession(for: record)?.attributeAgentTab(opened)
                    return opened
                }()
            if options.explicitEngine || options.url != nil {
                try ensureSiteWritable(tab: tab, browser: coordinator.browser)
            }
            if options.explicitEngine, effectiveEngine(of: tab) != options.engine {
                let currentOrigin = coordinator.browser.siteOrigin(for: tab)
                if options.engine == .chromium, SitePermissions.webKitOnlyOrigins.contains(currentOrigin) {
                    throw MCPAgentWindowError(.unsupported, "This origin requires WebKit and cannot switch to Chromium.")
                }
                if tab.isMaterialised {
                    let switched = await tab.switchEngine(to: options.engine) {
                        self.mayMutate(record, generation: generation)
                    }
                    if coordinator.browser.agentCompanion?.owner == .human {
                        throw MCPAgentWindowError(.humanControl, "Window is under human control.")
                    }
                    guard mayMutate(record, generation: generation) else {
                        throw MCPAgentWindowError(.staleGeneration, "Window ownership changed while running.")
                    }
                    guard switched else {
                        throw MCPAgentWindowError(.actionFailed, "Could not switch the tab engine.")
                    }
                }
                configureTabEngine(tab, requested: options.engine, url: options.url ?? URL(string: tab.urlString))
            }
            if let url = options.url {
                _ = await navigateAgentTab(tab, to: url, record: record, generation: generation)
                guard mayMutate(record, generation: generation) else {
                    throw MCPAgentWindowError(.staleGeneration, "Window ownership changed while running.")
                }
            }
        }
        ensurePreviewSession(for: record)?.syncAgentWindowGrants()
        if options.open ?? !isWindowVisible(coordinator) {
            showAgentWindow(coordinator)
        }
        return windowDescriptor(record: record, coordinator: coordinator, tab: tab)
    }

    func navigateAgentTab(_ tab: BrowserTab, to url: URL, record: Record, generation: Int) async -> PageNavigation? {
        let immediate = tab.load(url, transition: .agent) {
            self.mayMutate(record, generation: generation)
        }
        return await tab.waitForPendingNavigation(cancelWithCaller: true) ?? immediate
    }

    func ensureDestinationAllowed(_ url: URL, permissions: SitePermissions) throws {
        let origin = SitePermissions.origin(for: url)
        let policy = permissions.assistantRecord(for: origin)
        if policy == .deny {
            throw MCPAgentWindowError(.forbidden, "Assistant access is off for this website.")
        }
        if policy == .ask {
            throw MCPAgentWindowError(.denied, "This website explicitly requires asking before assistant control.")
        }
    }

    private func validateRequestedAccess(_ access: AgentWindowAccess, for pairedClientId: UUID) throws {
        guard !isClientStopped(pairedClientId),
              trustStore.isAvailable,
              let client = trustStore.client(id: pairedClientId),
              !client.paused
        else {
            throw MCPAgentWindowError(.unauthorized, "Client trust was revoked, paused, or stopped.")
        }
        switch access {
        case .control:
            return
        case .development:
            guard client.standing == .development || client.standing == .developer else {
                throw MCPAgentWindowError(.denied, "Development access requires Development or Developer standing in Connected apps.")
            }
        case .developer:
            guard client.standing == .developer else {
                throw MCPAgentWindowError(.denied, "Developer access requires Developer standing in Connected apps.")
            }
        }
    }

    private func transitionOwner(
        record: Record,
        coordinator: AppCoordinator,
        to owner: AgentWindowOwner,
        tabId: UUID?,
        preservingCall: UUID? = nil
    ) -> Int {
        var companion = coordinator.browser.agentCompanion ?? AgentCompanionInfo(
            hostName: record.hostName,
            threadId: record.threadId
        )
        companion.owner = owner
        companion.generation += 1
        if owner != .agent {
            companion.isWorking = false
            record.activeWorkingIDs.removeAll()
        }
        coordinator.browser.agentCompanion = companion
        record.previewSession?.syncAgentWindowGeneration()
        for tab in coordinator.browser.tabs {
            if let view = tab.liveView {
                PageDriver.observations.removeObject(forKey: view)
            }
        }
        if owner != .agent {
            cancelOperations(in: record)
            cancelMCPCalls(coordinator.browser, preservingCall)
            for tab in coordinator.browser.tabs {
                tab.setExternalAutomationWorking(false)
            }
        }
        let resolvedTabId = (tabId ?? coordinator.browser.activeTab?.id)?.uuidString ?? ""
        onEvent?(record.pairedClientId, "ownerChanged", [
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
        record.activeWorkingIDs.removeAll()
        record.previewSession?.revoke()
        record.previewSession = nil
        record.secrets.wipe()
        if let coordinator = record.coordinator {
            cancelMCPCalls(coordinator.browser, nil)
            disconnectMCP(coordinator.browser)
            for tab in coordinator.browser.tabs {
                tab.setExternalAutomationWorking(false)
            }
            if clearCompanion {
                coordinator.browser.agentCompanion = nil
            }
        }
        if emitClosed {
            onEvent?(record.pairedClientId, "windowClosed", [
                "windowId": record.windowId.uuidString,
                "threadId": record.threadId,
            ])
        }
    }

    /// Page-controlled metadata is sent on both the wire replies and pushed tab events.
    func previewMetadata(_ text: String, tab: BrowserTab, record: Record) -> String {
        if record.coordinator?.browser.agentCompanion?.owner == .human || tab.isMCPCredentialTainted
            || (tab.mcpSecretWriteEpoch == tab.documentCommitEpoch && record.secrets.isEmpty) {
            return MCPSecretScrubber.replacement
        }
        return record.secrets.scrub(text)
    }

    func mayMutate(_ record: Record, generation: Int) -> Bool {
        guard !Task.isCancelled, isActiveRecord(record), let companion = record.coordinator?.browser.agentCompanion else { return false }
        return companion.owner == .agent && companion.generation == generation
    }

    private func cancelOperations(in record: Record) {
        let tasks = Array(record.activeOperations.values)
        record.activeOperations.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func verifiedDisplayName(for pairedClientId: UUID, fallback: String) -> String {
        if trustStore.isAvailable, let client = trustStore.client(id: pairedClientId) {
            let cleaned = MCPAgentBridgeProtocol.cleanText(client.name, maxLength: 60)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return MCPAgentBridgeProtocol.cleanText(fallback, maxLength: 60)
    }

    private func parseAccess(_ raw: Any?) throws -> AgentWindowAccess {
        guard let raw else { return .control }
        guard let value = raw as? String, let access = AgentWindowAccess(rawValue: value.lowercased()) else {
            throw MCPAgentWindowError(.invalidParams, "access must be control, development, or developer.")
        }
        return access
    }

    private func resolveProfile(_ profileId: String?) throws -> Profile {
        let catalog = profileCatalog()
        guard let profileId, !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if trustStore.isAvailable,
               let devID = trustStore.developerProfileID,
               let devProfile = catalog.profiles.first(where: { $0.id == devID && !$0.isPrivate }) {
                return devProfile
            }
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
        for record in records.values where record.coordinator == nil || record.coordinator?.isClosed == true {
            teardown(record, clearCompanion: false, emitClosed: false)
        }
    }
}
