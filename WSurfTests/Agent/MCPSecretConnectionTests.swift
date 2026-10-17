// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Network
import Testing
import WebKit

@testable import WSurf

/// A secret typed by a real MCP client over the Unix socket: the reply that reaches it, and what each way a connection ends
/// leaves behind. The server uses in-memory trust storage and a temporary socket directory.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPSecretConnectionTests {
    private static let password = "Zx9-wire-Pa$$word!"

    private static let page = """
        <!doctype html><title>Login</title>
        <input id=pw type=password aria-label="Password">
        <p id=echo></p>
        <script>
          const pw = document.getElementById('pw');
          pw.addEventListener('input', () => {
            document.getElementById('echo').textContent = 'You typed ' + pw.value;
            document.title = 'Signed in with ' + pw.value;
          });
        </script>
        """

    private final class Running {
        let directory = "/tmp/wsurf-mcp-secret-\(UUID().uuidString)"
        var endpoint: String { directory + "/browser.sock" }
        let developerProfile = Profile(id: UUID(), name: "Developer", symbol: "hammer", color: .teal)
        let developer: BrowserModel
        var window: NSWindow
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        var server: BrowserMCPServer!

        init() {
            developer = BrowserModel(
                context: BrowserProfileContext(profile: developerProfile), windowID: UUID(), database: .temporary())
            window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 700, height: 500), styleMask: [], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            trust.loadIfNeeded()
        }
    }

    private func start() async throws -> (Running, PairedClient) {
        let running = Running()
        running.developer.context.extensions.register(browser: running.developer, window: running.window)
        let client = try running.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try running.trust.setStanding(.developer, for: client.id)
        try running.trust.setDeveloperProfile(running.developerProfile.id, dedicated: true)
        let developer = running.developer
        running.server = BrowserMCPServer(
            endpoint: running.endpoint, defaults: nil, trustStore: running.trust,
            target: { developer }, available: { _ in true }, developerTarget: { _ in developer })
        running.server.setEnabled(true)
        try #require(await waitUntil { running.server.isListening })
        return (running, client)
    }

    private func stop(_ running: Running) async {
        running.server.stop()
        running.developer.context.extensions.unregister(browser: running.developer)
        try? FileManager.default.removeItem(atPath: running.directory)
        BrowserProfileContext.forget(running.developerProfile.id)
        try? await WKWebsiteDataStore.remove(forIdentifier: running.developerProfile.id)
    }

    private func connect(_ running: Running) async throws -> (client: MCP.Client, transport: LocalMCPTransport) {
        let hello = String(decoding: MCPPairing.helloMessage(token: SyntheticToken.first) ?? Data(), as: UTF8.self)
        let transport = LocalMCPTransport(
            connection: NWConnection(to: .unix(path: running.endpoint), using: .tcp), hello: Data(hello.utf8))
        let client = MCP.Client(name: "Secret test", version: "1")
        _ = try await client.connect(transport: transport)
        return (client, transport)
    }

    private func text(_ content: [MCP.Tool.Content]) -> String {
        content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    /// The `content` string and `observationID` of a page tool's reply, as a client parses them.
    private func page(_ content: [MCP.Tool.Content]) throws -> (content: String, observation: String) {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any])
        return (try #require(object["content"] as? String), try #require(object["observationID"] as? String))
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["revoke the app", "disconnect", "stop the server"])
    func aSecretTypedOverTheWireIsHiddenFromTheClientAndForgottenWhenTheConnectionEnds(ending: String) async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html(Self.page)])
        let (running, paired) = try await start()
        defer { Task { await stop(running) } }
        let connection = try await connect(running)
        defer { Task { await connection.transport.disconnect() } }
        defer { withExtendedLifetime(fixture) {} }
        let session = try #require(running.server.sessions.first)

        let (opened, openFailed) = try await connection.client.callTool(name: "newTab", arguments: ["url": .string(try fixture.url().absoluteString)])
        #expect(openFailed == false, "\(text(opened))")
        let tab = try #require(running.developer.tabs.first)
        let tabID: Value = .string(tab.id.uuidString)
        #expect(await PageSettle.untilIdle(tab.page))
        #expect(session.permits(tab, capability: .developer))

        let (readContent, readFailed) = try await connection.client.callTool(name: "readPage", arguments: ["tabID": tabID])
        #expect(readFailed == false, "\(text(readContent))")
        let read = try page(readContent)
        let line = try #require(read.content.split(separator: "\n").first { $0.contains("field \"Password\"") })
        let ref = try #require(Int(line.dropFirst().prefix { $0.isNumber }))

        let (typed, typeFailed) = try await connection.client.callTool(
            name: "typeOnPage",
            arguments: ["tabID": tabID, "observationID": .string(read.observation), "ref": .int(ref), "text": .string(Self.password), "secret": true])
        #expect(typeFailed == false, "\(text(typed))")
        #expect(!text(typed).contains(Self.password), "the reply that reaches the client")
        #expect(try await tab.page.evaluateJavaScript("document.getElementById('pw').value") as? String == Self.password)
        #expect(try await tab.page.evaluateJavaScript("document.getElementById('echo').textContent") as? String == "You typed \(Self.password)")

        let (again, againFailed) = try await connection.client.callTool(name: "readPage", arguments: ["tabID": tabID])
        #expect(againFailed == false)
        #expect(!text(again).contains(Self.password), "the page echoed the secret into its text, and the reader still did not get it")
        #expect(text(again).contains(MCPSecretScrubber.replacement))
        let (tabs, _) = try await connection.client.callTool(name: "listTabs")
        #expect(!text(tabs).contains(Self.password), "the title the page set to its password")
        #expect(session.secrets.count == 1)

        switch ending {
        case "revoke the app":
            try running.server.revoke(paired)
        case "disconnect":
            running.server.disconnect(session.id)
        default:
            running.server.stop()
        }

        #expect(session.secrets.isEmpty, "\(ending): the registry is wiped")
        #expect(session.secretFields.isEmpty)
        #expect(running.server.sessions.isEmpty)
        #expect(!"\(session.secrets)".contains(Self.password))
    }
}
