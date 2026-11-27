// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP
import Network
import Testing

@testable import WSurf

extension MCPAgentWindowBridgeTests {
    private func openReviewWindow(
        _ client: BridgeClient, _ harness: Harness, profile: Profile, url: URL, access: String = "control", engine: BrowserEngine = .webKit
    ) async throws -> (window: AppCoordinator, tab: BrowserTab, token: String) {
        let (reply, _) = try await client.request(id: "open", op: "openAgentWindow", params: [
            "threadId": "review", "profileId": profile.id.uuidString, "url": url.absoluteString, "engine": engine.rawValue, "access": access,
        ])
        let result = try #require(reply["result"] as? [String: Any], "\(reply)")
        let window = try #require(harness.app.windows.first { $0.windowID.uuidString == result["windowId"] as? String })
        let tab = try #require(window.browser.tabs.first { $0.id.uuidString == result["tabId"] as? String })
        try #require(await waitUntil { tab.liveView?.url == url && !tab.isLoading && tab.liveView?.mainDocumentID != nil })
        return (window, tab, try #require(result["windowToken"] as? String))
    }

    private func connectWindowToken(_ token: String, in harness: Harness) async throws -> (MCP.Client, LocalMCPTransport) {
        let hello = try #require(MCPPairing.helloMessage(token: SyntheticToken.first, windowToken: token))
        let transport = LocalMCPTransport(connection: NWConnection(to: .unix(path: harness.mcpEndpoint), using: .tcp), hello: hello)
        let client = MCP.Client(name: "Review test", version: "1")
        _ = try await client.connect(transport: transport)
        return (client, transport)
    }

    private func preview(
        _ client: BridgeClient, _ operation: String, tab: BrowserTab, params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let (reply, _) = try await client.request(id: operation, op: "invokePreview", params: [
            "threadId": "review", "tabId": tab.id.uuidString, "operation": operation, "params": params,
        ])
        return reply
    }

    private func ref(for label: String, in text: String) throws -> Int {
        let line = try #require(text.split(separator: "\n").first { $0.contains(label) && $0.hasPrefix("[") }, "\(text)")
        return try #require(Int(line.dropFirst().prefix(while: \.isNumber)))
    }

    @Test(.timeLimit(.minutes(1))) func windowTokenSecretIsScrubbedAcrossBothTransportsAfterDisconnect() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Original</title><label>Code <input id='code' type='text'></label><p id='echo'>Original</p>"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            try harness.trust.setAllowsPasswordEntry(true)
            try harness.trust.setClientPolicy(\.allowsPasswordEntry, to: true, for: paired.id)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, tab, token) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"))
            let (client, transport) = try await connectWindowToken(token, in: harness)
            defer { Task { await transport.disconnect() } }
            let args: [String: Value] = ["tabID": .string(tab.id.uuidString)]
            let (read, failed) = try await client.callTool(name: "readPage", arguments: args)
            #expect(failed == false)
            let readText = read.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
            let readJSON = try #require(JSONSerialization.jsonObject(with: Data(readText.utf8)) as? [String: Any])
            let input = try ref(for: "field \"Code\"", in: #require(readJSON["content"] as? String))
            let secret = "review-demo-Q7-secret"
            let (_, typeFailed) = try await client.callTool(name: "typeOnPage", arguments: args.merging([
                "ref": .int(input), "text": .string(secret), "secret": true,
            ]) { _, new in new })
            #expect(typeFailed == false)
            let page = try #require(tab.liveView)
            #expect(try await page.evaluateJavaScript("document.querySelector('#code').value") as? String == secret)
            #expect(tab.mcpSecretWriteEpoch == tab.documentCommitEpoch)
            _ = try await page.evaluateJavaScript("""
                const value = document.querySelector('#code').value;
                document.title = value;
                document.querySelector('#echo').textContent = value;
                history.replaceState({}, '', '#' + value);
                0
                """)
            try #require(await waitUntil { tab.title.contains(secret) && tab.urlString.contains(secret) })
            await transport.disconnect()
            try #require(await waitUntil { harness.server.sessions(in: window.browser).isEmpty })

            harness.registry.notifyTabsChanged(for: window.browser)
            let (list, events) = try await bridge.request(id: "list", op: "listTabs")
            let sentEvent = events.last { $0["event"] as? String == "tabsChanged" }
            let event: [String: Any]
            if let sentEvent {
                event = sentEvent
            } else {
                event = try await bridge.waitForEvent(named: "tabsChanged")
            }
            let status = try await preview(bridge, "status", tab: tab)
            let snapshot = try await preview(bridge, "snapshot", tab: tab, params: ["includeImage": true])
            let result = try #require(snapshot["result"] as? [String: Any], "\(snapshot)")
            let descriptors = [
                ((list["result"] as? [String: Any])?["tabs"] as? [[String: Any]])?.first,
                ((event["payload"] as? [String: Any])?["tabs"] as? [[String: Any]])?.first,
                status["result"] as? [String: Any],
                result,
            ]
            for descriptor in descriptors {
                #expect(descriptor?["title"] as? String == MCPSecretScrubber.replacement)
                #expect((descriptor?["url"] as? String)?.hasSuffix("#" + MCPSecretScrubber.replacement) == true)
            }
            for key in ["page", "accessibilityTree"] {
                let content = try #require(result[key] as? String)
                #expect(!content.contains(secret))
                #expect(content.contains(MCPSecretScrubber.replacement))
            }
            #expect(result["imageBase64"] == nil)
            let record = try #require(harness.registry.record(pairedClientId: paired.id, threadId: "review"))
            record.secrets.wipe()
            let refused = try await preview(bridge, "snapshot", tab: tab)
            #expect((refused["error"] as? [String: Any])?["code"] as? String == "protectedSecretPresent")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func manualLoginTakesOverBeforeReturningWaitingForUser(useSheet: Bool) async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Login</title><p>Sign in</p>")])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, tab, token) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"))
            let args: [String: Value] = ["tabID": .string(tab.id.uuidString)]
            if useSheet {
                let scope = try #require(harness.registry.resolve(windowToken: token, pairedClientId: paired.id)?.1)
                let session = MCPBrowserSession(
                    browser: window.browser, trust: harness.trust, available: { true }, loginConsent: { _, _, _, manual, _ in
                        #expect(manual)
                        return .takeOver
                    })
                session.pairedClient = paired
                session.agentWindowScope = scope
                defer { session.revoke() }
                let response = try await session.call(name: "requestUserLogin", arguments: args)
                #expect(response.structuredContent?.objectValue?["code"] == "waitingForUser")
            } else {
                let (client, transport) = try await connectWindowToken(token, in: harness)
                defer { Task { await transport.disconnect() } }
                let (reply, failed) = try await client.callTool(
                    name: "requestUserLogin", arguments: args.merging(["mode": "manualLogin"]) { _, new in new })
                #expect(failed == false)
                #expect(String(describing: reply).contains("waitingForUser"))
            }
            let event = try await bridge.waitForEvent(named: "ownerChanged")
            #expect((event["payload"] as? [String: Any])?["owner"] as? String == "human")
            #expect((event["payload"] as? [String: Any])?["generation"] as? Int == 2)
            let blocked = try await preview(bridge, "navigate", tab: tab, params: ["url": fixture.url("/").absoluteString])
            #expect((blocked["error"] as? [String: Any])?["code"] as? String == "humanControl")
            let (close, _) = try await bridge.request(id: "close", op: "closeAgentWindow", params: ["threadId": "review"])
            #expect((close["error"] as? [String: Any])?["code"] as? String == "humanControl")
            #expect(!window.isClosed)
        }
    }

    enum ProtectedFrame: CaseIterable {
        case lightDOM, closedShadow, opaque
    }

    @Test(.timeLimit(.minutes(1)), arguments: ProtectedFrame.allCases)
    func crossOriginFramesBlockHumanAndDeveloperImagesAndHandoffInvalidatesRefs(placement: ProtectedFrame) async throws {
        let nested = try await HTTPFixtureServer.start(routes: ["/": .html("<input type='password' value='demo-otp'>")])
        let frameURL = try nested.url("/")
        let sandbox = placement == .opaque ? " sandbox" : ""
        let frame = "<iframe\(sandbox) src=\"\(frameURL.absoluteString)\" width=\"260\" height=\"180\"></iframe>"
        let content = placement != .lightDOM
            ? "<div id='host'></div><script>document.querySelector('#host').attachShadow({mode: 'closed'}).innerHTML = '\(frame)'</script>"
            : frame
        let top = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <title>Frame fixture</title><button onclick="this.textContent = 'Clicked'">Go</button>
                <section id="other"><button>Alternate</button></section>\(content)
                """),
        ])
        defer { withExtendedLifetime((top, nested)) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            try harness.trust.setStanding(.developer, for: paired.id)
            try harness.trust.setDeveloperProfile(profile.id, dedicated: true)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, tab, token) = try await openReviewWindow(bridge, harness, profile: profile, url: top.url("/"), access: "developer")
            try #require(await waitUntil { nested.lastRequestHead(for: "/") != nil })
            let (client, transport) = try await connectWindowToken(token, in: harness)
            defer { Task { await transport.disconnect() } }
            let (shot, failed) = try await client.callTool(name: "screenshotPage", arguments: ["tabID": .string(tab.id.uuidString)])
            #expect(failed == true)
            #expect(!shot.contains { if case .image = $0 { true } else { false } })
            #expect(String(describing: shot).localizedCaseInsensitiveContains("frame"))

            window.takeOverAgentMicroWindow()
            let human = try await preview(bridge, "snapshot", tab: tab, params: ["includeImage": true])
            let snapshot = try #require(human["result"] as? [String: Any], "\(human)")
            #expect(snapshot["imageBase64"] == nil)
            let control = try ref(for: "button \"Go\"", in: #require(snapshot["page"] as? String))
            let observation = try #require(snapshot["observationId"] as? String)
            window.handBackAgentMicroWindow()
            let click: [String: Any] = ["action": "click", "ref": control, "observationId": observation]
            let stale = try await preview(bridge, "act", tab: tab, params: click)
            #expect(stale["ok"] as? Bool == false)
            #expect(String(describing: stale["error"]).contains("stale"))
            let fresh = try await preview(bridge, "snapshot", tab: tab, params: ["scope": "#other"])
            let current = try #require(fresh["result"] as? [String: Any], "\(fresh)")
            let controls = try #require(current["page"] as? String)
            #expect(!controls.contains("button \"Go\""))
            let freshControl = try ref(for: "button \"Alternate\"", in: controls)
            let newObservation = try #require(current["observationId"] as? String)
            let omitted = try await preview(bridge, "act", tab: tab, params: [
                "action": "click", "ref": control, "observationId": newObservation,
            ])
            #expect(omitted["ok"] as? Bool == false)
            #expect(try await tab.page.evaluateJavaScript("document.querySelector('button').textContent") as? String == "Go")
            let accepted = try await preview(bridge, "act", tab: tab, params: [
                "action": "click", "ref": freshControl, "observationId": newObservation,
            ])
            #expect(accepted["ok"] as? Bool == true, "\(accepted)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func reusedOpenOnlyFocusesVisibleWindowOnExplicitRequest() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Focus</title>")])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            var shows = 0
            let harness = try await startHarness(onShow: { shows += 1 })
            defer { stopHarness(harness) }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"))
            let native = try #require(window.nativeWindow)
            let args: [String: Any] = ["threadId": "review"]
            #expect(shows == 1)
            #expect((try await preview(bridge, "status", tab: tab)["result"] as? [String: Any])?["visible"] as? Bool == true)
            for (open, total) in [(nil, 1), (false, 1), (true, 2)] as [(Bool?, Int)] {
                var supplied = args
                supplied["open"] = open
                let (response, _) = try await bridge.request(id: "reuse", op: "openAgentWindow", params: supplied)
                #expect((response["result"] as? [String: Any])?["visible"] as? Bool == true)
                #expect(shows == total)
            }
            native.orderOut(nil)
            #expect((try await preview(bridge, "status", tab: tab)["result"] as? [String: Any])?["visible"] as? Bool == false)
            let (reopened, _) = try await bridge.request(id: "reopen", op: "openAgentWindow", params: args)
            #expect((reopened["result"] as? [String: Any])?["visible"] as? Bool == true)
            #expect(shows == 3)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func takeOverCancelsReusedOpenAwaitingEngineRetirement(urlDriven: Bool) async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Preserve this page</title>")])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let source = try fixture.url("/")
            let (window, tab, _) = try await openReviewWindow(
                bridge, harness, profile: profile, url: source, engine: urlDriven ? .chromium : .webKit)
            let page = try #require(tab.liveView)
            let generation = tab.pageGeneration
            let record = try #require(harness.registry.record(pairedClientId: paired.id, threadId: "review"))

            // Hold the retirement wait while the live page is still installed.
            let pending = Task {
                try? await Task.sleep(for: .seconds(30))
                tab.retirement = nil
            }
            tab.retirement = pending
            defer { pending.cancel() }
            let port = try #require(fixture.port).rawValue
            let restricted = try #require(URL(string: "http://localhost:\(port)/"))
            try await SitePermissions.withWebKitOnlyOriginForTesting(SitePermissions.origin(for: restricted)) {
                var params: [String: Any] = ["threadId": "review", "title": "Preparing engine"]
                if urlDriven {
                    params["url"] = restricted.absoluteString
                } else {
                    params["engine"] = "chromium"
                }
                try await bridge.sendJSON(["id": "switch", "op": "openAgentWindow", "params": params])
                try #require(await waitUntil {
                    !record.activeOperations.isEmpty && window.browser.agentCompanion?.threadTitle == "Preparing engine"
                        && (!urlDriven || tab.pendingNavigationTask != nil)
                })
                window.takeOverAgentMicroWindow()
                // The reply must arrive while the retirement remains blocked.
                let response = try await bridge.waitForReply(id: "switch")
                #expect((response["error"] as? [String: Any])?["code"] as? String == "humanControl")
                #expect(tab.retirement != nil)
                pending.cancel()
                await pending.value
                #expect(tab.liveView === page)
                #expect(tab.pageGeneration == generation)
                #expect(tab.liveView?.url == source)
                #expect(tab.urlString == source.absoluteString)
                #expect(tab.signInEngine == nil)
                #expect(tab.loadedEngine == (urlDriven ? .chromium : .webKit))
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func explicitChromiumTabUsesWebKitForSecondNavigation() async throws {
        let first = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Initial Chromium page</title>")])
        let second = try await HTTPFixtureServer.start(routes: ["/": .html("<title>WebKit only</title>")])
        let url = try second.url("/")
        defer { withExtendedLifetime((first, second)) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, _, token) = try await openReviewWindow(bridge, harness, profile: profile, url: first.url("/"))
            let (client, transport) = try await connectWindowToken(token, in: harness)
            defer { Task { await transport.disconnect() } }
            let (_, failed) = try await client.callTool(name: "newTab", arguments: [
                "url": .string(first.url("/").absoluteString), "engine": "chromium", "waitAndRead": false,
            ])
            #expect(failed == false)
            let tab = try #require(window.browser.tabs.first { $0.engineOverride == .chromium })
            try #require(await waitUntil { tab.liveView?.engine == .chromium && !tab.isLoading })
            try await SitePermissions.withWebKitOnlyOriginForTesting(SitePermissions.origin(for: url)) {
                var submission = URLRequest(url: url)
                submission.httpMethod = "POST"
                submission.httpBody = Data("fixture".utf8)
                #expect(!tab.permitsEngineNavigation(submission, isMainFrame: true))
                let reply = try await preview(bridge, "navigate", tab: tab, params: ["url": url.absoluteString])
                #expect(reply["ok"] as? Bool == true, "\(reply)")
                try #require(await waitUntil { tab.liveView?.engine == .webKit && tab.liveView?.url == url && !tab.isLoading })
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func numericSecretIsRedactedByBothScriptTransports() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Numeric result</title><p>Fixture</p>")])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            try harness.trust.setStanding(.developer, for: paired.id)
            try harness.trust.setDeveloperProfile(profile.id, dedicated: true)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (_, tab, token) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"), access: "developer")
            let record = try #require(harness.registry.record(pairedClientId: paired.id, threadId: "review"))
            #expect(record.secrets.register("718429") == .registered)
            let (client, transport) = try await connectWindowToken(token, in: harness)
            defer { Task { await transport.disconnect() } }
            let context: MCP.RequestContext<CallTool.Result> = try await client.callTool(
                name: "evaluateScript", arguments: ["tabID": .string(tab.id.uuidString), "source": "718429"])
            let result = try await context.value
            #expect(result.isError == false)
            #expect(result.structuredContent?.objectValue?["value"] == .string(MCPSecretScrubber.replacement))
            #expect(!MCPBrowserSession.text(of: result).contains("718429"))
            let previewReply = try await preview(bridge, "evaluate", tab: tab, params: ["expression": "718429"])
            let previewContent = try #require(previewReply["result"] as? [String: Any], "\(previewReply)")
            #expect(previewContent["value"] as? String == MCPSecretScrubber.replacement)
        }
    }

    @Test(.timeLimit(.minutes(1))) func humanSnapshotOmitsTheGeneratedCallbackAddress() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/callback": .html("<title>Signed in</title><p>Welcome</p>")])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let callbackCode = "fixture-oauth-callback"
            let url = try fixture.url("/callback?code=\(callbackCode)")
            let (window, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: url)
            let agent = try await preview(bridge, "snapshot", tab: tab)
            let agentContent = try #require(agent["result"] as? [String: Any])
            window.takeOverAgentMicroWindow()
            let human = try await preview(bridge, "snapshot", tab: tab)
            let humanContent = try #require(human["result"] as? [String: Any])
            for key in ["url", "page", "accessibilityTree"] {
                #expect((agentContent[key] as? String)?.contains(callbackCode) == true)
                #expect((humanContent[key] as? String)?.contains(callbackCode) == false)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func windowSecretCapAndDeadRecordUseWindowLifetime() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Secret registry</title>")])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            try harness.trust.setAllowsPasswordEntry(true)
            try harness.trust.setClientPolicy(\.allowsPasswordEntry, to: true, for: paired.id)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (_, tab, token) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"))
            let record = try #require(harness.registry.record(pairedClientId: paired.id, threadId: "review"))
            let session = try #require(record.previewSession)
            session.syncAgentWindowGrants()
            let scope = try #require(harness.registry.resolve(windowToken: token, pairedClientId: paired.id)?.1)
            for index in 0..<MCPSecretScrubber.maximumSecrets {
                #expect(scope.secrets.register("synthetic-secret-\(index)") == .registered)
            }
            let entry = MCPBrowserSession.SecretEntry(values: ["one-more-test-value"], refs: [])
            let refusal = try #require(session.secretEntryRefusal(entry, tab: tab))
            let text = MCPBrowserSession.text(of: refusal)
            #expect(text.contains("Open another Agent Micro Window"))
            #expect(!text.contains("Disconnect"))

            record.coordinator = nil
            _ = harness.registry.listTabs(pairedClientId: paired.id, threadId: "review")
            #expect(!scope.isActive())
            #expect(scope.secrets.isEmpty)
            #expect(!session.isConnected)
        }
    }
}
