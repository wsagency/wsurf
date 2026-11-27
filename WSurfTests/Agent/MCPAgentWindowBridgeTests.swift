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
/// (including Developer-tier & sensitive-field `evaluate` guards, Read Only/Deny enforcement,
/// `agentMismatch`, `humanControl`, `staleGeneration`), Take Over / Stop finality, reconnect reattachment,
/// `bridge.stop()` cleanup, and `closeAgentWindow`.
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
    final class BridgeClient {
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

    struct Harness {
        let directory: String
        let bridgeEndpoint: String
        let mcpEndpoint: String
        let app: BrowserApplication
        let trust: MCPTrustStore
        let registry: MCPAgentWindowRegistry
        let bridge: MCPAgentWindowBridge
        let server: BrowserMCPServer
    }

    func startHarness(
        authTimeout: Duration = .seconds(2),
        storage: MemoryTrustStorage = MemoryTrustStorage(),
        onOpen: @escaping (Bool) -> Void = { _ in }
    ) async throws -> Harness {
        let directory = "/tmp/wsurf-bridge-\(UUID().uuidString)"
        let mcpEndpoint = directory + "/browser.sock"
        let bridgeEndpoint = directory + "/host-bridge.sock"
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let trust = MCPTrustStore(storage: storage)
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
                onOpen(open)
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

    func stopHarness(_ harness: Harness) {
        harness.server.stop()
        for window in harness.app.windows {
            window.closeWindow()
        }
        try? FileManager.default.removeItem(atPath: harness.directory)
    }

    func withProfile(name: String = "Host Bridge Tests", _ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: name)
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

    func connectAuthenticated(_ harness: Harness, token: String = SyntheticToken.first, host: String = "t3-code") async throws -> BridgeClient {
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

    // MARK: - Socket permissions & authentication

    @Test(.timeLimit(.minutes(1))) func hostBridgePermissionsAndHelloAuthentication() async throws {
        let harness = try await startHarness(authTimeout: .milliseconds(250))
        defer { stopHarness(harness) }

        var dirInfo = stat()
        #expect(lstat(harness.directory, &dirInfo) == 0)
        #expect(dirInfo.st_mode & 0o777 == 0o700)
        var sockInfo = stat()
        #expect(lstat(harness.bridgeEndpoint, &sockInfo) == 0)
        #expect(sockInfo.st_mode & 0o777 == 0o600)

        let paired = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)

        // Unknown token rejected.
        let badClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await badClient.connect()
        try await badClient.sendJSON(["wsurf": "host-hello", "v": 1, "token": SyntheticToken.stranger, "host": "t3-code"])
        let badReply = try await badClient.nextMessage()
        #expect(badReply["ok"] as? Bool == false)
        #expect((badReply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
        await badClient.close()

        // Paused paired client rejected.
        try harness.trust.setPaused(true, for: paired.id)
        let pausedClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await pausedClient.connect()
        try await pausedClient.sendJSON(["wsurf": "host-hello", "v": 1, "token": SyntheticToken.first, "host": "t3-code"])
        let pausedReply = try await pausedClient.nextMessage()
        #expect(pausedReply["ok"] as? Bool == false)
        #expect((pausedReply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
        await pausedClient.close()
        try harness.trust.setPaused(false, for: paired.id)

        // Slow/missing hello times out with unauthorized.
        let slowClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await slowClient.connect()
        try await slowClient.sendRaw(Data(#"{"wsurf":"host-hel"#.utf8))
        do {
            let reply = try await slowClient.nextMessage()
            #expect(reply["ok"] as? Bool == false)
            #expect((reply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
        } catch {
            // Timeout closure is valid.
        }
        await slowClient.close()

        // Valid paired token succeeds with exact protocol capabilities (even split across TCP chunks).
        let goodClient = BridgeClient(socketPath: harness.bridgeEndpoint)
        try await goodClient.connect()
        let helloBytes = MCPAgentBridgeProtocol.encodeLine([
            "wsurf": "host-hello", "v": 1, "token": SyntheticToken.first, "host": "t3-code",
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

        // Stopping BrowserMCPServer stops host-bridge.sock.
        harness.server.stop()
        #expect(!harness.bridge.isListening)
        #expect(!FileManager.default.fileExists(atPath: harness.bridgeEndpoint))
    }

    // MARK: - Preview Operations

    @Test(.timeLimit(.minutes(1))) func bridgeOpenListAndPreviewOperations() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/app": .html("""
                <!doctype html><title>Bridge Fixture</title>
                <main>
                  <h1>Welcome Bridge</h1>
                  <button id="btn" onclick="document.getElementById('out').textContent = 'Clicked!'">Click Me</button>
                  <p id="out">Initial</p>
                </main>
                """),
            "/next": .html("<!doctype html><title>Second Page</title><p>Navigated OK</p>"),
        ])
        let appURL = try fixture.url("/app")
        let nextURL = try fixture.url("/next")
        try await withProfile { profile in
            var requestedOpen: Bool?
            let harness = try await startHarness(onOpen: { requestedOpen = $0 })
            defer {
                stopHarness(harness)
                withExtendedLifetime(fixture) {}
            }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Verified Host", kind: nil)
            try harness.trust.setStanding(.developer, for: paired.id)
            try harness.trust.setDeveloperProfile(profile.id, dedicated: true)
            let regular = harness.app.newWindow(profile: profile, show: false)
            let regularTab = regular.browser.newTab(url: nextURL, activate: true)

            // Self-asserted host string in hello is NOT used for display; MCPTrustStore's verified name wins.
            let client = try await connectAuthenticated(harness, host: "spoofed-host-label")
            defer { Task { await client.close() } }

            let (openResp, _) = try await client.request(
                id: "req-1", op: "openAgentWindow",
                params: [
                    "threadId": "thread-A", "title": "Checkout Fix",
                    "url": appURL.absoluteString, "engine": "webkit", "access": "developer",
                    "floatOnTop": true, "open": false,
                ]
            )
            #expect(openResp["ok"] as? Bool == true)
            let openResult = try #require(openResp["result"] as? [String: Any])
            let windowId = try #require(openResult["windowId"] as? String)
            let tabId = try #require(openResult["tabId"] as? String)
            let windowToken = try #require(openResult["windowToken"] as? String)
            #expect(openResult["backend"] as? String == "wsurf-micro")
            #expect(openResult["mcpAllowed"] as? Bool == true)
            #expect(MCPPairing.isWellFormed(windowToken))

            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })
            let nativeWindow = try #require(agentWindow.nativeWindow)
            #expect(requestedOpen == false)
            #expect(openResult["visible"] as? Bool == (nativeWindow.isVisible && !nativeWindow.isMiniaturized))
            #expect(agentWindow.floatsOnTop == true)
            #expect(agentWindow.browser.agentCompanion?.hostName == "Verified Host")
            let agentTab = try #require(agentWindow.browser.tabs.first { $0.id.uuidString == tabId })
            try #require(await waitUntil { agentTab.liveView?.url == appURL && !agentTab.isLoading })

            let (listResp, _) = try await client.request(id: "req-2", op: "listTabs", params: ["threadId": "thread-A"])
            let listedTabs = try #require((listResp["result"] as? [String: Any])?["tabs"] as? [[String: Any]])
            #expect(listedTabs.count == 1)
            #expect(listedTabs.first?["tabId"] as? String == tabId)
            #expect(!listedTabs.contains { ($0["tabId"] as? String) == regularTab.id.uuidString })

            let (snapResp, _) = try await client.request(
                id: "req-3", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-A", "expectedGeneration": 1, "operation": "snapshot"]
            )
            #expect(snapResp["ok"] as? Bool == true)
            let snapResult = try #require(snapResp["result"] as? [String: Any])
            #expect((snapResult["page"] as? String)?.contains("Welcome Bridge") == true)

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
                    "params": ["expression": "() => document.getElementById('out').textContent"],
                ]
            )
            #expect(evalResp["ok"] as? Bool == true)
            #expect((evalResp["result"] as? [String: Any])?["value"] as? String == "Clicked!")

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

            let (closeResp, closeEvents) = try await client.request(
                id: "req-9", op: "closeAgentWindow",
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

    // MARK: - H1: Evaluate & Site Policy Security Guards

    @Test(.timeLimit(.minutes(1))) func evaluateRefusedOnReadOnlyNonDeveloperSitesAndFilledPasswords() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/clean": .html("<!doctype html><title>Clean</title><p id='msg'>Safe</p><button id='btn'>Go</button>"),
            "/secret": .html("""
                <!doctype html><title>Login</title>
                <input id="pw" type="password" value="super-secret-pass-999">
                <p id="status">Locked</p>
                """),
            "/blocked": .html("<!doctype html><title>Denied</title><p>No access</p>"),
        ])
        let cleanURL = try fixture.url("/clean")
        let secretURL = try fixture.url("/secret")
        let blockedURL = try fixture.url("/blocked")
        try await withProfile(name: "Dev Profile") { devProfile in
            try await withProfile(name: "Regular Profile") { regularProfile in
                let harness = try await startHarness()
                defer {
                    stopHarness(harness)
                    withExtendedLifetime(fixture) {}
                }
                let paired = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
                try harness.trust.setStanding(.developer, for: paired.id)
                try harness.trust.setDeveloperProfile(devProfile.id, dedicated: true)
                let client = try await connectAuthenticated(harness)
                defer { Task { await client.close() } }

                // 1. Default access (control) refuses evaluate.
                let (ctrlOpen, _) = try await client.request(
                    id: "c1", op: "openAgentWindow",
                    params: ["threadId": "t-ctrl", "url": cleanURL.absoluteString, "engine": "webkit"]
                )
                let ctrlTabId = try #require((ctrlOpen["result"] as? [String: Any])?["tabId"] as? String)
                let ctrlWinId = try #require((ctrlOpen["result"] as? [String: Any])?["windowId"] as? String)
                let ctrlWin = try #require(harness.app.windows.first { $0.windowID.uuidString == ctrlWinId })
                let ctrlTab = try #require(ctrlWin.browser.tabs.first { $0.id.uuidString == ctrlTabId })
                try #require(await waitUntil { ctrlTab.liveView?.url == cleanURL && !ctrlTab.isLoading })

                let (ctrlEval, _) = try await client.request(
                    id: "c2", op: "invokePreview",
                    params: ["tabId": ctrlTabId, "threadId": "t-ctrl", "operation": "evaluate", "params": ["expression": "() => 1 + 1"]]
                )
                #expect(ctrlEval["ok"] as? Bool == false)
                #expect((ctrlEval["error"] as? [String: Any])?["code"] as? String == "forbidden")

                // 2. Non-Developer profile refuses evaluate even with access:"developer" on localhost.
                let (regOpen, _) = try await client.request(
                    id: "r1", op: "openAgentWindow",
                    params: [
                        "threadId": "t-reg", "profileId": regularProfile.id.uuidString,
                        "url": cleanURL.absoluteString, "engine": "webkit", "access": "developer",
                    ]
                )
                let regTabId = try #require((regOpen["result"] as? [String: Any])?["tabId"] as? String)
                let regWinId = try #require((regOpen["result"] as? [String: Any])?["windowId"] as? String)
                let regWin = try #require(harness.app.windows.first { $0.windowID.uuidString == regWinId })
                let regTab = try #require(regWin.browser.tabs.first { $0.id.uuidString == regTabId })
                try #require(await waitUntil { regTab.liveView?.url == cleanURL && !regTab.isLoading })

                let (regEval, _) = try await client.request(
                    id: "r2", op: "invokePreview",
                    params: ["tabId": regTabId, "threadId": "t-reg", "operation": "evaluate", "params": ["expression": "() => 1 + 1"]]
                )
                #expect(regEval["ok"] as? Bool == false)
                #expect((regEval["error"] as? [String: Any])?["code"] as? String == "forbidden")

                // 3. Developer profile + developer access: succeeds on clean localhost, refuses non-developer site,
                //    refuses Read Only site (for evaluate & mutating ops), refuses filled password field, and refuses Deny!
                let (devOpen, _) = try await client.request(
                    id: "d1", op: "openAgentWindow",
                    params: [
                        "threadId": "t-dev", "profileId": devProfile.id.uuidString,
                        "url": cleanURL.absoluteString, "engine": "webkit", "access": "developer",
                    ]
                )
                let devTabId = try #require((devOpen["result"] as? [String: Any])?["tabId"] as? String)
                let devWinId = try #require((devOpen["result"] as? [String: Any])?["windowId"] as? String)
                let devWin = try #require(harness.app.windows.first { $0.windowID.uuidString == devWinId })
                let devTab = try #require(devWin.browser.tabs.first { $0.id.uuidString == devTabId })
                try #require(await waitUntil { devTab.liveView?.url == cleanURL && !devTab.isLoading })

                // 3a. Non-developer site (includesThisMac = false) refuses evaluate.
                try harness.trust.setIncludesThisMac(false)
                let (nonDevEval, _) = try await client.request(
                    id: "d2", op: "invokePreview",
                    params: ["tabId": devTabId, "threadId": "t-dev", "operation": "evaluate", "params": ["expression": "() => 1 + 1"]]
                )
                #expect(nonDevEval["ok"] as? Bool == false)
                #expect((nonDevEval["error"] as? [String: Any])?["code"] as? String == "forbidden")
                try harness.trust.setIncludesThisMac(true)

                // 3b. Read Only site refuses evaluate AND mutating ops (act, resize, set_appearance, set_engine, navigate).
                let origin = SitePermissions.origin(for: cleanURL)
                devWin.browser.sitePermissions.setAssistantAccess(.readOnly, for: origin)
                let readOnlyChecks: [(String, String, [String: Any])] = [
                    ("ro-1", "evaluate", ["expression": "() => 1"]),
                    ("ro-2", "act", ["action": "click", "selector": "#btn"]),
                    ("ro-3", "resize", ["width": 500, "height": 400]),
                    ("ro-4", "set_appearance", ["colorScheme": "dark"]),
                    ("ro-5", "set_engine", ["engine": "chromium"]),
                    ("ro-6", "navigate", ["url": secretURL.absoluteString]),
                ]
                for (reqId, op, opParams) in readOnlyChecks {
                    let (resp, _) = try await client.request(
                        id: reqId, op: "invokePreview",
                        params: ["tabId": devTabId, "threadId": "t-dev", "operation": op, "params": opParams]
                    )
                    #expect(resp["ok"] as? Bool == false, "\(op) must be refused on Read Only site")
                    #expect((resp["error"] as? [String: Any])?["code"] as? String == "forbidden")
                }

                // 3c. Deny site refuses navigate/open BEFORE loading.
                devWin.browser.sitePermissions.setAssistantAccess(.control, for: origin)
                devWin.browser.sitePermissions.setAssistantAccess(.deny, for: SitePermissions.origin(for: blockedURL))
                let (denyOpen, _) = try await client.request(
                    id: "deny-1", op: "openAgentWindow",
                    params: ["threadId": "t-deny", "profileId": devProfile.id.uuidString, "url": blockedURL.absoluteString]
                )
                #expect(denyOpen["ok"] as? Bool == false)
                #expect((denyOpen["error"] as? [String: Any])?["code"] as? String == "forbidden")

                // 3d. Filled password field refuses evaluate!
                devWin.browser.sitePermissions.setAssistantAccess(.control, for: SitePermissions.origin(for: secretURL))
                let (navSecret, _) = try await client.request(
                    id: "sec-1", op: "invokePreview",
                    params: ["tabId": devTabId, "threadId": "t-dev", "operation": "navigate", "params": ["url": secretURL.absoluteString]]
                )
                #expect(navSecret["ok"] as? Bool == true)
                let (pwEval, _) = try await client.request(
                    id: "sec-2", op: "invokePreview",
                    params: [
                        "tabId": devTabId, "threadId": "t-dev", "operation": "evaluate",
                        "params": ["expression": "() => document.getElementById('pw').value"],
                    ]
                )
                #expect(pwEval["ok"] as? Bool == false, "evaluate MUST be refused on pages with filled password fields")
                #expect((pwEval["error"] as? [String: Any])?["code"] as? String == "forbidden")
            }
        }
    }

    // MARK: - H2: Take Over & Stop Finality + Ownership Guards

    @Test(.timeLimit(.minutes(1))) func bridgeTakeOverAndStopFinalityAndOwnershipGuards() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/app": .html("<!doctype html><title>Guard Fixture</title><p>Hello</p>"),
            "/next": .html("<!doctype html><title>Next Page</title><p>Next</p>"),
        ])
        let appURL = try fixture.url("/app")
        let nextURL = try fixture.url("/next")
        try await withProfile { profile in
            var requestedOpen: Bool?
            let harness = try await startHarness(onOpen: { requestedOpen = $0 })
            defer {
                stopHarness(harness)
                withExtendedLifetime(fixture) {}
            }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            try harness.trust.setClientPolicy(\.defaultEngine, to: .webKit, for: paired.id)
            try harness.trust.setStanding(.development, for: paired.id)

            let client = try await connectAuthenticated(harness)
            defer { Task { await client.close() } }

            let (openResp, _) = try await client.request(
                id: "open-1", op: "openAgentWindow",
                params: [
                    "threadId": "thread-B", "title": "Initial Title", "profileId": profile.id.uuidString,
                    "url": appURL.absoluteString, "floatOnTop": false, "access": "development",
                ]
            )
            let openResult = try #require(openResp["result"] as? [String: Any])
            let windowId = try #require(openResult["windowId"] as? String)
            let tabId = try #require(openResult["tabId"] as? String)
            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })
            let agentTab = try #require(agentWindow.browser.tabs.first { $0.id.uuidString == tabId })
            let window = try #require(agentWindow.nativeWindow)
            #expect(requestedOpen == true)
            #expect(openResult["visible"] as? Bool == true)
            #expect(openResult["engine"] as? String == "webkit")
            #expect(window.isVisible && !window.isMiniaturized)
            try #require(await waitUntil { agentTab.liveView?.url == appURL && !agentTab.isLoading })

            // agentMismatch & staleGeneration
            let (mismatchResp, _) = try await client.request(
                id: "guard-1", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-OTHER", "operation": "status"]
            )
            #expect((mismatchResp["error"] as? [String: Any])?["code"] as? String == "agentMismatch")

            let (staleResp, _) = try await client.request(
                id: "guard-2", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "expectedGeneration": 99, "operation": "snapshot"]
            )
            #expect((staleResp["error"] as? [String: Any])?["code"] as? String == "staleGeneration")

            // User clicks Take Over -> host receives ownerChanged, mutating ops fail, status still succeeds.
            agentWindow.takeOverAgentMicroWindow()
            let ownerEvent = try await client.waitForEvent(named: "ownerChanged")
            #expect((ownerEvent["payload"] as? [String: Any])?["owner"] as? String == "human")
            #expect((ownerEvent["payload"] as? [String: Any])?["generation"] as? Int == 2)

            let (blockedResp, _) = try await client.request(
                id: "guard-3", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "operation": "navigate", "params": ["url": nextURL.absoluteString]]
            )
            #expect((blockedResp["error"] as? [String: Any])?["code"] as? String == "humanControl")

            // Low #10 & H2: openAgentWindow reuse while owner == .human is refused and does NOT mutate title or floatOnTop!
            let (reuseBlocked, _) = try await client.request(
                id: "guard-reuse", op: "openAgentWindow",
                params: ["threadId": "thread-B", "title": "Hijacked Title", "floatOnTop": true]
            )
            #expect(reuseBlocked["ok"] as? Bool == false)
            #expect((reuseBlocked["error"] as? [String: Any])?["code"] as? String == "humanControl")
            #expect(agentWindow.browser.agentCompanion?.threadTitle == "Initial Title")
            #expect(agentWindow.floatsOnTop == false)

            // H2: While owner == .human, ALL host setOwner calls (including to "unclaimed"!) are refused with humanControl!
            for (reqId, requestedOwner) in [("guard-reclaim-1", "agent"), ("guard-reclaim-2", "unclaimed"), ("guard-reclaim-3", "human")] {
                let (reclaimResp, _) = try await client.request(
                    id: reqId, op: "setOwner",
                    params: ["tabId": tabId, "owner": requestedOwner]
                )
                #expect(reclaimResp["ok"] as? Bool == false, "setOwner(\(requestedOwner)) must fail under human Take Over")
                #expect((reclaimResp["error"] as? [String: Any])?["code"] as? String == "humanControl")
            }
            #expect(agentWindow.browser.agentCompanion?.owner == .human)

            // Status still succeeds under human control.
            let (statusResp, _) = try await client.request(
                id: "guard-4", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "operation": "status"]
            )
            #expect(statusResp["ok"] as? Bool == true)
            #expect((statusResp["result"] as? [String: Any])?["visible"] as? Bool == true)

            try await checkHumanSnapshot(client, harness: harness, pairedID: paired.id, agentTab: agentTab)
            window.orderOut(nil)
            let (hidden, _) = try await client.request(
                id: "guard-hidden", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "operation": "status"])
            #expect((hidden["result"] as? [String: Any])?["visible"] as? Bool == false)

            // ONLY user Hand Back restores agent ownership!
            agentWindow.handBackAgentMicroWindow()
            let backEvent = try await client.waitForEvent(named: "ownerChanged")
            #expect((backEvent["payload"] as? [String: Any])?["owner"] as? String == "agent")

            agentWindow.stopAgentMicroWindow()
            #expect(harness.trust.client(id: paired.id)?.paused == true)
            #expect(!harness.registry.hasActiveWindows)

            let retryClient = BridgeClient(socketPath: harness.bridgeEndpoint)
            try await retryClient.connect()
            try await retryClient.sendJSON(["wsurf": "host-hello", "v": 1, "token": SyntheticToken.first, "host": "t3-code"])
            let retryReply = try await retryClient.nextMessage()
            #expect(retryReply["ok"] as? Bool == false)
            #expect((retryReply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
            await retryClient.close()
        }
    }

    private func checkHumanSnapshot(_ client: BridgeClient, harness: Harness, pairedID: UUID, agentTab: BrowserTab) async throws {
        let tabId = agentTab.id.uuidString
        let snapshotSecret = "bridge-snapshot-secret-Q7"
        let session = try #require(harness.registry.record(pairedClientId: pairedID, threadId: "thread-B")?.previewSession)
        #expect(session.secrets.registerVaultSecret(snapshotSecret) == .registered)
        let page = try #require(agentTab.liveView)
        _ = try await page.evaluateJavaScript(
            "document.title = '\(snapshotSecret)'; document.querySelector('p').textContent += ' \(snapshotSecret)'; 0")
        let snapshotRequest: [String: Any] = [
            "tabId": tabId, "threadId": "thread-B", "expectedGeneration": 2, "operation": "snapshot",
            "params": ["includeImage": true],
        ]
        let (snapshot, _) = try await client.request(id: "guard-snapshot", op: "invokePreview", params: snapshotRequest)
        let read = try #require(snapshot["result"] as? [String: Any])
        #expect(read["owner"] as? String == "human")
        #expect((read["page"] as? String)?.contains("Hello") == true)
        #expect(read["imageBase64"] == nil)
        #expect(!String(describing: read).contains(snapshotSecret))

        try harness.trust.setStanding(.off, for: pairedID)
        let (downgraded, _) = try await client.request(id: "guard-downgraded", op: "invokePreview", params: snapshotRequest)
        #expect((downgraded["error"] as? [String: Any])?["code"] as? String == "denied")
        try harness.trust.setStanding(.development, for: pairedID)

        _ = try await page.evaluateJavaScript(
            "document.body.insertAdjacentHTML('beforeend', '<input type=password value=humanSecretOnly>'); 0")
        let (protected, _) = try await client.request(id: "guard-protected", op: "invokePreview", params: snapshotRequest)
        #expect(protected["ok"] as? Bool == false)
        #expect((protected["error"] as? [String: Any])?["code"] as? String == "protectedSecretPresent")
        _ = try await page.evaluateJavaScript("document.querySelector('input').remove(); 0")
        session.markCredentialTainted(tab: agentTab, mainDocumentID: page.mainDocumentID)
        let (tainted, _) = try await client.request(id: "guard-tainted", op: "invokePreview", params: snapshotRequest)
        #expect((tainted["error"] as? [String: Any])?["code"] as? String == "protectedSecretPresent")

        for operation in ["act", "evaluate", "resize", "set_appearance", "dialog", "close", "set_engine", "open"] {
            let (blocked, _) = try await client.request(
                id: "guard-\(operation)", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-B", "operation": operation])
            #expect((blocked["error"] as? [String: Any])?["code"] as? String == "humanControl")
        }
    }

    // MARK: - M2: Paired-client reconnect reattachment & bridge.stop() cleanup

    @Test(.timeLimit(.minutes(1))) func hostDisconnectReconnectReattachesAndBridgeStopInvalidatesTokens() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/app": .html("<!doctype html><title>Reconnect Fixture</title><p>Persistent</p>"),
        ])
        let appURL = try fixture.url("/app")
        try await withProfile { profile in
            let harness = try await startHarness()
            defer {
                stopHarness(harness)
                withExtendedLifetime(fixture) {}
            }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)

            // Connection 1 opens an Agent Micro Window, then disconnects.
            let first = try await connectAuthenticated(harness)
            let (openResp, _) = try await first.request(
                id: "r1", op: "openAgentWindow",
                params: [
                    "threadId": "thread-reconnect", "profileId": profile.id.uuidString,
                    "url": appURL.absoluteString, "engine": "webkit",
                ]
            )
            let openResult = try #require(openResp["result"] as? [String: Any])
            let windowId = try #require(openResult["windowId"] as? String)
            let tabId = try #require(openResult["tabId"] as? String)
            let windowToken = try #require(openResult["windowToken"] as? String)
            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })
            let agentTab = try #require(agentWindow.browser.tabs.first { $0.id.uuidString == tabId })
            try #require(await waitUntil { agentTab.liveView?.url == appURL && !agentTab.isLoading })
            await first.close()
            try await Task.sleep(for: .milliseconds(50))

            // Connection 2 reconnects with the same paired client token and seamlessly manages the live window!
            let second = try await connectAuthenticated(harness)
            defer { Task { await second.close() } }
            let (listResp, _) = try await second.request(id: "r2", op: "listTabs", params: ["threadId": "thread-reconnect"])
            let tabs = try #require((listResp["result"] as? [String: Any])?["tabs"] as? [[String: Any]])
            #expect(tabs.count == 1)
            #expect(tabs.first?["tabId"] as? String == tabId)

            // Push events route to the reconnected client!
            agentWindow.takeOverAgentMicroWindow()
            let pushed = try await second.waitForEvent(named: "ownerChanged")
            #expect((pushed["payload"] as? [String: Any])?["owner"] as? String == "human")

            // M2: bridge.stop() tears down active records and invalidates every minted windowToken!
            #expect(harness.registry.resolve(windowToken: windowToken, pairedClientId: paired.id) != nil)
            harness.bridge.stop()
            #expect(!harness.registry.hasActiveWindows)
            #expect(harness.registry.resolve(windowToken: windowToken, pairedClientId: paired.id) == nil)
            #expect(agentWindow.browser.agentCompanion == nil)
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
