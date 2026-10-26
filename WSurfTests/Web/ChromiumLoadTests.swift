// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What Chromium's DevTools connection does for a page load and no more: a script installed twice is registered once, an event
/// nothing acts on is never parsed, a world is bound only when something can use it, the isolated-context lookup is a
/// dictionary's, and a cross-site frame's scripts go in as one burst before the frame runs. The cost itself is measured in
/// `ChromiumLoadPerformanceTests`.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ChromiumLoadTests {
    private func withDevTools(_ body: (ChromiumDevTools) async throws -> Void) async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        do {
            try await body(ChromiumDevTools(page: native))
        } catch {
            await context.endPrivateSession()
            throw error
        }
        withExtendedLifetime(native) {}
        await context.endPrivateSession()
    }

    // MARK: Scripts

    @Test func theSameScriptInstalledTwiceIsRegisteredOnce() async throws {
        try await withDevTools { devTools in
            let world = AutofillPage.world
            let form = AutofillFormScript.source + AutofillSuggestionScript.source
            // The four autofill features each install the shared form script ahead of their own.
            for client in ["password", "save", "contact", "card"] {
                devTools.installScript(form, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                devTools.installScript("/* \(client) */", in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            }
            #expect(devTools.scripts.map(\.source) == [form, "/* password */", "/* save */", "/* contact */", "/* card */"],
                    "once each, in the order they were first installed")

            // Anything that differs makes another script: world, injection time, frame scope, source.
            devTools.installScript(form, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            devTools.installScript(form, in: world, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            devTools.installScript(form, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            devTools.installScript(form + "\n", in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            #expect(devTools.scripts.count == 9)
            devTools.installScript(form, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            devTools.installScript(form, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            #expect(devTools.scripts.count == 10, "the page world is a world of its own")
        }
    }

    /// A script that is already in goes to no cross-site frame session a second time either.
    @Test func aScriptInstalledTwiceReachesAFrameSessionOnce() async throws {
        try await withDevTools { root in
            let child = ChromiumDevTools(root: root, parent: root, sessionID: "S", targetID: "T")
            root.sessions["S"] = child
            for _ in 0..<3 {
                root.installScript("/* autofill */", in: AutofillPage.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            }
            #expect(child.scripts.map(\.source) == ["/* autofill */"])
        }
    }

    // MARK: Events

    private func deliver(_ name: String, _ json: String, to devTools: ChromiumDevTools) {
        let data = Data(json.utf8)
        data.withUnsafeBytes { devTools.receiveEvent(name: name, pointer: $0.baseAddress, size: data.count) }
    }

    /// Chromium sends five Network events for every resource, all the time. Nothing acts on them without a diagnostics capture, so
    /// they are told apart by their name, before their parameters are read.
    @Test func anEventNothingActsOnIsNeitherParsedNorDispatched() async throws {
        try await withDevTools { devTools in
            let revision = devTools.frameRevision
            let unwanted = [
                "Network.requestWillBeSent", "Network.requestWillBeSentExtraInfo", "Network.responseReceivedExtraInfo",
                "Network.loadingFinished", "Network.dataReceived", "Page.lifecycleEvent", "Runtime.consoleAPICalled",
            ]
            for name in unwanted {
                deliver(name, #"{"requestId":"1.1","frameId":"X","reason":"remove"}"#, to: devTools)
                deliver(name, "this is not JSON", to: devTools)
            }
            #expect(devTools.loadStatistics.eventsReceived == unwanted.count * 2)
            #expect(devTools.loadStatistics.eventsParsed == 0, "not one of them was parsed")
            #expect(devTools.frameRevision == revision)

            // An event the session acts on is parsed and handed on: a frame going away turns the revision.
            deliver("Page.frameDetached", #"{"frameId":"X","reason":"remove"}"#, to: devTools)
            #expect(devTools.loadStatistics.eventsParsed == 1)
            #expect(devTools.frameRevision == revision &+ 1)
        }
    }

    /// Chromium reports every resource's response, and only a document's is used: only that is parsed.
    @Test func onlyADocumentsResponseIsParsed() async throws {
        try await withDevTools { devTools in
            deliver("Network.responseReceived", #"{"requestId":"1.1","type":"Script","response":{"url":"https://a.example/a.js","status":200}}"#, to: devTools)
            deliver("Network.responseReceived", #"{"requestId":"1.2","type":"Image","response":{"url":"https://a.example/a.png","status":200}}"#, to: devTools)
            #expect(devTools.loadStatistics.eventsParsed == 0)
            deliver("Network.responseReceived", #"{"requestId":"1.3","type":"Document","frameId":"M","loaderId":"L","response":{"url":"https://a.example/","status":200}}"#, to: devTools)
            #expect(devTools.loadStatistics.eventsParsed == 1)
            #expect(devTools.loadStatistics.eventsReceived == 3)
        }
    }

    /// While a capture is running, its events are the diagnostics': they are parsed and handed to the sink, and only those.
    @Test func aDiagnosticsCaptureStillHearsTheNetworkEvents() async throws {
        try await withDevTools { devTools in
            var heard: [String] = []
            devTools.diagnosticsSink = { method, params in heard.append(method + ":" + (params["requestId"] as? String ?? "")) }
            deliver("Network.requestWillBeSent", #"{"requestId":"1.1"}"#, to: devTools)
            deliver("Network.responseReceived", #"{"requestId":"1.2","type":"Image"}"#, to: devTools)
            deliver("Network.loadingFinished", #"{"requestId":"1.3"}"#, to: devTools)
            deliver("Network.dataReceived", #"{"requestId":"1.4"}"#, to: devTools)
            #expect(heard == ["Network.requestWillBeSent:1.1", "Network.responseReceived:1.2", "Network.loadingFinished:1.3"])
            #expect(devTools.loadStatistics.eventsParsed == 3, "the event nobody listens to is still not parsed")
        }
    }

    /// A page's own messages are only searched for a session's name, and none is taken for one by what is inside its parameters.
    @Test func theSearchForASessionsNameFindsItWhereverItIs() async throws {
        try await withDevTools { root in
            @MainActor func taken(_ json: String) -> Bool {
                let data = Data(json.utf8)
                return data.withUnsafeBytes { root.receiveSessionMessage($0.baseAddress!, size: data.count) }
            }
            #expect(taken(#"{"method":"Page.frameNavigated","params":{"frame":{"id":"T"}},"sessionId":"S"}"#))
            #expect(!taken(#"{"method":"Network.requestWillBeSent","params":{"requestId":"1.1","documentURL":"https://a.example/"}}"#))
            #expect(!taken("x"))
            #expect(root.loadStatistics.sessionMessagesParsed == 1, "only the message that names a session was parsed")
        }
    }

    // MARK: Contexts

    @Test func theContextTableFindsAContextByItsFrameDocumentAndWorld() {
        typealias State = ChromiumDevTools.ContextState
        var table = ChromiumDevTools.ContextTable()
        func state(_ unique: String, _ frame: String, _ document: String, _ world: String, _ execution: Int) -> State {
            State(executionID: execution, uniqueID: unique, frameID: frame, worldName: world, documentID: document)
        }
        table["a"] = state("a", "F", "L1", "WSurfAutofill", 1)
        table["b"] = state("b", "F", "L1", "", 0)
        table["c"] = state("c", "G", "L2", "WSurfAutofill", 2)
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "WSurfAutofill")?.uniqueID == "a")
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "")?.uniqueID == "b")
        #expect(table.context(frameID: "G", documentID: "L2", worldName: "WSurfAutofill")?.uniqueID == "c")
        #expect(table.context(frameID: "F", documentID: "L2", worldName: "WSurfAutofill") == nil)
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "WSurfServices") == nil)

        // A record changed in place is found under what it names now, and no longer under what it named.
        table["a"]?.bound = true
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "WSurfAutofill")?.bound == true)
        table["a"] = state("a", "F", "L3", "WSurfAutofill", 1)
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "WSurfAutofill") == nil)
        #expect(table.context(frameID: "F", documentID: "L3", worldName: "WSurfAutofill")?.uniqueID == "a")

        // A page restored from the cache gives its frame's contexts the document it came back with.
        table.setDocument("L9", ofFrame: "F")
        #expect(table.context(frameID: "F", documentID: "L3", worldName: "WSurfAutofill") == nil)
        #expect(table.context(frameID: "F", documentID: "L9", worldName: "WSurfAutofill")?.uniqueID == "a")
        #expect(table.context(frameID: "F", documentID: "L9", worldName: "")?.uniqueID == "b")
        #expect(table.context(frameID: "G", documentID: "L2", worldName: "WSurfAutofill")?.uniqueID == "c", "another frame's stay")

        #expect(table.removeValue(forKey: "a")?.uniqueID == "a")
        #expect(table.context(frameID: "F", documentID: "L9", worldName: "WSurfAutofill") == nil)
        #expect(table.removeValue(forKey: "a") == nil)
        table["b"] = nil
        #expect(table.context(frameID: "F", documentID: "L9", worldName: "") == nil)
        #expect(table.values.count == 1 && !table.isEmpty)
        #expect(table.map { $0.key } == ["c"])
        table.removeAll()
        #expect(table.isEmpty && table.context(frameID: "G", documentID: "L2", worldName: "WSurfAutofill") == nil)

        // Two records of one frame, document and world: the lookup names one of them, and losing the other keeps it found.
        table["x"] = state("x", "F", "L1", "W", 1)
        table["y"] = state("y", "F", "L1", "W", 2)
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "W")?.uniqueID == "y")
        table["x"] = nil
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "W")?.uniqueID == "y")
        table["y"] = nil
        #expect(table.context(frameID: "F", documentID: "L1", worldName: "W") == nil)
    }

    // MARK: Which worlds are bound

    @Test func aWorldIsBoundOnlyWhenSomethingCanUseIt() async throws {
        try await withDevTools { devTools in
            let autofill = AutofillPage.world, services = BrowserPage.servicesWorld, pull = PullToRefreshMonitor.world
            devTools.installScript(AutofillFormScript.source, in: autofill, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            devTools.installScript(PasswordAutofillScript.clientSource, in: autofill, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            devTools.addScriptMessageHandler(name: "wsurfPasswords", in: autofill) { _ in }
            devTools.installScript(PullToRefreshMonitor.wheelWatchScript, in: pull, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            devTools.installScript("/* a script of another world that sends nothing */", in: services, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            #expect(devTools.needsBinding(autofill.name ?? ""), "a handler hears it")
            #expect(!devTools.needsBinding(pull.name ?? ""), "a wheel watch has nothing to send and nobody to hear it")
            #expect(!devTools.needsBinding(services.name ?? ""), "no handler, and its script never sends")
            devTools.installScript("__wsurfSend('late', 1);", in: services, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            #expect(devTools.needsBinding(services.name ?? ""), "a script that sends needs the relay whether or not a handler is there yet")
            // A world only a handler names (nothing installed in it) is bound for the messages sent by evaluation.
            let echo = WKContentWorld.world(name: "WSurfLoadTestEcho")
            devTools.addScriptMessageHandler(name: "echo", in: echo) { _ in }
            #expect(devTools.needsBinding(echo.name ?? ""))
            // The page world gets its relay only for a page-world handler; the bridge world follows it.
            #expect(!devTools.needsBinding("") && !devTools.needsBinding(ChromiumDevTools.pageBridgeWorld))
            devTools.addScriptMessageHandler(name: "page", in: .page) { _ in }
            #expect(devTools.needsBinding("") && devTools.needsBinding(ChromiumDevTools.pageBridgeWorld))
        }
    }

    /// A cross-site frame's session binds a world only for the handlers that hear such frames, which are the page session's.
    @Test func aFrameSessionBindsOnlyTheWorldsWhoseHandlersHearIt() async throws {
        try await withDevTools { root in
            let child = ChromiumDevTools(root: root, parent: root, sessionID: "S", targetID: "T")
            root.sessions["S"] = child
            let autofill = AutofillPage.world.name ?? "", services = BrowserPage.servicesWorld.name ?? ""
            root.addScriptMessageHandler(name: "wsurfPasswords", in: AutofillPage.world) { _ in }
            root.addScriptMessageHandler(name: "wsurfSiteGuard", in: BrowserPage.servicesWorld) { _ in }
            #expect(child.needsBinding(autofill))
            #expect(!child.needsBinding(services), "the services world has only handlers that never hear a cross-site frame")
            root.addScriptMessageHandler(name: MediaCenter.frameScriptHandlerName, in: BrowserPage.servicesWorld) { _ in }
            #expect(child.needsBinding(services))
            #expect(root.needsBinding(services))
        }
    }

    // MARK: A real frame session

    private static let probeRoutes: [String: HTTPFixtureServer.Response] = [
        "/": .html("""
            <!doctype html><html><body><script>
            const f = document.createElement('iframe'); f.src = 'http://localhost:' + location.port + '/frame'; document.body.append(f);
            </script></body></html>
            """),
        "/frame": .html("<!doctype html><html><body><input id=\"u\"></body></html>"),
    ]

    /// The probe: a script that records, one that throws, and one that reports, all in the autofill world after the form script.
    private static let probeScripts = [
        "(globalThis.__wsurfProbe ??= []).push('before:' + (document.body === null));",
        "throw new Error('a script of ours that fails');",
        """
        (globalThis.__wsurfProbe ??= []).push('after');
        __wsurfSend('wsurfProbe', {order: globalThis.__wsurfProbe, forms: typeof globalThis.__wsurfAutofillForms, send: typeof globalThis.__wsurfSend});
        """,
    ]

    @MainActor
    private final class Probe {
        var posts: [(body: [String: Any], frame: BrowserFrame)] = []
    }

    private func withProbePage(_ body: (ChromiumPage, BrowserPage, Probe) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.probeRoutes)
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/")
        try ChromiumRuntime.shared.ensureInitialized()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        let probe = Probe()
        let world = AutofillPage.world
        let form = AutofillFormScript.source + AutofillSuggestionScript.source
        // As the app installs them: the shared form script ahead of each feature's own, so four times.
        for _ in 0..<4 {
            page.installScript(form, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
        for script in Self.probeScripts {
            page.installScript(script, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
        page.addScriptMessageHandler(name: "wsurfProbe", in: world) { message in
            if let body = message.body as? [String: Any] {
                probe.posts.append((body, message.frameInfo))
            }
        }
        // The pull-to-refresh wheel watch: a world with no handler.
        PullToRefreshMonitor.install(in: page)
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { probe.posts.count >= 2 && !page.isLoading })
            try await body(native, page, probe)
        } catch {
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        window.contentView = nil
        window.close()
        await page.close()
        await context.endPrivateSession()
    }

    /// The page's own session registers each script by itself and a cross-site frame's session registers a world's scripts as
    /// one: both must run all of them, in order, from document start, a failing one stopping none, with the shim in place.
    @Test func aCrossSiteFramesScriptsRunAsThePagesDo() async throws {
        try await withProbePage { native, _, probe in
            let main = try #require(probe.posts.first { $0.frame.isMainFrame })
            let frame = try #require(probe.posts.first { !$0.frame.isMainFrame })
            #expect(frame.frame.securityOrigin.host == "localhost" && main.frame.securityOrigin.host == "127.0.0.1")
            for (name, post) in [("the page", main), ("the cross-site frame", frame)] {
                #expect(post.body["order"] as? [String] == ["before:true", "after"], "\(name): in order, before its body, one failing")
                #expect(post.body["forms"] as? String == "object", "\(name): the form script ran before the scripts that use it")
                #expect(post.body["send"] as? String == "function", "\(name): the relay was there")
            }
            let devTools = native.devTools
            #expect(devTools.sessions.count == 1, "the frame has a session of its own")
            #expect(devTools.scripts.count == 5, "the form script once, the three probes and the wheel watch")
            let session = try #require(devTools.sessions.values.first)
            #expect(session.scripts.count == 4 && session.scripts.allSatisfy { $0.identifier != nil })
            #expect(Set(session.scripts.compactMap(\.identifier)).count == 1, "its world's scripts are one registration")
            #expect(await waitUntil { devTools.loadStatistics.framePauses == 1 }, "the frame was held once, and let go")
        }
    }

    /// The pull-to-refresh world has a script and no handler: no relay for it, no context made for it by a document, and it works.
    @Test func aWorldNothingListensInIsNotBoundButStillWorks() async throws {
        try await withProbePage { native, page, _ in
            let devTools = native.devTools
            let pull = PullToRefreshMonitor.world
            #expect(devTools.bindingWorlds.contains(AutofillPage.world.name ?? ""))
            #expect(!devTools.bindingWorlds.contains(pull.name ?? ""))
            #expect(!devTools.contextsByUniqueID.values.contains { $0.worldName == pull.name })
            let state = try await page.callAsyncJavaScript(
                "return [typeof window.__wsurfWheel, typeof globalThis.__wsurfSend];", in: nil, contentWorld: pull
            ) as? [String]
            #expect(state == ["object", "undefined"], "the wheel watch ran, and it has no relay")
        }
    }
}
