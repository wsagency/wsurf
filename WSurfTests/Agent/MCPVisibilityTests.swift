// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Network
import Testing

@testable import WSurf

/// The badge's model, the activity log a connection writes, and Stop.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPVisibilityTests {
    private static let page = "<!doctype html><title>Visible</title><input id=name type=text aria-label=Name><button>Go</button>"

    private func fixture() async throws -> (HTTPFixtureServer, BrowserModel, BrowserTab) {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.page)])
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPVisibility-\(UUID().uuidString).json")))
        let url = try server.url()
        let tab = browser.newTab(url: url)
        #expect(await PageSettle.untilIdle(tab.page))
        #expect(await waitUntil { tab.page.mainDocumentID != nil }, "the page registered its main document")
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        return (server, browser, tab)
    }

    private func session(_ browser: BrowserModel, client: String = "Claude Code", answer: MCPAccessConsent.Access = .control) -> MCPBrowserSession {
        let session = MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in answer })
        session.clientName = client
        return session
    }

    private func call(
        _ session: MCPBrowserSession, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]
    ) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await session.call(name: name, arguments: arguments)
    }

    // MARK: The log

    @Test func everyToolCallIsLoggedWithoutArguments() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        let typedText = "typed-marker-4217"
        _ = try await call(subject, "requestAccess")
        _ = try await call(subject, "listTabs")
        let read = try await call(subject, "readPage", tab)
        let observation = try #require(read.structuredContent?.objectValue?["observationID"]?.stringValue)
        let typed = try await call(
            subject, "typeOnPage", tab, ["observationID": .string(observation), "ref": 1, "text": .string(typedText)])
        #expect(typed.isError == false)
        let moved = try await call(subject, "navigate", tab, ["url": "https://example.invalid/private/path?token=hidden-secret#frag"])
        #expect(moved.isError == true, "a destination no page link offered is refused")

        let entries = subject.activity.entries
        #expect(
            entries.map(\.event) == [
                .tool("requestAccess"), .tool("listTabs"), .tool("readPage"), .tool("typeOnPage"), .tool("navigate"),
            ])
        #expect(entries.map(\.outcome) == [.succeeded, .succeeded, .succeeded, .succeeded, .failed])
        let typing = entries[3]
        #expect(typing.tabID == tab.id)
        #expect(typing.tabTitle == "Visible")
        #expect(typing.target == "element 1")
        #expect(entries[2].bytes > 0)
        #expect(entries.allSatisfy { $0.milliseconds >= 0 })
        #expect(entries[4].detail == "example.invalid", "a navigation keeps its host and nothing else")
        #expect(entries[0].tabID == nil)
        #expect(subject.activity.client == "Claude Code")
        let everything = String(describing: entries)
        for secret in [typedText, "hidden-secret", "/private/path", observation] {
            #expect(!everything.contains(secret), "\(secret) must not reach the log")
        }
        // The panel shows a tab's own entries with the connection-level ones around them, and nothing for another tab.
        #expect(subject.activity.entries(forTab: tab.id).count == entries.count)
        #expect(subject.activity.entries(forTab: UUID()).isEmpty)
    }

    @Test func developmentToolsAreLoggedByNameAndNeverByWhatTheyReturn() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser, answer: .development)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(try await call(subject, "startDiagnostics", tab).isError == false)
        _ = try await tab.page.evaluateJavaScript("console.log('console-marker-8841'); 0")
        let returned = try await waitUntil {
            let read = try await call(subject, "readConsole", tab)
            return read.content.contains { block in
                guard case .text(let text, _, _) = block else { return false }
                return text.contains("console-marker-8841")
            }
        }
        try #require(returned, "the console text came back to the client")
        _ = try await call(subject, "resetDevelopment", tab)

        let names = subject.activity.entries.compactMap { entry -> String? in
            guard case .tool(let name) = entry.event else { return nil }
            return name
        }
        #expect(names.first == "requestAccess")
        #expect(names.contains("startDiagnostics"))
        #expect(names.last == "resetDevelopment")
        #expect(Set(names).subtracting(["requestAccess", "startDiagnostics", "readConsole", "resetDevelopment"]).isEmpty)
        #expect(!String(describing: subject.activity.entries).contains("console-marker-8841"))
    }

    // MARK: The badge

    @Test func badgeAppearsOnlyWhileAConnectionHoldsAGrant() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        #expect(!subject.isControlling)
        #expect(subject.tier == nil)

        _ = try await call(subject, "requestAccess")
        #expect(subject.isControlling)
        #expect(subject.sharedTabs.map(\.id) == [tab.id])
        #expect(subject.tier == .control)
        #expect(ExternalConnectionBadge.label(for: [subject]) == "Claude Code · Control")
        #expect(ExternalConnectionBadge.help(for: [subject]) == "Claude Code is using this window")

        let developer = session(browser, client: "codex-mcp-client", answer: .development)
        _ = try await call(developer, "requestAccess", nil, ["development": true])
        #expect(ExternalConnectionBadge.label(for: [subject, developer]) == "Claude Code +1 · Development")
        #expect(ExternalConnectionBadge.help(for: [subject, developer]) == "2 external apps are using this window")
        #expect(ExternalConnectionBadge.label(for: [developer]) == "Codex · Development")

        tab.setExternalAutomationWorking(true)
        #expect(subject.isWorking)
        tab.setExternalAutomationWorking(false)
        #expect(!subject.isWorking)

        subject.revoke()
        #expect(!subject.isControlling)
        #expect(developer.isControlling)
    }

    // MARK: The tab's AI mark

    @Test func aTabsMarkNamesTheAppsThatHoldItAndWhatTheyMayDo() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let origin = SitePermissions.origin(for: try server.url())
        let reader = session(browser, client: "codex-mcp-client")
        reader.grants[tab.id] = .init(origin: origin, access: .readOnly)
        #expect(tab.processState.externalControllers == [reader.id], "a read-only share is marked too")
        #expect(ExternalControlMark.label(for: [reader], tab: tab) == "Codex can read this tab")

        let controller = session(browser)
        controller.grants[tab.id] = .init(origin: origin, access: .control)
        #expect(ExternalControlMark.label(for: [controller], tab: tab) == "Claude Code controls this tab")
        #expect(ExternalControlMark.label(for: [reader, controller], tab: tab) == "2 apps control this tab")

        // The mark stays between calls: only the grant ends it, never the end of a call.
        tab.setExternalAutomationWorking(true)
        tab.setExternalAutomationWorking(false)
        #expect(tab.processState.externalControllers == [reader.id, controller.id])
        reader.revoke()
        controller.revoke()
        #expect(tab.processState.externalControllers.isEmpty)
    }

    @Test func aLeaseKeepsTheBadgeEvenWithoutAGrant() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser, answer: .development)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        _ = try await call(subject, "startDiagnostics", tab)
        try #require(tab.developmentOwner != nil)

        subject.grants = [:]

        #expect(subject.isControlling, "a connection that holds a lease is never hidden")
    }

    // MARK: Stop

    private func window(in app: BrowserApplication) -> AppCoordinator {
        let context = BrowserProfileContext.shared(for: .original())
        let coordinator = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        app.register(coordinator)
        coordinator.showBrowser(activate: false)
        return coordinator
    }

    private func connect(_ name: String, to endpoint: String) async throws -> MCP.Client {
        let client = MCP.Client(name: name, version: "1")
        _ = try await client.connect(
            transport: LocalMCPTransport(connection: NWConnection(to: .unix(path: endpoint), using: .tcp)))
        return client
    }

    /// An application whose server listens on its own socket. The caller closes the windows.
    private func listeningApp(_ endpoint: String) async throws -> BrowserApplication {
        let app = BrowserApplication()
        app.mcpServer = BrowserMCPServer(
            endpoint: endpoint,
            target: { [weak app] in app?.activeCoordinator?.browser },
            available: { _ in true }
        )
        app.mcpServer.setEnabled(true)
        try #require(await waitUntil { app.mcpServer.isListening || app.mcpServer.status != nil })
        try #require(app.mcpServer.isListening)
        return app
    }

    @Test func stopDisconnectsCancelsAndReleasesLeases() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.page)])
        let directory = "/tmp/wsurf-mcp-stop-\(UUID().uuidString)"
        let endpoint = directory + "/browser.sock"
        let app = try await listeningApp(endpoint)
        let first = window(in: app)
        let second = window(in: app)
        defer {
            app.mcpServer.stop()
            first.closeWindow()
            second.closeWindow()
            try? FileManager.default.removeItem(atPath: directory)
            _ = server
        }
        let url = try server.url()
        let tab = first.browser.newTab(url: url)
        try #require(await PageSettle.untilIdle(tab.page))
        try #require(await waitUntil { tab.page.mainDocumentID != nil })
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)

        app.focus(first)
        let firstClient = try await connect("First app", to: endpoint)
        app.focus(second)
        let secondClient = try await connect("Second app", to: endpoint)
        defer {
            Task {
                await firstClient.disconnect()
                await secondClient.disconnect()
            }
        }
        let firstSession = try #require(app.mcpServer.sessions.first { $0.isBound(to: first.browser) })
        let secondSession = try #require(app.mcpServer.sessions.first { $0.isBound(to: second.browser) })
        firstSession.grants[tab.id] = .init(origin: SitePermissions.origin(for: url), access: .development)
        let tabArguments: [String: Value] = ["tabID": .string(tab.id.uuidString)]

        _ = try await firstClient.callTool(name: "startDiagnostics", arguments: tabArguments)
        try #require(tab.developmentOwner != nil, "the connection holds a lease")
        #expect(app.mcpServer.controllers(in: first.browser).map(\.id) == [firstSession.id])
        #expect(app.mcpServer.controllers(in: second.browser).isEmpty, "a connection without a grant shows no badge")
        #expect(first.hasExternalConnections)
        #expect(second.hasExternalConnections)

        // A call that would run for its full 15 seconds unless Stop cancels it.
        let running = Task {
            try? await firstClient.callTool(
                name: "waitForPage",
                arguments: tabArguments.merging(["condition": "text", "value": "never-on-this-page", "timeout": 15]) { $1 })
        }
        defer { running.cancel() }
        try #require(await waitUntil { firstSession.lastTool == "waitForPage" })

        first.stopExternalConnections()

        #expect(!firstSession.isConnected)
        #expect(firstSession.grants.isEmpty, "the grants are gone")
        #expect(tab.developmentOwner == nil, "the lease is released")
        #expect(app.mcpServer.sessions.map(\.id) == [secondSession.id])
        #expect(app.mcpServer.controllers(in: first.browser).isEmpty)
        #expect(app.mcpServer.endedLogs.contains { $0 === firstSession.activity }, "what it did stays readable")
        #expect(try await firstSession.call(name: "listTabs", arguments: [:]).isError == true)
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                firstSession.activity.entries.contains { $0.event == .tool("waitForPage") }
            }, "the running call ended at once instead of waiting out its timeout")
        let entries = firstSession.activity.entries
        #expect(entries.first { $0.event == .tool("waitForPage") }?.outcome == .stopped)
        #expect(entries.contains { $0.event == .stopped })
        #expect(secondSession.isConnected)
        let (_, secondFailed) = try await secondClient.callTool(name: "listTabs")
        #expect(secondFailed == false)

        // A client that reconnects starts with nothing.
        app.focus(first)
        let again = try await connect("First app again", to: endpoint)
        defer { Task { await again.disconnect() } }
        let reconnected = try #require(app.mcpServer.sessions.first { $0.isBound(to: first.browser) })
        #expect(reconnected.id != firstSession.id)
        #expect(reconnected.grants.isEmpty)
        #expect(!reconnected.isControlling)
    }

    @Test func takingOverATabEndsOnlyThatTabsAccessAndItsRunningCall() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.page)])
        let directory = "/tmp/wsurf-mcp-takeover-\(UUID().uuidString)"
        let endpoint = directory + "/browser.sock"
        let app = try await listeningApp(endpoint)
        let first = window(in: app)
        defer {
            app.mcpServer.stop()
            first.closeWindow()
            try? FileManager.default.removeItem(atPath: directory)
            _ = server
        }
        let url = try server.url()
        let taken = first.browser.newTab(url: url)
        let kept = first.browser.newTab(url: url)
        for tab in [taken, kept] {
            try #require(await PageSettle.untilIdle(tab.page))
            try #require(await waitUntil { tab.page.mainDocumentID != nil })
            tab.assistantAccess.persistsAnswers = false
            tab.assistantAccess.pageChanged(url: url)
        }
        app.focus(first)
        let client = try await connect("Codex", to: endpoint)
        defer { Task { await client.disconnect() } }
        let session = try #require(app.mcpServer.sessions.first { $0.isBound(to: first.browser) })
        let origin = SitePermissions.origin(for: url)
        session.grants[taken.id] = .init(origin: origin, access: .development)
        session.grants[kept.id] = .init(origin: origin, access: .control)
        _ = try await client.callTool(name: "startDiagnostics", arguments: ["tabID": .string(taken.id.uuidString)])
        try #require(taken.developmentOwner != nil)
        #expect(app.mcpServer.controllers(of: taken, in: first.browser).map(\.id) == [session.id])

        let running = Task {
            try? await client.callTool(
                name: "waitForPage",
                arguments: ["tabID": .string(taken.id.uuidString), "condition": "text", "value": "never-on-this-page", "timeout": 15])
        }
        defer { running.cancel() }
        try #require(await waitUntil { session.lastTool == "waitForPage" && taken.processState.isExternalAutomationWorking })

        app.mcpServer.takeOver(taken, in: first.browser)

        #expect(session.isConnected, "the connection keeps its other tabs")
        #expect(session.grants[taken.id] == nil)
        #expect(session.grants[kept.id] != nil)
        #expect(taken.developmentOwner == nil, "its lease on the tab is released")
        #expect(taken.processState.externalControllers.isEmpty, "the tab loses its mark")
        #expect(kept.processState.externalControllers == [session.id])
        #expect(app.mcpServer.controllers(of: taken, in: first.browser).isEmpty)
        #expect(app.mcpServer.controllers(of: kept, in: first.browser).map(\.id) == [session.id])
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                session.activity.entries.contains { $0.event == .tool("waitForPage") }
            }, "the call on the tab ended at once instead of waiting out its timeout")
        let (refused, refusedFailed) = try await client.callTool(name: "readPage", arguments: ["tabID": .string(taken.id.uuidString)])
        #expect(refusedFailed == true)
        let namesTheRefusal = refused.contains { block in
            guard case .text(let text, _, _) = block else { return false }
            return text.contains("not shared")
        }
        #expect(namesTheRefusal, "the tab is no longer shared with the connection")
        let (_, keptFailed) = try await client.callTool(name: "readPage", arguments: ["tabID": .string(kept.id.uuidString)])
        #expect(keptFailed == false)
    }

    @Test func stoppingFromATabEndsOnlyTheAppsThatHoldIt() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.page)])
        let directory = "/tmp/wsurf-mcp-tabstop-\(UUID().uuidString)"
        let endpoint = directory + "/browser.sock"
        let app = try await listeningApp(endpoint)
        let first = window(in: app)
        defer {
            app.mcpServer.stop()
            first.closeWindow()
            try? FileManager.default.removeItem(atPath: directory)
            _ = server
        }
        let url = try server.url()
        let held = first.browser.newTab(url: url)
        let other = first.browser.newTab(url: url)
        app.focus(first)
        let holder = try await connect("Codex", to: endpoint)
        let bystander = try await connect("Claude Code", to: endpoint)
        defer {
            Task {
                await holder.disconnect()
                await bystander.disconnect()
            }
        }
        try #require(await waitUntil { app.mcpServer.sessions(in: first.browser).count == 2 })
        let sessions = app.mcpServer.sessions(in: first.browser)
        let origin = SitePermissions.origin(for: url)
        sessions[0].grants[held.id] = .init(origin: origin, access: .control)
        sessions[1].grants[other.id] = .init(origin: origin, access: .control)

        #expect(app.mcpServer.stop(controllersOf: held, in: first.browser) == 1)

        #expect(!sessions[0].isConnected)
        #expect(sessions[1].isConnected, "an app that does not hold the tab keeps working")
        #expect(app.mcpServer.sessions(in: first.browser).map(\.id) == [sessions[1].id])
        #expect(held.processState.externalControllers.isEmpty)
        #expect(other.processState.externalControllers == [sessions[1].id])
        #expect(sessions[0].activity.entries.contains { $0.event == .stopped }, "Agent Activity records the stop")
    }

    @Test func stopOnlyAffectsThatWindowsConnections() async throws {
        let directory = "/tmp/wsurf-mcp-stop-\(UUID().uuidString)"
        let endpoint = directory + "/browser.sock"
        let app = try await listeningApp(endpoint)
        let first = window(in: app)
        let second = window(in: app)
        defer {
            app.mcpServer.stop()
            first.closeWindow()
            second.closeWindow()
            try? FileManager.default.removeItem(atPath: directory)
        }
        app.focus(first)
        let firstClient = try await connect("First app", to: endpoint)
        app.focus(second)
        let secondClient = try await connect("Second app", to: endpoint)
        defer {
            Task {
                await firstClient.disconnect()
                await secondClient.disconnect()
            }
        }
        let secondSession = try #require(app.mcpServer.sessions.first { $0.isBound(to: second.browser) })

        #expect(app.mcpServer.stop(window: first.browser) == 1)
        #expect(app.mcpServer.stop(window: first.browser) == 0, "nothing is left to stop")
        #expect(!first.hasExternalConnections)
        #expect(second.hasExternalConnections)
        #expect(app.mcpServer.sessions.map(\.id) == [secondSession.id])
        #expect(secondSession.isConnected)
        let (_, failed) = try await secondClient.callTool(name: "listTabs")
        #expect(failed == false)
    }
}
