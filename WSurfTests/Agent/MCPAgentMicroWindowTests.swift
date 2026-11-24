// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP
import Network
import Testing
import WebKit

@testable import WSurf

/// Tests for detached Agent Micro Windows: multi-tab retention, Chromium default + WebKit switching,
/// strict isolation from regular windows, Take Over / Hand Back / Stop transitions, and window-scoped MCP auto-allow.
@MainActor
@Suite(.serialized, .boundedWebViews, .noAnnouncePause)
struct MCPAgentMicroWindowTests {
    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Agent Micro Tests")
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

    private func makeApp() -> BrowserApplication {
        BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
    }

    private func finish(_ app: BrowserApplication) {
        app.mcpServer.stop()
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
    }

    private func makeIsolatedServer(
        in app: BrowserApplication,
        directory: String,
        trust: MCPTrustStore
    ) -> (server: BrowserMCPServer, registry: MCPAgentWindowRegistry, endpoint: String) {
        let endpoint = directory + "/browser.sock"
        let server = BrowserMCPServer(
            endpoint: endpoint,
            trustStore: trust,
            target: { [weak app] in
                guard let coordinator = app?.activeBrowsingCoordinator,
                      !coordinator.isClosed, coordinator.nativeWindow != nil,
                      !coordinator.profiles.isPrivate, !coordinator.isSwitchingProfile
                else {
                    return nil
                }
                return coordinator.browser
            },
            available: { [weak app] browser in
                app?.windows.contains {
                    $0.browser === browser && !$0.isClosed && $0.nativeWindow != nil && !$0.isMicro
                        && !$0.profiles.isPrivate && !$0.isSwitchingProfile && !$0.agentTurns.isRunning
                } == true
            }
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
            disconnectMCP: { [weak server] browser in
                server?.disconnect(browser: browser)
            },
            cancelMCPCalls: { [weak server] browser in
                server?.cancelActiveCall(in: browser)
            }
        )
        server.agentWindowRegistry = registry
        app.mcpServer = server
        app.agentWindowRegistry = registry
        return (server, registry, endpoint)
    }

    // MARK: - Multi-tab isolation & Chromium default

    @Test func agentMicroWindowRetainsMultipleTabsAndNeverLeaksToMainWindow() async throws {
        try await withProfile { profile in
            let app = makeApp()
            defer { finish(app) }
            let main = app.newWindow(profile: profile, show: false)
            let mainInitialCount = main.browser.tabs.count

            let companion = AgentCompanionInfo(hostName: "t3-code", threadId: "thread-tabs", threadTitle: "Preview")
            let agentWindow = app.openAgentMicroWindow(
                profile: profile,
                companion: companion,
                url: URL(string: "https://one.example/"),
                engine: .chromium,
                floatOnTop: false,
                open: false
            )

            #expect(agentWindow.isMicro)
            #expect(agentWindow.isAgentMicro)
            #expect(agentWindow.keepsOwnTabs)
            #expect(agentWindow.browser.tabs.count == 1)
            #expect(agentWindow.browser.activeTab?.engineOverride == .chromium)
            #expect(MicroWindowBadge.offer(for: agentWindow, tab: agentWindow.browser.activeTab) == nil)
            #expect(MicroShell.keepsBar(browser: agentWindow.browser, coordinator: agentWindow, isEditing: false, voiceOver: false))

            // Opening additional tabs, linked tabs, popups, and new-window requests all stay in the Agent Micro Window.
            let firstTab = try #require(agentWindow.browser.activeTab)
            let secondTab = agentWindow.browser.newTab(url: URL(string: "https://two.example/"), activate: true, transition: .agent)
            firstTab.onOpenInNewTab?(try #require(URL(string: "https://three.example/")), false)
            let popupView = WKWebView(frame: .zero, configuration: WebViewPool.makeConfiguration())
            firstTab.onNewWindow?(popupView, false)
            agentWindow.browser.onOpenInNewWindow?(firstTab, try #require(URL(string: "https://four.example/")), false)

            // Let any async handOff tasks run.
            try await Task.sleep(for: .milliseconds(100))

            #expect(agentWindow.browser.tabs.count == 5, "all tabs stay inside the Agent Micro Window")
            #expect(main.browser.tabs.count == mainInitialCount, "zero tabs leaked into the user's main window")
            #expect(secondTab.engineOverride == .chromium, "tabs in Agent Micro Window default to Chromium")
            #expect(!agentWindow.giveToMainWindow(firstTab, activate: true), "Agent Micro Window tabs cannot hand off to main")

            // Ephemeral: Agent Micro Windows never persist into sessionWindow or CloudTabs.
            agentWindow.browser.saveBlocking()
            #expect(!BrowserModel.savedWindows(in: main.context.database, includeClosed: true).contains { $0.id == agentWindow.windowID })
            #expect(agentWindow.browser.cloudTabsNodes().isEmpty)
        }
    }

    @Test func agentMicroWindowDefaultsToChromiumAndSwitchesToWebKit() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Engine Switch</title><p>Hello</p>"),
        ])
        let url = try server.url("/")
        try await withProfile { profile in
            let context = BrowserProfileContext.shared(for: profile)
            let app = makeApp()
            let trust = MCPTrustStore(storage: MemoryTrustStorage())
            let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let directory = "/tmp/wsurf-agent-engine-\(UUID().uuidString)"
            defer {
                finish(app)
                try? FileManager.default.removeItem(atPath: directory)
                withExtendedLifetime(server) {}
            }
            let (_, registry, _) = makeIsolatedServer(in: app, directory: directory, trust: trust)

            let hostId = UUID()
            let opened = try await registry.openAgentWindow(
                hostId: hostId,
                pairedClientId: paired.id,
                hostName: "t3-code",
                params: [
                    "threadId": "thread-engine",
                    "profileId": profile.id.uuidString,
                    "url": url.absoluteString,
                ]
            )
            #expect(opened["engine"] as? String == "chromium")
            let tabId = try #require(opened["tabId"] as? String)
            let windowId = try #require((opened["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let agentWindow = try #require(app.windows.first { $0.windowID == windowId })
            let tabUUID = try #require(UUID(uuidString: tabId))
            let tab = try #require(agentWindow.browser.tab(id: tabUUID))
            try #require(await waitUntil { tab.liveView?.engine == .chromium && !tab.isLoading })

            // Switch to WebKit for Safari testing.
            let switched = try await registry.invokePreview(
                hostId: hostId,
                pairedClientId: paired.id,
                hostName: "t3-code",
                params: [
                    "threadId": "thread-engine",
                    "tabId": tabId,
                    "operation": "set_engine",
                    "params": ["engine": "webkit"],
                ]
            )
            #expect(switched["engine"] as? String == "webkit")
            try #require(await waitUntil { tab.liveView?.engine == .webKit && !tab.isLoading })
            #expect(tab.engineOverride == .webKit)

            // Switch back to Chromium.
            let back = try await registry.invokePreview(
                hostId: hostId,
                pairedClientId: paired.id,
                hostName: "t3-code",
                params: [
                    "threadId": "thread-engine",
                    "tabId": tabId,
                    "operation": "set_engine",
                    "params": ["engine": "chromium"],
                ]
            )
            #expect(back["engine"] as? String == "chromium")
            try #require(await waitUntil { tab.liveView?.engine == .chromium && !tab.isLoading })

            finish(app)
            await tab.waitForRetirement()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        }
    }

    // MARK: - Strict window isolation & window-scoped MCP auto-allow

    @Test(.timeLimit(.minutes(1))) func windowTokenGrantsAutoAllowToAgentMicroWindowOnlyAndRejectsBadTokens() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/agent": .html("<title>Agent Target</title><p>Agent Target</p><button id='go'>Run</button>"),
            "/user": .html("<title>User Secret Page</title><p>Private user tab</p>"),
        ])
        let agentURL = try fixture.url("/agent")
        let userURL = try fixture.url("/user")
        try await withProfile { profile in
            let context = BrowserProfileContext.shared(for: profile)
            let directory = "/tmp/wsurf-agent-scope-\(UUID().uuidString)"
            let app = makeApp()
            let trust = MCPTrustStore(storage: MemoryTrustStorage())
            let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let (server, registry, endpoint) = makeIsolatedServer(in: app, directory: directory, trust: trust)
            defer {
                finish(app)
                try? FileManager.default.removeItem(atPath: directory)
                withExtendedLifetime(fixture) {}
            }
            server.setEnabled(true)
            try #require(await waitUntil { server.isListening })

            // Regular user window with a user tab.
            let main = app.newWindow(profile: profile, show: false)
            let userTab = main.browser.newTab(url: userURL, activate: true)
            try #require(await waitUntil { userTab.liveView?.url == userURL && !userTab.isLoading })

            // Open an Agent Micro Window (using WebKit for fast deterministic fixture check).
            let hostId = UUID()
            let opened = try await registry.openAgentWindow(
                hostId: hostId,
                pairedClientId: paired.id,
                hostName: "t3-code",
                params: [
                    "threadId": "thread-iso",
                    "title": "Build UI",
                    "profileId": profile.id.uuidString,
                    "url": agentURL.absoluteString,
                    "engine": "webkit",
                ]
            )
            let windowToken = try #require(opened["windowToken"] as? String)
            let agentWindowId = try #require((opened["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let agentTabId = try #require(opened["tabId"] as? String)
            let agentWindow = try #require(app.windows.first { $0.windowID == agentWindowId })
            let agentTabUUID = try #require(UUID(uuidString: agentTabId))
            let agentTab = try #require(agentWindow.browser.tab(id: agentTabUUID))
            try #require(await waitUntil { agentTab.liveView?.url == agentURL && !agentTab.isLoading })

            // Ordinary MCP targeting never sees the Agent Micro Window even if focused.
            app.focus(agentWindow)
            #expect(app.activeBrowsingCoordinator === main)
            #expect(app.externalLinkTarget === main)
            #expect(server.makeSessionForConnection(browser: agentWindow.browser) == nil)
            #expect(server.makeSessionForConnection()?.isBound(to: main.browser) == true)

            // 1. Connecting with a valid paired token + valid windowToken binds ONLY to the Agent Micro Window with auto-allow (no consent sheet!).
            let validHello = try #require(MCPPairing.helloMessage(token: SyntheticToken.first, windowToken: windowToken))
            let validTransport = LocalMCPTransport(
                connection: NWConnection(to: .unix(path: endpoint), using: .tcp),
                hello: validHello
            )
            let validClient = MCP.Client(name: "T3 Agent", version: "1")
            _ = try await validClient.connect(transport: validTransport)
            defer { Task { await validTransport.disconnect() } }

            let (listContent, listFailed) = try await validClient.callTool(name: "listTabs")
            #expect(listFailed == false)
            let listText = listContent.compactMap { block -> String? in
                if case .text(let text, _, _) = block {
                    return text
                }
                return nil
            }.joined()
            #expect(listText.contains(agentTabId), "agent tab is pre-approved without requestAccess consent sheet")
            #expect(!listText.contains(userTab.id.uuidString), "user's regular window tab is NEVER visible")

            // Reading the agent tab works immediately with zero consent sheet.
            let (readContent, readFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(agentTabId)])
            #expect(readFailed == false)
            let readText = readContent.compactMap { block -> String? in
                if case .text(let text, _, _) = block {
                    return text
                }
                return nil
            }.joined()
            #expect(readText.contains("Agent Target"))

            // Attempting to read the user's regular window tab is refused.
            let (_, userTabFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(userTab.id.uuidString)])
            #expect(userTabFailed == true)

            // 2. Take Over immediately blocks window-scoped MCP calls with humanControl!
            agentWindow.takeOverAgentMicroWindow()
            #expect(agentWindow.browser.agentCompanion?.owner == .human)
            #expect(agentWindow.browser.agentCompanion?.generation == 2)
            let (takenOverContent, takenOverFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(agentTabId)])
            #expect(takenOverFailed == true)
            let takenOverText = takenOverContent.compactMap { block -> String? in
                if case .text(let text, _, _) = block {
                    return text
                }
                return nil
            }.joined()
            #expect(takenOverText.contains("humanControl"))

            // 3. Hand Back resumes window-scoped MCP control seamlessly with bumped generation.
            agentWindow.handBackAgentMicroWindow()
            #expect(agentWindow.browser.agentCompanion?.owner == .agent)
            #expect(agentWindow.browser.agentCompanion?.generation == 3)
            let (_, resumedFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(agentTabId)])
            #expect(resumedFailed == false)

            // 4. An invalid windowToken NEVER falls back to the regular window — connection is dropped!
            let sessionsBeforeBad = server.sessions.count
            let badHello = try #require(MCPPairing.helloMessage(token: SyntheticToken.first, windowToken: SyntheticToken.stranger))
            try await assertRejectedMCPConnection(endpoint: endpoint, hello: badHello)
            try #require(await waitUntil { server.sessions.count == sessionsBeforeBad })

            // 5. Stop revokes windowToken and disconnects the live window-scoped session immediately!
            let scopedSession = try #require(server.sessions.first { $0.isBound(to: agentWindow.browser) })
            agentWindow.stopAgentMicroWindow()
            #expect(!scopedSession.isConnected)
            #expect(agentWindow.browser.agentCompanion == nil)
            #expect(registry.resolve(windowToken: windowToken, pairedClientId: paired.id) == nil)

            finish(app)
            await agentTab.waitForRetirement()
            await userTab.waitForRetirement()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        }
    }

    @Test(.timeLimit(.minutes(1))) func windowTokenConnectsEvenWhenNoRegularWindowExists() async throws {
        try await withProfile { profile in
            let directory = "/tmp/wsurf-agent-only-\(UUID().uuidString)"
            let app = makeApp()
            let trust = MCPTrustStore(storage: MemoryTrustStorage())
            let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let (server, registry, endpoint) = makeIsolatedServer(in: app, directory: directory, trust: trust)
            defer {
                finish(app)
                try? FileManager.default.removeItem(atPath: directory)
            }
            server.setEnabled(true)
            try #require(await waitUntil { server.isListening })

            // Open ONLY an Agent Micro Window (no regular window at all!).
            let opened = try await registry.openAgentWindow(
                hostId: UUID(),
                pairedClientId: paired.id,
                hostName: "t3-code",
                params: [
                    "threadId": "thread-solo",
                    "profileId": profile.id.uuidString,
                    "engine": "webkit",
                ]
            )
            let windowToken = try #require(opened["windowToken"] as? String)
            #expect(server.makeSessionForConnection() == nil, "ordinary MCP still sees no regular window")

            // A window-scoped client connects cleanly!
            let hello = try #require(MCPPairing.helloMessage(token: SyntheticToken.first, windowToken: windowToken))
            let transport = LocalMCPTransport(
                connection: NWConnection(to: .unix(path: endpoint), using: .tcp),
                hello: hello
            )
            let client = MCP.Client(name: "Solo Agent", version: "1")
            _ = try await client.connect(transport: transport)
            defer { Task { await transport.disconnect() } }
            let (_, failed) = try await client.callTool(name: "listTabs")
            #expect(failed == false)

            // An ordinary client without windowToken is rejected when no regular window exists.
            try await assertRejectedMCPConnection(endpoint: endpoint, hello: nil)
        }
    }

    private func assertRejectedMCPConnection(endpoint: String, hello: Data?) async throws {
        let transport = LocalMCPTransport(
            connection: NWConnection(to: .unix(path: endpoint), using: .tcp),
            hello: hello
        )
        defer { Task { await transport.disconnect() } }
        let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Rejected","version":"1"}}}"#.utf8)
        do {
            try await transport.connect()
            try await transport.send(initialize)
            var replies = await transport.receive().makeAsyncIterator()
            let reply = try await replies.next()
            #expect(reply == nil, "Server must close rejected connection without sending an MCP reply")
        } catch {
            // Expected: server closed or rejected the socket.
        }
    }

    @Test func microBarStatusSummaryReflectsHostThreadAndOwner() {
        var companion = AgentCompanionInfo(hostName: "t3-code", threadId: "t-1", threadTitle: "Fix checkout")
        #expect(AgentMicroControlBar.statusSummary(for: companion) == "T3 · Fix checkout · \(String(localized: "MCP Allowed"))")

        companion.owner = .human
        #expect(AgentMicroControlBar.statusSummary(for: companion) == "T3 · \(String(localized: "Human Control"))")

        companion.owner = .unclaimed
        #expect(AgentMicroControlBar.statusSummary(for: companion) == "T3 · \(String(localized: "Unclaimed"))")
    }

    @Test func takeOverCancelsInFlightAgentOperationAndBumpsGeneration() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Wait Page</title><p>Waiting...</p>"),
        ])
        let url = try server.url("/")
        try await withProfile { profile in
            let app = makeApp()
            let trust = MCPTrustStore(storage: MemoryTrustStorage())
            let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let directory = "/tmp/wsurf-agent-cancel-\(UUID().uuidString)"
            defer {
                finish(app)
                try? FileManager.default.removeItem(atPath: directory)
                withExtendedLifetime(server) {}
            }
            let (_, registry, _) = makeIsolatedServer(in: app, directory: directory, trust: trust)

            var events: [(String, [String: Any])] = []
            registry.onEvent = { _, event, payload in
                events.append((event, payload))
            }

            let hostId = UUID()
            let opened = try await registry.openAgentWindow(
                hostId: hostId,
                pairedClientId: paired.id,
                hostName: "t3-code",
                params: [
                    "threadId": "thread-cancel",
                    "profileId": profile.id.uuidString,
                    "url": url.absoluteString,
                    "engine": "webkit",
                ]
            )
            let tabId = try #require(opened["tabId"] as? String)
            let windowId = try #require((opened["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let agentWindow = try #require(app.windows.first { $0.windowID == windowId })
            let tabUUID = try #require(UUID(uuidString: tabId))
            let tab = try #require(agentWindow.browser.tab(id: tabUUID))
            try #require(await waitUntil { tab.liveView?.url == url && !tab.isLoading })

            // Start a long-running wait_for operation.
            let pending = Task<Void, any Error> { @MainActor in
                _ = try await registry.invokePreview(
                    hostId: hostId,
                    pairedClientId: paired.id,
                    hostName: "t3-code",
                    params: [
                        "threadId": "thread-cancel",
                        "tabId": tabId,
                        "expectedGeneration": 1,
                        "operation": "wait_for",
                        "params": [
                            "urlIncludes": "never-happens",
                            "timeoutMs": 15_000,
                        ],
                    ]
                )
            }
            try #require(await waitUntil { agentWindow.browser.agentCompanion?.isWorking == true })

            // User clicks Take Over while the agent operation is running!
            agentWindow.takeOverAgentMicroWindow()

            do {
                _ = try await pending.value
                Issue.record("Expected wait_for to fail when user took over")
            } catch let error as MCPAgentWindowError {
                #expect(error.code == .humanControl || error.code == .cancelled)
            }
            #expect(agentWindow.browser.agentCompanion?.owner == .human)
            #expect(agentWindow.browser.agentCompanion?.generation == 2)
            #expect(agentWindow.browser.agentCompanion?.isWorking == false)
            #expect(events.contains { $0.0 == "ownerChanged" && ($0.1["owner"] as? String) == "human" && ($0.1["generation"] as? Int) == 2 })
        }
    }

    @Test func agentMicroWindowRejectsPrivateProfile() async throws {
        let app = makeApp()
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
        let directory = "/tmp/wsurf-agent-priv-\(UUID().uuidString)"
        defer {
            finish(app)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let (_, registry, _) = makeIsolatedServer(in: app, directory: directory, trust: trust)

        for requested in ["private", Profile.privateID.uuidString] {
            do {
                _ = try await registry.openAgentWindow(
                    hostId: UUID(),
                    pairedClientId: paired.id,
                    hostName: "t3-code",
                    params: ["threadId": "thread-priv", "profileId": requested]
                )
                Issue.record("Expected private profile \(requested) to be forbidden")
            } catch let error as MCPAgentWindowError {
                #expect(error.code == .forbidden)
            }
        }
    }
}
