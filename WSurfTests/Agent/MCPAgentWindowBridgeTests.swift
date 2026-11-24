// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Darwin
import Foundation
import Network
import Testing

@testable import WSurf

/// End-to-end tests for the external host bridge (`host-bridge.sock`) over real Unix domain sockets:
/// NDJSON framing, hello authentication, `openAgentWindow`, `listTabs`, `setOwner`, `invokePreview`
/// (including `agentMismatch`, `humanControl`, `staleGeneration`, sensitive-field redaction), push events,
/// and `closeAgentWindow`.
@MainActor
@Suite(.serialized, .boundedWebViews, .noAnnouncePause)
struct MCPAgentWindowBridgeTests {
    /// Minimal NDJSON client over a real Unix domain socket (transport on actor, JSON decoding on MainActor).
    private actor BridgeSocketClient {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "WSurf.mcp.hostBridge.testClient")
        private var framer = MCPMessageFramer()
        private var queuedLines: [Data] = []
        private var closed = false

        init(socketPath: String) {
            connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        }

        func connect() async throws {
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

        func sendRaw(_ data: Data) async throws {
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

        func nextLine() async throws -> Data {
            while queuedLines.isEmpty {
                guard let chunk = try await readChunk() else {
                    closed = true
                    throw MCPAgentWindowError(.cancelled, "EOF")
                }
                guard !chunk.isEmpty else { continue }
                queuedLines.append(contentsOf: try framer.append(chunk))
            }
            return queuedLines.removeFirst()
        }

        func close() {
            closed = true
            connection.cancel()
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

    @MainActor
    private final class BridgeClient {
        private let socket: BridgeSocketClient

        init(socketPath: String) {
            socket = BridgeSocketClient(socketPath: socketPath)
        }

        func connect() async throws {
            try await socket.connect()
        }

        func sendRaw(_ data: Data) async throws {
            try await socket.sendRaw(data)
        }

        func sendJSON(_ object: [String: Any]) async throws {
            try await socket.sendRaw(MCPAgentBridgeProtocol.encodeLine(object))
        }

        func nextMessage() async throws -> [String: Any] {
            let line = try await socket.nextLine()
            guard let object = (try JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw MCPAgentWindowError(.invalidRequest, "Non-object JSON line")
            }
            return object
        }

        func request(id: String, op: String, params: [String: Any] = [:]) async throws -> (response: [String: Any], events: [[String: Any]]) {
            try await sendJSON(["id": id, "op": op, "params": params])
            var events: [[String: Any]] = []
            while true {
                let message = try await nextMessage()
                if message["event"] != nil {
                    events.append(message)
                    continue
                }
                if message["id"] as? String == id {
                    return (message, events)
                }
            }
        }

        func waitForEvent(named name: String, maxMessages: Int = 8) async throws -> [String: Any] {
            for _ in 0..<maxMessages {
                let message = try await nextMessage()
                if message["event"] as? String == name {
                    return message
                }
            }
            throw MCPAgentWindowError(.timedOut, "Did not receive event \(name)")
        }

        func close() async {
            await socket.close()
        }
    }

    private struct Harness {
        let directory: String
        let bridgeEndpoint: String
        let mcpEndpoint: String
        let app: BrowserApplication
        let trust: MCPTrustStore
        let registry: MCPAgentWindowRegistry
        let bridge: MCPAgentWindowBridge
        let server: BrowserMCPServer
    }

    private func startHarness(authTimeout: Duration = .seconds(2)) async throws -> Harness {
        let directory = "/tmp/wsurf-bridge-\(UUID().uuidString)"
        let mcpEndpoint = directory + "/browser.sock"
        let bridgeEndpoint = directory + "/host-bridge.sock"
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        let server = BrowserMCPServer(
            endpoint: mcpEndpoint,
            trustStore: trust,
            target: { [weak app] in app?.activeBrowsingCoordinator?.browser },
            available: { _ in true }
        )
        let registry = MCPAgentWindowRegistry(
            trustStore: trust,
            opener: { [weak app] profile, companion, url, engine, floatOnTop, open in
                guard let app else { preconditionFailure("app gone") }
                return app.openAgentMicroWindow(
                    profile: profile,
                    companion: companion,
                    url: url,
                    engine: engine,
                    floatOnTop: floatOnTop,
                    open: open
                )
            },
            disconnectMCP: { [weak server] browser in server?.disconnect(browser: browser) },
            cancelMCPCalls: { [weak server] browser in server?.cancelActiveCall(in: browser) }
        )
        let bridge = MCPAgentWindowBridge(
            endpoint: bridgeEndpoint,
            trustStore: trust,
            registry: registry,
            authTimeout: authTimeout
        )
        server.agentWindowRegistry = registry
        server.hostBridge = bridge
        app.mcpServer = server
        app.agentWindowRegistry = registry
        app.agentWindowBridge = bridge

        server.setEnabled(true)
        try #require(await waitUntil { server.isListening && bridge.isListening })
        return Harness(
            directory: directory,
            bridgeEndpoint: bridgeEndpoint,
            mcpEndpoint: mcpEndpoint,
            app: app,
            trust: trust,
            registry: registry,
            bridge: bridge,
            server: server
        )
    }

    private func stopHarness(_ harness: Harness) {
        harness.server.stop()
        for window in harness.app.windows {
            window.closeWindow()
        }
        try? FileManager.default.removeItem(atPath: harness.directory)
    }

    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Host Bridge Tests")
        var failure: (any Error)?
        do {
            try await body(profile)
        } catch {
            failure = error
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    // MARK: - Socket permissions & authentication

    @Test(.timeLimit(.minutes(1))) func hostBridgePermissionsAndHelloAuthentication() async throws {
        let harness = try await startHarness(authTimeout: .milliseconds(250))
        defer { stopHarness(harness) }

        // Socket permissions are strictly 0600 inside 0700 directory.
        var dirInfo = stat()
        #expect(lstat(harness.directory, &dirInfo) == 0)
        #expect(dirInfo.st_mode & 0o777 == 0o700)
        var sockInfo = stat()
        #expect(lstat(harness.bridgeEndpoint, &sockInfo) == 0)
        #expect(sockInfo.st_mode & 0o777 == 0o600)

        let paired = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)

        // 1. Unknown token is rejected with unauthorized and socket closes.
        let badClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await badClient.connect()
        try await badClient.sendJSON([
            "wsurf": "host-hello",
            "v": 1,
            "token": SyntheticToken.stranger,
            "host": "t3-code",
        ])
        let badReply = try await badClient.nextMessage()
        #expect(badReply["ok"] as? Bool == false)
        #expect((badReply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
        await badClient.close()

        // 2. Paused paired client is rejected with unauthorized.
        try harness.trust.setPaused(true, for: paired.id)
        let pausedClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await pausedClient.connect()
        try await pausedClient.sendJSON([
            "wsurf": "host-hello",
            "v": 1,
            "token": SyntheticToken.first,
            "host": "t3-code",
        ])
        let pausedReply = try await pausedClient.nextMessage()
        #expect(pausedReply["ok"] as? Bool == false)
        #expect((pausedReply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
        await pausedClient.close()
        try harness.trust.setPaused(false, for: paired.id)

        // 3. Slow/missing hello times out with unauthorized.
        let slowClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await slowClient.connect()
        try await slowClient.sendRaw(Data(#"{"wsurf":"host-hel"#.utf8))
        do {
            let reply = try await slowClient.nextMessage()
            #expect(reply["ok"] as? Bool == false)
            #expect((reply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
        } catch {
            // Connection cancelled by timeout is also valid closure.
        }
        await slowClient.close()

        // 4. Valid paired token succeeds with exact protocol capabilities (even split across TCP chunks!).
        let goodClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await goodClient.connect()
        let helloBytes = MCPAgentBridgeProtocol.encodeLine([
            "wsurf": "host-hello",
            "v": 1,
            "token": SyntheticToken.first,
            "host": "t3-code",
        ])
        try await goodClient.sendRaw(helloBytes.prefix(20))
        try await goodClient.sendRaw(helloBytes.dropFirst(20))
        let okReply = try await goodClient.nextMessage()
        #expect(okReply["ok"] as? Bool == true)
        #expect(okReply["v"] as? Int == 1)
        #expect(okReply["protocol"] as? String == "wsurf-host-bridge")
        let caps = try #require(okReply["capabilities"] as? [String: Any])
        #expect(caps["agentMicroWindow"] as? Bool == true)
        #expect(caps["backgroundPointer"] as? Bool == true)
        #expect(caps["vaultLoginPrompt"] as? Bool == true)
        #expect(caps["engines"] as? [String] == ["chromium", "webkit"])
        await goodClient.close()

        // 5. Stopping BrowserMCPServer stops host-bridge.sock too.
        harness.server.stop()
        #expect(!harness.bridge.isListening)
        #expect(!FileManager.default.fileExists(atPath: harness.bridgeEndpoint))
    }

    private func connectAuthenticated(_ harness: Harness, token: String = SyntheticToken.first, host: String = "t3-code") async throws -> BridgeClient {
        let client = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await client.connect()
        try await client.sendJSON([
            "wsurf": "host-hello",
            "v": 1,
            "token": token,
            "host": host,
        ])
        let hello = try await client.nextMessage()
        try #require(hello["ok"] as? Bool == true)
        return client
    }

    // MARK: - Preview Operations & Sensitive Redaction

    @Test(.timeLimit(.minutes(1))) func bridgeOpenListAndPreviewOperations() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/app": .html("""
                <!doctype html><title>Bridge Fixture</title>
                <main>
                  <h1>Welcome Bridge</h1>
                  <input id="pw" type="password" value="super-secret-pass-999">
                  <button id="btn" onclick="document.getElementById('out').textContent = 'Clicked!'">Click Me</button>
                  <p id="out">Initial</p>
                </main>
                """),
            "/next": .html("<!doctype html><title>Second Page</title><p>Navigated OK</p>"),
        ])
        let appURL = try fixture.url("/app")
        let nextURL = try fixture.url("/next")
        try await withProfile { profile in
            let harness = try await startHarness()
            defer {
                stopHarness(harness)
                withExtendedLifetime(fixture) {}
            }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let regular = harness.app.newWindow(profile: profile, show: false)
            let regularTab = regular.browser.newTab(url: nextURL, activate: true)

            let client = try await connectAuthenticated(harness)
            defer { Task { await client.close() } }

            let (openResp, _) = try await client.request(
                id: "req-1", op: "openAgentWindow",
                params: [
                    "threadId": "thread-A", "title": "Checkout Fix", "profileId": profile.id.uuidString,
                    "url": appURL.absoluteString, "engine": "webkit", "access": "development",
                    "floatOnTop": true, "open": false,
                ]
            )
            #expect(openResp["ok"] as? Bool == true)
            let openResult = try #require(openResp["result"] as? [String: Any])
            let windowId = try #require(openResult["windowId"] as? String)
            let tabId = try #require(openResult["tabId"] as? String)
            let windowToken = try #require(openResult["windowToken"] as? String)
            #expect(openResult["threadId"] as? String == "thread-A")
            #expect(openResult["generation"] as? Int == 1)
            #expect(openResult["owner"] as? String == "agent")
            #expect(openResult["engine"] as? String == "webkit")
            #expect(openResult["backend"] as? String == "wsurf-micro")
            #expect(openResult["mcpAllowed"] as? Bool == true)
            #expect(MCPPairing.isWellFormed(windowToken))

            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })
            #expect(agentWindow.floatsOnTop == true)
            let agentTab = try #require(agentWindow.browser.tabs.first { $0.id.uuidString == tabId })
            try #require(await waitUntil { agentTab.liveView?.url == appURL && !agentTab.isLoading })

            // listTabs exposes ONLY the Agent Micro Window's tab, never the user's regular tab.
            let (listResp, _) = try await client.request(id: "req-2", op: "listTabs", params: ["threadId": "thread-A"])
            let listedTabs = try #require((listResp["result"] as? [String: Any])?["tabs"] as? [[String: Any]])
            #expect(listedTabs.count == 1)
            #expect(listedTabs.first?["tabId"] as? String == tabId)
            #expect(!listedTabs.contains { ($0["tabId"] as? String) == regularTab.id.uuidString })

            // snapshot + act + evaluate (with sensitive password redaction)
            let (snapResp, _) = try await client.request(
                id: "req-3", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-A", "expectedGeneration": 1, "operation": "snapshot"]
            )
            #expect(snapResp["ok"] as? Bool == true)
            let snapResult = try #require(snapResp["result"] as? [String: Any])
            #expect((snapResult["page"] as? String)?.contains("Welcome Bridge") == true)
            #expect((snapResult["accessibilityTree"] as? String)?.isEmpty == false)

            let (actResp, _) = try await client.request(
                id: "req-4", op: "invokePreview",
                params: [
                    "tabId": tabId, "threadId": "thread-A", "expectedGeneration": 1,
                    "operation": "act", "params": ["action": "click", "selector": "#btn"],
                ]
            )
            #expect(actResp["ok"] as? Bool == true)

            let (evalResp, _) = try await client.request(
                id: "req-5", op: "invokePreview",
                params: [
                    "tabId": tabId, "threadId": "thread-A", "expectedGeneration": 1, "operation": "evaluate",
                    "params": ["expression": "() => ({ out: document.getElementById('out').textContent, pw: document.getElementById('pw').value })"],
                ]
            )
            #expect(evalResp["ok"] as? Bool == true)
            let evalValue = try #require((evalResp["result"] as? [String: Any])?["value"] as? [String: Any])
            #expect(evalValue["out"] as? String == "Clicked!")
            #expect(evalValue["pw"] as? String != "super-secret-pass-999", "sensitive password field MUST be redacted")

            // navigate + set_appearance + resize
            let (navResp, _) = try await client.request(
                id: "req-6", op: "invokePreview",
                params: [
                    "tabId": tabId, "threadId": "thread-A", "expectedGeneration": 1,
                    "operation": "navigate", "params": ["url": nextURL.absoluteString],
                ]
            )
            #expect(navResp["ok"] as? Bool == true)
            #expect((navResp["result"] as? [String: Any])?["url"] as? String == nextURL.absoluteString)

            let (appearanceResp, _) = try await client.request(
                id: "req-7", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-A", "operation": "set_appearance", "params": ["colorScheme": "dark"]]
            )
            #expect(appearanceResp["ok"] as? Bool == true)

            let (resizeResp, _) = try await client.request(
                id: "req-8", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-A", "operation": "resize", "params": ["width": 640, "height": 480]]
            )
            #expect(resizeResp["ok"] as? Bool == true)
        }
    }

    // MARK: - Ownership Guards, Push Events & Close

    @Test(.timeLimit(.minutes(1))) func bridgeOwnershipGuardsPushEventsAndClose() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/app": .html("<!doctype html><title>Guard Fixture</title><p>Hello</p>"),
            "/next": .html("<!doctype html><title>Next Page</title><p>Next</p>"),
        ])
        let appURL = try fixture.url("/app")
        let nextURL = try fixture.url("/next")
        try await withProfile { profile in
            let harness = try await startHarness()
            defer {
                stopHarness(harness)
                withExtendedLifetime(fixture) {}
            }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)

            let client = try await connectAuthenticated(harness)
            defer { Task { await client.close() } }

            let (openResp, _) = try await client.request(
                id: "open-1",
                op: "openAgentWindow",
                params: [
                    "threadId": "thread-B",
                    "profileId": profile.id.uuidString,
                    "url": appURL.absoluteString,
                    "engine": "webkit",
                ]
            )
            let openResult = try #require(openResp["result"] as? [String: Any])
            let windowId = try #require(openResult["windowId"] as? String)
            let tabId = try #require(openResult["tabId"] as? String)
            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })
            let agentTab = try #require(agentWindow.browser.tabs.first { $0.id.uuidString == tabId })
            try #require(await waitUntil { agentTab.liveView?.url == appURL && !agentTab.isLoading })

            // agentMismatch when wrong threadId is passed.
            let (mismatchResp, _) = try await client.request(
                id: "guard-1",
                op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-OTHER", "operation": "status"]
            )
            #expect(mismatchResp["ok"] as? Bool == false)
            #expect((mismatchResp["error"] as? [String: Any])?["code"] as? String == "agentMismatch")

            // staleGeneration when expectedGeneration does not match.
            let (staleResp, _) = try await client.request(
                id: "guard-2",
                op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "expectedGeneration": 99, "operation": "snapshot"]
            )
            #expect(staleResp["ok"] as? Bool == false)
            #expect((staleResp["error"] as? [String: Any])?["code"] as? String == "staleGeneration")

            // Take Over pushes unsolicited ownerChanged; mutating ops fail with humanControl while status still succeeds!
            agentWindow.takeOverAgentMicroWindow()
            let ownerEvent = try await client.waitForEvent(named: "ownerChanged")
            let ownerPayload = try #require(ownerEvent["payload"] as? [String: Any])
            #expect(ownerPayload["owner"] as? String == "human")
            #expect(ownerPayload["generation"] as? Int == 2)
            #expect(ownerPayload["threadId"] as? String == "thread-B")

            let (blockedResp, _) = try await client.request(
                id: "guard-3",
                op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "operation": "navigate", "params": ["url": nextURL.absoluteString]]
            )
            #expect(blockedResp["ok"] as? Bool == false)
            #expect((blockedResp["error"] as? [String: Any])?["code"] as? String == "humanControl")

            let (statusResp, _) = try await client.request(
                id: "guard-4",
                op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "operation": "status"]
            )
            #expect(statusResp["ok"] as? Bool == true)
            let statusResult = try #require(statusResp["result"] as? [String: Any])
            #expect(statusResult["owner"] as? String == "human")
            #expect(statusResult["generation"] as? Int == 2)
            #expect(statusResult["mcpAllowed"] as? Bool == true)

            // setOwner back to agent bumps generation to 3 and emits ownerChanged.
            let (setOwnerResp, setOwnerEvents) = try await client.request(
                id: "guard-5",
                op: "setOwner",
                params: ["tabId": tabId, "owner": "agent"]
            )
            #expect(setOwnerResp["ok"] as? Bool == true)
            #expect((setOwnerResp["result"] as? [String: Any])?["generation"] as? Int == 3)
            let gotBackEvent = setOwnerEvents.contains { ($0["event"] as? String) == "ownerChanged" }
            if !gotBackEvent {
                let pushed = try await client.waitForEvent(named: "ownerChanged")
                #expect((pushed["payload"] as? [String: Any])?["owner"] as? String == "agent")
            }

            // closeAgentWindow revokes windowToken, emits windowClosed, closes window.
            let (closeResp, closeEvents) = try await client.request(
                id: "close-1",
                op: "closeAgentWindow",
                params: ["windowId": windowId]
            )
            #expect(closeResp["ok"] as? Bool == true)
            #expect((closeResp["result"] as? [String: Any])?["closed"] as? Bool == true)
            let sawClosed = closeEvents.contains { ($0["event"] as? String) == "windowClosed" }
            if !sawClosed {
                let pushed = try await client.waitForEvent(named: "windowClosed")
                #expect((pushed["payload"] as? [String: Any])?["windowId"] as? String == windowId)
            }
            #expect(agentWindow.isClosed)
            #expect(!harness.registry.hasActiveWindows)
        }
    }

    @Test func stageHostBridgePathIsStableDistinctAndWithinUnixLimit() {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-stage-bridge-\(UUID().uuidString)")
        let first = LocalMCPEndpoint.stageHostBridgePath(for: root.appending(path: "a"))
        let second = LocalMCPEndpoint.stageHostBridgePath(for: root.appending(path: "b"))
        #expect(first != second)
        #expect(first.hasSuffix("/host-bridge.sock"))
        #expect(first.utf8.count < 104)
    }
}
