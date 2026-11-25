// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Logging
import MCP
import Network

actor MCPStdioRelay {
    private let socketPath: String
    /// The client's pairing token. It goes only into the hello line on the socket.
    private let hello: Data?
    private var clientName = "External Connection"
    private var backend: (client: MCP.Client, transport: LocalMCPTransport)?
    /// The connect in progress, which concurrent calls wait for instead of opening a second socket.
    private var connecting: Task<Bool, Never>?
    private var stopped = false
    /// The tools this client sees and may call (`--tools`).
    nonisolated let profile: MCPToolCatalog.Profile

    init(socketPath: String, token: String? = nil, profile: MCPToolCatalog.Profile = .all) {
        self.socketPath = socketPath
        hello = token.flatMap(MCPPairing.helloMessage)
        self.profile = profile
    }

    func run(transport: any Transport) async throws {
        let server = MCP.Server(
            name: "WSurf", version: "1.0.0", instructions: MCPToolCatalog.instructions,
            capabilities: .init(tools: .init()), configuration: .strict
        )
        let profile = profile
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPToolCatalog.listed(for: profile).map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await self.call(params)
        }
        do {
            try await server.start(transport: MCPRelayInput(transport)) { info, _ in
                await self.setClientName(info.name)
            }
            await server.waitUntilCompleted()
        } catch {
            await stop()
            await server.stop()
            throw error
        }
        await stop()
        await server.stop()
    }

    private func setClientName(_ name: String) {
        clientName = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
    }

    private func stop() async {
        stopped = true
        let previous = backend
        backend = nil
        await previous?.client.disconnect()
    }

    private func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard !stopped else { throw MCPError.connectionClosed }
        guard let entry = MCPToolCatalog.listed(for: profile).first(where: { $0.name == params.name }) else {
            throw MCPError.invalidParams("Unknown tool.")
        }
        try entry.validate(params.arguments ?? [:])
        // Calls run side by side; WSurf orders those for one tab and refuses a flood.
        guard await connectedBackend() else {
            return failure("WSurf is unavailable. Open WSurf with MCP enabled, then retry. You do not need to restart the client.")
        }
        return try await send(params)
    }

    /// Whether a backend connection is up, connecting once for every call that needs it at the same time.
    private func connectedBackend() async -> Bool {
        if let backend, !(await backend.transport.isConnected), self.backend?.client === backend.client {
            self.backend = nil
            await backend.client.disconnect()
        }
        if backend != nil {
            return true
        }
        if let connecting {
            return await connecting.value
        }
        let task = Task { await self.connect() }
        connecting = task
        let connected = await task.value
        connecting = nil
        return connected
    }

    private func connect() async -> Bool {
        guard !stopped, !Task.isCancelled else { return false }
        if backend == nil {
            let client = MCP.Client(name: clientName, version: "1.0.0")
            let transport = LocalMCPTransport(
                connection: NWConnection(to: .unix(path: socketPath), using: .tcp),
                onDisconnect: { await client.disconnect() },
                hello: hello
            )
            do {
                try await withTaskCancellationHandler {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { _ = try await client.connect(transport: transport) }
                        group.addTask {
                            try await Task.sleep(for: .seconds(5))
                            await transport.disconnect()
                            await client.disconnect()
                            throw MCPError.connectionClosed
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                } onCancel: {
                    Task {
                        await transport.disconnect()
                        await client.disconnect()
                    }
                }
                guard !stopped, !Task.isCancelled else { throw CancellationError() }
                // Published only once connected: a call that arrives meanwhile waits for `connecting`.
                backend = (client, transport)
            } catch {
                await client.disconnect()
                await transport.disconnect()
                return false
            }
        }
        return backend != nil
    }

    private func send(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        guard let backend else { throw MCPError.connectionClosed }
        let request: RequestContext<CallTool.Result>
        do {
            request = try await backend.client.send(CallTool.request(params))
        } catch {
            return await interrupted(backend)
        }
        do {
            return try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                // Only this request ends: WSurf is told to cancel it, and the connection, its grants and secrets, and the calls
                // running beside it stay as they are.
                Task { try? await backend.client.cancelRequest(request.requestID, reason: "The client cancelled the call.") }
            }
        } catch {
            // The client's own cancel gets no reply; a backend that went away (its pending requests end as cancelled too) does.
            if Task.isCancelled {
                throw CancellationError()
            }
            return await interrupted(backend)
        }
    }

    /// The backend failed under a call: it is dropped, and the next call reconnects with no access.
    private func interrupted(_ backend: (client: MCP.Client, transport: LocalMCPTransport)) async -> CallTool.Result {
        if self.backend?.client === backend.client {
            self.backend = nil
        }
        await backend.client.disconnect()
        return failure("""
            The WSurf connection was interrupted. The operation may have completed; it was not retried. \
            On your next call WSurf will reconnect with no shared tabs. Request access again, then check the page before repeating an action.
            """)
    }

    private func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

private actor MCPRelayInput: Transport {
    nonisolated let logger = Logger(label: "WSurf.mcp.relay", factory: { _ in SwiftLogNoOpLogHandler() })
    private let upstream: any Transport
    private let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var reader: Task<Void, Never>?

    init(_ upstream: any Transport) {
        self.upstream = upstream
        (messages, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }

    func connect() async throws {
        try await upstream.connect()
        reader = Task {
            do {
                for try await message in await upstream.receive() {
                    guard message.count <= MCPMessageFramer.maximumBytes else {
                        throw MCPError.invalidRequest("Message is too large.")
                    }
                    if case .dropped = continuation.yield(MCPInitializationCompatibility.normalize(message)) {
                        throw MCPError.invalidRequest("Too many pending messages.")
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        reader?.cancel()
        reader = nil
        continuation.finish()
        await upstream.disconnect()
    }

    func send(_ data: Data) async throws {
        try await upstream.send(data)
    }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        messages
    }
}
