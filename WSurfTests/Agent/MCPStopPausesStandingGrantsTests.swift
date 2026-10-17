// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Network
import Testing

@testable import WSurf

/// Stop ends a window's connections and also pauses the paired apps among them that hold a standing grant, so reconnecting
/// does not bring the grant back. Servers use in-memory trust storage and a temporary socket directory.
@MainActor
@Suite(.serialized)
struct MCPStopPausesStandingGrantsTests {
    private final class Running {
        let directory = "/tmp/wsurf-mcp-stop-pause-\(UUID().uuidString)"
        var endpoint: String { directory + "/browser.sock" }
        let browser = BrowserModel(database: .temporary())
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 700, height: 500), styleMask: [], backing: .buffered, defer: true)
        var server: BrowserMCPServer!
    }

    private func start() async throws -> Running {
        let running = Running()
        running.window.isReleasedWhenClosed = false
        running.browser.context.extensions.register(browser: running.browser, window: running.window)
        let browser = running.browser
        running.server = BrowserMCPServer(
            endpoint: running.endpoint, trustStore: running.trust, target: { browser }, available: { _ in true })
        running.server.setEnabled(true)
        try #require(await waitUntil { running.server.isListening })
        return running
    }

    private func finish(_ running: Running) {
        running.server.stop()
        running.browser.context.extensions.unregister(browser: running.browser)
        try? FileManager.default.removeItem(atPath: running.directory)
    }

    private func connect(_ running: Running, token: String) async throws -> LocalMCPTransport {
        let hello = MCPPairing.helloMessage(token: token)
        let transport = LocalMCPTransport(connection: NWConnection(to: .unix(path: running.endpoint), using: .tcp), hello: hello)
        _ = try await MCP.Client(name: "Stop test", version: "1").connect(transport: transport)
        return transport
    }

    @Test(.timeLimit(.minutes(1))) func stopPausesTheStoppedAppsStandingGrantsUntilTheyAreResumed() async throws {
        let running = try await start()
        defer { finish(running) }
        let standing = try running.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        let plain = try running.trust.pair(token: SyntheticToken.second, name: "Codex", kind: .codex)
        try running.trust.setStanding(.development, for: standing.id)
        let first = try await connect(running, token: SyntheticToken.first)
        defer { Task { await first.disconnect() } }
        let second = try await connect(running, token: SyntheticToken.second)
        defer { Task { await second.disconnect() } }
        try #require(running.server.sessions.count == 2)
        #expect(MCPDeveloperAccess.standingAccess(for: standing, trust: running.trust) == .development)

        #expect(running.server.stop(window: running.browser) == 2)

        #expect(running.server.sessions.isEmpty)
        #expect(running.trust.client(id: standing.id)?.paused == true, "the app with a standing grant is paused")
        #expect(MCPDeveloperAccess.standingAccess(for: standing, trust: running.trust) == nil)
        #expect(running.trust.client(id: standing.id)?.standing == .development, "the level is kept for Resume")
        #expect(running.trust.client(id: plain.id)?.paused == false, "an app without a standing grant has nothing to pause")

        // Reconnecting brings no grant back; resuming does.
        let again = try await connect(running, token: SyntheticToken.first)
        defer { Task { await again.disconnect() } }
        let session = try #require(running.server.sessions.first)
        #expect(session.pairedClient?.id == standing.id)
        #expect(MCPDeveloperAccess.standingAccess(for: session.pairedClient, trust: running.trust) == nil)
        try running.trust.setPaused(false, for: standing.id)
        #expect(MCPDeveloperAccess.standingAccess(for: session.pairedClient, trust: running.trust) == .development)
    }
}
