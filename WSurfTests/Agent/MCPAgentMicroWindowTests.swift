// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import MCP
import Network
import Testing
import WebKit

@testable import WSurf

/// Tests for detached Agent Micro Windows: multi-tab retention, Chromium default + WebKit switching,
/// `webKitOnlyOrigins` & `signInEngine` protection, strict isolation & SQLite/CloudTabs non-persistence,
/// Take Over / Hand Back / Stop finality, and window-scoped MCP auto-allow.
@MainActor
@Suite(.serialized, .boundedWebViews, .noAnnouncePause)
struct MCPAgentMicroWindowTests {
    private func withProfile(name: String = "Agent Micro Tests", _ body: (Profile) async throws -> Void) async throws {
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

    private struct SessionRowCounts: Equatable {
        let windows: Int
        let tabs: Int
        let retirements: Int
        static let zero = Self(windows: 0, tabs: 0, retirements: 0)
    }

    private func sessionRowCounts(in database: AppDatabase, windowID: UUID) throws -> SessionRowCounts {
        try database.writer.read { db in
            let windows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessionWindow WHERE id = ?", arguments: [windowID]) ?? 0
            let tabs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessionTab WHERE windowID = ?", arguments: [windowID]) ?? 0
            let retirements = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessionWindowRetirement WHERE id = ?",
                arguments: [windowID]
            ) ?? 0
            return SessionRowCounts(windows: windows, tabs: tabs, retirements: retirements)
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

    // MARK: - Multi-tab isolation & Chromium default

    @Test func agentMicroWindowRetainsMultipleTabsAndNeverLeaksToMainWindow() async throws {
        try await withProfile { profile in
            let app = makeApp()
            defer { finish(app) }
            let main = app.newWindow(profile: profile, show: false)
            let mainInitialCount = main.browser.tabs.count

            let companion = AgentCompanionInfo(hostName: "T3 Code", threadId: "thread-tabs", threadTitle: "Preview")
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
            #expect(agentWindow.browser.activeTab?.defaultEngineOverride == .chromium)
            #expect(MicroWindowBadge.offer(for: agentWindow, tab: agentWindow.browser.activeTab) == nil)
            #expect(MicroShell.keepsBar(browser: agentWindow.browser, coordinator: agentWindow, isEditing: false, voiceOver: false))

            let firstTab = try #require(agentWindow.browser.activeTab)
            let secondTab = agentWindow.browser.newTab(url: URL(string: "https://two.example/"), activate: true, transition: .agent)
            firstTab.onOpenInNewTab?(try #require(URL(string: "https://three.example/")), false)
            let popupView = WKWebView(frame: .zero, configuration: WebViewPool.makeConfiguration())
            firstTab.onNewWindow?(popupView, false)
            agentWindow.browser.onOpenInNewWindow?(firstTab, try #require(URL(string: "https://four.example/")), false)

            try await Task.sleep(for: .milliseconds(100))

            #expect(agentWindow.browser.tabs.count == 5, "all tabs stay inside the Agent Micro Window")
            #expect(main.browser.tabs.count == mainInitialCount, "zero tabs leaked into the user's main window")
            #expect(secondTab.defaultEngineOverride == .chromium, "tabs in Agent Micro Window default to Chromium")
            #expect(!agentWindow.giveToMainWindow(firstTab, activate: true), "Agent Micro Window tabs cannot hand off to main")

            agentWindow.browser.saveBlocking()
            let counts = try sessionRowCounts(in: main.context.database, windowID: agentWindow.windowID)
            #expect(counts == .zero)
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

            let opened = try await registry.openAgentWindow(
                pairedClientId: paired.id,
                hostName: "T3 Code",
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
                pairedClientId: paired.id,
                hostName: "T3 Code",
                params: [
                    "threadId": "thread-engine",
                    "tabId": tabId,
                    "operation": "set_engine",
                    "params": ["engine": "webkit"],
                ]
            )
            #expect(switched["engine"] as? String == "webkit")
            try #require(await waitUntil { tab.liveView?.engine == .webKit && !tab.isLoading })
            #expect(tab.defaultEngineOverride == .webKit)

            // Switch back to Chromium.
            let back = try await registry.invokePreview(
                pairedClientId: paired.id,
                hostName: "T3 Code",
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

    // MARK: - M1: WebKit-only sign-in origins & signInEngine precedence

    @Test func webKitOnlyOriginsAndSignInEngineOverrideChromiumDefault() async throws {
        try await withProfile { profile in
            let app = makeApp()
            let trust = MCPTrustStore(storage: MemoryTrustStorage())
            let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let directory = "/tmp/wsurf-agent-wkonly-\(UUID().uuidString)"
            defer {
                finish(app)
                try? FileManager.default.removeItem(atPath: directory)
            }
            let (_, registry, _) = makeIsolatedServer(in: app, directory: directory, trust: trust)

            // Opening a blank Agent Micro Window defaults to Chromium.
            let opened = try await registry.openAgentWindow(
                pairedClientId: paired.id,
                hostName: "T3 Code",
                params: ["threadId": "thread-wkonly", "profileId": profile.id.uuidString]
            )
            let tabId = try #require(opened["tabId"] as? String)
            let windowId = try #require((opened["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let agentWindow = try #require(app.windows.first { $0.windowID == windowId })
            let tabUUID = try #require(UUID(uuidString: tabId))
            let tab = try #require(agentWindow.browser.tab(id: tabUUID))

            let googleSignIn = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth"))
            let openAISignIn = try #require(URL(string: "https://auth.openai.com/authorize"))
            let normalSite = try #require(URL(string: "https://app.example/dashboard"))

            // Normal site defaults to Chromium; WebKit-only sign-in origins MUST resolve to WebKit!
            #expect(tab.preferredEngine(for: normalSite) == .chromium)
            #expect(tab.preferredEngine(for: googleSignIn) == .webKit)
            #expect(tab.preferredEngine(for: openAISignIn) == .webKit)

            // Active signInEngine hold keeps sign-in return redirects in WebKit even on a Chromium-default agent tab.
            tab.noteNavigation(to: googleSignIn, startedByUser: false)
            #expect(tab.signInEngine == .webKit)
            #expect(tab.preferredEngine(for: normalSite, keepingSignIn: true) == .webKit)
            #expect(tab.preferredEngine(for: normalSite, keepingSignIn: false) == .chromium)

            // Explicit set_engine("chromium") on accounts.google.com is refused with `.unsupported`.
            tab.urlString = googleSignIn.absoluteString
            #expect(agentWindow.browser.engine(for: tab) == .webKit)
            do {
                _ = try await registry.invokePreview(
                    pairedClientId: paired.id,
                    hostName: "T3 Code",
                    params: [
                        "threadId": "thread-wkonly",
                        "tabId": tabId,
                        "operation": "set_engine",
                        "params": ["engine": "chromium"],
                    ]
                )
                Issue.record("Expected set_engine(chromium) on accounts.google.com to fail with unsupported")
            } catch let error as MCPAgentWindowError {
                #expect(error.code == .unsupported)
            }

            // Explicit openAgentWindow with engine:"chromium" and accounts.google.com is also refused.
            do {
                _ = try await registry.openAgentWindow(
                    pairedClientId: paired.id,
                    hostName: "T3 Code",
                    params: [
                        "threadId": "thread-wkonly-2",
                        "profileId": profile.id.uuidString,
                        "url": googleSignIn.absoluteString,
                        "engine": "chromium",
                    ]
                )
                Issue.record("Expected openAgentWindow(engine: chromium) on accounts.google.com to fail")
            } catch let error as MCPAgentWindowError {
                #expect(error.code == .unsupported)
            }
        }
    }

    // MARK: - H3: Zero SQLite / CloudTabs persistence across every close/stop/revoke path

    @Test func zeroSessionRowsPersistedAcrossCloseLastTabStopAndRevoke() async throws {
        try await withProfile { profile in
            let context = BrowserProfileContext.shared(for: profile)
            let app = makeApp()
            let trust = MCPTrustStore(storage: MemoryTrustStorage())
            let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let directory = "/tmp/wsurf-agent-ephemeral-\(UUID().uuidString)"
            defer {
                finish(app)
                try? FileManager.default.removeItem(atPath: directory)
            }
            let (server, registry, _) = makeIsolatedServer(in: app, directory: directory, trust: trust)

            // 1. closeAgentWindow
            let w1 = try await registry.openAgentWindow(
                pairedClientId: paired.id, hostName: "T3 Code",
                params: ["threadId": "t-close", "profileId": profile.id.uuidString, "engine": "webkit"]
            )
            let id1 = try #require((w1["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            _ = try registry.closeAgentWindow(pairedClientId: paired.id, threadId: "t-close", windowId: id1)
            #expect(try sessionRowCounts(in: context.database, windowID: id1) == .zero)

            // 2. Last-tab preview close
            let w2 = try await registry.openAgentWindow(
                pairedClientId: paired.id, hostName: "T3 Code",
                params: ["threadId": "t-lasttab", "profileId": profile.id.uuidString, "engine": "webkit"]
            )
            let id2 = try #require((w2["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let tab2 = try #require(w2["tabId"] as? String)
            _ = try await registry.invokePreview(
                pairedClientId: paired.id, hostName: "T3 Code",
                params: ["threadId": "t-lasttab", "tabId": tab2, "operation": "close"]
            )
            #expect(try sessionRowCounts(in: context.database, windowID: id2) == .zero)

            // 3. Stop in MicroBar (both while still open and after subsequently closing the window!)
            let w3 = try await registry.openAgentWindow(
                pairedClientId: paired.id, hostName: "T3 Code",
                params: ["threadId": "t-stop", "profileId": profile.id.uuidString, "engine": "webkit"]
            )
            let id3 = try #require((w3["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let coord3 = try #require(app.windows.first { $0.windowID == id3 })
            coord3.stopAgentMicroWindow()
            #expect(coord3.browser.agentCompanion == nil)
            #expect(coord3.isAgentMicro, "ephemeral agent identity stays sticky after Stop")
            #expect(coord3.browser.cloudTabsNodes().isEmpty)
            coord3.browser.saveBlocking()
            coord3.closeWindow()
            #expect(try sessionRowCounts(in: context.database, windowID: id3) == .zero)

            // Resume client to test path 4 (revoke)
            try trust.setPaused(false, for: paired.id)
            let w4 = try await registry.openAgentWindow(
                pairedClientId: paired.id, hostName: "T3 Code",
                params: ["threadId": "t-revoke", "profileId": profile.id.uuidString, "engine": "webkit"]
            )
            let id4 = try #require((w4["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let coord4 = try #require(app.windows.first { $0.windowID == id4 })
            try server.revoke(paired)
            #expect(coord4.browser.agentCompanion == nil)
            #expect(coord4.isAgentMicro, "ephemeral agent identity stays sticky after revoke")
            coord4.closeWindow()
            #expect(try sessionRowCounts(in: context.database, windowID: id4) == .zero)
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

            let main = app.newWindow(profile: profile, show: false)
            let userTab = main.browser.newTab(url: userURL, activate: true)
            try #require(await waitUntil { userTab.liveView?.url == userURL && !userTab.isLoading })

            let opened = try await registry.openAgentWindow(
                pairedClientId: paired.id,
                hostName: "T3 Code",
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

            // 1. Valid paired token + valid windowToken binds ONLY to the Agent Micro Window with auto-allow.
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
            let listText = listContent.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
            #expect(listText.contains(agentTabId))
            #expect(!listText.contains(userTab.id.uuidString))

            let (readContent, readFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(agentTabId)])
            #expect(readFailed == false)
            let readText = readContent.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
            #expect(readText.contains("Agent Target"))

            let (_, userTabFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(userTab.id.uuidString)])
            #expect(userTabFailed == true)

            // 2. Take Over blocks window-scoped MCP calls with humanControl; Hand Back resumes.
            agentWindow.takeOverAgentMicroWindow()
            let (takenOverContent, takenOverFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(agentTabId)])
            #expect(takenOverFailed == true)
            let takenOverText = takenOverContent.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
            #expect(takenOverText.contains("humanControl"))

            agentWindow.handBackAgentMicroWindow()
            let (_, resumedFailed) = try await validClient.callTool(name: "readPage", arguments: ["tabID": .string(agentTabId)])
            #expect(resumedFailed == false)

            // 3. Invalid windowToken NEVER falls back to the regular window.
            let sessionsBeforeBad = server.sessions.count
            let badHello = try #require(MCPPairing.helloMessage(token: SyntheticToken.first, windowToken: SyntheticToken.stranger))
            try await assertRejectedMCPConnection(endpoint: endpoint, hello: badHello)
            try #require(await waitUntil { server.sessions.count == sessionsBeforeBad })

            // 4. Stop revokes windowToken, disconnects live session, AND pauses the paired client!
            let scopedSession = try #require(server.sessions.first { $0.isBound(to: agentWindow.browser) })
            agentWindow.stopAgentMicroWindow()
            #expect(!scopedSession.isConnected)
            #expect(agentWindow.browser.agentCompanion == nil)
            #expect(trust.client(id: paired.id)?.paused == true, "Stop pauses the paired client in MCPTrustStore")
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

            let opened = try await registry.openAgentWindow(
                pairedClientId: paired.id,
                hostName: "T3 Code",
                params: [
                    "threadId": "thread-solo",
                    "profileId": profile.id.uuidString,
                    "engine": "webkit",
                ]
            )
            let windowToken = try #require(opened["windowToken"] as? String)
            #expect(server.makeSessionForConnection() == nil, "ordinary MCP still sees no regular window")

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

            try await assertRejectedMCPConnection(endpoint: endpoint, hello: nil)
        }
    }

    // MARK: - Default access, Developer profile preference, caps, working tokens, MicroBar

    @Test func defaultsToControlAccessPrefersDeveloperProfileAndEnforcesPerClientCap() async throws {
        try await withProfile(name: "Everyday Profile") { everyday in
            try await withProfile(name: "Dev Profile") { devProfile in
                let app = makeApp()
                let trust = MCPTrustStore(storage: MemoryTrustStorage())
                let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
                try trust.setDeveloperProfile(devProfile.id, dedicated: true)
                let directory = "/tmp/wsurf-agent-defaults-\(UUID().uuidString)"
                defer {
                    finish(app)
                    try? FileManager.default.removeItem(atPath: directory)
                }
                let (_, registry, _) = makeIsolatedServer(in: app, directory: directory, trust: trust)

                // Omitting profileId & access defaults to Developer profile + `.control` access!
                ProfileStore.shared.markCurrent(everyday)
                let first = try await registry.openAgentWindow(
                    pairedClientId: paired.id,
                    hostName: "spoofed-unverified-host",
                    params: ["threadId": "cap-0", "engine": "webkit"]
                )
                let firstWinID = try #require((first["windowId"] as? String).flatMap(UUID.init(uuidString:)))
                let firstWindow = try #require(app.windows.first { $0.windowID == firstWinID })
                #expect(firstWindow.context.profile.id == devProfile.id, "defaults to Developer profile when configured")
                #expect(firstWindow.browser.agentCompanion?.access == .control, "defaults to control access, not development")
                #expect(firstWindow.browser.agentCompanion?.hostName == "T3 Code", "uses verified paired client name from MCPTrustStore")

                // Open up to the per-client cap (8 total), then the 9th MUST fail with forbidden.
                for idx in 1..<MCPAgentWindowRegistry.maxWindowsPerClient {
                    _ = try await registry.openAgentWindow(
                        pairedClientId: paired.id,
                        hostName: "T3 Code",
                        params: ["threadId": "cap-\(idx)", "engine": "webkit"]
                    )
                }
                do {
                    _ = try await registry.openAgentWindow(
                        pairedClientId: paired.id,
                        hostName: "T3 Code",
                        params: ["threadId": "cap-overflow", "engine": "webkit"]
                    )
                    Issue.record("Expected exceeding maxWindowsPerClient to fail with forbidden")
                } catch let error as MCPAgentWindowError {
                    #expect(error.code == .forbidden)
                }
            }
        }
    }

    @Test func workingTokensDoNotUnderflowAfterTakeOverAndHandBack() async throws {
        try await withProfile { profile in
            let app = makeApp()
            let trust = MCPTrustStore(storage: MemoryTrustStorage())
            let paired = try trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let directory = "/tmp/wsurf-agent-worktok-\(UUID().uuidString)"
            defer {
                finish(app)
                try? FileManager.default.removeItem(atPath: directory)
            }
            let (_, registry, _) = makeIsolatedServer(in: app, directory: directory, trust: trust)
            let opened = try await registry.openAgentWindow(
                pairedClientId: paired.id, hostName: "T3 Code",
                params: ["threadId": "worktok", "profileId": profile.id.uuidString, "engine": "webkit"]
            )
            let windowId = try #require((opened["windowId"] as? String).flatMap(UUID.init(uuidString:)))
            let agentWindow = try #require(app.windows.first { $0.windowID == windowId })
            let record = try #require(registry.record(pairedClientId: paired.id, threadId: "worktok"))

            let oldToken = registry.beginWorking(for: record)
            #expect(agentWindow.browser.agentCompanion?.isWorking == true)

            agentWindow.takeOverAgentMicroWindow()
            #expect(agentWindow.browser.agentCompanion?.isWorking == false)

            agentWindow.handBackAgentMicroWindow()
            let newToken = registry.beginWorking(for: record)
            #expect(agentWindow.browser.agentCompanion?.isWorking == true)

            // Late completion of the cancelled old operation must NOT clear the new operation's working indicator.
            registry.endWorking(oldToken, for: record)
            #expect(agentWindow.browser.agentCompanion?.isWorking == true)

            registry.endWorking(newToken, for: record)
            #expect(agentWindow.browser.agentCompanion?.isWorking == false)
        }
    }

    @Test func microBarStatusSummaryReflectsHostThreadAndOwner() {
        var companion = AgentCompanionInfo(hostName: "T3 Code", threadId: "t-1", threadTitle: "Fix checkout")
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

            let opened = try await registry.openAgentWindow(
                pairedClientId: paired.id,
                hostName: "T3 Code",
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

            let pending = Task<Void, any Error> { @MainActor in
                _ = try await registry.invokePreview(
                    pairedClientId: paired.id,
                    hostName: "T3 Code",
                    params: [
                        "threadId": "thread-cancel",
                        "tabId": tabId,
                        "expectedGeneration": 1,
                        "operation": "wait_for",
                        "params": ["urlIncludes": "never-happens", "timeoutMs": 15_000],
                    ]
                )
            }
            try #require(await waitUntil { agentWindow.browser.agentCompanion?.isWorking == true })

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
                    pairedClientId: paired.id,
                    hostName: "T3 Code",
                    params: ["threadId": "thread-priv", "profileId": requested]
                )
                Issue.record("Expected private profile \(requested) to be forbidden")
            } catch let error as MCPAgentWindowError {
                #expect(error.code == .forbidden)
            }
        }
    }
}
