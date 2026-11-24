// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import MCP
import Network
import Observation

@MainActor
@Observable
final class BrowserMCPServer {
    private struct Connection {
        let server: MCP.Server
        let transport: LocalMCPTransport
        /// Replaced once, when a paired client's hello moves it to the Developer window or an Agent Micro Window.
        /// Nil briefly while a window-scope-only connection awaits its hello handshake.
        var session: MCPBrowserSession?
        let task: Task<Void, Never>
    }

    private(set) var isEnabled = false
    private(set) var isListening = false
    private(set) var isPaused = false
    private(set) var status: String?
    private(set) var sessions: [MCPBrowserSession] = []
    /// The clients the user paired. Only this store can make a connection a paired one.
    @ObservationIgnored let trustStore: MCPTrustStore
    /// Logs of connections that ended, newest last, so Agent Activity still shows what they did. Memory only.
    private(set) var endedLogs: [ExternalActivityLog] = []
    static let endedLogLimit = 8
    @ObservationIgnored private let target: () -> BrowserModel?
    @ObservationIgnored private let available: (BrowserModel) -> Bool
    /// The window of the Developer profile with this ID, opened behind other windows if none exists. Never activates WSurf.
    @ObservationIgnored private let developerTarget: ((UUID) -> BrowserModel?)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let endpoint: String
    @ObservationIgnored private var listener: LocalMCPListener?
    @ObservationIgnored private var connections: [UUID: Connection] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var activeCall: (id: UUID, sessionID: UUID, task: Task<CallTool.Result, any Error>)?
    /// Registry of detached Agent Micro Windows addressable exclusively via `windowToken`.
    @ObservationIgnored var agentWindowRegistry: MCPAgentWindowRegistry?
    /// External host bridge (`host-bridge.sock`) started and stopped alongside `browser.sock`.
    @ObservationIgnored var hostBridge: MCPAgentWindowBridge?

    static var appDefaults: UserDefaults {
        #if DEBUG
        StageMode.defaults
        #else
        .standard
        #endif
    }

    init(
        endpoint: String = LocalMCPEndpoint.path,
        defaults: UserDefaults? = nil,
        trustStore: MCPTrustStore = .shared,
        target: @escaping () -> BrowserModel?,
        available: @escaping (BrowserModel) -> Bool,
        developerTarget: ((UUID) -> BrowserModel?)? = nil
    ) {
        self.endpoint = endpoint
        self.defaults = defaults
        self.trustStore = trustStore
        self.target = target
        self.available = available
        self.developerTarget = developerTarget
        isEnabled = defaults?.bool(forKey: "mcp.enabled") ?? false
        // Pausing a client, lowering its level, or changing the developer sites or profile takes effect on live connections.
        trustStore.onChange { [weak self] in
            self?.sessions.forEach { $0.refreshStanding() }
        }
    }

    func disconnect(browser: BrowserModel) {
        for session in sessions where session.isBound(to: browser) {
            disconnect(session.id)
        }
    }

    /// The connections bound to `browser`'s window, granted or not.
    func sessions(in browser: BrowserModel) -> [MCPBrowserSession] {
        sessions.filter { $0.isBound(to: browser) }
    }

    /// The connections bound to `browser`'s window that can act in it. The window's badge shows exactly these.
    func controllers(in browser: BrowserModel) -> [MCPBrowserSession] {
        sessions(in: browser).filter(\.isControlling)
    }

    /// The connections bound to `browser`'s window that hold a grant for `tab`. The tab's AI mark names exactly these.
    func controllers(of tab: BrowserTab, in browser: BrowserModel) -> [MCPBrowserSession] {
        sessions(in: browser).filter { $0.isConnected && $0.grants[tab.id] != nil }
    }

    /// The person takes `tab` back from every connection that holds it. A call one of them runs on the tab is cancelled;
    /// each keeps its other tabs. See `MCPBrowserSession.handBack(_:)`.
    func takeOver(_ tab: BrowserTab, in browser: BrowserModel) {
        for session in controllers(of: tab, in: browser) {
            if activeCall?.sessionID == session.id, tab.processState.isExternalAutomationWorking {
                activeCall?.task.cancel()
            }
            session.handBack(tab)
        }
    }

    /// `stop(window:)` for only the connections that hold `tab`; the window's other connections keep working.
    @discardableResult
    func stop(controllersOf tab: BrowserTab, in browser: BrowserModel) -> Int {
        stop(controllers(of: tab, in: browser), in: browser)
    }

    /// The kill switch. Ends every connection bound to `browser`'s window: each loses its grants, development leases and
    /// remembered approvals, its running call is cancelled, and its socket closes. A client that reconnects starts with no
    /// access and has to ask the user again; a paired app that had a standing grant is also paused, so its next call does
    /// not get the grant back until the user resumes it in Connected apps. Other windows' connections are untouched.
    /// Returns how many were ended.
    @discardableResult
    func stop(window browser: BrowserModel) -> Int {
        stop(sessions(in: browser), in: browser)
    }

    private func stop(_ ending: [MCPBrowserSession], in browser: BrowserModel) -> Int {
        // An app that works without asking, or opens websites under the Website access default, is paused: either would
        // otherwise come back the moment it reconnects.
        let followsDefault = MCPDefaultAccess.level(in: browser, trust: trustStore) == .control
        for id in Set(ending.compactMap { $0.pairedClient?.id })
        where trustStore.client(id: id).map({ $0.standing != .off || followsDefault }) == true {
            // Best effort: if the keychain write fails the app keeps its standing level, which Connected apps still shows.
            try? trustStore.setPaused(true, for: id)
        }
        for session in ending {
            session.recordStop()
            disconnect(session.id)
        }
        return ending.count
    }

    /// Logs that show activity on `tabID`, live connections first.
    func activityLogs(forTab tabID: UUID) -> [ExternalActivityLog] {
        (endedLogs + sessions.map(\.activity)).filter { !$0.entries(forTab: tabID).isEmpty }
    }

    var configuration: String {
        render(token: nil)
    }

    /// The JSON configuration to paste into a client, which also sets the pairing token of an app WSurf just paired.
    func configuration(pairedWith token: String) -> String {
        render(token: token)
    }

    private func render(token: String?) -> String {
        var entry: [String: Any] = ["command": MCPClientConfiguration.command, "args": MCPClientConfiguration.arguments]
        if let token { entry["env"] = [MCPPairing.environmentName: token] }
        let value: [String: Any] = ["mcpServers": ["wsurf": entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults?.set(enabled, forKey: "mcp.enabled")
        if !enabled {
            stop()
            return
        }
        resume()
    }

    func resume() {
        isPaused = false
        guard isEnabled, listener == nil else { return }
        status = nil
        let started = generation
        Task { [weak self] in
            guard let self, started == generation, isEnabled, listener == nil else { return }
            do {
                let listener = try LocalMCPListener(path: endpoint) { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                try await listener.start()
                guard started == generation, isEnabled else { return }
                isListening = true
                hostBridge?.start()
            } catch {
                guard started == generation else { return }
                stop()
                status = String(localized: "Couldn’t start the MCP server. Another copy of WSurf may be using the connection.")
            }
        }
    }

    func stop() {
        generation = UUID()
        isListening = false
        isPaused = false
        status = nil
        hostBridge?.stop()
        listener?.stop()
        listener = nil
        for id in Array(connections.keys) {
            disconnect(id)
        }
    }

    func disconnect(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        if let session = connection.session {
            retire(session.activity)
            session.revoke()
        }
        connection.task.cancel()
        sessions.removeAll { $0.id == id }
        if activeCall?.sessionID == id {
            activeCall?.task.cancel()
        }
        Task {
            await connection.server.stop()
            await connection.transport.disconnect()
        }
    }

    /// Forgets a paired client and disconnects its live connections, so its token and any access it held end now.
    func revoke(_ client: PairedClient) throws {
        try trustStore.revoke(client.id)
        for session in sessions where session.pairedClient?.id == client.id {
            disconnect(session.id)
        }
        hostBridge?.disconnect(clientID: client.id)
        agentWindowRegistry?.revokeClient(client.id)
    }

    func cancelActiveCall() {
        activeCall?.task.cancel()
    }

    func cancelActiveCall(in browser: BrowserModel) {
        guard let active = activeCall,
              let session = connections[active.sessionID]?.session,
              session.isBound(to: browser)
        else {
            return
        }
        active.task.cancel()
    }

    private func retire(_ log: ExternalActivityLog) {
        endedLogs.removeAll { $0.entries.isEmpty }
        endedLogs.append(log)
        if endedLogs.count > Self.endedLogLimit {
            endedLogs.removeFirst(endedLogs.count - Self.endedLogLimit)
        }
    }

    /// - Parameters:
    ///   - browser: The window to bind to; the focused window when nil.
    ///   - id: The identity of the connection when this replaces a session of the same connection.
    func makeSessionForConnection(
        consent: @escaping (String, [MCPAccessConsent.Page], Bool, NSWindow?) async -> MCPAccessConsent.Access? = MCPAccessConsent.share,
        openConsent: @escaping (String, URL, NSWindow?) async -> Bool = MCPAccessConsent.open,
        sensitiveConsent: @escaping (String, URL, NSWindow?) async -> Bool = MCPAccessConsent.useSensitivePage,
        browser requested: BrowserModel? = nil,
        id: UUID = UUID()
    ) -> MCPBrowserSession? {
        guard let browser = requested ?? target(), !browser.opensPrivately, !browser.context.profile.isPrivate,
              available(browser) else { return nil }
        let context = browser.context
        let adapter = context.extensions.adapter(for: browser)
        let nativeWindow = adapter?.nativeWindow
        let available = available
        return MCPBrowserSession(
            browser: browser,
            id: id,
            trust: trustStore,
            available: { [weak browser, weak context, weak adapter] in
                guard let browser, let context, let adapter, browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow else { return false }
                return available(browser)
            },
            consent: { [weak browser, weak context, weak adapter] client, pages, development in
                guard let browser, let context, let adapter, let nativeWindow,
                      browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow,
                      available(browser)
                else { return nil }
                let answer = await consent(client, pages, development, nativeWindow)
                guard browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow,
                      available(browser)
                else { return nil }
                return answer
            },
            openConsent: { [weak browser, weak context, weak adapter] client, url in
                guard let browser, let context, let adapter, let nativeWindow,
                      browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow,
                      available(browser)
                else { return false }
                let approved = await openConsent(client, url, nativeWindow)
                guard browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow,
                      available(browser)
                else { return false }
                return approved
            },
            sensitiveConsent: { [weak browser, weak context, weak adapter] client, url in
                guard let browser, let context, let adapter, let nativeWindow,
                      browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow,
                      available(browser)
                else { return false }
                let approved = await sensitiveConsent(client, url, nativeWindow)
                guard browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow,
                      available(browser)
                else { return false }
                return approved
            }
        )
    }

    /// Creates a pre-approved MCP session bound strictly to an Agent Micro Window via `scope`.
    func makeAgentWindowSession(
        for coordinator: AppCoordinator,
        scope: MCPAgentWindowScope,
        pairedClient: PairedClient?,
        id: UUID = UUID()
    ) -> MCPBrowserSession? {
        let browser = coordinator.browser
        guard !coordinator.isClosed, !browser.opensPrivately, !browser.context.profile.isPrivate,
              coordinator.isAgentMicro, scope.isActive()
        else {
            return nil
        }
        let session = MCPBrowserSession(
            browser: browser,
            id: id,
            trust: trustStore,
            available: { [weak coordinator, weak scope] in
                guard let coordinator, let scope, !coordinator.isClosed, coordinator.isAgentMicro,
                      !coordinator.profiles.isPrivate, !coordinator.isSwitchingProfile
                else {
                    return false
                }
                return scope.isActive()
            },
            consent: { _, _, _ in nil },
            openConsent: { _, _ in false },
            sensitiveConsent: { _, _ in false }
        )
        session.pairedClient = pairedClient
        session.agentWindowScope = scope
        session.syncAgentWindowGrants()
        return session
    }

    private func accept(_ connection: NWConnection) {
        guard isEnabled, connections.count < 8 else {
            connection.cancel()
            return
        }
        let initialSession = makeSessionForConnection()
        let requiresWindowScope = initialSession == nil
        guard initialSession != nil || agentWindowRegistry?.hasActiveWindows == true else {
            connection.cancel()
            return
        }
        let id = initialSession?.id ?? UUID()
        let transport = LocalMCPTransport(
            connection: connection,
            onHelloScope: { [weak self] token, windowScope in
                await self?.pair(id, token: token, windowScope: windowScope, requiresWindowScope: requiresWindowScope) ?? false
            },
            requiresWindowScope: requiresWindowScope
        )
        let server = MCP.Server(
            name: "WSurf", version: "1.0.0",
            instructions: MCPToolCatalog.instructions,
            capabilities: .init(tools: .init()), configuration: .strict
        )
        let task = Task { [weak self] in
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: MCPToolCatalog.listed.map(\.tool))
            }
            await server.withMethodHandler(CallTool.self) { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.call(params, connectionID: id)
            }
            do {
                try await server.start(transport: transport) { [weak self] info, _ in
                    await MainActor.run {
                        self?.connections[id]?.session?.clientName = String(
                            info.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
                    }
                }
                await server.waitUntilCompleted()
            } catch {
            }
            self?.disconnect(id)
        }
        connections[id] = Connection(server: server, transport: transport, session: initialSession, task: task)
        if let initialSession {
            sessions.append(initialSession)
        }
    }

    /// Binds the connection to the paired client that owns `token`, and when `windowToken` is present binds it
    /// exclusively to that Agent Micro Window (rejecting invalid `windowToken` without falling back to regular windows).
    private func pair(_ id: UUID, token: String?, windowScope: MCPWindowScopeHello, requiresWindowScope: Bool) -> Bool {
        if case .requested(let windowToken) = windowScope {
            guard let token,
                  let client = trustStore.authenticate(token: token),
                  !client.paused,
                  let windowToken,
                  let resolved = agentWindowRegistry?.resolve(windowToken: windowToken, pairedClientId: client.id),
                  let scopedSession = makeAgentWindowSession(
                      for: resolved.coordinator,
                      scope: resolved.scope,
                      pairedClient: client,
                      id: id
                  )
            else {
                disconnect(id)
                return false
            }
            let previous = connections[id]?.session
            connections[id]?.session = scopedSession
            if let previous, let index = sessions.firstIndex(where: { $0 === previous }) {
                sessions[index] = scopedSession
                previous.revoke()
            } else {
                sessions.append(scopedSession)
            }
            return true
        }
        guard !requiresWindowScope else {
            disconnect(id)
            return false
        }
        guard let session = connections[id]?.session, let token, let client = trustStore.authenticate(token: token) else {
            return true
        }
        session.pairedClient = client
        bindToDeveloperWindow(id, client: client)
        return true
    }

    /// A paired client that may work without asking lives in a window of the Developer profile, so it never touches the
    /// everyday profile's sign-ins. Unpaired clients and clients at Off keep the window they connected to.
    private func bindToDeveloperWindow(_ id: UUID, client: PairedClient) {
        guard let current = connections[id]?.session, current.completedCalls == 0, current.grants.isEmpty,
              MCPDeveloperAccess.standingAccess(for: client, trust: trustStore) != nil,
              let profileID = trustStore.developerProfileID,
              let browser = developerTarget?(profileID), !current.isBound(to: browser),
              let replacement = makeSessionForConnection(browser: browser, id: id)
        else { return }
        replacement.pairedClient = client
        connections[id]?.session = replacement
        if let index = sessions.firstIndex(where: { $0 === current }) {
            sessions[index] = replacement
        }
        current.revoke()
    }

    private func call(_ params: CallTool.Parameters, connectionID: UUID) async throws -> CallTool.Result {
        guard isEnabled, let session = connections[connectionID]?.session else { throw MCPError.connectionClosed }
        if let client = session.pairedClient {
            trustStore.touch(client.id)
        }
        guard activeCall == nil else {
            return CallTool.Result(content: [.text(text: "Another external operation is running. Wait for its result.", annotations: nil, _meta: nil)], isError: true)
        }
        let id = UUID()
        let task = Task { try await session.call(name: params.name, arguments: params.arguments ?? [:]) }
        activeCall = (id, session.id, task)
        defer {
            if activeCall?.id == id {
                activeCall = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
