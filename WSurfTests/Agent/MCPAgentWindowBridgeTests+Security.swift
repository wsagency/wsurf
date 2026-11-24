// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

extension MCPAgentWindowBridgeTests {
    // MARK: - Unclaimed owner, standing cap, explicit `.ask`, Stop Keychain resilience, pending-hello cap

    @Test(.timeLimit(.minutes(1))) func unclaimedOwnerRefusesMutationsCloseAndOpenReuse() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/app": .html("<!doctype html><title>Unclaimed Fixture</title><p>Hello</p><button id='btn'>Go</button>"),
            "/next": .html("<!doctype html><title>Next</title><p>Next</p>"),
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
                id: "u-open", op: "openAgentWindow",
                params: [
                    "threadId": "thread-unclaimed", "title": "Original",
                    "profileId": profile.id.uuidString, "url": appURL.absoluteString, "engine": "webkit",
                ]
            )
            let openResult = try #require(openResp["result"] as? [String: Any])
            let windowId = try #require(openResult["windowId"] as? String)
            let tabId = try #require(openResult["tabId"] as? String)
            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })
            let agentTab = try #require(agentWindow.browser.tabs.first { $0.id.uuidString == tabId })
            try #require(await waitUntil { agentTab.liveView?.url == appURL && !agentTab.isLoading })

            // Host transitions .agent -> .unclaimed.
            let (unclaimResp, _) = try await client.request(
                id: "u-set", op: "setOwner",
                params: ["tabId": tabId, "owner": "unclaimed"]
            )
            #expect(unclaimResp["ok"] as? Bool == true)
            #expect(agentWindow.browser.agentCompanion?.owner == .unclaimed)

            // Every preview op except `status` MUST be refused while unclaimed!
            let blockedOps: [(String, String, [String: Any])] = [
                ("u-nav", "navigate", ["url": nextURL.absoluteString]),
                ("u-close", "close", [:]),
                ("u-resize", "resize", ["width": 500, "height": 400]),
                ("u-engine", "set_engine", ["engine": "chromium"]),
                ("u-snap", "snapshot", [:]),
                ("u-act", "act", ["action": "click", "selector": "#btn"]),
            ]
            for (reqId, op, opParams) in blockedOps {
                let (resp, _) = try await client.request(
                    id: reqId, op: "invokePreview",
                    params: ["tabId": tabId, "threadId": "thread-unclaimed", "operation": op, "params": opParams]
                )
                #expect(resp["ok"] as? Bool == false, "\(op) must be refused while unclaimed")
                #expect((resp["error"] as? [String: Any])?["code"] as? String == "denied")
            }

            // openAgentWindow reuse while unclaimed MUST also be refused without mutating title/floatOnTop!
            let (reuseResp, _) = try await client.request(
                id: "u-reuse", op: "openAgentWindow",
                params: ["threadId": "thread-unclaimed", "title": "Mutated", "floatOnTop": true, "url": nextURL.absoluteString]
            )
            #expect(reuseResp["ok"] as? Bool == false)
            #expect((reuseResp["error"] as? [String: Any])?["code"] as? String == "denied")
            #expect(agentWindow.browser.agentCompanion?.threadTitle == "Original")
            #expect(agentWindow.floatsOnTop == false)

            // Read-only `status` still succeeds while unclaimed.
            let (statusResp, _) = try await client.request(
                id: "u-status", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "thread-unclaimed", "operation": "status"]
            )
            #expect(statusResp["ok"] as? Bool == true)
            #expect((statusResp["result"] as? [String: Any])?["owner"] as? String == "unclaimed")
        }
    }

    @Test(.timeLimit(.minutes(1))) func openAgentWindowCapsAccessByStandingAndRefusesExplicitAskSites() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/ok": .html("<!doctype html><title>Default Site</title><p>OK</p><button id='btn'>Go</button>"),
            "/ask": .html("<!doctype html><title>Ask Site</title><p>Ask First</p>"),
        ])
        let okURL = try fixture.url("/ok")
        let askURL = try fixture.url("/ask")
        try await withProfile { profile in
            let harness = try await startHarness()
            defer {
                stopHarness(harness)
                withExtendedLifetime(fixture) {}
            }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let client = try await connectAuthenticated(harness)
            defer { Task { await client.close() } }

            // 1. Standing `.off`: allows `.control`, refuses `.development` and `.developer` with `denied`.
            let (devDenied, _) = try await client.request(
                id: "st-1", op: "openAgentWindow",
                params: ["threadId": "st-t1", "profileId": profile.id.uuidString, "access": "development", "engine": "webkit"]
            )
            #expect(devDenied["ok"] as? Bool == false)
            #expect((devDenied["error"] as? [String: Any])?["code"] as? String == "denied")

            let (devTierDenied, _) = try await client.request(
                id: "st-2", op: "openAgentWindow",
                params: ["threadId": "st-t2", "profileId": profile.id.uuidString, "access": "developer", "engine": "webkit"]
            )
            #expect(devTierDenied["ok"] as? Bool == false)
            #expect((devTierDenied["error"] as? [String: Any])?["code"] as? String == "denied")

            let (ctrlAllowed, _) = try await client.request(
                id: "st-3", op: "openAgentWindow",
                params: ["threadId": "st-t3", "profileId": profile.id.uuidString, "url": okURL.absoluteString, "engine": "webkit"]
            )
            #expect(ctrlAllowed["ok"] as? Bool == true)
            let tabId = try #require((ctrlAllowed["result"] as? [String: Any])?["tabId"] as? String)
            let winId = try #require((ctrlAllowed["result"] as? [String: Any])?["windowId"] as? String)
            let agentWin = try #require(harness.app.windows.first { $0.windowID.uuidString == winId })
            let agentTab = try #require(agentWin.browser.tabs.first { $0.id.uuidString == tabId })
            try #require(await waitUntil { agentTab.liveView?.url == okURL && !agentTab.isLoading })

            // 2. Standing `.development`: allows `.development`, still refuses `.developer` with `denied`.
            try harness.trust.setStanding(.development, for: paired.id)
            let (devAllowed, _) = try await client.request(
                id: "st-4", op: "openAgentWindow",
                params: ["threadId": "st-t4", "profileId": profile.id.uuidString, "access": "development", "engine": "webkit"]
            )
            #expect(devAllowed["ok"] as? Bool == true)
            let (stillNoDeveloper, _) = try await client.request(
                id: "st-5", op: "openAgentWindow",
                params: ["threadId": "st-t5", "profileId": profile.id.uuidString, "access": "developer", "engine": "webkit"]
            )
            #expect(stillNoDeveloper["ok"] as? Bool == false)
            #expect((stillNoDeveloper["error"] as? [String: Any])?["code"] as? String == "denied")

            // 3. Explicit site `.ask` policy refuses silent grant in Agent Micro Window with `denied`.
            let askOrigin = SitePermissions.origin(for: askURL)
            agentWin.browser.sitePermissions.setAssistantAccess(.ask, for: askOrigin)
            let (askOpen, _) = try await client.request(
                id: "ask-1", op: "openAgentWindow",
                params: ["threadId": "ask-t1", "profileId": profile.id.uuidString, "url": askURL.absoluteString, "engine": "webkit"]
            )
            #expect(askOpen["ok"] as? Bool == false)
            #expect((askOpen["error"] as? [String: Any])?["code"] as? String == "denied")

            let (askNav, _) = try await client.request(
                id: "ask-2", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "st-t3", "operation": "navigate", "params": ["url": askURL.absoluteString]]
            )
            #expect(askNav["ok"] as? Bool == false)
            #expect((askNav["error"] as? [String: Any])?["code"] as? String == "denied")

            agentWin.browser.sitePermissions.setAssistantAccess(.ask, for: SitePermissions.origin(for: okURL))
            let (askAct, _) = try await client.request(
                id: "ask-3", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "st-t3", "operation": "act", "params": ["action": "click", "selector": "#btn"]]
            )
            #expect(askAct["ok"] as? Bool == false)
            #expect((askAct["error"] as? [String: Any])?["code"] as? String == "denied")

            let (askSnap, _) = try await client.request(
                id: "ask-4", op: "invokePreview",
                params: ["tabId": tabId, "threadId": "st-t3", "operation": "snapshot"]
            )
            #expect(askSnap["ok"] as? Bool == false)
            #expect((askSnap["error"] as? [String: Any])?["code"] as? String == "denied")
        }
    }

    @Test(.timeLimit(.minutes(1))) func stopBlocksReconnectEvenWhenKeychainWriteFails() async throws {
        try await withProfile { profile in
            let storage = MemoryTrustStorage()
            let harness = try await startHarness(storage: storage)
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)
            let client = try await connectAuthenticated(harness)
            defer { Task { await client.close() } }

            let (openResp, _) = try await client.request(
                id: "kc-1", op: "openAgentWindow",
                params: ["threadId": "kc-thread", "profileId": profile.id.uuidString, "engine": "webkit"]
            )
            let windowId = try #require((openResp["result"] as? [String: Any])?["windowId"] as? String)
            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })

            // Simulate Keychain write failure (e.g. unsigned build) right before user clicks Stop.
            storage.refuseWrites()
            agentWindow.stopAgentMicroWindow()

            // Even though Keychain could not persist `paused = true`, Stop STILL blocks the client in memory!
            #expect(harness.trust.client(id: paired.id)?.paused == false)
            #expect(harness.registry.isClientStopped(paired.id) == true)

            let retryClient = BridgeClient(socketPath: harness.bridgeEndpoint)
            try await retryClient.connect()
            try await retryClient.sendJSON(["wsurf": "host-hello", "v": 1, "token": SyntheticToken.first, "host": "t3-code"])
            let retryReply = try await retryClient.nextMessage()
            #expect(retryReply["ok"] as? Bool == false)
            #expect((retryReply["error"] as? [String: Any])?["code"] as? String == "unauthorized")
            await retryClient.close()
        }
    }

    @Test(.timeLimit(.minutes(1))) func pendingUnauthenticatedSocketsCannotStarveAuthenticatedHost() async throws {
        let harness = try await startHarness(authTimeout: .seconds(5))
        defer { stopHarness(harness) }
        _ = try harness.trust.pair(token: SyntheticToken.first, name: "T3 Code", kind: nil)

        // Authenticate a valid host first.
        let authed = try await connectAuthenticated(harness)
        defer { Task { await authed.close() } }

        // Open `maxPendingConnections` silent unauthenticated sockets; they stay in the pending pool.
        var silentClients: [BridgeClient] = []
        for _ in 0..<MCPAgentWindowBridge.maxPendingConnections {
            let silent = BridgeClient(socketPath: harness.bridgeEndpoint)
            try await silent.connect()
            silentClients.append(silent)
        }
        defer {
            let toClose = silentClients
            Task {
                for client in toClose {
                    await client.close()
                }
            }
        }

        // The already-authenticated host is completely unaffected and continues serving requests cleanly.
        let (listResp, _) = try await authed.request(id: "cap-ok", op: "listTabs")
        #expect(listResp["ok"] as? Bool == true)

        // Once a pending slot clears, another authenticated host connects cleanly!
        await silentClients.removeFirst().close()
        try await Task.sleep(for: .milliseconds(50))
        let secondAuthed = try await connectAuthenticated(harness)
        let (secondList, _) = try await secondAuthed.request(id: "cap-ok-2", op: "listTabs")
        #expect(secondList["ok"] as? Bool == true)
        await secondAuthed.close()
    }

    @Test(.timeLimit(.minutes(1))) func closeAgentWindowBlockedUnderTakeOverAndSucceedsAfterHandBack() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/login": .html("<!doctype html><title>Sign In</title><p>Complete login</p>"),
        ])
        let loginURL = try fixture.url("/login")
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
                id: "close-to-1", op: "openAgentWindow",
                params: [
                    "threadId": "thread-close-takeover",
                    "profileId": profile.id.uuidString,
                    "url": loginURL.absoluteString,
                    "engine": "webkit",
                ]
            )
            let openResult = try #require(openResp["result"] as? [String: Any])
            let windowId = try #require(openResult["windowId"] as? String)
            let tabId = try #require(openResult["tabId"] as? String)
            let agentWindow = try #require(harness.app.windows.first { $0.windowID.uuidString == windowId })
            let agentTab = try #require(agentWindow.browser.tabs.first { $0.id.uuidString == tabId })
            try #require(await waitUntil { agentTab.liveView?.url == loginURL && !agentTab.isLoading })

            // User clicks Take Over: direct closeAgentWindow MUST fail with humanControl and leave window + tab intact!
            agentWindow.takeOverAgentMicroWindow()
            _ = try await client.waitForEvent(named: "ownerChanged")

            let (blockedByWindow, _) = try await client.request(
                id: "close-to-2", op: "closeAgentWindow",
                params: ["windowId": windowId]
            )
            #expect(blockedByWindow["ok"] as? Bool == false)
            #expect((blockedByWindow["error"] as? [String: Any])?["code"] as? String == "humanControl")

            let (blockedByThread, _) = try await client.request(
                id: "close-to-3", op: "closeAgentWindow",
                params: ["threadId": "thread-close-takeover"]
            )
            #expect(blockedByThread["ok"] as? Bool == false)
            #expect((blockedByThread["error"] as? [String: Any])?["code"] as? String == "humanControl")
            #expect(!agentWindow.isClosed)
            #expect(agentWindow.browser.tabs.count == 1)
            #expect(agentWindow.browser.tabs.first?.id.uuidString == tabId)

            // User clicks Hand Back: closeAgentWindow now succeeds cleanly!
            agentWindow.handBackAgentMicroWindow()
            _ = try await client.waitForEvent(named: "ownerChanged")

            let (closeResp, closeEvents) = try await client.request(
                id: "close-to-4", op: "closeAgentWindow",
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
}
