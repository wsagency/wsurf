// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Darwin
import Foundation
import MCP
import Network
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized)
struct MCPTransportTests {
    private final class RetainedWindows {
        var values: [ObjectIdentifier: NSWindow] = [:]
    }

    private let retainedWindows = RetainedWindows()

    private func registerNativeWindow(for browser: BrowserModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 700, height: 500),
            styleMask: [], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        browser.context.extensions.register(browser: browser, window: window)
        retainedWindows.values[ObjectIdentifier(browser)] = window
    }

    @Test func stagedHomesKeepPreferencesAndWebKitStoresSeparateAcrossRestarts() {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-stage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstHome = root.appending(path: "first")
        let secondHome = root.appending(path: "second")
        let restartedHome = root.appending(path: "unused").appending(path: "..").appending(path: "first")
        let firstSuite = StageMode.defaultsSuiteName(for: firstHome)
        let secondSuite = StageMode.defaultsSuiteName(for: secondHome)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: firstSuite)
            UserDefaults.standard.removePersistentDomain(forName: secondSuite)
        }

        let first = StageMode.defaults(for: firstHome)
        first.set("first stage", forKey: "isolation-test")
        let restartedFirst = StageMode.defaults(for: restartedHome)
        let second = StageMode.defaults(for: secondHome)

        #expect(restartedFirst.string(forKey: "isolation-test") == "first stage")
        #expect(second.string(forKey: "isolation-test") == nil)
        #expect(StageMode.dataStoreID(for: firstHome) == StageMode.dataStoreID(for: restartedHome))
        #expect(StageMode.dataStoreID(for: firstHome) != StageMode.dataStoreID(for: secondHome))
    }

    @Test func stagedMCPSocketsAreStableDistinctAndWithinUnixPathLimit() {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-stage-test-\(UUID().uuidString)")
        let firstHome = root.appending(path: "first")
        let secondHome = root.appending(path: "second")
        let first = LocalMCPEndpoint.stagePath(for: firstHome)
        let restartedFirst = LocalMCPEndpoint.stagePath(for: firstHome.appending(path: "..").appending(path: "first"))
        let second = LocalMCPEndpoint.stagePath(for: secondHome)

        #expect(first == restartedFirst)
        #expect(first != second)
        #expect(first.utf8.count < 104)
    }

    @Test func initializationIgnoresUnsupportedExtensionsAndPreservesStandardFields() throws {
        let request = Data(#"""
            {"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{
              "protocolVersion":"2025-06-18","capabilities":{
                "experimental":{"codex/auth-change":{},"future":{"enabled":true}},
                "elicitation":{"form":{},"url":{}},"roots":{"listChanged":true}},
              "clientInfo":{"name":"Codex","title":"Codex CLI","version":"1"},"_meta":{"fixture":true}}}
            """#.utf8)
        let expected = Data(#"""
            {"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{
              "protocolVersion":"2025-06-18","capabilities":{
                "elicitation":{"form":{},"url":{}},"roots":{"listChanged":true}},
              "clientInfo":{"name":"Codex","title":"Codex CLI","version":"1"},"_meta":{"fixture":true}}}
            """#.utf8)
        let actual = try JSONSerialization.jsonObject(with: MCPInitializationCompatibility.normalize(request))
        #expect((actual as? NSDictionary) == (try JSONSerialization.jsonObject(with: expected) as? NSDictionary))
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"initialize","capabilities":{"experimental":{"extension":{}}}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":[]}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":null}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":"extension"}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":null}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
        "[]", "invalid JSON",
    ])
    func initializationCompatibilityLeavesOtherMessagesUnchanged(_ request: String) {
        let message = Data(request.utf8)
        #expect(MCPInitializationCompatibility.normalize(message) == message)
    }

    @Test(.timeLimit(.minutes(1))) func localSocketAcceptsObjectValuedInitializationCapabilities() async throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let endpoint = directory + "/browser.sock"
        let server = MCP.Server(name: "WSurf fixture", version: "1")
        let listener = try LocalMCPListener(path: endpoint) { connection in
            Task {
                do {
                    try await server.start(transport: LocalMCPTransport(connection: connection))
                } catch {
                    Issue.record(error)
                }
            }
        }
        defer {
            listener.stop()
            Task { await server.stop() }
        }
        try await listener.start()
        let transport = LocalMCPTransport(connection: NWConnection(to: .unix(path: endpoint), using: .tcp))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        try await transport.send(Self.initializationRequest)
        var replies = await transport.receive().makeAsyncIterator()
        let reply = try #require(await replies.next())
        let object = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(object["id"] as? Int == 1)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "WSurf fixture")
    }

    @Test(.timeLimit(.minutes(1))) func relayAcceptsObjectValuedInitializationWithoutBrowserAccess() async throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        let pair = await InMemoryTransport.createConnectedPair()
        try await pair.server.connect()
        try await pair.client.connect()
        let relay = MCPStdioRelay(socketPath: directory + "/browser.sock")
        let running = Task { try await relay.run(transport: pair.server) }
        defer { Task { await pair.client.disconnect() } }
        try await pair.client.send(Self.initializationRequest)
        var replies = await pair.client.receive().makeAsyncIterator()
        let reply = try #require(await replies.next())
        let initialized = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(initialized["id"] as? Int == 1)
        #expect(initialized["result"] != nil)
        try await pair.client.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await pair.client.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
        let listing = try #require(await replies.next())
        let object = try #require(JSONSerialization.jsonObject(with: listing) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(MCPToolCatalog.entries.map(\.name)))
        #expect(!FileManager.default.fileExists(atPath: directory))
        await pair.client.disconnect()
        try await running.value
    }

    private static var initializationRequest: Data {
        Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","#
            + #""capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}},"roots":{"listChanged":true}},"#
            + #""clientInfo":{"name":"Stdio integration","title":"Codex","version":"1"}}}"#).utf8)
    }

    @Test(.timeLimit(.minutes(1))) func relayCanStartBeforeBrowserAndRecoverAfterItLaunches() async throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let endpoint = directory + "/browser.sock"
        let pair = await InMemoryTransport.createConnectedPair()
        try await pair.server.connect()
        let relay = MCPStdioRelay(socketPath: endpoint)
        let running = Task { try await relay.run(transport: pair.server) }
        defer { Task { await pair.client.disconnect() } }
        let client = MCP.Client(name: "Offline startup", version: "1")
        _ = try await client.connect(transport: pair.client)
        let (tools, _) = try await client.listTools()
        #expect(!tools.isEmpty)
        let (_, offline) = try await client.callTool(name: "listTabs")
        #expect(offline == true)
        let browser = BrowserModel(database: .temporary())
        registerNativeWindow(for: browser)
        let server = BrowserMCPServer(endpoint: endpoint, target: { browser }, available: { _ in true })
        defer { server.stop() }
        server.setEnabled(true)
        #expect(await waitUntil { server.isListening })
        let (_, recovered) = try await client.callTool(name: "listTabs")
        #expect(recovered == false)
        await client.disconnect()
        try await running.value
        #expect(await waitUntil { server.sessions.isEmpty })
    }

    @Test(.timeLimit(.minutes(1))) func relayFailsInterruptedActionsWithoutReplayingThem() async throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let endpoint = directory + "/browser.sock"
        let probe = SuspendedRelayCall()
        let backend = MCP.Server(name: "Fixture", version: "1", capabilities: .init(tools: .init()))
        await backend.withMethodHandler(CallTool.self) { _ in await probe.call() }
        var socket: LocalMCPTransport?
        let listener = try LocalMCPListener(path: endpoint) { connection in
            let transport = LocalMCPTransport(connection: connection)
            socket = transport
            Task {
                do {
                    try await backend.start(transport: transport)
                } catch {
                    Issue.record(error)
                    await transport.disconnect()
                }
            }
        }
        defer {
            listener.stop()
            Task { await probe.release(); await backend.stop() }
        }
        try await listener.start()
        let pair = await InMemoryTransport.createConnectedPair()
        try await pair.server.connect()
        let relay = MCPStdioRelay(socketPath: endpoint)
        let running = Task { try await relay.run(transport: pair.server) }
        defer { Task { await pair.client.disconnect() } }
        let client = MCP.Client(name: "Interrupted action", version: "1")
        _ = try await client.connect(transport: pair.client)
        let action = Task { try await client.callTool(name: "scrollPage", arguments: ["tabID": "fixture", "direction": "down"]) }
        #expect(await waitUntil { await probe.count == 1 })
        await socket?.disconnect()
        let (content, failed) = try await action.value
        #expect(failed == true)
        #expect(content.contains { if case .text(let text, _, _) = $0 { return text.contains("was not retried") }; return false })
        let (tools, _) = try await client.listTools()
        #expect(!tools.isEmpty)
        #expect(await probe.count == 1)
        await probe.release()
        await client.disconnect()
        try await running.value
    }

    @Test func enablementSurvivesShutdownAndExplicitDisablePersists() async throws {
        let name = "wsurf-mcp-preference-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let browser = BrowserModel(database: .temporary())
        let server = BrowserMCPServer(endpoint: directory + "/browser.sock", defaults: defaults, target: { browser }, available: { _ in true })
        #expect(!server.isEnabled)
        server.setEnabled(true)
        #expect(await waitUntil { server.isListening })
        server.stop()
        #expect(server.isEnabled)
        #expect(!server.isListening)

        let relaunched = BrowserMCPServer(endpoint: directory + "/browser.sock", defaults: defaults, target: { browser }, available: { _ in true })
        defer { relaunched.stop() }
        #expect(relaunched.isEnabled)
        relaunched.resume()
        #expect(await waitUntil { relaunched.isListening })
        relaunched.setEnabled(false)
        let disabled = BrowserMCPServer(defaults: defaults, target: { browser }, available: { _ in true })
        #expect(!disabled.isEnabled)
    }

    @Test func privateFocusDeniesNewConnectionsWithoutRetargetingExistingOnes() async throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let browser = BrowserModel(database: .temporary())
        let privateBrowser = BrowserModel(context: .shared(for: .privateBrowsing()), windowID: UUID())
        registerNativeWindow(for: browser)
        registerNativeWindow(for: privateBrowser)
        var target = browser
        let server = BrowserMCPServer(
            endpoint: directory + "/browser.sock",
            target: { target },
            available: { !$0.opensPrivately }
        )
        defer { server.stop() }
        server.setEnabled(true)
        #expect(await waitUntil { server.isListening })
        let client = MCP.Client(name: "Profile test", version: "1")
        let transport = LocalMCPTransport(connection: NWConnection(to: .unix(path: directory + "/browser.sock"), using: .tcp))
        _ = try await client.connect(transport: transport)
        let session = try #require(server.sessions.first)

        target = privateBrowser

        #expect(server.makeSessionForConnection() == nil)
        #expect(server.isEnabled)
        #expect(!server.isPaused)
        #expect(server.isListening)
        #expect(session.isConnected)
        #expect((try await session.call(name: "listTabs", arguments: [:])).isError == false)

        server.disconnect(browser: browser)
        #expect(!session.isConnected)
        #expect(server.sessions.isEmpty)
        target = browser
        #expect(server.makeSessionForConnection()?.isBound(to: browser) == true)
        await transport.disconnect()
    }

    @Test func partialAndCoalescedMessagesKeepTheirBoundaries() throws {
        var framer = MCPMessageFramer()
        #expect(try framer.append(Data("{\"id\":".utf8)).isEmpty)
        let messages = try framer.append(Data("1}\n{\"id\":2}\n\n".utf8))
        #expect(messages.map { String(decoding: $0, as: UTF8.self) } == ["{\"id\":1}", "{\"id\":2}"])
    }

    @Test func overlongMessagesAreRejectedBeforeDispatch() {
        var framer = MCPMessageFramer()
        #expect(throws: (any Error).self) {
            _ = try framer.append(Data(repeating: 65, count: MCPMessageFramer.maximumBytes + 1))
        }
        var complete = MCPMessageFramer()
        #expect(throws: (any Error).self) {
            _ = try complete.append(Data(repeating: 65, count: MCPMessageFramer.maximumBytes + 1) + Data([10]))
        }
    }

    @Test func argumentValidationRejectsCoercionAndUnknownFields() throws {
        let click = try #require(MCPToolCatalog.entries.first { $0.name == "clickOnPage" })
        #expect(throws: (any Error).self) {
            try click.validate(["tabID": "tab", "observationID": "observation", "ref": "1"])
        }
        #expect(throws: (any Error).self) {
            try click.validate(["tabID": "tab", "observationID": "observation", "ref": 1, "bypass": true])
        }
        #expect(throws: (any Error).self) {
            try click.validate(["tabID": "tab", "observationID": "observation", "ref": 0])
        }
    }
    @Test func fillFieldsContractAcceptsThirtyTwoControlsAndRejectsThirtyThree() throws {
        let fill = try #require(MCPToolCatalog.entries.first { $0.name == "fillFields" })
        let arguments: (Int) -> [String: Value] = { count in
            [
                "tabID": "tab", "observationID": "observation",
                "fields": .array((1...count).map {
                    .object(["ref": .int($0), "value": .string("value"), "select": .bool(false)])
                }),
            ]
        }
        try fill.validate(arguments(32))
        #expect(throws: (any Error).self) { try fill.validate(arguments(33)) }
        #expect(throws: (any Error).self) {
            try fill.validate([
                "tabID": "tab", "observationID": "observation",
                "fields": .array([.object(["ref": .int(1), "value": .string("v"), "select": .string("true")])]),
            ])
        }
    }
    @Test func fillFieldsSchemaKeepsSelectionBooleanAndCapsThirtyTwo() throws {
        let fill = try #require(MCPToolCatalog.entries.first { $0.name == "fillFields" })
        let data = try JSONEncoder().encode(fill.tool.inputSchema)
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let fields = try #require(properties["fields"] as? [String: Any])
        #expect(fields["maxItems"] as? Int == 32)
        let items = try #require(fields["items"] as? [String: Any])
        let itemProperties = try #require(items["properties"] as? [String: Any])
        let select = try #require(itemProperties["select"] as? [String: Any])
        #expect(select["type"] as? String == "boolean")
    }

    @Test func endpointRejectsInsecureDirectoriesAndCompetingListeners() throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(mkdir(directory, 0o755) == 0)
        #expect(throws: (any Error).self) {
            _ = try LocalMCPEndpoint.lockDirectory(directory)
        }
        #expect(chmod(directory, 0o700) == 0)
        let lock = try LocalMCPEndpoint.lockDirectory(directory)
        defer { close(lock) }
        #expect(throws: (any Error).self) {
            _ = try LocalMCPEndpoint.lockDirectory(directory)
        }
    }

    @Test func standardClientCanDiscoverToolsWithoutBrowserAccess() async throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        let endpoint = directory + "/browser.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let browser = BrowserModel(database: .temporary())
        registerNativeWindow(for: browser)
        let server = BrowserMCPServer(endpoint: endpoint, target: { browser }, available: { _ in true })
        defer { server.stop() }
        server.setEnabled(true)
        #expect(await waitUntil { server.isListening || server.status != nil })
        #expect(server.isListening, "\(server.status ?? "No status")")
        var info = stat()
        #expect(lstat(endpoint, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let client = MCP.Client(name: "Integration test", version: "1")
        let transport = LocalMCPTransport(connection: NWConnection(to: .unix(path: endpoint), using: .tcp))
        let initialized = try await client.connect(transport: transport)
        #expect(initialized.capabilities.tools != nil)
        let (tools, _) = try await client.listTools()
        #expect(Set(tools.map(\.name)) == Set(MCPToolCatalog.entries.map(\.name)))
        let (content, isError) = try await client.callTool(name: "listTabs")
        #expect(isError == false)
        #expect(content == [.text(text: "{\"tabs\":[]}", annotations: nil, _meta: nil)])
        #expect(await waitUntil { server.sessions.first?.clientName == "Integration test" })
        let session = try #require(server.sessions.first)
        server.stop()
        #expect(!session.isConnected)
        #expect(server.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: endpoint))
        await transport.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func bundledStdioRelaySurvivesBrowserRestartAndExitsOnEOF() async throws {
        let directory = "/tmp/wsurf-mcp-test-\(UUID().uuidString)"
        let endpoint = directory + "/browser.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let browser = BrowserModel(database: .temporary())
        registerNativeWindow(for: browser)
        let server = BrowserMCPServer(endpoint: endpoint, target: { browser }, available: { _ in true })
        defer { server.stop() }
        server.setEnabled(true)
        #expect(await waitUntil { server.isListening || server.status != nil })
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--mcp", "--mcp-socket", endpoint]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        let request = Self.initializationRequest
        try input.fileHandleForWriting.write(contentsOf: request.prefix(37))
        try input.fileHandleForWriting.write(contentsOf: request.dropFirst(37) + Data([10]))
        let (lines, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let read = Task.detached {
            var line = Data()
            do {
                for try await byte in output.fileHandleForReading.bytes {
                    if byte == 10 {
                        continuation.yield(line)
                        line = Data()
                    } else {
                        line.append(byte)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        defer { read.cancel() }
        var replies = lines.makeAsyncIterator()
        let reply = try #require(await replies.next())
        let object = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(object["id"] as? Int == 1)
        #expect(object["result"] != nil)
        let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let list = #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#
        try input.fileHandleForWriting.write(contentsOf: Data((initialized + "\n" + list + "\n").utf8))
        let listing = try #require(await replies.next())
        let listingObject = try #require(JSONSerialization.jsonObject(with: listing) as? [String: Any])
        #expect(listingObject["id"] as? Int == 10)
        let listingResult = try #require(listingObject["result"] as? [String: Any])
        let tools = try #require(listingResult["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(MCPToolCatalog.entries.map(\.name)))
        #expect(server.sessions.isEmpty)
        func send(_ id: Int, _ tool: String) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool],
            ])
            try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        }
        try send(2, "listTabs")
        let first = try #require(await replies.next())
        #expect(String(decoding: first, as: UTF8.self).contains("structuredContent"))
        let originalSession = try #require(server.sessions.first)
        #expect(originalSession.clientName == "Stdio integration")

        server.stop()
        #expect(!originalSession.isConnected)
        try send(3, "listTabs")
        let offline = try #require(await replies.next())
        #expect(String(decoding: offline, as: UTF8.self).contains("\"isError\":true"))
        #expect(process.isRunning)

        server.resume()
        #expect(await waitUntil { server.isListening })
        try send(4, "listTabs")
        let recovered = try #require(await replies.next())
        let recoveredObject = try #require(JSONSerialization.jsonObject(with: recovered) as? [String: Any])
        let result = try #require(recoveredObject["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect((structured["tabs"] as? [Any])?.isEmpty == true)
        let freshSession = try #require(server.sessions.first)
        #expect(freshSession.id != originalSession.id)
        #expect(freshSession.grants.isEmpty)
        #expect(freshSession.clientName == "Stdio integration")
        try await Task.sleep(for: .milliseconds(100))
        #expect(process.isRunning)
        try input.fileHandleForWriting.close()
        #expect(await waitUntil { !process.isRunning })
        #expect(process.terminationStatus == 0)
        #expect(await waitUntil { server.sessions.isEmpty })
    }
}

private actor SuspendedRelayCall {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func call() async -> CallTool.Result {
        count += 1
        await withCheckedContinuation { continuation = $0 }
        return CallTool.Result(content: [], isError: false)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
