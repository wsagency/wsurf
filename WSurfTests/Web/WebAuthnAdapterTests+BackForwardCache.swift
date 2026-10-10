// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

extension WebAuthnAdapterTests {
    // MARK: Back/forward-cache restore

    /// Counts anything the relay posts to the registry's resume handler. Only the registry may ask native to resume; the
    /// relay must never do it, so after a real restore this stays zero.
    private final class ResumePosts { var count = 0 }

    /// A real navigate-away-and-back in WKWebView with the registry stand-in (`.registry`). Fails (rather than passing
    /// vacuously) when WebKit did not restore the document from its back/forward cache, because only a restored document
    /// receives a trusted `persisted` pageshow. The stand-in then holds the restore proof pending until the test settles it.
    private func restoredFromBackForwardCache(
        prelude: String = "", enabled: Bool = true, providerAtRestore: String? = nil, holdRoute: Bool = false
    ) async throws -> (BrowserPage, Native, ResumePosts) {
        let (view, native) = try await load(prelude + routeProbe, enabled: enabled, handshake: .registry("doc-1"))
        let posts = ResumePosts()
        view.addScriptMessageHandler(name: "wsurfFrameRegistryResume", in: Self.world) { _ in posts.count += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = "<!doctype html><input id=field autocomplete='username webauthn'>"
        let first = directory.appendingPathComponent("a.html"), second = directory.appendingPathComponent("b.html")
        try html.write(to: first, atomically: true, encoding: .utf8)
        try html.write(to: second, atomically: true, encoding: .utf8)

        view.loadFileURL(first, allowingReadAccessTo: directory)
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        _ = try await view.evaluateJavaScript("window.cached = true; window.persistedShows = 0; addEventListener('pageshow', e => { if (e.persisted) window.persistedShows++; }); true")
        view.loadFileURL(second, allowingReadAccessTo: directory)
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        native.mode = providerAtRestore
        native.holdRoute = holdRoute
        view.goBack()
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        let restored = await waitUntil { (try? await view.evaluateJavaScript("window.persistedShows") as? Int) == 1 }
        try #require(restored, "WebKit did not restore the document from its back/forward cache; the resume path was not exercised")
        if !holdRoute {
            // Native answers the restore's one route question; requests made before that are refused by design.
            try #require(await waitUntil { (try? await view.evaluateJavaScript("routeEvents.at(-1)") as? String).map { $0 != "pending" } == true })
        }
        return (view, native, posts)
    }

    /// The registry's answer to the restore: accepted (`true`) or refused (`false`).
    private func settleRestore(_ view: BrowserPage, accepted: Bool) async throws {
        _ = try await view.callAsyncJavaScript(
            "globalThis.__settleTestRestore(accepted); return true;", arguments: ["accepted": accepted], in: nil, contentWorld: Self.world
        )
    }

    private var rawRequest: String {
        "window.outcomes = window.outcomes || []; navigator.credentials.create(\(createOptions)).then(() => window.outcomes.push('resolved'), e => window.outcomes.push(e.name)); true"
    }

    @Test(.boundedWebViews, .requiresBackForwardCache) func aRestoredDocumentStaysInertUntilTheRegistryProvesItsFrameAndNeverPostsAResumeItself() async throws {
        let (view, native, posts) = try await restoredFromBackForwardCache()

        _ = try await view.evaluateJavaScript(rawRequest)
        try await Task.sleep(for: .milliseconds(300))
        #expect(native.requests.isEmpty, "nothing reaches native before the registry's proof")
        #expect(try await view.evaluateJavaScript("window.outcomes.length") as? Int == 0)

        try await settleRestore(view, accepted: true)
        #expect(await waitUntil { !native.requests.isEmpty })
        #expect(native.requests.allSatisfy { $0["document"] as? String == "doc-1" }, "the same native nonce, now proven live again")
        #expect(try await view.evaluateJavaScript("window.outcomes.length") as? Int == 0, "the request is pending, not failed")
        #expect(posts.count == 0, "the registry alone posts the resume; the relay never does")
    }

    /// The relay captured the registry's epoch when the restore began. If the registry moved on before its proof arrived,
    /// an accepted proof is for a different document state and must not reactivate this one.
    @Test(.boundedWebViews, .requiresBackForwardCache) func aProofForADifferentRegistryEpochDoesNotReactivateTheDocument() async throws {
        let (view, native, _) = try await restoredFromBackForwardCache()
        _ = try await view.evaluateJavaScript(rawRequest)
        _ = try await view.callAsyncJavaScript("globalThis.__bumpTestEpoch(); return true;", arguments: [:], in: nil, contentWorld: Self.world)
        try await settleRestore(view, accepted: true)
        #expect(await waitUntil { !native.requests.isEmpty })
        #expect(native.requests.allSatisfy { $0["document"] as? String == "" }, "demoted: no identity")
    }

    /// Encrypted provider: a refused restore leaves the document unidentified. Native is asked about it only as document
    /// '' and, as the real adapter does, answers that the manager refuses it: the page gets NotAllowedError, and not
    /// the engine, not a frame, a context or a ceremony, for the first request or any later one.
    @Test(.boundedWebViews, .requiresBackForwardCache) func aRefusedResumeIsRefusedUnderTheEncryptedProviderAndNeverFallsBackToTheEngine() async throws {
        let (view, native, posts) = try await restoredFromBackForwardCache(prelude: engineCalls)

        _ = try await view.evaluateJavaScript(rawRequest)
        try await Task.sleep(for: .milliseconds(200))
        #expect(native.requests.isEmpty, "still waiting for the registry's proof")
        try await settleRestore(view, accepted: false)
        #expect(await waitUntil { (try? await view.evaluateJavaScript("window.outcomes.join()") as? String) == "NotAllowedError" })
        _ = try await view.evaluateJavaScript(rawRequest)
        #expect(await waitUntil { (try? await view.evaluateJavaScript("window.outcomes.join()") as? String) == "NotAllowedError,NotAllowedError" })

        #expect(native.requests.count == 2 && native.requests.allSatisfy { $0["document"] as? String == "" },
                "native saw only identity-less documents and refused them; it made no ceremony")
        #expect(try await view.evaluateJavaScript("originalCalls.length") as? Int == 0, "the engine never saw a manager-owned call")
        #expect(posts.count == 0)
    }

    /// Legacy provider: a refused restore must not take the engine's own WebAuthn away. Native decides `legacy` for the
    /// unidentified document and the engine's behaviour, with the untouched options, is what the page gets.
    @Test(.boundedWebViews, .requiresBackForwardCache) func aRefusedResumeStillRunsTheEngineUnderTheLegacyProvider() async throws {
        let (view, native, _) = try await restoredFromBackForwardCache(prelude: engineCalls, enabled: false)
        try await settleRestore(view, accepted: false)

        #expect(try await settled(view, "navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } })") as? String == "engine-get")
        #expect(native.requests.isEmpty, "the legacy provider never reaches the manager")
        #expect(native.queries.isEmpty, "the page script never asks native first: the announced provider decides in the caller's turn")
        #expect(try await view.evaluateJavaScript("originalCalls.join()") as? String == "get")
    }

    /// Page-world observer of the route events the relay announces; `restoredFromBackForwardCache` installs it.
    private var routeProbe: String {
        "window.routeEvents = []; document.addEventListener('wsurf-webauthn-route', e => routeEvents.push(e.detail));"
    }

    /// A document cached under one provider runs no new-document script when it comes back; the provider chosen meanwhile
    /// is learned from native's single answer to the restore's route question.
    @Test(.boundedWebViews, .requiresBackForwardCache) func aDocumentCachedUnderLegacyUsesTheEncryptedProviderChosenWhileItWasCached() async throws {
        let (view, native, _) = try await restoredFromBackForwardCache(prelude: engineCalls, enabled: false, providerAtRestore: "manager")
        try await settleRestore(view, accepted: true)
        #expect(await waitUntil { (try? await view.evaluateJavaScript("routeEvents.at(-1)") as? String) == "manager" })
        _ = try await view.evaluateJavaScript(rawRequest)
        #expect(await waitUntil { !native.requests.isEmpty })
        #expect(try await view.evaluateJavaScript("originalCalls.length") as? Int == 0, "the stale legacy route never reached the engine")
        #expect(native.messages.filter { $0["action"] as? String == "route" }.count == 1, "one re-announcement, not a query per call")
    }

    @Test(.boundedWebViews, .requiresBackForwardCache) func aDocumentCachedUnderTheEncryptedProviderUsesTheLegacyOneChosenWhileItWasCached() async throws {
        let (view, native, _) = try await restoredFromBackForwardCache(prelude: engineCalls, enabled: true, providerAtRestore: "legacy")
        try await settleRestore(view, accepted: true)
        #expect(await waitUntil { (try? await view.evaluateJavaScript("routeEvents.at(-1)") as? String) == "legacy" })
        #expect(try await settled(view, "navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } })") as? String == "engine-get")
        #expect(native.requests.isEmpty, "the encrypted provider was not asked")
    }

    /// Until native answers the restore's one route question, a document that was legacy is refused at once and its options
    /// are never touched (no getter, no buffer read, nothing queued, no engine call); a fresh explicit answer restores
    /// delegation, and a manager answer a request that snapshots its buffers in the calling turn.
    @Test(.boundedWebViews, .requiresBackForwardCache) func aCachedLegacyDocumentIsRefusedUnreadUntilNativeAnswersTheRestoreRoute() async throws {
        let prelude = engineCalls + "window.reads = 0; window.untouched = { get publicKey() { window.reads++; throw new Error('read'); } };"
        let (view, native, _) = try await restoredFromBackForwardCache(prelude: prelude, enabled: false, holdRoute: true)
        try await settleRestore(view, accepted: true)
        #expect(await waitUntil { native.messages.contains { $0["action"] as? String == "route" } })
        #expect(try await view.evaluateJavaScript("routeEvents.at(-1)") as? String == "pending")
        let refused = try await settled(view, "navigator.credentials.get(untouched).then(() => 'resolved', e => e.name)") as? String
        #expect(refused == "NotAllowedError")
        #expect(try await view.evaluateJavaScript("reads") as? Int == 0, "a refused restore-window request is never read")
        #expect(native.requests.isEmpty)
        #expect(try await view.evaluateJavaScript("originalCalls.length") as? Int == 0, "never delegated to the engine")

        _ = try await view.callAsyncJavaScript("globalThis.__wsurfWebAuthnFence.route('legacy', 2); return true;", arguments: [:], in: nil, contentWorld: Self.world)
        #expect(try await settled(view, "navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } })") as? String == "engine-get")

        _ = try await view.callAsyncJavaScript("globalThis.__wsurfWebAuthnFence.route('manager', 2); return true;", arguments: [:], in: nil, contentWorld: Self.world)
        _ = try await view.evaluateJavaScript("""
        (() => { const challenge = new Uint8Array([1, 2, 3, 4]);
          navigator.credentials.get({ publicKey: { challenge } }).catch(() => {}); challenge.fill(9); return true; })()
        """)
        let request = try #require(await pending(native))
        let options = try #require(request["options"] as? [String: Any])
        #expect(try WebAuthnWire.base64URLDecode(options["challenge"], maximum: 1_024) == Data([1, 2, 3, 4]))
    }

    /// A document that was the encrypted provider's keeps preparing manager requests during the window: the buffers are
    /// copied in the calling turn and the request goes to native once the relay's frame proof lands, never to the engine.
    @Test(.boundedWebViews, .requiresBackForwardCache) func aCachedManagerRequestSnapshotsInItsTurnAndWaitsForTheFrameProof() async throws {
        let (view, native, _) = try await restoredFromBackForwardCache(prelude: engineCalls, enabled: true, holdRoute: true)
        #expect(try await view.evaluateJavaScript("routeEvents.at(-1)") as? String == "pending")
        _ = try await view.evaluateJavaScript("""
        (() => { const challenge = new Uint8Array([1, 2, 3, 4]);
          navigator.credentials.get({ publicKey: { challenge } }).catch(() => {}); challenge.fill(9); return true; })()
        """)
        #expect(native.requests.isEmpty, "held for the native frame proof")
        try await settleRestore(view, accepted: true)
        let request = try #require(await pending(native))
        let options = try #require(request["options"] as? [String: Any])
        #expect(try WebAuthnWire.base64URLDecode(options["challenge"], maximum: 1_024) == Data([1, 2, 3, 4]))
        #expect(try await view.evaluateJavaScript("originalCalls.length") as? Int == 0, "never delegated to the engine")
    }

    /// Native moved the document to another provider while it was cached: the manager request it receives is refused (as the
    /// adapter refuses any request it does not serve) and the page never falls back to the engine.
    @Test(.boundedWebViews, .requiresBackForwardCache) func aCachedManagerRequestRefusedBecauseTheProviderMovedAwayNeverFallsBackToTheEngine() async throws {
        let (view, native, _) = try await restoredFromBackForwardCache(prelude: engineCalls, enabled: true, providerAtRestore: "legacy", holdRoute: true)
        _ = try await view.evaluateJavaScript(
            "window.outcome = null; navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } })" +
            ".then(() => { outcome = 'resolved'; }, e => { outcome = e.name; }); true"
        )
        try await settleRestore(view, accepted: true)
        #expect(await waitUntil { !native.requests.isEmpty })
        #expect(await waitUntil { (try? await view.evaluateJavaScript("outcome") as? String) == "NotAllowedError" })
        #expect(try await view.evaluateJavaScript("originalCalls.length") as? Int == 0, "no fallback to the engine")
    }
}
