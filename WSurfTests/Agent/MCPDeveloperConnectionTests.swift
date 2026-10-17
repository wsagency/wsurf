// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Network
import Testing
import WebKit

@testable import WSurf

/// Which window a connection lives in, over a real Unix socket. Servers use in-memory trust storage and temporary socket
/// directories; windows are bare `NSWindow`s.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPDeveloperConnectionTests {
    private final class Running {
        let directory = "/tmp/wsurf-mcp-dev-\(UUID().uuidString)"
        var endpoint: String { directory + "/browser.sock" }
        let developerProfile = Profile(id: UUID(), name: "Developer", symbol: "hammer", color: .teal)
        let focused: BrowserModel
        let developer: BrowserModel
        var windows: [NSWindow] = []
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        var server: BrowserMCPServer!
        var canOpenDeveloperWindow = true

        init() {
            focused = BrowserModel(database: .temporary())
            developer = BrowserModel(
                context: BrowserProfileContext(profile: developerProfile), windowID: UUID(), database: .temporary())
            trust.loadIfNeeded()
        }
    }

    private func start(
        standing: PairedClient.Standing = .development, chooseProfile: Bool = true, canOpenDeveloperWindow: Bool = true
    ) async throws -> (Running, PairedClient) {
        let running = Running()
        running.canOpenDeveloperWindow = canOpenDeveloperWindow
        for browser in [running.focused, running.developer] {
            let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 700, height: 500), styleMask: [], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            browser.context.extensions.register(browser: browser, window: window)
            running.windows.append(window)
        }
        let client = try running.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try running.trust.setStanding(standing, for: client.id)
        if chooseProfile {
            try running.trust.setDeveloperProfile(running.developerProfile.id, dedicated: true)
        }
        let focused = running.focused, developer = running.developer, profileID = running.developerProfile.id
        running.server = BrowserMCPServer(
            endpoint: running.endpoint, defaults: nil, trustStore: running.trust,
            target: { focused }, available: { _ in true },
            developerTarget: { [weak running] id in
                running?.canOpenDeveloperWindow == true && id == profileID ? developer : nil
            })
        running.server.setEnabled(true)
        try #require(await waitUntil { running.server.isListening })
        return (running, client)
    }

    private func stop(_ running: Running) async {
        running.server.stop()
        for browser in [running.focused, running.developer] {
            browser.context.extensions.unregister(browser: browser)
        }
        try? FileManager.default.removeItem(atPath: running.directory)
        BrowserProfileContext.forget(running.developerProfile.id)
        try? await WKWebsiteDataStore.remove(forIdentifier: running.developerProfile.id)
    }

    private func connect(_ running: Running, hello: String?) async throws -> (client: MCP.Client, transport: LocalMCPTransport) {
        let transport = LocalMCPTransport(
            connection: NWConnection(to: .unix(path: running.endpoint), using: .tcp), hello: hello.map { Data($0.utf8) })
        let client = MCP.Client(name: "Developer test", version: "1")
        _ = try await client.connect(transport: transport)
        return (client, transport)
    }

    private var hello: String {
        String(decoding: MCPPairing.helloMessage(token: SyntheticToken.first) ?? Data(), as: UTF8.self)
    }

    private func text(_ content: [MCP.Tool.Content]) -> String {
        content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    // MARK: Binding

    @Test(.timeLimit(.minutes(2)))
    func aPairedClientWithAStandingGrantWorksInTheDeveloperWindowAndLeavesTheFocusedOneAlone() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Dev server</title><p>Hello</p>")])
        let (running, paired) = try await start()
        defer { Task { await stop(running) } }
        let connection = try await connect(running, hello: hello)
        defer { Task { await connection.transport.disconnect() } }
        defer { withExtendedLifetime(fixture) {} }

        let session = try #require(running.server.sessions.first)
        #expect(running.server.sessions.count == 1)
        #expect(session.isBound(to: running.developer))
        #expect(!session.isBound(to: running.focused))
        #expect(session.pairedClient?.id == paired.id)

        let (_, listFailed) = try await connection.client.callTool(name: "listTabs")
        #expect(listFailed == false)
        #expect(session.clientName == "Developer test")
        let (content, failed) = try await connection.client.callTool(
            name: "newTab", arguments: ["url": .string(try fixture.url().absoluteString)])
        #expect(failed == false, "\(text(content))")
        #expect(running.developer.tabs.count == 1)
        #expect(running.focused.tabs.isEmpty)
        let tab = try #require(running.developer.tabs.first)
        let (listed, _) = try await connection.client.callTool(name: "listTabs")
        #expect(text(listed).contains(tab.id.uuidString))
        #expect(session.grants[tab.id]?.source == .standing)
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["unpaired", "off", "noProfile", "paused", "noWindow"])
    func everyoneElseKeepsTheWindowTheyConnectedTo(scenario: String) async throws {
        let (running, paired) = try await start(
            standing: scenario == "off" ? .off : .developer, chooseProfile: scenario != "noProfile",
            canOpenDeveloperWindow: scenario != "noWindow")
        defer { Task { await stop(running) } }
        if scenario == "paused" {
            try running.trust.setPaused(true, for: paired.id)
        }
        let connection = try await connect(running, hello: scenario == "unpaired" ? nil : hello)
        defer { Task { await connection.transport.disconnect() } }

        let session = try #require(running.server.sessions.first)
        #expect(session.isBound(to: running.focused))
        #expect(!session.isBound(to: running.developer))
        #expect(session.pairedClient?.id == (scenario == "unpaired" ? nil : paired.id))
        let (_, failed) = try await connection.client.callTool(name: "listTabs")
        #expect(failed == false)
    }

    @Test(.timeLimit(.minutes(2)))
    func pausingALiveClientDropsItsTabsAtOnceAndResumingRestoresThem() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Dev server</title><p>Hello</p>")])
        let (running, paired) = try await start()
        defer { Task { await stop(running) } }
        let connection = try await connect(running, hello: hello)
        defer { Task { await connection.transport.disconnect() } }
        defer { withExtendedLifetime(fixture) {} }
        let address: [String: Value] = ["url": .string(try fixture.url().absoluteString)]
        _ = try await connection.client.callTool(name: "newTab", arguments: address)
        let session = try #require(running.server.sessions.first)
        #expect(session.grants.count == 1)

        try running.trust.setPaused(true, for: paired.id)
        // The server refreshes live connections as soon as the store changes.
        #expect(session.grants.isEmpty)
        let (listed, _) = try await connection.client.callTool(name: "listTabs")
        #expect(text(listed).contains("\"tabs\":[]"))
        let (_, refused) = try await connection.client.callTool(name: "newTab", arguments: address)
        #expect(refused == true)

        try running.trust.setPaused(false, for: paired.id)
        let (_, reopened) = try await connection.client.callTool(name: "newTab", arguments: address)
        #expect(reopened == false)
    }

    @Test(.timeLimit(.minutes(2)))
    func privateWindowsAreNeverBoundToAStandingGrant() async throws {
        let (running, _) = try await start()
        defer { Task { await stop(running) } }
        let privateBrowser = BrowserModel(
            context: BrowserProfileContext(profile: .privateBrowsing(), settingsOwner: .original()), windowID: UUID(), database: .temporary())
        // The server will not make a session for a private window, whatever asks for it.
        #expect(running.server.makeSessionForConnection(browser: privateBrowser) == nil)
        #expect(running.server.makeSessionForConnection(browser: running.developer) != nil)
        // And a private profile cannot be chosen as the Developer profile.
        #expect(throws: MCPTrustStore.Failure.invalidProfile) { try running.trust.setDeveloperProfile(Profile.privateID) }
    }

    // MARK: The application

    @Test func theApplicationFindsOrOpensTheDeveloperWindowWithoutFocusingIt() async throws {
        let app = BrowserApplication()
        let catalog = ProfileStore.shared
        let originalSelection = catalog.current
        let profile = catalog.add(name: "Developer QA")
        let result = Result {
            let everyday = app.newWindow(profile: .original(), show: false)
            app.focus(everyday)
            let wasActive = NSApp.isActive
            let currentProfile = catalog.current

            let opened = try #require(app.developerWindow(profileID: profile.id))
            #expect(opened.context.profile.id == profile.id)
            #expect(!opened.profiles.isPrivate)
            #expect(app.windows.count == 2)
            // Showing it behind never took the focus, and never activated WSurf.
            #expect(app.activeWindowID == everyday.windowID)
            #expect(NSApp.isActive == wasActive)
            #expect(!opened.isKeyWindow)
            #expect(catalog.current == currentProfile)
            #expect(try #require(app.mcpServer.makeSessionForConnection(browser: opened.browser)).isBound(to: opened.browser))

            // Asking again finds the same window; nothing else is opened.
            #expect(app.developerWindow(profileID: profile.id) === opened)
            #expect(app.windows.count == 2)

            // A profile that does not exist, and private browsing, never get a window.
            #expect(app.developerWindow(profileID: UUID()) == nil)
            #expect(app.developerWindow(profileID: Profile.privateID) == nil)
            #expect(app.windows.count == 2)
        }
        app.windows.forEach { $0.closeWindow() }
        try await app.clearDataOnQuitIfNeeded()
        await catalog.remove(profile)
        catalog.markCurrent(originalSelection)
        try result.get()
    }
}
