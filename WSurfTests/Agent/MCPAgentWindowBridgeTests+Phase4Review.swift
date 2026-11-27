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
            #expect(record.secrets.register("1920") == .registered)
            tab.page.developmentViewport = CGSize(width: 1920, height: 1080)
            let info: MCP.RequestContext<CallTool.Result> = try await client.callTool(
                name: "getDevelopmentInfo", arguments: ["tabID": .string(tab.id.uuidString)])
            let infoReply = try await info.value
            #expect(infoReply.isError == false)
            let text = Data(MCPBrowserSession.text(of: infoReply).utf8)
            let decoded = try JSONDecoder().decode(Value.self, from: text)
            #expect(decoded.objectValue?["viewportOverride"] == .object(["width": .int(1920), "height": .int(1080)]))
            #expect(decoded.objectValue?["viewportOverride"] == infoReply.structuredContent?.objectValue?["viewportOverride"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func webKitScreenshotAccountsForSameOriginSVGFields() async throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="250" height="100">
              <foreignObject width="250" height="100">
                <input xmlns="http://www.w3.org/1999/xhtml" type="password" value="fixture-secret"/>
              </foreignObject>
            </svg>
            """
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>SVG fixture</title><iframe src='/field.svg'></iframe>"),
            "/field.svg": .bytes(Data(svg.utf8), contentType: "image/svg+xml"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"))
            let page = try #require(tab.liveView)
            let nonce = try await page.evaluateJavaScript(
                "document.querySelector('iframe').contentWindow.__wsurfNativeFrameNonce",
                in: nil, contentWorld: PageAutomationGuard.world
            )
            try #require(PageFrameRegistry.shared.target(try #require(nonce as? String), in: page) != nil)
            #expect(await PageDriver.screenshot(in: page).failure == .privacy)
            let masked = await PageDriver.screenshot(masking: ScreenshotMasking(), in: page)
            let capture = try masked.get()
            let bitmap = try #require(NSBitmapImageRep(data: capture.jpeg))
            let center = try #require(try await page.evaluateJavaScript("""
                (() => { const r = document.querySelector('iframe').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()
                """) as? [Double])
            let color = try #require(bitmap.colorAt(x: Int(center[0] * capture.scale), y: Int(center[1] * capture.scale))?.usingColorSpace(.sRGB))
            #expect(color.redComponent < 0.1 && color.greenComponent < 0.1 && color.blueComponent < 0.1)
            let unregistered = await PageDriver.$afterScreenshotCapture.withValue({
                // The frame's URL and JavaScript nonce still match, but its native registration is no longer current.
                PageFrameRegistry.shared.retire(page)
            }) {
                await PageDriver.screenshot(masking: ScreenshotMasking(), in: page)
            }
            #expect(unregistered.failure == .uninspectableFrame)
            window.takeOverAgentMicroWindow()
            let human = try await preview(bridge, "snapshot", tab: tab, params: ["includeImage": true])
            #expect((human["error"] as? [String: Any])?["code"] as? String == "protectedSecretPresent")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [BrowserEngine.webKit, .chromium])
    func transientChildDuringCaptureInvalidatesOtherwiseIdenticalFrames(engine: BrowserEngine) async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Stable top document</title><iframe src='/child'></iframe>"),
            "/child": .html("<p>Safe child</p>"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (_, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"), engine: engine)
            let page = try #require(tab.liveView)
            let stable = await PageDriver.screenshot(in: page)
            try #require(stable.failure == nil, "\(stable)")
            var mutated = false
            let changed = await PageDriver.$afterScreenshotCapture.withValue({
                let result = try? await page.evaluateJavaScript("""
                    const transient = document.createElement('iframe');
                    document.body.append(transient);
                    transient.remove();
                    document.querySelectorAll('iframe').length;
                    """)
                mutated = result as? Int == 1
            }) {
                await PageDriver.screenshot(in: page)
            }
            #expect(mutated)
            #expect(changed.failure == .uninspectableFrame)
        }
    }

    @Test(.timeLimit(.minutes(1))) func takeOverCancelsRedirectReissueWaitingForEngineRetirement() async throws {
        let target = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Redirect destination</title>")])
        let targetURL = try target.url("/")
        let gate = ResponseGate()
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Keep this document</title>"),
            "/redirect": .init(status: "302 Found", headers: ["Location": targetURL.absoluteString], body: Data(), gate: gate),
        ])
        defer { gate.open(); withExtendedLifetime((fixture, target)) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let source = try fixture.url("/")
            let (window, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: source, engine: .chromium)
            let page = try #require(tab.liveView)
            try await SitePermissions.withWebKitOnlyOriginForTesting(SitePermissions.origin(for: targetURL)) {
                let response = try await preview(bridge, "navigate", tab: tab, params: [
                    "url": fixture.url("/redirect").absoluteString, "readiness": "none",
                ])
                try #require(response["ok"] as? Bool == true, "\(response)")
                try #require(await gate.waitForRequest())
                let retirement = Task {
                    try? await Task.sleep(for: .seconds(30))
                    tab.retirement = nil
                }
                defer { retirement.cancel() }
                tab.retirement = retirement
                gate.open()
                try #require(await waitUntil { tab.pendingNavigationTask != nil })
                window.takeOverAgentMicroWindow()
                retirement.cancel()
                await retirement.value
                #expect(await tab.waitForPendingNavigation() == nil)
                #expect(tab.liveView === page)
                #expect(page.url == source)
                #expect(target.lastRequestHead(for: "/") == nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func takeOverStopsUnattachedChromiumNavigationBeforeDispatch() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Window fixture</title>"), "/queued": .html("<title>Queued Chromium request</title>"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"))
            let record = try #require(harness.registry.record(pairedClientId: paired.id, threadId: "review"))
            let generation = try #require(window.browser.agentCompanion?.generation)
            try ChromiumRuntime.shared.ensureInitialized()
            let native = ChromiumPage(context: tab.context)
            let page = BrowserPage(chromium: native)
            let pendingURL = try fixture.url("/queued")
            try #require(page.load(URLRequest(url: pendingURL), authorized: {
                harness.registry.mayMutate(record, generation: generation)
            }) != nil)
            try #require(await waitUntil { !native.attachmentWaiters.isEmpty })
            window.takeOverAgentMicroWindow()
            let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                                styleMask: .borderless, backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = page
            defer { host.contentView = nil; host.close() }
            await native.pendingLoad?.value
            #expect(native.navigation == nil)
            #expect(!page.isLoading)
            #expect(fixture.lastRequestHead(for: "/queued") == nil)
            await page.close()
        }
    }

    @Test(.timeLimit(.minutes(1))) func parkedFindCannotPublishAnObservationAcrossTakeOverAndHandBack() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: ["/": .html("<button id='old'>Old</button><section id='new'><button>New</button></section>")])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            let paired = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let (window, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: fixture.url("/"))
            let record = try #require(harness.registry.record(pairedClientId: paired.id, threadId: "review"))
            let session = try #require(record.previewSession)
            session.syncAgentWindowGrants()
            let entry = try #require(MCPToolCatalog.entries.first { $0.name == "findElements" })
            let queue = tab.dialogs
            let claim = queue.claim(connection: session.id) { true }
            defer { claim.end(); queue.cancelAll() }
            let result = await PageDriver.$beforeFindObservation.withValue({
                _ = await queue.run(.init(kind: .alert, message: "Fixture dialog", origin: "")) {
                    .init(accepted: true)
                }
            }) {
                await session.usePage(entry, arguments: ["selector": "#old"], tab: tab, capability: .read)
            }
            #expect(result.structuredContent?.objectValue?["status"]?.stringValue == "dialogOpened")
            let dialog = try #require(queue.pending(for: session.id).first)
            window.takeOverAgentMicroWindow()
            window.handBackAgentMicroWindow()
            #expect(queue.answer(dialog.id, connection: session.id, with: .init(accepted: true)))
            await queue.settleParked()
            #expect(PageDriver.observation(in: tab.page) == nil)
            let scoped = try await preview(bridge, "snapshot", tab: tab, params: ["scope": "#new"])
            #expect((scoped["result"] as? [String: Any])?["observationId"] != nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func hostBridgeReportsRetirementTimeoutForNavigateAndReusedOpen() async throws {
        let fixture = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Current page</title>"), "/next": .html("<title>Next page</title>"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        try await withProfile { profile in
            let harness = try await startHarness()
            defer { stopHarness(harness) }
            _ = try harness.trust.pair(token: SyntheticToken.first, name: "Review", kind: nil)
            let bridge = try await connectAuthenticated(harness)
            defer { Task { await bridge.close() } }
            let source = try fixture.url("/")
            let (_, tab, _) = try await openReviewWindow(bridge, harness, profile: profile, url: source)
            let page = try #require(tab.liveView)
            let retirement = Task {
                try? await Task.sleep(for: .seconds(45))
                tab.retirement = nil
            }
            defer { retirement.cancel() }
            tab.retirement = retirement
            let next = try fixture.url("/next").absoluteString
            let navigated = try await preview(bridge, "navigate", tab: tab, params: ["url": next, "readiness": "none"])
            #expect((navigated["error"] as? [String: Any])?["code"] as? String == "actionFailed")
            let (reopened, _) = try await bridge.request(id: "reopen", op: "openAgentWindow", params: ["threadId": "review", "url": next])
            #expect((reopened["error"] as? [String: Any])?["code"] as? String == "actionFailed")
            #expect(tab.liveView === page)
            #expect(page.url == source)
            #expect(fixture.lastRequestHead(for: "/next") == nil)
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

private extension Result where Failure == ScreenshotFailure {
    var failure: ScreenshotFailure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
