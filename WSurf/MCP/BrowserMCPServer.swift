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
        let session: MCPBrowserSession
        let task: Task<Void, Never>
    }

    private(set) var isEnabled = false
    private(set) var isListening = false
    private(set) var isPaused = false
    private(set) var status: String?
    private(set) var sessions: [MCPBrowserSession] = []
    @ObservationIgnored private let target: () -> BrowserModel?
    @ObservationIgnored private let available: (BrowserModel) -> Bool
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
        target: @escaping () -> BrowserModel?,
        available: @escaping (BrowserModel) -> Bool
    ) {
        self.endpoint = endpoint
        self.defaults = defaults
        self.target = target
        self.available = available
        isEnabled = defaults?.bool(forKey: "mcp.enabled") ?? false
    }

    func disconnect(browser: BrowserModel) {
        for session in sessions where session.isBound(to: browser) {
            disconnect(session.id)
        }
    }

    var configuration: String {
        let command = MCPClientConfiguration.command
        let value: [String: Any] = ["mcpServers": ["wsurf": ["command": command, "args": ["--mcp"]]]]
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

    func cancelActiveCall() {
        activeCall?.task.cancel()
    }

    func makeSessionForConnection(
        consent: @escaping (String, [MCPAccessConsent.Page], NSWindow?) async -> MCPAccessConsent.Access? = MCPAccessConsent.share,
        openConsent: @escaping (String, URL, NSWindow?) async -> Bool = MCPAccessConsent.open
    ) -> MCPBrowserSession? {
        guard let browser = target(), !browser.opensPrivately, !browser.context.profile.isPrivate,
              available(browser) else { return nil }
        let context = browser.context
        let adapter = context.extensions.adapter(for: browser)
        let nativeWindow = adapter?.nativeWindow
        let available = available
        return MCPBrowserSession(
            browser: browser,
            available: { [weak browser, weak context, weak adapter] in
                guard let browser, let context, let adapter, browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow else { return false }
                return available(browser)
            },
            consent: { [weak browser, weak context, weak adapter] client, pages in
                guard let browser, let context, let adapter, let nativeWindow,
                      browser.context === context,
                      context.extensions.adapter(for: browser) === adapter,
                      adapter.nativeWindow === nativeWindow,
                      available(browser)
                else { return nil }
                let answer = await consent(client, pages, nativeWindow)
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
        let transport = LocalMCPTransport(connection: connection)
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
                return try await self.call(params, session: session)
            }
            do {
                try await server.start(transport: transport) { info, _ in
                    await MainActor.run {
                        session.clientName = String(info.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
                    }
                }
                await server.waitUntilCompleted()
            } catch {
            }
            self?.disconnect(session.id)
        }
        connections[session.id] = Connection(server: server, transport: transport, session: session, task: task)
        sessions.append(session)
    }

    private func call(_ params: CallTool.Parameters, session: MCPBrowserSession) async throws -> CallTool.Result {
        guard isEnabled, connections[session.id] != nil else { throw MCPError.connectionClosed }
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
