// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Logging
import MCP
import Network

actor LocalMCPTransport: Transport {
    nonisolated let logger = Logger(label: "WSurf.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "WSurf.mcp.connection")
    private let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var reader: Task<Void, Never>?
    private var connected = false
    private let onDisconnect: (@Sendable () async -> Void)?
    private let hello: Data?
    private let onHello: (@Sendable (String?) async -> Void)?
    private let helloTimeout: Duration

    var isConnected: Bool {
        connected
    }

    /// - Parameters:
    ///   - hello: A pairing hello to write right after connecting (the relay side).
    ///   - onHello: Called once, before any later message is delivered, when the connection starts with a hello
    ///     (the server side). Its token is nil when the hello carries no valid one. A connection that does not start
    ///     with a hello is not reported and reaches MCP unchanged.
    ///   - helloTimeout: How long a hello may take to arrive in full.
    init(
        connection: NWConnection,
        onDisconnect: (@Sendable () async -> Void)? = nil,
        hello: Data? = nil,
        onHello: (@Sendable (String?) async -> Void)? = nil,
        helloTimeout: Duration = .seconds(2)
    ) {
        self.connection = connection
        self.onDisconnect = onDisconnect
        self.hello = hello
        self.onHello = onHello
        self.helloTimeout = helloTimeout
        (messages, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }

    func connect() async throws {
        guard !connected else { return }
        connected = true
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
        if let hello {
            try await send(hello)
        }
        reader = Task { await readMessages() }
    }

    func disconnect() {
        let wasConnected = connected
        connected = false
        reader?.cancel()
        reader = nil
        connection.cancel()
        continuation.finish(throwing: MCPError.connectionClosed)
        if wasConnected, let onDisconnect {
            Task { await onDisconnect() }
        }
    }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPError.connectionClosed }
        var framed = data
        framed.append(10)
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    sent.resume(throwing: error)
                } else {
                    sent.resume()
                }
            })
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        messages
    }

    private func readMessages() async {
        var frames = MCPMessageFramer()
        var gate = onHello == nil ? nil : MCPHelloGate()
        var deadline: Task<Void, Never>?
        defer { deadline?.cancel() }
        do {
            while connected, !Task.isCancelled {
                guard var data = try await readChunk() else { break }
                guard !data.isEmpty else { continue }
                if let onHello, var pending = gate {
                    let outcome = pending.append(data)
                    gate = pending
                    switch outcome {
                    case .undecided:
                        deadline = deadline ?? Task { [helloTimeout] in
                            try? await Task.sleep(for: helloTimeout)
                            if !Task.isCancelled {
                                disconnect()
                            }
                        }
                        continue
                    case .rejected:
                        throw MCPError.invalidRequest("The pairing message is invalid.")
                    case .passthrough(let bytes):
                        data = bytes
                    case .hello(let token, let rest):
                        await onHello(token)
                        data = rest
                    }
                    gate = nil
                    deadline?.cancel()
                }
                for message in try frames.append(data) {
                    if case .dropped = continuation.yield(MCPInitializationCompatibility.normalize(message)) {
                        throw MCPError.invalidRequest("Too many pending messages.")
                    }
                }
            }
            continuation.finish(throwing: MCPError.connectionClosed)
        } catch {
            continuation.finish(throwing: error)
        }
        disconnect()
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
}

nonisolated struct MCPMessageFramer {
    static let maximumBytes = 262_144
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            guard pending.distance(from: pending.startIndex, to: newline) <= Self.maximumBytes else {
                throw MCPError.invalidRequest("Message is too large.")
            }
            let message = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if !message.isEmpty {
                messages.append(message)
            }
        }
        guard pending.count <= Self.maximumBytes else {
            throw MCPError.invalidRequest("Message is too large.")
        }
        return messages
    }
}
