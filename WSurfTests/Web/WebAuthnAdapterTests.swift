// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

// The page-facing contract of the real relay/adapter scripts in a real WKWebView, with a native side that answers with
// genuine ES256 ceremony output. Engine-specific context/dispatch evidence belongs to WebAuthnContextTests; Chromium page
// delivery is not exercised here.

@MainActor
struct WebAuthnAdapterTests {
    final class Native {
        var messages: [[String: Any]] = []
        /// Ceremony requests. The provider question the page script asks first is in `queries`.
        var requests: [[String: Any]] {
            messages.filter { $0["action"] as? String == "request" && $0["operation"] as? String != "capabilities" }
        }
        var queries: [[String: Any]] {
            messages.filter { $0["action"] as? String == "request" && $0["operation"] as? String == "capabilities" }
        }
        var cancels: [[String: Any]] {
            messages.filter { $0["action"] as? String == "cancel" }
        }
        /// Whether the stand-in refuses a manager request from a document with no identity, as the real adapter does.
        var refusesUnidentified = true
        /// The provider native selects at the moment a restored document asks (defaults to the one it was loaded with).
        var mode: String?
        /// Withholds native's answer to the restore's route question until the test gives it.
        var holdRoute = false
        /// The window of a view that must be visible; kept alive with the stand-in.
        var window: NSWindow?
    }

    static let world = WKContentWorld.world(name: "WSurfWebAuthnTestRelay")
    let origin = "https://login.example"
    let rpID = "login.example"

    enum Handshake {
        /// Chromium: its relay keeps a random per-document fence and native attributes the document itself over CDP.
        case chromium
        /// WebKit with the registry's handshake already finished (isolated-world globals, as the real registry defines them).
        case native(String)
        /// WebKit whose registry stand-in also models epochs and back/forward-cache restore proofs (see `load`).
        case registry(String)
        /// WebKit whose handshake finishes only when the test completes it.
        case deferred(String)
        /// WebKit with no handshake at all, or one that failed.
        case absent, failed
    }

    /// `enabled: false` models a profile on the legacy provider: native decides `legacy` and the engine runs untouched.
    /// `answer` models the other native decisions: no answer at all, or a manager that refuses this page (stale/foreign
    /// profile). A manager document without an identity (empty document) is always refused, as the real adapter does.
    enum Answer { case normal, silent, staleManager }

    func load(
        _ prelude: String = "", enabled: Bool = true, answer: Answer = .normal, handshake: Handshake = .chromium, visible: Bool = false
    ) async throws -> (BrowserPage, Native) {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The page contract is exercised against this stand-in native, so no manager, vault or profile data is involved: a
        // private context is enough to own the page. The real adapter and the per-context provider are covered against
        // fresh regular profiles in `Per-context provider` below.
        let view = BrowserPage(
            webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        let native = Native()
        let deliverer = self
        view.addScriptMessageHandler(name: WebAuthnScript.handlerName, in: Self.world) { [weak view] message in
            guard let body = message.body as? [String: Any] else { return }
            native.messages.append(body)
            if body["action"] as? String == "route", let view {
                guard !native.holdRoute else { return }
                // The adapter's answer for a document restored from the back/forward cache: the provider selected NOW.
                let mode = native.mode ?? (enabled ? "manager" : "legacy")
                Task { _ = try? await view.callAsyncJavaScript("globalThis.__wsurfWebAuthnFence?.route(mode, 2);", arguments: ["mode": mode], in: nil, contentWorld: Self.world) }
                return
            }
            guard let view, body["action"] as? String == "request",
                  let id = body["id"] as? String, let document = body["document"] as? String else { return }
            if body["operation"] as? String == "capabilities" {
                let usable = enabled && answer == .normal && !document.isEmpty
                let value: [String: Any] = ["provider": enabled ? "manager" : "legacy", "enabled": usable, "canVerifyUser": usable]
                guard answer != .silent else { return }
                Task { _ = try? await deliverer.deliver(["result": value], id: id, document: document, in: view) }
            } else if enabled, answer == .staleManager || native.mode == "legacy" || (document.isEmpty && native.refusesUnidentified) {
                // The real adapter: the manager refuses a document with no identity and a page it does not serve. Never a ceremony.
                Task { _ = try? await deliverer.deliver(["error": ["name": "NotAllowedError", "message": ""]], id: id, document: document, in: view) }
            }
        }
        let define = "(n) => Object.defineProperty(globalThis, '__wsurfNativeFrameNonce', {value: n, writable: false, configurable: false})"
        let relayNative: Bool
        switch handshake {
        case .chromium:
            relayNative = false
        case .native(let nonce):
            relayNative = true
            view.installScript(
                """
                (\(define))('\(nonce)'); Object.defineProperty(globalThis, '__wsurfNativeFrameEpoch', {value: 0});
                Object.defineProperty(globalThis, '__wsurfNativeFrameReady', {value: Promise.resolve(true)});
                """,
                in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: true
            )
        case .registry(let nonce):
            // A per-document stand-in for the native registry's contract: immutable nonce, an epoch that grows on every
            // pagehide, and a ready promise that is replaced by a pending one on each persisted restore (before the
            // relay's own listeners run) and settles only when the test says native accepted or refused it.
            relayNative = true
            view.installScript(
                """
                (() => {
                  const state = { epoch: 0, ready: Promise.resolve(true), settle: null };
                  (\(define))('\(nonce)');
                  Object.defineProperty(globalThis, '__wsurfNativeFrameEpoch', {get: () => state.epoch});
                  Object.defineProperty(globalThis, '__wsurfNativeFrameReady', {get: () => state.ready});
                  Object.defineProperty(globalThis, '__settleTestRestore', {value: accepted => state.settle(accepted)});
                  Object.defineProperty(globalThis, '__bumpTestEpoch', {value: () => { state.epoch += 1; }});
                  addEventListener('pagehide', () => { state.epoch += 1; state.ready = Promise.resolve(false); });
                  addEventListener('pageshow', event => {
                    if (event.persisted && event.isTrusted) state.ready = new Promise(resolve => { state.settle = resolve; });
                  });
                })();
                """,
                in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: true
            )
        case .deferred(let nonce):
            relayNative = true
            view.installScript(
                """
                (() => { let done; const ready = new Promise(resolve => { done = resolve; });
                  Object.defineProperty(globalThis, '__wsurfNativeFrameReady', {value: ready});
                  Object.defineProperty(globalThis, '__wsurfNativeFrameEpoch', {value: 0});
                  Object.defineProperty(globalThis, '__completeTestHandshake', {value: () => { (\(define))('\(nonce)'); done(true); }}); })();
                """,
                in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: true
            )
        case .failed:
            relayNative = true
            view.installScript(
                """
                Object.defineProperty(globalThis, '__wsurfNativeFrameEpoch', {value: 0});
                Object.defineProperty(globalThis, '__wsurfNativeFrameReady', {value: Promise.reject(new Error('handshake failed'))});
                """,
                in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: true
            )
        case .absent:
            relayNative = true
        }
        view.installScript(WebAuthnScript.relay(nativeNonce: relayNative), in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        // Native's own announcement, installed right after the relay as the adapter does. A native that never announces
        // leaves the page script refusing, never handing anything to the engine.
        if answer != .silent {
            view.installScript(
                WebAuthnScript.route(enabled ? "manager" : "legacy", sequence: 1),
                in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false
            )
        }
        if !prelude.isEmpty {
            view.installScript(prelude, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
        view.installScript(WebAuthnScript.page, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        if visible {
            // The fence never delivers a ceremony result to a hidden document, and a view outside any window is hidden.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderBack(nil)
            native.window = window
        }
        view.loadHTMLString("<!doctype html><input id=field autocomplete='username webauthn'>", baseURL: URL(string: origin + "/"))
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        return (view, native)
    }

    private func deliver(_ value: [String: Any], id: String, document: String, in view: BrowserPage) async throws -> Bool {
        let json = try String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8) ?? "{}"
        let result = try await view.callAsyncJavaScript(
            "return globalThis.__wsurfWebAuthnFence.deliver(documentID, id, JSON.parse(value));",
            arguments: ["documentID": document, "id": id, "value": json], in: nil, contentWorld: Self.world
        )
        return result as? Bool ?? false
    }

    let createOptions = """
    { publicKey: { challenge: new Uint8Array([1,2,3,4,5,6,7,8]), rp: { name: 'Example' },
      user: { id: new Uint8Array([9,8,7,6]), name: 'ada@example.com', displayName: 'Ada' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }], extensions: { credProps: true } } }
    """

    private func registration(_ parsed: WebAuthnWire.Parsed) throws -> (json: [String: Any], result: WebAuthnResult) {
        let client = WebAuthnClientData(origin: origin, topOrigin: nil, crossOrigin: false, rpID: rpID)
        let account = CredentialAccount(
            id: UUID(), username: "ada@example.com", displayName: nil, origins: [origin], loginURLs: [], password: nil,
            passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        let made = try WebsiteAuthenticator.makeRegistration(
            parsed.request, client: client, account: account,
            consent: WebAuthnConsent(requestID: parsed.request.requestID, userPresent: true, userVerified: true)
        )
        return (try WebAuthnWire.resultJSON(made.result, operation: .create), made.result)
    }

    func pending(_ native: Native) async -> [String: Any]? {
        _ = await waitUntil { !native.requests.isEmpty }
        return native.requests.first
    }

    // MARK: Browser-facing contract

    @Test(.boundedWebViews) func publicKeyResultsMatchWebContract() async throws {
        let (view, native) = try await load(visible: true)
        do { try await assertPublicKeyResults(view, native) } catch { await release(view, native); throw error }
        await release(view, native)
    }

    private func assertPublicKeyResults(_ view: BrowserPage, _ native: Native) async throws {
        _ = try await view.evaluateJavaScript(
            "window.settled = 0; navigator.credentials.create(\(createOptions))" +
            ".then(r => { window.registration = r; window.settled++; }, e => { window.failure = e.name; window.settled++; }); true"
        )
        let request = try #require(await pending(native))
        let parsed = try WebAuthnWire.parse(request)
        #expect(parsed.operation == .create)
        let (json, _) = try registration(parsed)
        #expect(try await deliver(["result": json], id: parsed.id, document: try #require(request["document"] as? String), in: view))
        #expect(await waitUntil { (try? await view.evaluateJavaScript("window.settled") as? Int) == 1 })

        let checks = try await view.evaluateJavaScript("""
        (() => { const r = window.registration, s = r.response;
          return JSON.stringify({
            type: r.type === 'public-key', instance: r instanceof PublicKeyCredential,
            rawId: r.rawId instanceof ArrayBuffer && r.rawId.byteLength > 0,
            idMatches: r.id.length > 0 && !/[+/=]/.test(r.id),
            attestationResponse: s instanceof AuthenticatorAttestationResponse,
            clientData: s.clientDataJSON instanceof ArrayBuffer, attestation: s.attestationObject instanceof ArrayBuffer,
            algorithm: s.getPublicKeyAlgorithm() === -7, publicKey: s.getPublicKey() instanceof ArrayBuffer,
            authenticatorData: s.getAuthenticatorData() instanceof ArrayBuffer, transports: s.getTransports().join(),
            credProps: r.getClientExtensionResults().credProps?.rk === true,
            json: JSON.parse(JSON.stringify(r)).id === r.id, attachment: r.authenticatorAttachment,
            copies: s.getPublicKey() !== s.getPublicKey()
          }); })()
        """) as? String
        let checksJSON = try #require(checks)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(checksJSON.utf8)) as? [String: Any])
        for (name, value) in decoded where name != "transports" && name != "attachment" {
            #expect(value as? Bool == true, "\(name)")
        }
        #expect(decoded["transports"] as? String == "internal")
        #expect(decoded["attachment"] as? String == "platform")
    }

    /// Releases a `visible: true` view on every exit: the page is closed before the window it lives in, and the stand-in's
    /// hold on the window is dropped (view → message handler → stand-in → window → view is otherwise a cycle).
    private func release(_ view: BrowserPage, _ native: Native) async {
        await view.close()
        native.window?.close()
        native.window = nil
    }

    @Test(.boundedWebViews) func aWebKitRelayIdentifiesItsDocumentByTheNativeNonceAndNeverByAnythingThePageSupplies() async throws {
        let (view, native) = try await load(handshake: .native("native-doc-nonce-1"))
        _ = try await view.evaluateJavaScript("navigator.credentials.create(\(createOptions)).catch(() => {}); true")
        let request = try #require(await pending(native))
        #expect(request["document"] as? String == "native-doc-nonce-1")
        // A result for any other document identity is refused by the fence; the right one is accepted.
        #expect(try await !deliver(["error": ["name": "NotAllowedError", "message": ""]], id: try #require(request["id"] as? String), document: "old-doc", in: view))
        #expect(try await deliver(["error": ["name": "NotAllowedError", "message": ""]], id: try #require(request["id"] as? String), document: "native-doc-nonce-1", in: view))
    }

    private func isPending(_ view: BrowserPage, document: String, id: String) async throws -> Bool {
        try await view.callAsyncJavaScript(
            "return globalThis.__wsurfWebAuthnFence?.isPending(documentID, id) === true;",
            arguments: ["documentID": document, "id": id], in: nil, contentWorld: Self.world
        ) as? Bool ?? false
    }

    /// The settled value of a Promise-returning expression. `evaluateJavaScript` cannot return a Promise (WKError 5, an
    /// unsupported result type), so the page awaits it and returns the plain value.
    func settled(_ view: BrowserPage, _ expression: String) async throws -> Any {
        try await view.callAsyncJavaScript("return await (\(expression));", in: nil, contentWorld: .page)
    }

    @Test(.boundedWebViews) func theRelayAnswersPendingOnlyForItsOwnDocumentAndRequestAndNotAfterASameOriginReplacement() async throws {
        let (view, native) = try await load(handshake: .native("native-doc-nonce-2"))
        _ = try await view.evaluateJavaScript("navigator.credentials.create(\(createOptions)).catch(() => {}); true")
        let request = try #require(await pending(native))
        let id = try #require(request["id"] as? String)
        #expect(try await isPending(view, document: "native-doc-nonce-2", id: id))
        #expect(try await !isPending(view, document: "another-document", id: id))
        #expect(try await !isPending(view, document: "native-doc-nonce-2", id: "another-request"))

        // The same origin, replaced by a whole new document (even one that happens to be given the same identity): the old
        // request is not held by it, so a delayed message from the old document can never be served by the new one.
        view.loadHTMLString("<!doctype html><title>next</title>", baseURL: URL(string: origin + "/"))
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        #expect(try await !isPending(view, document: "native-doc-nonce-2", id: id))
    }

    /// What the manager's page script never sends for an unidentified document: a ceremony. The relay's own fence must hold
    /// even so, because the page can emit the relay's request event itself.
    private let rawCeremony = """
    document.dispatchEvent(new CustomEvent('wsurf-webauthn-request', { detail: JSON.stringify(
      { action: 'request', id: 'raw-1', operation: 'create', mediation: 'optional', options: {} }) })); true
    """

    @Test(.boundedWebViews) func aWebKitDocumentWithoutAHandshakeIsSentUnidentifiedAndNeverGivenAnInvention() async throws {
        let (view, native) = try await load(handshake: .absent)
        let outcome = try await settled(view, "navigator.credentials.create(\(createOptions)).then(() => 'resolved', e => e.name)") as? String
        #expect(outcome == "NotAllowedError", "the manager refuses a document with no identity; it is never taken for legacy")
        #expect(native.requests.count == 1 && native.requests.allSatisfy { $0["document"] as? String == "" },
                "no identity at all, never a random or page-supplied one")

        native.refusesUnidentified = false
        _ = try await view.evaluateJavaScript(rawCeremony)
        #expect(await waitUntil { native.requests.count == 2 })
        let request = try #require(native.requests.last)
        #expect(request["document"] as? String == "")
        let id = try #require(request["id"] as? String)
        #expect(try await !isPending(view, document: "", id: id), "an unidentified document is never confirmed as live")
        // Only an error may reach it; a signed result is not accepted by an unidentified document.
        #expect(try await !deliver(["result": ["id": "x"]], id: id, document: "", in: view))
        #expect(try await deliver(["error": ["name": "NotAllowedError", "message": ""]], id: id, document: "", in: view))
    }

    @Test(.boundedWebViews) func aFailedHandshakeIsTheSameAsNone() async throws {
        let (view, native) = try await load(handshake: .failed)
        _ = try await view.evaluateJavaScript("navigator.credentials.create(\(createOptions)).catch(() => {}); true")
        #expect(await waitUntil { !native.requests.isEmpty })
        #expect(native.requests.allSatisfy { $0["document"] as? String == "" })
    }

    @Test(.boundedWebViews) func aRequestMadeBeforeTheHandshakeWaitsForItWithoutPollingAndThenCarriesTheNativeNonce() async throws {
        let (view, native) = try await load(handshake: .deferred("native-doc-nonce-3"))
        _ = try await view.evaluateJavaScript("navigator.credentials.create(\(createOptions)).catch(() => {}); true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(native.requests.isEmpty, "nothing is sent until the handshake has decided the document's identity")
        _ = try await view.callAsyncJavaScript("globalThis.__completeTestHandshake(); return true;", arguments: [:], in: nil, contentWorld: Self.world)
        let request = try #require(await pending(native))
        #expect(request["document"] as? String == "native-doc-nonce-3")
        #expect(try await isPending(view, document: "native-doc-nonce-3", id: try #require(request["id"] as? String)))
    }

    @Test(.boundedWebViews) func aPageWorldImpostorOfTheHandshakeNeverIdentifiesTheDocument() async throws {
        let (view, native) = try await load(
            "globalThis.__wsurfNativeFrameReady = Promise.resolve(); globalThis.__wsurfNativeFrameNonce = 'forged-by-page';",
            handshake: .absent
        )
        _ = try await view.evaluateJavaScript("navigator.credentials.create(\(createOptions)).catch(() => {}); true")
        #expect(await waitUntil { !native.requests.isEmpty })
        #expect(native.requests.allSatisfy { $0["document"] as? String == "" })
    }

    @Test(.boundedWebViews) func sliceOfALargerBufferIsMarshalledWithoutItsNeighbours() async throws {
        let (view, native) = try await load()
        _ = try await view.evaluateJavaScript("""
        (() => { const backing = new Uint8Array([9,9,1,2,3,9,9]); navigator.credentials.get({ publicKey:
          { challenge: backing.subarray(2,5), allowCredentials: [{ type: 'public-key', id: backing.subarray(2,5) }] } }).catch(() => {}); return true; })()
        """)
        let request = try #require(await pending(native))
        let options = try #require(request["options"] as? [String: Any])
        #expect(try WebAuthnWire.base64URLDecode(options["challenge"], maximum: 1_024) == Data([1, 2, 3]))
        let allow = try #require(options["allowCredentials"] as? [[String: Any]])
        #expect(try WebAuthnWire.base64URLDecode(allow[0]["id"], maximum: 1_024) == Data([1, 2, 3]))
    }

    /// The provider is announced before the page runs, so the decision is made in the caller's own turn: the mutation made
    /// right after the call cannot reach the request native receives.
    @Test(.boundedWebViews) func aManagerRequestIsSnapshottedBeforeTheCallerCanMutateItsBuffers() async throws {
        let (view, native) = try await load()
        _ = try await view.evaluateJavaScript("""
        (() => { const challenge = new Uint8Array([1, 2, 3, 4]); const id = new Uint8Array([5, 6]);
          navigator.credentials.get({ publicKey: { challenge, allowCredentials: [{ type: 'public-key', id }] } }).catch(() => {});
          challenge.fill(9); id.fill(9); return true; })()
        """)
        let request = try #require(await pending(native))
        let options = try #require(request["options"] as? [String: Any])
        #expect(try WebAuthnWire.base64URLDecode(options["challenge"], maximum: 1_024) == Data([1, 2, 3, 4]))
        let allow = try #require(options["allowCredentials"] as? [[String: Any]])
        #expect(try WebAuthnWire.base64URLDecode(allow[0]["id"], maximum: 1_024) == Data([5, 6]))
    }

    /// Legacy hands the engine the caller's own arguments in the same turn: nothing awaited, nothing copied, nothing asked.
    @Test(.boundedWebViews) func aLegacyCallReachesTheEngineSynchronouslyWithTheUntouchedOptions() async throws {
        let (view, native) = try await load(engineCalls, enabled: false)
        let outcome = try await view.evaluateJavaScript("""
        (() => { const options = { publicKey: { challenge: new Uint8Array(4) }, mediation: 'silent' };
          navigator.credentials.get(options); return originalCalls.join() + ':' + (originalOptions[0] === options); })()
        """) as? String
        #expect(outcome == "get:true", "the engine had the call, with the very same options object, before the script returned")
        #expect(native.messages.isEmpty, "the legacy provider is never consulted per call")
    }

    /// A provider change reaches a document that is already live as a newer announcement; an older one never overrides it.
    @Test(.boundedWebViews) func aNewerAnnouncementReroutesALiveDocumentAndAnOlderOneNeverDoes() async throws {
        let (view, native) = try await load(engineCalls, enabled: false)
        func announce(_ value: String, _ sequence: Int) async throws -> Bool {
            try await view.callAsyncJavaScript(
                "return globalThis.__wsurfWebAuthnFence.route(value, sequence);", arguments: ["value": value, "sequence": sequence],
                in: nil, contentWorld: Self.world
            ) as? Bool ?? false
        }
        let get = "navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } }).catch(() => {}); originalCalls.join()"
        #expect(try await announce("manager", 2))
        #expect(try await !announce("legacy", 1), "a stale announcement is ignored")
        #expect(try await view.evaluateJavaScript(get) as? String == "", "manager: the engine is not called")
        _ = await pending(native)
        #expect(native.requests.count == 1)
        #expect(try await announce("legacy", 3))
        #expect(try await view.evaluateJavaScript("navigator.credentials.create(\(createOptions)).catch(() => {}); originalCalls.join()") as? String == "create")
        #expect(try await !announce("other", 4), "only a provider native names is accepted")
    }

    @Test(.boundedWebViews) func nonPublicKeyStillUsesOriginalEngineAndPublicKeyNeverDoes() async throws {
        let (view, native) = try await load("""
        window.originalCalls = []; const proto = Object.getPrototypeOf(navigator.credentials);
        for (const name of ['create', 'get']) proto[name] = function (options) { originalCalls.push(name); return Promise.resolve('original'); };
        """)
        #expect(try await settled(view, "navigator.credentials.get({ password: true })") as? String == "original")
        #expect(try await settled(view, "navigator.credentials.create({ password: { id: 'a' } })") as? String == "original")
        _ = try await view.evaluateJavaScript("navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } }).catch(() => {}); true")
        _ = await pending(native)
        #expect(try await view.evaluateJavaScript("originalCalls.join()") as? String == "get,create")
        #expect(native.requests.count == 1)
    }

    @Test(.boundedWebViews) func abortAndTimeoutSettleExactlyOnceAndLateResultsAreDropped() async throws {
        let (view, native) = try await load()
        // Aborted before the call: rejected with the signal's reason, nothing reaches native.
        let early = try await settled(view, """
        (async () => { const c = new AbortController(); c.abort(); try { await navigator.credentials.get({ signal: c.signal, publicKey: { challenge: new Uint8Array(4) } }); return 'resolved'; }
          catch (e) { return e.name; } })()
        """) as? String
        #expect(early == "AbortError")
        #expect(native.requests.isEmpty)

        _ = try await view.evaluateJavaScript("""
        window.c = new AbortController(); window.outcomes = [];
        navigator.credentials.get({ signal: c.signal, publicKey: { challenge: new Uint8Array(4) } })
          .then(() => outcomes.push('resolved'), e => outcomes.push(e.name)); true
        """)
        let request = try #require(await pending(native))
        let id = try #require(request["id"] as? String), document = try #require(request["document"] as? String)
        _ = try await view.evaluateJavaScript("c.abort(); true")
        #expect(await waitUntil { !native.cancels.isEmpty })
        #expect(native.cancels.first?["id"] as? String == id)
        #expect(await waitUntil { (try? await view.evaluateJavaScript("outcomes.join()") as? String) == "AbortError" })
        // A native result for the aborted request is refused by the fence and never reaches the page.
        #expect(try await deliver(["error": ["name": "NotAllowedError", "message": "late"]], id: id, document: document, in: view) == false)
        #expect(try await view.evaluateJavaScript("outcomes.join()") as? String == "AbortError")
    }

    @Test(.boundedWebViews) func nativeFailuresBecomeNamedDOMExceptionsOnce() async throws {
        let (view, native) = try await load()
        _ = try await view.evaluateJavaScript("""
        window.outcomes = [];
        navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } }).then(() => outcomes.push('resolved'), e => outcomes.push(e instanceof DOMException ? e.name : 'other')); true
        """)
        let request = try #require(await pending(native))
        let id = try #require(request["id"] as? String), document = try #require(request["document"] as? String)
        let error = WebAuthnWire.pageError(WebsiteAuthenticatorError.credentialExcluded)
        #expect(try await deliver(["error": ["name": error.name, "message": error.message]], id: id, document: document, in: view))
        #expect(try await deliver(["error": ["name": "NotAllowedError", "message": "again"]], id: id, document: document, in: view) == false)
        #expect(await waitUntil { (try? await view.evaluateJavaScript("outcomes.join()") as? String) == "InvalidStateError" })
    }

    @Test(.boundedWebViews) func conditionalRequestOnlyRegistersAndForegroundRequestSupersedesIt() async throws {
        let (view, native) = try await load()
        _ = try await view.evaluateJavaScript("""
        window.outcomes = [];
        navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(4) } })
          .then(() => outcomes.push('resolved'), e => outcomes.push(e.name));
        document.getElementById('field').dispatchEvent(new MouseEvent('click', { bubbles: true }));
        document.getElementById('field').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); true
        """)
        let request = try #require(await pending(native))
        #expect(request["mediation"] as? String == "conditional")
        // Scripted events are not trusted: no activation, no native selection, no signing.
        try await Task.sleep(for: .milliseconds(200))
        #expect(native.requests.count == 1)
        #expect(try await view.evaluateJavaScript("outcomes.length") as? Int == 0)

        _ = try await view.evaluateJavaScript("""
        navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } }).catch(() => {}); true
        """)
        #expect(await waitUntil { native.requests.count == 2 })
        #expect(native.cancels.first?["id"] as? String == request["id"] as? String)
        #expect(try await view.evaluateJavaScript("outcomes.join()") as? String == "AbortError")
    }

    /// WebAuthn L3: a conditional get has an infinite lifetime timer. The page arms no timer and sends no timeout for it,
    /// while a modal request is still bounded (the default 5 minutes here) and says so to native.
    @Test(.boundedWebViews) func aConditionalGetArmsNoPageTimerAndAModalOneStillDoes() async throws {
        let (view, native) = try await load("""
        window.armed = []; const realSetTimeout = globalThis.setTimeout;
        globalThis.setTimeout = function (callback, delay, ...rest) { armed.push(delay); return realSetTimeout(callback, delay, ...rest); };
        """)
        _ = try await view.evaluateJavaScript("""
        navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(4), timeout: 20000 } }).catch(() => {}); true
        """)
        let conditional = try #require(await pending(native))
        let conditionalOptions = try #require(conditional["options"] as? [String: Any])
        #expect(conditionalOptions["timeout"] == nil, "a conditional request has no lifetime to announce")
        #expect(try await view.evaluateJavaScript("armed.filter(delay => delay >= 10000).length") as? Int == 0, "no page timer for a conditional request")

        _ = try await view.evaluateJavaScript("""
        navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } }).catch(() => {}); true
        """)
        #expect(await waitUntil { native.requests.count == 2 })
        let modalOptions = try #require(native.requests[1]["options"] as? [String: Any])
        #expect(modalOptions["timeout"] as? Double == 300_000)
        #expect(try await view.evaluateJavaScript("armed.filter(delay => delay === 300000).length") as? Int == 1)
    }

    /// A relay message as native receives it: page JSON bridged by the script-message machinery, where every number is an
    /// `NSNumber` (a Swift `Int` literal in an `[String: Any]` is a different dynamic type and never reaches the parser).
    func bridged(_ body: [String: Any]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body)) as? [String: Any])
    }

    @Test func aConditionalGetParsesWithNoDeadlineAndEveryOtherRequestHasOne() throws {
        let now = ContinuousClock.now
        let challenge = WebAuthnWire.base64URL(Data([1, 2, 3]))
        func request(_ operation: String, _ mediation: String, _ options: [String: Any]) throws -> WebAuthnRequest {
            try WebAuthnWire.parse(bridged(["id": "r1", "operation": operation, "mediation": mediation, "options": options]), now: now).request
        }
        #expect(try request("get", "conditional", ["challenge": challenge]).deadline == nil)
        #expect(try request("get", "conditional", ["challenge": challenge, "timeout": 5]).deadline == nil, "even an explicit timeout never bounds a conditional get")
        for mediation in ["optional", "required"] {
            #expect(try request("get", mediation, ["challenge": challenge]).deadline == now.advanced(by: .milliseconds(300_000)))
        }
        let creation: [String: Any] = [
            "challenge": challenge, "rp": ["name": "x"], "user": ["id": WebAuthnWire.base64URL(Data([1])), "name": "a", "displayName": "A"],
        ]
        #expect(try request("create", "optional", creation).deadline == now.advanced(by: .milliseconds(300_000)))
        // A malformed timeout is still malformed for a conditional get.
        #expect(throws: (any Error).self) { try request("get", "conditional", ["challenge": challenge, "timeout": -1]) }
    }

    @Test(.boundedWebViews) func malformedAndUnsupportedRequestsNeverReachNative() async throws {
        let (view, native) = try await load()
        let outcomes = try await settled(view, """
        (async () => {
          const run = async options => { try { await options(); return 'resolved'; } catch (e) { return e.name; } };
          return [
            await run(() => navigator.credentials.get({ publicKey: {} })),
            await run(() => navigator.credentials.create({ publicKey: { challenge: new Uint8Array(4), rp: { name: 'x' },
              user: { id: new Uint8Array(1), name: 'a', displayName: 'a' }, pubKeyCredParams: [{ type: 'other', alg: -7 }] } })),
            await run(() => navigator.credentials.create({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(4), rp: { name: 'x' },
              user: { id: new Uint8Array(1), name: 'a', displayName: 'a' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }] } })),
            await run(() => navigator.credentials.get({ mediation: 'silent', publicKey: { challenge: new Uint8Array(4) } })),
            await run(() => navigator.credentials.get({ password: true, publicKey: { challenge: new Uint8Array(4) } })),
            await run(() => navigator.credentials.create({ publicKey: { challenge: new Uint8Array(4), rp: { name: 'x' },
              user: { id: new Uint8Array(1), name: 'a', displayName: 'a' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
              extensions: { largeBlob: { support: 'required' } } } })),
          ].join();
        })()
        """) as? String
        #expect(outcomes == "TypeError,NotSupportedError,NotSupportedError,NotAllowedError,TypeError,NotSupportedError")
        #expect(native.requests.isEmpty)
    }

    /// Real script, real WebKit: a BufferSource from another realm (an iframe's) is accepted exactly as the engine's own
    /// implementation accepts it, while anything that is not a real, unshared buffer is a TypeError that never reaches native.
    @Test(.boundedWebViews) func bufferSourcesFromAnotherRealmAreAcceptedAndNonBuffersAreNot() async throws {
        let (view, native) = try await load()
        let outcomes = try await settled(view, """
        (async () => {
          const frame = document.createElement('iframe');
          document.body.append(frame);
          const other = frame.contentWindow;
          // A request that was accepted ("sent") stays pending (the stand-in never answers), and two foreground requests cannot
          // overlap, so each accepted one is aborted before the next case; rejected ones never become pending.
          const outcome = async (challenge, userID) => {
            const controller = new AbortController();
            const settled = navigator.credentials.create({ signal: controller.signal, publicKey: { challenge, rp: { name: 'x' },
              user: { id: userID, name: 'a', displayName: 'a' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }] } })
              .then(() => 'resolved', e => e.name);
            const result = await Promise.race([settled, new Promise(resolve => setTimeout(() => resolve('sent'), 1000))]);
            controller.abort();
            return result;
          };
          const results = [
            await outcome(new other.ArrayBuffer(8), new other.ArrayBuffer(4)),
            await outcome(new other.Uint8Array(8), new other.DataView(new other.ArrayBuffer(4))),
            await outcome(new ArrayBuffer(8), new Uint8Array(new other.ArrayBuffer(4))),
            await outcome({ byteLength: 8 }, new Uint8Array(4)),
            await outcome(new Uint8Array(8), 'not a buffer'),
            await outcome(Object.create(ArrayBuffer.prototype), new Uint8Array(4)),
          ];
          try {
            if (typeof other.SharedArrayBuffer === 'function') {
              const shared = new other.SharedArrayBuffer(8);
              results.push(await outcome(shared, new Uint8Array(4)));
              results.push(await outcome(new Uint8Array(shared), new Uint8Array(4)));
            }
          } catch {}
          return results.join();
        })()
        """) as? String
        let results = try #require(outcomes).split(separator: ",").map(String.init)
        #expect(Array(results.prefix(6)) == ["sent", "sent", "sent", "TypeError", "TypeError", "TypeError"])
        #expect(results.dropFirst(6).allSatisfy { $0 == "TypeError" }, "shared memory is not a BufferSource here")
        #expect(native.requests.count == 3)
    }

    /// Legacy hands the engine the caller's options before anything of them is read; a manager request reads each property
    /// once, and a throwing getter is a rejected Promise, never a synchronous throw.
    @Test(.boundedWebViews) func optionsAreNeverReadForLegacyAndReadOnceForTheManager() async throws {
        let probe = """
        window.reads = 0;
        window.countingOptions = () => ({ get publicKey() { window.reads++; return { challenge: new Uint8Array(4) }; } });
        window.throwingOptions = () => ({ get publicKey() { throw new RangeError('getter'); } });
        """
        let (legacy, legacyNative) = try await load(engineCalls + probe, enabled: false)
        _ = try await legacy.evaluateJavaScript("navigator.credentials.get(countingOptions()); true")
        #expect(try await legacy.evaluateJavaScript("reads") as? Int == 0, "legacy: the page's getter is not touched by us")
        #expect(try await legacy.evaluateJavaScript("originalCalls.join()") as? String == "get")
        #expect(legacyNative.messages.isEmpty)

        let (manager, managerNative) = try await load(engineCalls + probe)
        _ = try await manager.evaluateJavaScript("navigator.credentials.get(countingOptions()).catch(() => {}); true")
        #expect(await waitUntil { !managerNative.requests.isEmpty })
        #expect(try await manager.evaluateJavaScript("reads") as? Int == 1, "the manager path reads publicKey exactly once")
        let outcome = try await settled(manager, """
        (() => { try { return navigator.credentials.get(throwingOptions()).then(() => 'resolved', e => e.name); } catch (e) { return 'sync:' + e.name; } })()
        """) as? String
        #expect(outcome == "RangeError")
    }

    /// Records every call the engine's own implementation receives, with the exact options object it was handed.
    let engineCalls = """
    window.originalCalls = []; window.originalOptions = [];
    for (const name of ['create', 'get']) Object.getPrototypeOf(navigator.credentials)[name] = function (options) {
      originalCalls.push(name); originalOptions.push(options); return Promise.resolve('engine-' + name); };
    PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve('engine-uv');
    PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve('engine-conditional');
    PublicKeyCredential.getClientCapabilities = () => Promise.resolve({ engine: true });
    for (const name of ['signalUnknownCredential', 'signalAllAcceptedCredentials', 'signalCurrentUserDetails']) {
      PublicKeyCredential[name] = function () { originalCalls.push(name); return Promise.resolve('engine-' + name); };
    }
    """

    /// The engine's own methods, captured before our page script wraps them. Every case is an ALREADY-ABORTED request, so
    /// the real engine settles it without any provider UI, credential or side effect, and never reaches native here.
    private static let originalEngineBeforeOurScript = """
    window.__engine = { create: navigator.credentials.create.bind(navigator.credentials), get: navigator.credentials.get.bind(navigator.credentials) };
    """

    /// Runs each case twice in the page: against the captured real engine method (control) and against the routed
    /// `navigator.credentials` method. Outcomes are standardized (the abort reason's identity, else the error name).
    private static let abortedCases = """
    (async () => {
      const sentinel = new Error('aborted-before-the-call');
      const aborted = realm => { const controller = new realm.AbortController(); controller.abort(sentinel); return controller.signal; };
      const frame = document.createElement('iframe');
      document.body.append(frame);
      const other = frame.contentWindow;
      const publicKey = () => ({ challenge: new Uint8Array(4), rp: { name: 'x' },
        user: { id: new Uint8Array(1), name: 'a', displayName: 'a' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }] });
      const cases = [
        ['create', () => ({ mediation: 'conditional', signal: aborted(window), publicKey: publicKey() })],
        ['get', () => ({ mediation: 'silent', signal: aborted(window), publicKey: { challenge: new Uint8Array(4) } })],
        ['create', () => ({ signal: aborted(other), publicKey: publicKey() })],
        ['get', () => ({ signal: aborted(window), password: true, publicKey: { challenge: new Uint8Array(4) } })],
        ['create', () => ({ signal: aborted(window), publicKey: { ...publicKey(), extensions: { largeBlob: { support: 'required' } } } })],
      ];
      const outcome = async (call, options) => {
        const settled = call(options).then(() => 'resolved', e => e === sentinel ? 'signal-reason' : e.name);
        return Promise.race([settled, new Promise(resolve => setTimeout(() => resolve('pending'), 3000))]);
      };
      const control = [], routed = [];
      for (const [operation, options] of cases) {
        control.push(await outcome(window.__engine[operation], options()));
        routed.push(await outcome(navigator.credentials[operation].bind(navigator.credentials), options()));
      }
      return JSON.stringify({ control, routed });
    })()
    """

    private func abortedOutcomes(enabled: Bool) async throws -> (control: [String], routed: [String], native: Native) {
        let (view, native) = try await load(Self.originalEngineBeforeOurScript, enabled: enabled)
        let answer = try #require(try await settled(view, Self.abortedCases) as? String)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: [String]])
        return (try #require(decoded["control"]), try #require(decoded["routed"]), native)
    }

    /// The legacy provider keeps every engine behaviour the manager restricts (conditional create, silent mediation, a
    /// cross-realm AbortSignal, other credential types alongside publicKey, required largeBlob). Under the legacy provider
    /// the routed call settles exactly as the real engine's own method does; the manager-only checks run first and give
    /// other answers, which is what makes the comparison meaningful.
    @Test(.boundedWebViews) func legacyRoutesAbortedRequestsToTheRealEngineExactlyAsItsOwnMethodSettlesThem() async throws {
        let legacy = try await abortedOutcomes(enabled: false)
        #expect(legacy.control.count == 5 && !legacy.control.contains("pending"), "the real engine settled every aborted request")
        #expect(legacy.routed == legacy.control, "legacy is the engine, not the manager's reading of the call")
        #expect(legacy.native.requests.isEmpty, "no ceremony request was ever made")

        let manager = try await abortedOutcomes(enabled: true)
        #expect(manager.control == legacy.control, "the captured engine method does not depend on the provider")
        #expect(manager.routed != manager.control, "the control can tell the manager's own restrictions apart from the engine")
        #expect(manager.native.requests.isEmpty)
    }

    /// No answer (the bridge is gone or hung) and a manager that refuses this page are both refusals: the engine is never
    /// asked, and the page is told the truth (nothing available) rather than the other provider's answer.
    @Test(.boundedWebViews, arguments: [Answer.silent, Answer.staleManager]) func anUnavailableOrRefusingManagerIsNeverTakenForLegacy(_ answer: Answer) async throws {
        let (view, native) = try await load(engineCalls, answer: answer)
        let results = try await settled(view, """
        (async () => {
          const attempt = async call => { try { return String(await call()); } catch (e) { return e.name; } };
          const signals = ['signalUnknownCredential', 'signalAllAcceptedCredentials', 'signalCurrentUserDetails'];
          const out = [
            ...await Promise.all([
              attempt(() => navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } })),
              attempt(() => navigator.credentials.create(\(createOptions))),
              attempt(() => PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()),
              attempt(() => PublicKeyCredential.isConditionalMediationAvailable()),
            ]),
            ...await Promise.all([
              attempt(() => PublicKeyCredential.getClientCapabilities().then(JSON.stringify)),
              ...signals.map(name => attempt(() => PublicKeyCredential[name]({ rpId: 'login.example', credentialId: 'imported-id' }))),
            ]),
          ];
          return JSON.stringify({ out, engine: originalCalls });
        })()
        """) as? String
        let resultsJSON = try #require(results)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(resultsJSON.utf8)) as? [String: Any])
        #expect(decoded["out"] as? [String] == [
            "NotAllowedError", "NotAllowedError", "false", "false", "{}",
            "NotSupportedError", "NotSupportedError", "NotSupportedError",
        ])
        #expect((decoded["engine"] as? [String])?.isEmpty == true, "the engine was never asked: nothing unavailable is legacy")
        // Never announced: refused in the page, nothing reaches native. A manager that refuses the page saw one request (the
        // second foreground call is refused locally while it is pending) and answered it with an error, never a ceremony.
        #expect(native.requests.count == (answer == .silent ? 0 : 1))
    }

    @Test(.boundedWebViews) func capabilitiesDescribeOnlyWhatIsImplemented() async throws {
        let (view, _) = try await load()
        let capabilities = try await settled(view, """
        (async () => JSON.stringify({
          conditional: await PublicKeyCredential.isConditionalMediationAvailable(),
          uv: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
          client: await PublicKeyCredential.getClientCapabilities() }))()
        """) as? String
        let capabilitiesJSON = try #require(capabilities)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(capabilitiesJSON.utf8)) as? [String: Any])
        let client = try #require(decoded["client"] as? [String: Any])
        #expect(decoded["conditional"] as? Bool == true && decoded["uv"] as? Bool == true)
        #expect(client["conditionalGet"] as? Bool == true && client["conditionalCreate"] as? Bool == false)
        #expect(client["hybridTransport"] as? Bool == false && client["relatedOrigins"] as? Bool == false)
        #expect(["signalUnknownCredential", "signalAllAcceptedCredentials", "signalCurrentUserDetails"].allSatisfy { client[$0] as? Bool == false })
    }

    @Test(.boundedWebViews) func legacyProviderLeavesTheEnginesOwnBehaviour() async throws {
        let (view, _) = try await load("""
        window.originalCalls = []; const proto = Object.getPrototypeOf(navigator.credentials);
        for (const name of ['create', 'get']) proto[name] = function (options) { originalCalls.push(name); return Promise.resolve('engine-' + name); };
        PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve('engine-conditional');
        """, enabled: false)
        #expect(try await settled(view, "navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } })") as? String == "engine-get")
        #expect(try await settled(view, "PublicKeyCredential.isConditionalMediationAvailable()") as? String == "engine-conditional")
        // Without the engine's own capability the answer is the engine's absence, not an invented one.
        #expect(try await settled(view, "PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()") as? Bool == false)
    }

    private let signalPrelude = """
    window.engineSignals = [];
    for (const name of ['signalUnknownCredential', 'signalAllAcceptedCredentials', 'signalCurrentUserDetails']) {
      PublicKeyCredential[name] = function (options) { engineSignals.push(name + ':' + options.credentialId); return Promise.resolve('engine-' + name); };
    }
    """
    private let signalCalls = """
    (async () => { const out = []; for (const name of ['signalUnknownCredential', 'signalAllAcceptedCredentials', 'signalCurrentUserDetails']) {
      try { out.push(String(await PublicKeyCredential[name]({ rpId: 'login.example', credentialId: 'imported-id' }))); } catch (e) { out.push(e.name); } }
      return JSON.stringify({ out, engine: engineSignals }); })()
    """

    @Test(.boundedWebViews) func managerModeNeverForwardsCredentialSignalsToTheEngineStore() async throws {
        let (view, _) = try await load(signalPrelude)
        let answer = try #require(try await settled(view, signalCalls) as? String)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(decoded["out"] as? [String] == Array(repeating: "NotSupportedError", count: 3))
        #expect((decoded["engine"] as? [String])?.isEmpty == true, "an imported credential ID must never reach the engine's store")
    }

    @Test(.boundedWebViews) func legacyModeKeepsTheEnginesSignalBehaviour() async throws {
        let (view, _) = try await load(signalPrelude, enabled: false)
        let answer = try #require(try await settled(view, signalCalls) as? String)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(decoded["out"] as? [String] == ["engine-signalUnknownCredential", "engine-signalAllAcceptedCredentials", "engine-signalCurrentUserDetails"])
    }

    @Test(.boundedWebViews) func anEngineWithoutSignalsStillHasNone() async throws {
        let (view, _) = try await load("for (const name of ['signalUnknownCredential', 'signalAllAcceptedCredentials', 'signalCurrentUserDetails']) delete PublicKeyCredential[name];")
        #expect(try await view.evaluateJavaScript("typeof PublicKeyCredential.signalUnknownCredential") as? String == "undefined")
    }
}
