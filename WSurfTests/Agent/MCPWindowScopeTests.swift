// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Network
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPWindowScopeTests {
    private func window(in app: BrowserApplication, privately: Bool = false) -> AppCoordinator {
        let profile = privately ? Profile.privateBrowsing() : .original()
        let context = BrowserProfileContext.shared(for: profile)
        let coordinator = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        app.register(coordinator)
        coordinator.showBrowser(activate: false)
        return coordinator
    }

    private func call(_ session: MCPBrowserSession, _ name: String, arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        try await session.call(name: name, arguments: arguments)
    }

    @Test func focusChangesDoNotRetargetAnExistingConnection() async throws {
        let app = BrowserApplication()
        let first = window(in: app)
        let second = window(in: app)
        let privateWindow = window(in: app, privately: true)
        defer {
            first.closeWindow()
            second.closeWindow()
            privateWindow.closeWindow()
        }

        app.focus(first)
        let firstConnection = try #require(app.mcpServer.makeSessionForConnection())
        app.focus(second)
        let secondConnection = try #require(app.mcpServer.makeSessionForConnection())

        #expect(firstConnection.isBound(to: first.browser))
        #expect(!firstConnection.isBound(to: second.browser))
        #expect(secondConnection.isBound(to: second.browser))
        app.focus(privateWindow)
        #expect(app.mcpServer.makeSessionForConnection() == nil)
        #expect(try await call(firstConnection, "listTabs").isError == false)
        #expect(try await call(secondConnection, "listTabs").isError == false)
    }

    @Test(arguments: [false, true])
    func retiringAWindowRevokesOnlyItsAcceptedConnection(switchProfile: Bool) async throws {
        let directory = "/tmp/wsurf-mcp-window-\(UUID().uuidString)"
        let endpoint = directory + "/browser.sock"
        let app = BrowserApplication()
        app.mcpServer = BrowserMCPServer(
            endpoint: endpoint,
            target: { [weak app] in app?.activeCoordinator?.browser },
            available: { _ in true }
        )
        let first = window(in: app)
        let second = window(in: app)
        defer {
            app.mcpServer.stop()
            first.closeWindow()
            second.closeWindow()
            try? FileManager.default.removeItem(atPath: directory)
        }
        app.mcpServer.setEnabled(true)
        try #require(await waitUntil { app.mcpServer.isListening || app.mcpServer.status != nil })
        try #require(app.mcpServer.isListening)

        app.focus(first)
        let firstClient = MCP.Client(name: "First window", version: "1")
        _ = try await firstClient.connect(transport: LocalMCPTransport(
            connection: NWConnection(to: .unix(path: endpoint), using: .tcp)
        ))
        let firstConnection = try #require(app.mcpServer.sessions.first)
        app.focus(second)
        let secondClient = MCP.Client(name: "Second window", version: "1")
        _ = try await secondClient.connect(transport: LocalMCPTransport(
            connection: NWConnection(to: .unix(path: endpoint), using: .tcp)
        ))
        defer {
            Task {
                await firstClient.disconnect()
                await secondClient.disconnect()
            }
        }
        let secondConnection = try #require(app.mcpServer.sessions.last)
        #expect(firstConnection.isBound(to: first.browser))
        #expect(secondConnection.isBound(to: second.browser))
        #expect(app.mcpServer.sessions.count == 2)

        if switchProfile {
            let profile = Profile(id: UUID(), name: "Other", symbol: "person", color: .gray)
            await first.switchProfile(to: profile)
        } else {
            first.closeWindow()
        }

        #expect(!firstConnection.isConnected)
        #expect(try await call(firstConnection, "listTabs").isError == true)
        #expect(try await call(firstConnection, "requestAccess").isError == true)
        #expect(secondConnection.isConnected)
        #expect(app.mcpServer.sessions.map(\.id) == [secondConnection.id])
        let (_, failed) = try await secondClient.callTool(name: "listTabs")
        #expect(failed == false)
        app.focus(switchProfile ? first : second)
        #expect(app.mcpServer.makeSessionForConnection()?.isBound(to: switchProfile ? first.browser : second.browser) == true)
    }

    @Test func privateFocusDeniesOnlyNewConnections() async throws {
        let app = BrowserApplication()
        let regular = window(in: app)
        let privateWindow = window(in: app, privately: true)
        defer {
            regular.closeWindow()
            privateWindow.closeWindow()
        }
        app.focus(regular)
        let existing = try #require(app.mcpServer.makeSessionForConnection())

        app.focus(privateWindow)

        #expect(app.mcpServer.makeSessionForConnection() == nil)
        #expect(existing.isConnected)
        #expect(try await call(existing, "listTabs").isError == false)
    }

    @Test func consentAndOpenConsentStayWithTheOriginalNativeWindow() async throws {
        let app = BrowserApplication()
        let first = window(in: app)
        let second = window(in: app)
        let firstNative = try #require(first.nativeWindow)
        let secondNative = try #require(second.nativeWindow)
        defer {
            first.closeWindow()
            second.closeWindow()
            firstNative.close()
            secondNative.close()
        }
        let tab = first.browser.newTab(url: URL(string: "https://first-window.invalid/"))
        app.focus(first)
        var shareWindow: NSWindow?
        var openWindow: NSWindow?
        let connection = try #require(app.mcpServer.makeSessionForConnection(
            consent: { _, _, window in
                shareWindow = window
                return .control
            },
            openConsent: { _, _, window in
                openWindow = window
                return false
            }
        ))
        app.focus(second)

        #expect(try await call(connection, "requestAccess").isError == false)
        #expect(shareWindow === firstNative)
        #expect(try await call(connection, "newTab", arguments: ["url": .string("https://first-window.invalid/next")]).isError == true)
        #expect(openWindow === firstNative)
        #expect(first.browser.tabs.contains(where: { $0 === tab }))
        #expect(second.browser.tabs.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func consequentialConsentStaysWithItsOwnerAndRejectsRetirement(
        privateFocus: Bool, retireRegistration: Bool
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Consent owner</title><button onclick='window.published = true'>Publish post</button>"),
        ])
        let app = BrowserApplication()
        let first = window(in: app)
        let focused = window(in: app, privately: privateFocus)
        let firstNative = try #require(first.nativeWindow)
        let focusedNative = try #require(focused.nativeWindow)
        defer {
            first.closeWindow()
            focused.closeWindow()
            firstNative.close()
            focusedNative.close()
        }
        let tab = first.browser.newTab(url: try server.url())
        firstNative.contentView = tab.page
        firstNative.orderFront(nil)
        try #require(await PageSettle.untilIdle(tab.page))
        app.focus(first)
        let connection = try #require(app.mcpServer.makeSessionForConnection(consent: { _, _, _ in .control }))
        try #require(try await call(connection, "requestAccess").isError == false)
        let read = try await call(connection, "readPage", arguments: ["tabID": .string(tab.id.uuidString)])
        guard case .object(let observation) = read.structuredContent else {
            throw MCPError.internalError("Missing observation")
        }
        let observationID = try #require(observation["observationID"]?.stringValue)
        app.focus(focused)
        focusedNative.makeKeyAndOrderFront(nil)
        var prompts = 0
        var policy: AgentActionPolicy?
        let result = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, category, _, window in
            prompts += 1
            #expect(category == .publication)
            #expect(window === firstNative)
            #expect(window !== focusedNative)
            policy = AgentActionConsent.scopedPolicy
            await Task.yield()
            if retireRegistration {
                first.extensions.unregister(browser: first.browser)
                first.extensions.register(browser: first.browser, window: firstNative)
            }
            return .allowAlways
        }) {
            try await call(connection, "clickOnPage", arguments: [
                "tabID": .string(tab.id.uuidString), "observationID": .string(observationID), "ref": 1,
            ])
        }
        #expect(prompts == 1)
        #expect(result.isError == retireRegistration)
        #expect(try await tab.page.evaluateJavaScript("window.published === true") as? Bool == !retireRegistration)
        #expect(policy?.isAlwaysAllowed(.publication, host: tab.page.url?.host()) == !retireRegistration)
        #expect(focused.browser.tabs.isEmpty)
    }

    @Test func missingOriginalWindowDeniesConsentWithoutUsingFocusedWindow() async throws {
        let app = BrowserApplication()
        let first = window(in: app)
        let second = window(in: app)
        let firstNative = try #require(first.nativeWindow)
        let secondNative = try #require(second.nativeWindow)
        defer {
            first.closeWindow()
            second.closeWindow()
            firstNative.close()
            secondNative.close()
        }
        first.browser.newTab(url: URL(string: "https://first-window.invalid/"))
        app.focus(first)
        var prompts = 0
        let connection = try #require(app.mcpServer.makeSessionForConnection(consent: { _, _, _ in
            prompts += 1
            return .control
        }))
        first.extensions.unregister(browser: first.browser)
        app.focus(second)

        #expect(try await call(connection, "requestAccess").isError == true)
        #expect(prompts == 0)
        #expect(connection.grants.isEmpty)
    }
}
