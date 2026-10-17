// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Network
import Testing

@testable import WSurf

/// Pairing over a real Unix socket. Servers use in-memory trust storage and temporary socket directories.
@MainActor
@Suite(.serialized)
struct MCPPairingConnectionTests {
    private final class RetainedWindows {
        var values: [ObjectIdentifier: NSWindow] = [:]
    }

    private final class Running {
        let directory = "/tmp/wsurf-mcp-pairing-\(UUID().uuidString)"
        var endpoint: String { directory + "/browser.sock" }
        let browser = BrowserModel(database: .temporary())
        let windows = RetainedWindows()
        let storage: MemoryTrustStorage
        let trust: MCPTrustStore
        var server: BrowserMCPServer!

        init(storage: MemoryTrustStorage) {
            self.storage = storage
            trust = MCPTrustStore(storage: storage)
        }
    }

    private func start(storage: MemoryTrustStorage = MemoryTrustStorage(), defaults: UserDefaults? = nil) async throws -> Running {
        let running = Running(storage: storage)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 700, height: 500), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        running.browser.context.extensions.register(browser: running.browser, window: window)
        running.windows.values[ObjectIdentifier(running.browser)] = window
        let browser = running.browser
        running.server = BrowserMCPServer(
            endpoint: running.endpoint, defaults: defaults, trustStore: running.trust,
            target: { browser }, available: { _ in true }
        )
        running.server.setEnabled(true)
        try #require(await waitUntil { running.server.isListening })
        return running
    }

    private func stop(_ running: Running) {
        running.server.stop()
        running.browser.context.extensions.unregister(browser: running.browser)
        try? FileManager.default.removeItem(atPath: running.directory)
    }

    private func connect(
        _ running: Running, hello: String? = nil, name: String = "Pairing test"
    ) async throws -> (client: MCP.Client, transport: LocalMCPTransport) {
        let transport = LocalMCPTransport(
            connection: NWConnection(to: .unix(path: running.endpoint), using: .tcp),
            hello: hello.map { Data($0.utf8) }
        )
        let client = MCP.Client(name: name, version: "1")
        _ = try await client.connect(transport: transport)
        return (client, transport)
    }

    private func hello(_ token: String) -> String {
        String(decoding: MCPPairing.helloMessage(token: token) ?? Data(), as: UTF8.self)
    }

    // MARK: Server

    @Test(.timeLimit(.minutes(1))) func helloWithAValidTokenPairsTheConnection() async throws {
        let running = try await start()
        defer { stop(running) }
        let paired = try running.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        let connection = try await connect(running, hello: hello(SyntheticToken.first))
        defer { Task { await connection.transport.disconnect() } }
        let session = try #require(running.server.sessions.first)
        #expect(session.pairedClient?.id == paired.id)
        #expect(session.pairedClient?.name == "Claude Code")
        let (_, failed) = try await connection.client.callTool(name: "listTabs")
        #expect(failed == false)
        #expect(running.trust.client(id: paired.id)?.lastUsed != nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        "stranger", "missing", "malformed", "wrongVersion", "none",
    ])
    func wrongOrMissingTokenFallsBackToUnpairedAndMCPStillWorks(scenario: String) async throws {
        let running = try await start()
        defer { stop(running) }
        try running.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        let line: String? = switch scenario {
        case "stranger":
            hello(SyntheticToken.stranger)
        case "missing":
            #"{"wsurf":"hello","v":1}"#
        case "malformed":
            #"{"wsurf":"hello","v":1,"token":"not-a-token"}"#
        case "wrongVersion":
            #"{"wsurf":"hello","v":9,"token":"\#(SyntheticToken.first)"}"#
        default:
            nil
        }
        let connection = try await connect(running, hello: line)
        defer { Task { await connection.transport.disconnect() } }
        let session = try #require(running.server.sessions.first)
        #expect(session.pairedClient == nil)
        let (_, failed) = try await connection.client.callTool(name: "listTabs")
        #expect(failed == false)
        #expect(running.trust.clients.allSatisfy { $0.lastUsed == nil })
    }

    @Test(.timeLimit(.minutes(1))) func anUnavailableStoreLeavesEveryConnectionUnpaired() async throws {
        let running = try await start(storage: MemoryTrustStorage(refusesReads: true))
        defer { stop(running) }
        let connection = try await connect(running, hello: hello(SyntheticToken.first))
        defer { Task { await connection.transport.disconnect() } }
        #expect(running.server.sessions.first?.pairedClient == nil)
        #expect(!running.trust.isAvailable)
        #expect((try await connection.client.callTool(name: "listTabs")).isError == false)
    }

    @Test(.timeLimit(.minutes(1))) func revokeDisconnectsLiveSessionsAndInvalidatesTheToken() async throws {
        let running = try await start()
        defer { stop(running) }
        let revoked = try running.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        let other = try running.trust.pair(token: SyntheticToken.second, name: "Cursor", kind: .cursor)
        let first = try await connect(running, hello: hello(SyntheticToken.first))
        let second = try await connect(running, hello: hello(SyntheticToken.second))
        defer { Task { await first.transport.disconnect(); await second.transport.disconnect() } }
        try #require(await waitUntil { running.server.sessions.count == 2 })
        let firstSession = try #require(running.server.sessions.first { $0.pairedClient?.id == revoked.id })
        let secondSession = try #require(running.server.sessions.first { $0.pairedClient?.id == other.id })

        try running.server.revoke(revoked)

        #expect(!firstSession.isConnected)
        #expect(firstSession.pairedClient == nil)
        #expect(secondSession.isConnected)
        #expect(running.server.sessions.map(\.id) == [secondSession.id])
        #expect(running.trust.authenticate(token: SyntheticToken.first) == nil)
        #expect(running.trust.clients.map(\.id) == [other.id])
        // The revoked app reconnects with its old token and is just unpaired.
        let again = try await connect(running, hello: hello(SyntheticToken.first))
        defer { Task { await again.transport.disconnect() } }
        let newest = try #require(running.server.sessions.first { $0.id != secondSession.id })
        #expect(newest.pairedClient == nil)
    }

    @Test(.timeLimit(.minutes(1))) func rePairingStopsTheOldTokenAtOnce() async throws {
        let running = try await start()
        defer { stop(running) }
        let client = try running.trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        try running.trust.pair(token: SyntheticToken.second, name: "Codex", kind: .codex, replacing: client.id)
        let old = try await connect(running, hello: hello(SyntheticToken.first))
        let current = try await connect(running, hello: hello(SyntheticToken.second))
        defer { Task { await old.transport.disconnect(); await current.transport.disconnect() } }
        try #require(await waitUntil { running.server.sessions.count == 2 })
        #expect(running.server.sessions.filter { $0.pairedClient?.id == client.id }.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func defaultsWritesCannotCreateAPairing() async throws {
        let suite = "wsurf-mcp-pairing-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let forged = PairedClient(
            id: UUID(), name: "Forged", kindID: nil, tokenHash: MCPPairing.hash(SyntheticToken.first),
            created: Date(), standing: .developer
        )
        let document = try JSONEncoder().encode(["clients": [forged]])
        for key in ["mcp.pairedClients", "mcp.clients", "mcp.trust", "mcp.pairing"] {
            defaults.set(document, forKey: key)
            defaults.set(SyntheticToken.first, forKey: key + ".token")
        }
        let running = try await start(defaults: defaults)
        defer { stop(running) }
        let connection = try await connect(running, hello: hello(SyntheticToken.first))
        defer { Task { await connection.transport.disconnect() } }
        #expect(running.server.sessions.first?.pairedClient == nil)
        #expect(running.trust.clients.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func anOversizedHelloIsDroppedAndTheServerKeepsAcceptingConnections() async throws {
        let running = try await start()
        defer { stop(running) }
        let padding = String(repeating: "x", count: MCPHelloGate.maximumBytes)
        let transport = LocalMCPTransport(
            connection: NWConnection(to: .unix(path: running.endpoint), using: .tcp),
            hello: Data(#"{"wsurf":"hello","pad":"\#(padding)"}"#.utf8)
        )
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        try #require(await waitUntil { await !transport.isConnected })
        #expect(await waitUntil { running.server.sessions.isEmpty })
        let healthy = try await connect(running)
        defer { Task { await healthy.transport.disconnect() } }
        #expect((try await healthy.client.callTool(name: "listTabs")).isError == false)
    }

    // MARK: Transport

    @Test(.timeLimit(.minutes(1))) func aSlowHelloIsDroppedWhileOtherConnectionsKeepWorking() async throws {
        let directory = "/tmp/wsurf-mcp-pairing-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let endpoint = directory + "/browser.sock"
        var accepted: [LocalMCPTransport] = []
        let listener = try LocalMCPListener(path: endpoint) { connection in
            let transport = LocalMCPTransport(connection: connection, onHello: { _ in }, helloTimeout: .milliseconds(150))
            accepted.append(transport)
            let server = MCP.Server(name: "Fixture", version: "1")
            Task { try? await server.start(transport: transport) }
        }
        defer { listener.stop() }
        try await listener.start()

        let slow = NWConnection(to: .unix(path: endpoint), using: .tcp)
        defer { slow.cancel() }
        try await ready(slow)
        try await send(Data(#"{"wsurf":"hel"#.utf8), on: slow)
        try #require(await waitUntil { accepted.count == 1 })

        let healthy = MCP.Client(name: "Healthy", version: "1")
        let healthyTransport = LocalMCPTransport(connection: NWConnection(to: .unix(path: endpoint), using: .tcp))
        defer { Task { await healthyTransport.disconnect() } }
        _ = try await healthy.connect(transport: healthyTransport)

        #expect(await waitUntil { await accepted[0].isConnected == false })
        #expect(await accepted[1].isConnected)
    }

    @Test(.timeLimit(.minutes(1))) func aConnectionWithoutHelloReachesMCPUnchangedWhenTheServerListensForOne() async throws {
        let directory = "/tmp/wsurf-mcp-pairing-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let endpoint = directory + "/browser.sock"
        let recorder = HelloRecorder()
        let listener = try LocalMCPListener(path: endpoint) { connection in
            let transport = LocalMCPTransport(connection: connection, onHello: { await recorder.add($0) })
            let server = MCP.Server(name: "Fixture", version: "1")
            Task { try? await server.start(transport: transport) }
        }
        defer { listener.stop() }
        try await listener.start()
        let transport = LocalMCPTransport(connection: NWConnection(to: .unix(path: endpoint), using: .tcp))
        defer { Task { await transport.disconnect() } }
        let client = MCP.Client(name: "Unpaired", version: "1")
        _ = try await client.connect(transport: transport)
        #expect(await recorder.tokens.isEmpty)
    }

    // MARK: Relay

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func theRelayPresentsItsTokenOnlyInTheHelloLine(withToken: Bool) async throws {
        let directory = "/tmp/wsurf-mcp-pairing-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let endpoint = directory + "/browser.sock"
        let recorder = HelloRecorder()
        let backend = MCP.Server(name: "Fixture", version: "1", capabilities: .init(tools: .init()))
        await backend.withMethodHandler(CallTool.self) { _ in
            CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
        }
        let listener = try LocalMCPListener(path: endpoint) { connection in
            let transport = LocalMCPTransport(connection: connection, onHello: { await recorder.add($0) })
            Task { try? await backend.start(transport: transport) }
        }
        defer {
            listener.stop()
            Task { await backend.stop() }
        }
        try await listener.start()

        let pair = await InMemoryTransport.createConnectedPair()
        try await pair.server.connect()
        let relay = MCPStdioRelay(socketPath: endpoint, token: withToken ? SyntheticToken.first : nil)
        let running = Task { try await relay.run(transport: pair.server) }
        defer { Task { await pair.client.disconnect() } }
        let client = MCP.Client(name: "Relay client", version: "1")
        _ = try await client.connect(transport: pair.client)
        let (content, failed) = try await client.callTool(name: "listTabs")
        #expect(failed != true)
        #expect(content.contains { if case .text(let text, _, _) = $0 { return text == "ok" }; return false })
        #expect(await recorder.tokens == (withToken ? [SyntheticToken.first] : []))
        await client.disconnect()
        try await running.value
    }

    // MARK: Helpers

    private actor HelloRecorder {
        private(set) var tokens: [String?] = []

        func add(_ token: String?) {
            tokens.append(token)
        }
    }

    private func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error), .waiting(let error):
                    connection.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "WSurf.mcp.pairing.test"))
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
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
