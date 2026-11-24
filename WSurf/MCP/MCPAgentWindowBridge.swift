// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Network
import Observation

/// Unix-domain NDJSON bridge (`host-bridge.sock`) allowing authenticated external hosts (e.g. T3 Code) to manage
/// detached Agent Micro Windows and receive real-time ownership/tab/close events.
@MainActor
@Observable
final class MCPAgentWindowBridge {
    private(set) var isListening = false
    private(set) var status: String?

    @ObservationIgnored let endpoint: String
    @ObservationIgnored let trustStore: MCPTrustStore
    @ObservationIgnored let registry: MCPAgentWindowRegistry
    @ObservationIgnored private let authTimeout: Duration
    @ObservationIgnored private var listener: LocalMCPListener?
    @ObservationIgnored private var connections: [UUID: BridgeClientConnection] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private static let maxConnections = 8

    init(
        endpoint: String = LocalMCPEndpoint.hostBridgePath,
        trustStore: MCPTrustStore = .shared,
        registry: MCPAgentWindowRegistry,
        authTimeout: Duration = .seconds(2)
    ) {
        self.endpoint = endpoint
        self.trustStore = trustStore
        self.registry = registry
        self.authTimeout = authTimeout
        registry.onEvent = { [weak self] pairedClientId, event, payload in
            self?.broadcastEvent(to: pairedClientId, event: event, payload: payload)
        }
        registry.onStopClient = { [weak self] pairedClientId in
            self?.disconnectConnections(clientID: pairedClientId)
        }
        trustStore.onChange { [weak self] in
            self?.enforceTrustStoreState()
        }
    }

    func start() {
        guard listener == nil else { return }
        status = nil
        let started = generation
        Task { [weak self] in
            guard let self, started == generation, listener == nil else { return }
            do {
                let listener = try LocalMCPListener(path: endpoint, lockName: "host-bridge.lock") { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                try await listener.start()
                guard started == generation else { return }
                isListening = true
            } catch {
                guard started == generation else { return }
                stop()
                status = "Could not start the host bridge."
            }
        }
    }

    func stop() {
        generation = UUID()
        isListening = false
        listener?.stop()
        listener = nil
        // Tear down all active window tokens and sessions so disabling MCP leaves no usable windowToken behind.
        registry.teardownAll()
        let active = Array(connections.values)
        connections.removeAll()
        for client in active {
            Task { await client.close() }
        }
    }

    func disconnect(clientID: UUID) {
        disconnectConnections(clientID: clientID)
        registry.revokeClient(clientID)
    }

    private func disconnectConnections(clientID: UUID) {
        let matching = connections.values.filter { $0.pairedClientId == clientID }
        for client in matching {
            connections.removeValue(forKey: client.id)
            Task { await client.close() }
        }
    }

    // MARK: - Private

    private func accept(_ rawConnection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            rawConnection.cancel()
            return
        }
        let connectionId = UUID()
        let client = BridgeClientConnection(
            id: connectionId,
            connection: rawConnection,
            authTimeout: authTimeout,
            onAuthenticate: { [weak self] line in
                self?.authenticate(connectionId: connectionId, line: line)
            },
            onRequest: { [weak self] line in
                await self?.handleRequest(connectionId: connectionId, line: line)
                    ?? MCPAgentBridgeProtocol.responseErrorLine(id: "", code: .cancelled, message: "Host bridge stopped.")
            },
            onClose: { [weak self] in
                self?.connectionDidClose(connectionId)
            }
        )
        connections[connectionId] = client
        Task { await client.start() }
    }

    private func authenticate(connectionId: UUID, line: Data) -> (pairedClientId: UUID, hostName: String)? {
        guard let hello = MCPAgentBridgeProtocol.parseHello(line) else {
            return nil
        }
        guard let paired = trustStore.authenticate(token: hello.token), !paired.paused else {
            return nil
        }
        // Always display the verified paired client name from `MCPTrustStore`, not the self-asserted hello string.
        let verifiedName = MCPAgentBridgeProtocol.cleanText(paired.name, maxLength: 60)
        let resolvedName = verifiedName.isEmpty ? "Agent" : verifiedName
        connections[connectionId]?.markAuthenticated(pairedClientId: paired.id, hostName: resolvedName)
        return (paired.id, resolvedName)
    }

    private func handleRequest(connectionId: UUID, line: Data) async -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return MCPAgentBridgeProtocol.responseErrorLine(id: "", code: .invalidRequest, message: "Malformed JSON request.")
        }
        let requestId: String
        if let id = object["id"] as? String {
            requestId = id
        } else if let id = object["id"] as? Int {
            requestId = String(id)
        } else {
            return MCPAgentBridgeProtocol.responseErrorLine(id: "", code: .invalidRequest, message: "Request id is required.")
        }
        guard let op = object["op"] as? String, !op.isEmpty else {
            return MCPAgentBridgeProtocol.responseErrorLine(id: requestId, code: .invalidRequest, message: "Request op is required.")
        }
        let params = object["params"] as? [String: Any] ?? [:]
        guard let client = connections[connectionId],
              let pairedClientId = client.pairedClientId,
              let hostName = client.hostName
        else {
            return MCPAgentBridgeProtocol.responseErrorLine(id: requestId, code: .unauthorized, message: "Not authenticated.")
        }
        guard let live = trustStore.client(id: pairedClientId), !live.paused else {
            disconnect(clientID: pairedClientId)
            return MCPAgentBridgeProtocol.responseErrorLine(id: requestId, code: .unauthorized, message: "Client trust was revoked or paused.")
        }
        trustStore.touch(pairedClientId)
        do {
            let result = try await dispatch(
                op: op,
                params: params,
                pairedClientId: pairedClientId,
                hostName: hostName
            )
            return MCPAgentBridgeProtocol.responseSuccessLine(id: requestId, result: result)
        } catch let error as MCPAgentWindowError {
            return MCPAgentBridgeProtocol.responseErrorLine(id: requestId, code: error.code, message: error.message)
        } catch {
            return MCPAgentBridgeProtocol.responseErrorLine(id: requestId, code: .internalError, message: error.localizedDescription)
        }
    }

    private func dispatch(
        op: String,
        params: [String: Any],
        pairedClientId: UUID,
        hostName: String
    ) async throws -> [String: Any] {
        switch op {
        case "openAgentWindow":
            return try await registry.openAgentWindow(
                pairedClientId: pairedClientId,
                hostName: hostName,
                params: params
            )
        case "closeAgentWindow":
            let threadId = params["threadId"] as? String
            let windowId: UUID?
            if let raw = params["windowId"] as? String, !raw.isEmpty {
                guard let parsed = UUID(uuidString: raw) else {
                    throw MCPAgentWindowError(.invalidParams, "windowId must be a valid UUID.")
                }
                windowId = parsed
            } else {
                windowId = nil
            }
            return try registry.closeAgentWindow(pairedClientId: pairedClientId, threadId: threadId, windowId: windowId)
        case "setOwner":
            guard let rawTabId = params["tabId"] as? String,
                  let tabId = UUID(uuidString: rawTabId),
                  let rawOwner = params["owner"] as? String,
                  let owner = AgentWindowOwner(rawValue: rawOwner)
            else {
                throw MCPAgentWindowError(.invalidParams, "setOwner requires valid tabId and owner (agent, human, or unclaimed).")
            }
            return try registry.setOwner(pairedClientId: pairedClientId, tabId: tabId, owner: owner)
        case "listTabs":
            return registry.listTabs(pairedClientId: pairedClientId, threadId: params["threadId"] as? String)
        case "invokePreview":
            return try await registry.invokePreview(
                pairedClientId: pairedClientId,
                hostName: hostName,
                params: params
            )
        default:
            throw MCPAgentWindowError(.unknownOperation, "Unknown operation: \(op).")
        }
    }

    private func broadcastEvent(to pairedClientId: UUID, event: String, payload: [String: Any]) {
        let targets = connections.values.filter { $0.pairedClientId == pairedClientId }
        guard !targets.isEmpty else { return }
        let line = MCPAgentBridgeProtocol.eventLine(name: event, payload: payload)
        for client in targets {
            Task { await client.enqueueSend(line) }
        }
    }

    private func connectionDidClose(_ connectionId: UUID) {
        let closedClient = connections.removeValue(forKey: connectionId)
        guard let pairedClientId = closedClient?.pairedClientId else { return }
        let stillConnected = connections.values.contains { $0.pairedClientId == pairedClientId }
        if !stillConnected {
            registry.cancelInFlightOperations(for: pairedClientId)
        }
    }

    private func enforceTrustStoreState() {
        for client in Array(connections.values) {
            guard let pairedClientId = client.pairedClientId else { continue }
            let live = trustStore.isAvailable ? trustStore.client(id: pairedClientId) : nil
            if live == nil || live?.paused == true {
                disconnect(clientID: pairedClientId)
            }
        }
    }
}

/// Manages one NDJSON Unix socket connection for `MCPAgentWindowBridge` with serialized writes and bounded concurrency.
private final class BridgeClientConnection: @unchecked Sendable {
    let id: UUID
    @MainActor private(set) var pairedClientId: UUID?
    @MainActor private(set) var hostName: String?

    private let io: BridgeSocketIO

    init(
        id: UUID,
        connection: NWConnection,
        authTimeout: Duration,
        onAuthenticate: @escaping @MainActor (Data) -> (pairedClientId: UUID, hostName: String)?,
        onRequest: @escaping @MainActor (Data) async -> Data,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.id = id
        io = BridgeSocketIO(
            connection: connection,
            authTimeout: authTimeout,
            onAuthenticate: onAuthenticate,
            onRequest: onRequest,
            onClose: onClose
        )
    }

    @MainActor func markAuthenticated(pairedClientId: UUID, hostName: String) {
        self.pairedClientId = pairedClientId
        self.hostName = hostName
    }

    func start() async {
        await io.start()
    }

    func enqueueSend(_ line: Data) async {
        await io.send(line)
    }

    func close() async {
        await io.close()
    }
}

private actor BridgeSocketIO {
    private static let maxInFlightRequests = 16

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "WSurf.mcp.hostBridge.connection")
    private let authTimeout: Duration
    private let onAuthenticate: @MainActor (Data) -> (pairedClientId: UUID, hostName: String)?
    private let onRequest: @MainActor (Data) async -> Data
    private let onClose: @MainActor () -> Void
    private var closed = false
    private var readerTask: Task<Void, Never>?
    private var requestTasks: [UUID: Task<Void, Never>] = [:]

    init(
        connection: NWConnection,
        authTimeout: Duration,
        onAuthenticate: @escaping @MainActor (Data) -> (pairedClientId: UUID, hostName: String)?,
        onRequest: @escaping @MainActor (Data) async -> Data,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.connection = connection
        self.authTimeout = authTimeout
        self.onAuthenticate = onAuthenticate
        self.onRequest = onRequest
        self.onClose = onClose
    }

    func start() async {
        do {
            try await waitForReady()
        } catch {
            await close()
            return
        }
        readerTask = Task { await readLoop() }
    }

    func send(_ line: Data) async {
        guard !closed else { return }
        try? await sendRaw(line)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        readerTask = nil
        for task in requestTasks.values {
            task.cancel()
        }
        requestTasks.removeAll()
        connection.cancel()
        await onClose()
    }

    private func readLoop() async {
        var framer = MCPMessageFramer()
        let firstLines: [Data]
        do {
            firstLines = try await readFirstBatchWithTimeout(framer: &framer)
        } catch {
            let failure = MCPAgentBridgeProtocol.helloFailureLine(
                code: .unauthorized,
                message: "Authentication timed out or failed."
            )
            try? await sendRaw(failure)
            await close()
            return
        }
        guard let helloLine = firstLines.first else {
            await close()
            return
        }
        let authenticated = await onAuthenticate(helloLine)
        guard authenticated != nil else {
            let failure = MCPAgentBridgeProtocol.helloFailureLine(
                code: .unauthorized,
                message: "Invalid or revoked pairing token."
            )
            try? await sendRaw(failure)
            await close()
            return
        }
        do {
            try await sendRaw(MCPAgentBridgeProtocol.helloSuccessLine())
        } catch {
            await close()
            return
        }

        for extra in firstLines.dropFirst() {
            dispatchRequest(extra)
        }

        do {
            while !closed, !Task.isCancelled {
                guard let chunk = try await readChunk() else { break }
                guard !chunk.isEmpty else { continue }
                for line in try framer.append(chunk) {
                    dispatchRequest(line)
                }
            }
        } catch {
        }
        await close()
    }

    private func readFirstBatchWithTimeout(framer: inout MCPMessageFramer) async throws -> [Data] {
        let timeoutTask = Task { [authTimeout] in
            try? await Task.sleep(for: authTimeout)
            if !Task.isCancelled {
                let failure = MCPAgentBridgeProtocol.helloFailureLine(
                    code: .unauthorized,
                    message: "Authentication timed out."
                )
                try? await self.sendRaw(failure)
                self.connection.cancel()
            }
        }
        defer { timeoutTask.cancel() }
        while !closed, !Task.isCancelled {
            guard let chunk = try await readChunk() else {
                throw MCPAgentWindowError(.unauthorized, "Connection closed before authentication.")
            }
            guard !chunk.isEmpty else { continue }
            let lines = try framer.append(chunk)
            if !lines.isEmpty {
                return lines
            }
        }
        throw CancellationError()
    }

    private func dispatchRequest(_ line: Data) {
        guard requestTasks.count < Self.maxInFlightRequests else {
            let requestId = Self.extractRequestID(from: line)
            let rejected = MCPAgentBridgeProtocol.responseErrorLine(
                id: requestId,
                code: .actionFailed,
                message: "Too many concurrent requests (max \(Self.maxInFlightRequests))."
            )
            Task { await self.send(rejected) }
            return
        }
        let taskId = UUID()
        let task = Task {
            let response = await onRequest(line)
            await finishRequest(taskId: taskId, response: response)
        }
        requestTasks[taskId] = task
    }

    private nonisolated static func extractRequestID(from line: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return ""
        }
        if let id = object["id"] as? String {
            return id
        }
        if let id = object["id"] as? Int {
            return String(id)
        }
        return ""
    }

    private func finishRequest(taskId: UUID, response: Data) async {
        requestTasks.removeValue(forKey: taskId)
        await send(response)
    }

    private func waitForReady() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error), .waiting(let error):
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    ready.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    ready.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func readChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { received in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                if let error {
                    received.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    received.resume(returning: data)
                } else if complete {
                    received.resume(returning: nil)
                } else {
                    received.resume(returning: Data())
                }
            }
        }
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    sent.resume(throwing: error)
                } else {
                    sent.resume()
                }
            })
        }
    }
}
