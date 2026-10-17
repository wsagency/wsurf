// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

// The page half of handing a passkey request to the system's authenticator, against the real page script and relay in a real
// WKWebView. Native is the stand-in of `WebAuthnAdapterTests`: it answers the way the adapter does when the user chose "Use
// Another Device or Key…" or the vault holds nothing for the request. The engine is a stub the page's prelude installs before the
// page script captures it, so what reaches it is observable. The native decision itself is covered where the adapter runs.
extension WebAuthnAdapterTests {
    /// Records every call the page script makes to the engine and answers it with `engineBehavior`, which a test may replace.
    private var engine: String {
        """
        window.engineCalls = [];
        window.engineBehavior = name => Promise.resolve('engine-' + name);
        const proto = Object.getPrototypeOf(navigator.credentials);
        for (const name of ['create', 'get']) {
          proto[name] = function (options) { engineCalls.push({ name, options }); return engineBehavior(name, options); };
        }
        """
    }

    private var publicKeyGet: String {
        "navigator.credentials.get({ publicKey: window.pk })"
    }

    /// A causal barrier: native answers a capabilities question after everything the page posted before it, so once this has
    /// settled, a message the page was going to send has been handled.
    private func barrier(_ view: BrowserPage) async throws {
        _ = try await settled(view, "PublicKeyCredential.isConditionalMediationAvailable()")
    }

    private func startGet(_ view: BrowserPage, _ call: String? = nil, publicKey: String = "{ challenge: new Uint8Array(4) }") async throws {
        _ = try await view.evaluateJavaScript("""
        window.pk = \(publicKey); window.outcome = [];
        \(call ?? publicKeyGet).then(v => outcome.push(String(v)), e => outcome.push(e.name + ':' + e.message)); true
        """)
    }

    private func outcome(_ view: BrowserPage) async throws -> String {
        try await view.evaluateJavaScript("outcome.join('|')") as? String ?? ""
    }

    private func engineCalls(_ view: BrowserPage) async throws -> [[String: Any]] {
        let json = try await view.evaluateJavaScript("""
        JSON.stringify(engineCalls.map(call => ({ name: call.name, samePublicKey: call.options.publicKey === window.pk,
          mediation: String(call.options.mediation), hasSignal: call.options.signal instanceof AbortSignal,
          keys: Object.keys(call.options).sort() })))
        """) as? String ?? "[]"
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private func handOff(_ mode: String, _ view: BrowserPage, _ native: Native) async throws -> Bool {
        let request = try #require(await pending(native))
        return try await deliver(
            ["handoff": mode], id: try #require(request["id"] as? String), document: try #require(request["document"] as? String), in: view
        )
    }

    @Test(.boundedWebViews, arguments: ["get", "create"])
    func aHandOffRunsTheCallersOwnCallOnTheEngineOnce(operation: String) async throws {
        let (view, native) = try await load(engine)
        let call = operation == "get" ? publicKeyGet : "navigator.credentials.create({ publicKey: window.pk })"
        try await startGet(view, call, publicKey: operation == "get" ? "{ challenge: new Uint8Array(4) }" : "(\(createOptions)).publicKey")
        let request = try #require(await pending(native))
        #expect(try await engineCalls(view).isEmpty, "while the vault answers, the engine is not asked")

        #expect(try await handOff("modal", view, native))
        #expect(await waitUntil { (try? await outcome(view)) == "engine-\(operation)" }, "the engine's answer is the page's answer")
        let calls = try await engineCalls(view)
        #expect(calls.count == 1 && calls[0]["name"] as? String == operation)
        #expect(calls[0]["samePublicKey"] as? Bool == true, "the caller's own options, not a copy of them")
        #expect(calls[0]["mediation"] as? String == "undefined")
        // Once: a second hand-off for the same request is refused by the relay, and nothing more reaches the engine.
        #expect(try await !deliver(["handoff": "modal"], id: try #require(request["id"] as? String), document: try #require(request["document"] as? String), in: view))
        #expect(try await engineCalls(view).count == 1)
        #expect(native.requests.count == 1)
    }

    @Test(.boundedWebViews, arguments: [("modal", "optional"), ("conditional", "conditional")])
    func aConditionalRequestIsHandedOverModalOnlyWhenTheUserChoseIt(mode: String, mediation: String) async throws {
        let (view, native) = try await load(engine)
        try await startGet(view, "navigator.credentials.get({ mediation: 'conditional', publicKey: window.pk })")
        _ = try #require(await pending(native))

        #expect(try await handOff(mode, view, native))
        #expect(await waitUntil { (try? await outcome(view)) == "engine-get" })
        #expect(try await engineCalls(view).first?["mediation"] as? String == mediation)
    }

    @Test(.boundedWebViews) func aHandedOffRequestStillBlocksAnotherForegroundRequestUntilTheEngineSettles() async throws {
        let (view, native) = try await load(engine)
        _ = try await view.evaluateJavaScript("""
        engineBehavior = () => new Promise(resolve => { window.finishEngine = () => resolve('engine-done'); }); true
        """)
        try await startGet(view)
        #expect(try await handOff("modal", view, native))
        #expect(await waitUntil { (try? await view.evaluateJavaScript("engineCalls.length") as? Int) == 1 })

        // The system's sheet is up, so a second request of ours would be a second sheet on top of it.
        let second = try await settled(view, "navigator.credentials.get({ publicKey: window.pk }).then(() => 'resolved', e => e.name)") as? String
        #expect(second == "NotAllowedError")
        #expect(native.requests.count == 1, "the refused request never reached native")
        #expect(try await outcome(view).isEmpty)

        _ = try await view.evaluateJavaScript("finishEngine(); true")
        #expect(await waitUntil { (try? await outcome(view)) == "engine-done" })
        // Settled: the next request is the vault's again.
        _ = try await view.evaluateJavaScript("navigator.credentials.get({ publicKey: window.pk }).catch(() => {}); true")
        #expect(await waitUntil { native.requests.count == 2 })
    }

    @Test(.boundedWebViews) func theEnginesRefusalReachesThePageAsItIs() async throws {
        let (view, native) = try await load(engine)
        _ = try await view.evaluateJavaScript("engineBehavior = () => Promise.reject(new DOMException('the engine says no', 'NotAllowedError')); true")
        try await startGet(view)
        #expect(try await handOff("modal", view, native))
        #expect(await waitUntil { (try? await outcome(view)) == "NotAllowedError:the engine says no" })
    }

    @Test(.boundedWebViews) func theCallersAbortSignalBelongsToTheEngineAfterAHandOff() async throws {
        let (view, native) = try await load(engine)
        _ = try await view.evaluateJavaScript("engineBehavior = () => new Promise(() => {}); window.controller = new AbortController(); true")
        try await startGet(view, "navigator.credentials.get({ publicKey: window.pk, signal: controller.signal })")
        #expect(try await handOff("modal", view, native))
        #expect(await waitUntil { (try? await view.evaluateJavaScript("engineCalls.length") as? Int) == 1 })
        let call = try #require(try await engineCalls(view).first)
        #expect(call["hasSignal"] as? Bool == true && (call["keys"] as? [String]) == ["publicKey", "signal"])

        // Aborting now is the engine's to act on: our wrapper no longer settles the page's promise or tells native.
        _ = try await view.evaluateJavaScript("controller.abort(); true")
        try await barrier(view)
        #expect(native.cancels.isEmpty)
        #expect(try await outcome(view).isEmpty)
    }

    @Test(.boundedWebViews) func aHandOffNobodyAskedForDoesNothing() async throws {
        let (view, native) = try await load(engine)
        try await startGet(view)
        let request = try #require(await pending(native))
        let id = try #require(request["id"] as? String), document = try #require(request["document"] as? String)

        // Unknown words are no hand-off: the engine is not asked.
        _ = try await deliver(["handoff": "everything"], id: id, document: document, in: view)
        try await barrier(view)
        #expect(try await engineCalls(view).isEmpty)

        // A request that was never made, or is already settled, is not handed over either.
        #expect(try await !deliver(["handoff": "modal"], id: "never-asked", document: document, in: view))
        #expect(try await engineCalls(view).isEmpty)
    }
}
