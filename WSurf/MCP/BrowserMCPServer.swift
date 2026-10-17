// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

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
        /// Replaced once, when a paired client's hello moves it to the Developer window. The identity (`id`) stays.
        var session: MCPBrowserSession
        let task: Task<Void, Never>
    }

    private(set) var isEnabled = false
    private(set) var isListening = false
    private(set) var isPaused = false
    private(set) var status: String?
    private(set) var sessions: [MCPBrowserSession] = []
    /// The clients the user paired. Only this store can make a connection a paired one.
    @ObservationIgnored let trustStore: MCPTrustStore
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
        listener?.stop()
        listener = nil
        for id in Array(connections.keys) {
            disconnect(id)
        }
    }

    func disconnect(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.session.revoke()
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
    }

    func cancelActiveCall() {
        activeCall?.task.cancel()
    }

    /// - Parameters:
    ///   - browser: The window to bind to; the focused window when nil.
    ///   - id: The identity of the connection when this replaces a session of the same connection.
    func makeSessionForConnection(
        consent: @escaping (String, [MCPAccessConsent.Page], Bool, NSWindow?) async -> MCPAccessConsent.Access? = MCPAccessConsent.share,
        openConsent: @escaping (String, URL, NSWindow?) async -> Bool = MCPAccessConsent.open,
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
            }
        )
    }

    private func accept(_ connection: NWConnection) {
        guard isEnabled, connections.count < 8,
              let session = makeSessionForConnection() else {
            connection.cancel()
            return
        }
        let id = session.id
        let transport = LocalMCPTransport(connection: connection, onHello: { [weak self] token in
            await self?.pair(id, token: token)
        })
        let server = MCP.Server(
            name: "WSurf", version: "1.0.0",
            instructions: MCPToolCatalog.instructions,
            capabilities: .init(tools: .init()), configuration: .strict
        )
        let task = Task { [weak self] in
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: MCPToolCatalog.entries.map(\.tool))
            }
            await server.withMethodHandler(CallTool.self) { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.call(params, connectionID: id)
            }
            do {
                try await server.start(transport: transport) { [weak self] info, _ in
                    await MainActor.run {
                        self?.connections[id]?.session.clientName = String(
                            info.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
                    }
                }
                await server.waitUntilCompleted()
            } catch {
            }
            self?.disconnect(id)
        }
        connections[id] = Connection(server: server, transport: transport, session: session, task: task)
        sessions.append(session)
    }

    /// Binds the connection to the paired client that owns `token`; a missing, wrong or revoked token leaves it unpaired.
    /// The hello arrives before any MCP message, so a client with a standing grant moves to the Developer window while
    /// nothing has been shared yet.
    private func pair(_ id: UUID, token: String?) {
        guard let session = connections[id]?.session, let token, let client = trustStore.authenticate(token: token) else { return }
        session.pairedClient = client
        bindToDeveloperWindow(id, client: client)
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
