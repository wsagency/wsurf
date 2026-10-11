// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

extension WebAuthnAdapterTests {
    // MARK: Per-context provider

    private struct RealmError: Error { let reason: String }

    /// The real adapter on real pages of the engine under test: every page is a `BrowserTab` (the production constructor and
    /// adoption path, so the engine's frame registry, the relay and `WebAuthnAdapter` are the production ones) served from
    /// localhost and owned by the context of a fresh regular profile that this realm made, or by a private context. Only
    /// conditional requests are made, which register without unlocking, asking or needing the user, so a pending ceremony is a
    /// real adapter entry that no native sheet is waiting on.
    private final class Realm {
        let server: HTTPFixtureServer
        let engine: BrowserEngine
        private var profiles: [Profile] = []
        private var privateContexts: [BrowserProfileContext] = []
        private var tabs: [BrowserTab] = []
        private var windows: [NSWindow] = []

        private init(server: HTTPFixtureServer, engine: BrowserEngine) {
            self.server = server
            self.engine = engine
        }

        static func start(engine: BrowserEngine) async throws -> Realm {
            let document = "<!doctype html><title>Passkeys</title><input id=field autocomplete='username webauthn'>"
            return Realm(
                server: try await HTTPFixtureServer.start(routes: ["/": .html(document), "/next": .html(document)]), engine: engine
            )
        }

        func url(_ path: String = "/") throws -> URL {
            var components = try #require(URLComponents(url: server.url(path), resolvingAgainstBaseURL: false))
            components.host = "localhost"
            return try #require(components.url)
        }

        /// A fresh regular profile with its own context and the provider chosen before any page exists.
        func context(_ provider: PasswordProvider) -> BrowserProfileContext {
            let profile = Profile(id: UUID(), name: "Provider \(profiles.count)", symbol: "key", color: .blue)
            profiles.append(profile)
            let context = BrowserProfileContext(profile: profile)
            context.settings.passwordProvider = provider
            return context
        }

        /// A private context's settings are in memory only; nothing of it is persisted.
        func privateContext(_ provider: PasswordProvider) -> BrowserProfileContext {
            let context = BrowserProfileContext(profile: .privateBrowsing())
            privateContexts.append(context)
            context.settings.passwordProvider = provider
            return context
        }

        func open(_ context: BrowserProfileContext) async throws -> BrowserPage {
            // The tab routes a main-frame navigation to the engine its site is set to (default WebKit), cancelling and
            // replacing a Chromium page loading a WebKit-routed site. The engine under test is therefore this origin's
            // setting, in the context's own store (the profile's, or in memory for a private context), never a global one.
            let targetURL = try url()
            context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: targetURL))
            let tab = BrowserTab(opensBlank: false, privately: context.profile.isPrivate, context: context)
            tabs.append(tab)
            switch engine {
            case .webKit:
                tab.adopt(BrowserPage(webKit: context.webViewPool.acquire(), context: context))
            case .chromium:
                try ChromiumRuntime.shared.ensureInitialized()
                tab.adopt(BrowserPage(chromium: ChromiumPage(context: context)))
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = tab.page
            window.orderBack(nil)
            windows.append(window)
            try await navigate(tab.page, to: targetURL)
            return tab.page
        }

        /// Loads `url` and returns once the document is ready to carry requests: its native frame handshake has resolved in
        /// the relay's own isolated world (WebKit), and the relay itself is installed there (both engines).
        func navigate(_ page: BrowserPage, to url: URL) async throws {
            page.load(URLRequest(url: url))
            guard await waitUntil({ page.url?.path == url.path && !page.isLoading }) else { throw RealmError(reason: "page did not load") }
            let expression = page.chromium == nil ? "await globalThis.__wsurfNativeFrameReady" : "true"
            let report = try await page.callAsyncJavaScript("""
            return JSON.stringify({
              ready: \(expression),
              nonce: typeof globalThis.__wsurfNativeFrameNonce === 'string' ? globalThis.__wsurfNativeFrameNonce : null,
              relay: typeof globalThis.__wsurfWebAuthnFence
            });
            """, in: nil, contentWorld: PageAutomationGuard.world) as? String
            let state = try #require(report.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
            guard state["ready"] as? Bool == true, state["relay"] as? String == "object",
                  page.chromium != nil || (state["nonce"] as? String)?.isEmpty == false else {
                throw RealmError(reason: "the document's native handshake or relay is not ready")
            }
        }

        /// Awaited, in order: every tab is retired (its page closed) before the window it lives in, then the contexts and
        /// profiles this realm made are released with the app's own lifecycle: a private session ends, a regular profile is
        /// erased (its website data store, engine data, vaults, settings and directory), never anything of the user's data.
        func close() async {
            for tab in tabs {
                tab.detach()
            }
            for tab in tabs {
                await tab.waitForRetirement()
            }
            for window in windows {
                window.close()
            }
            tabs.removeAll()
            windows.removeAll()
            for context in privateContexts {
                await context.endPrivateSession()
            }
            for profile in profiles {
                await Profile.erase(profile)
            }
        }
    }

    private func withRealm(_ engine: BrowserEngine, _ body: (Realm) async throws -> Void) async throws {
        let realm = try await Realm.start(engine: engine)
        do { try await body(realm) } catch { await realm.close(); throw error }
        await realm.close()
    }

    /// The route the relay of the page's live document announces to the page: the provider native chose for it.
    private func route(of page: BrowserPage) async throws -> String? {
        try await page.evaluateJavaScript("""
        (() => { let route = null; const note = event => { route = event.detail; };
          document.addEventListener('wsurf-webauthn-route', note);
          document.dispatchEvent(new CustomEvent('wsurf-webauthn-route-request'));
          document.removeEventListener('wsurf-webauthn-route', note); return route; })()
        """) as? String
    }

    private func routes(_ pages: BrowserPage...) async throws -> [String?] {
        var announced: [String?] = []
        for page in pages {
            announced.append(try await route(of: page))
        }
        return announced
    }

    /// A causal native barrier. The relay posts what it receives to native in order, native handles each message as it
    /// arrives and answers a capabilities question after that, and the answers reach the document in order. So this
    /// question's answer is native's proof that everything the page sent before it was handled first, and that anything
    /// native had already decided to say to this document was delivered ahead of it. Returns the answer (`result` holds the
    /// provider native says serves this document). Nothing waits for a fixed time.
    @discardableResult
    private func fence(_ page: BrowserPage) async throws -> [String: Any] {
        let raw = try await settled(page, """
        new Promise(resolve => {
          const id = 'fence-' + crypto.randomUUID();
          const timer = setTimeout(() => resolve(null), 20000);
          const note = event => {
            let value; try { value = JSON.parse(event.detail); } catch { return; }
            if (value?.id !== id) return;
            clearTimeout(timer);
            document.removeEventListener('wsurf-webauthn-result', note);
            resolve(JSON.stringify(value));
          };
          document.addEventListener('wsurf-webauthn-result', note);
          document.dispatchEvent(new CustomEvent('wsurf-webauthn-request',
            { detail: JSON.stringify({ action: 'request', id, operation: 'capabilities' }) }));
        })
        """) as? String
        let answer = try #require(raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }, "native never answered the fence")
        return answer
    }

    /// A real conditional `get` the page leaves pending. `outcomes` records how its promise ended. Returns once native has
    /// handled the request (see `fence`): a request native rejected would already have an outcome by then.
    private func requestConditionalGet(in page: BrowserPage) async throws {
        _ = try await page.evaluateJavaScript("""
        window.outcomes = [];
        navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(4) } })
          .then(() => outcomes.push('resolved'), e => outcomes.push(e.name)); true
        """)
        try await fence(page)
    }

    private func outcomes(of page: BrowserPage) async throws -> [String] {
        let joined = try await page.evaluateJavaScript("outcomes.join()") as? String ?? ""
        return joined.isEmpty ? [] : joined.split(separator: ",").map(String.init)
    }

    /// Records the relay's results as the page world sees them, for requests the page script did not make itself. The
    /// fence's own questions are not among them.
    private func recordResults(in page: BrowserPage) async throws {
        _ = try await page.evaluateJavaScript("""
        window.results = []; document.addEventListener('wsurf-webauthn-result', event => {
          const value = JSON.parse(event.detail); if (!String(value.id).startsWith('fence-')) results.push(value);
        }); true
        """)
    }

    private func results(of page: BrowserPage) async throws -> [[String: Any]] {
        let json = try await page.evaluateJavaScript("JSON.stringify(results)") as? String ?? "[]"
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    /// The relay's own request event, which a page can always emit itself: a conditional get nothing on the page asked for.
    private func sendRawConditionalGet(_ id: String, in page: BrowserPage) async throws {
        _ = try await page.evaluateJavaScript("""
        document.dispatchEvent(new CustomEvent('wsurf-webauthn-request', { detail: JSON.stringify(
          { action: 'request', id: '\(id)', operation: 'get', mediation: 'conditional', options: { challenge: 'AQIDBA' } }) })); true
        """)
    }

    private func errorName(_ result: [String: Any]) -> String? {
        (result["error"] as? [String: Any])?["name"] as? String
    }

    private func provider(of answer: [String: Any]) -> String? {
        (answer["result"] as? [String: Any])?["provider"] as? String
    }

    /// A provider change on one context refuses that context's pending ceremonies (every page of it) and nobody else's.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func changingOneContextsProviderCancelsOnlyItsOwnPendingCeremonies(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let contextA = realm.context(.credentialManager), contextB = realm.context(.credentialManager)
            let a1 = try await realm.open(contextA), a2 = try await realm.open(contextA), b = try await realm.open(contextB)
            // Each request is past the fence, so native has registered it (a rejection would already be an outcome).
            for page in [a1, a2, b] {
                try await requestConditionalGet(in: page)
            }
            for page in [a1, a2, b] {
                #expect(try await outcomes(of: page).isEmpty, "a conditional discovery is pending, not failed")
            }

            contextA.settings.passwordProvider = .legacy
            for page in [a1, a2] {
                #expect(try await waitUntil { try await outcomes(of: page) == ["NotAllowedError"] }, "A's pending ceremony is refused by native")
            }
            #expect(try await waitUntil { try await route(of: a1) == "legacy" })
            // A native answer to B after A's change proves nothing was sent to B ahead of it.
            #expect(provider(of: try await fence(b)) == "manager")
            #expect(try await outcomes(of: b).isEmpty, "B's ceremony is untouched by A's change")
            #expect(try await route(of: b) == "manager")
            for page in [a1, a2] {
                #expect(provider(of: try await fence(page)) == "legacy", "native now answers A's pages with A's own provider")
                #expect(try await outcomes(of: page) == ["NotAllowedError"], "exactly one refusal, no later outcome")
            }

            // Back to the manager: A takes ceremonies again and is not wedged by the earlier refusal.
            contextA.settings.passwordProvider = .credentialManager
            #expect(try await waitUntil { try await route(of: a1) == "manager" })
            try await requestConditionalGet(in: a1)
            #expect(try await outcomes(of: a1).isEmpty)

            // B's request was registered with the adapter the whole time: only a registered entry is refused by its profile.
            WebAuthnAdapter.cancel(profileID: contextB.profile.id)
            #expect(try await waitUntil { try await outcomes(of: b) == ["NotAllowedError"] })
            try await fence(a1)
            #expect(try await outcomes(of: a1).isEmpty, "B's profile never refuses A's new ceremony")
            WebAuthnAdapter.cancel(profileID: contextA.profile.id)
            #expect(try await waitUntil { try await outcomes(of: a1) == ["NotAllowedError"] })
        }
    }

    /// The route a live page obeys follows its own context's setting, in both directions, for documents already live and for
    /// documents loaded afterwards, while every other context's pages keep the route their own setting gave them.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func aProviderChangeFlipsOnlyItsOwnContextsLivePagesAndNewDocuments(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let contextA = realm.context(.legacy), contextB = realm.context(.credentialManager), contextC = realm.context(.legacy)
            let a1 = try await realm.open(contextA), a2 = try await realm.open(contextA)
            let b = try await realm.open(contextB), c = try await realm.open(contextC)
            #expect(try await routes(a1, a2, b, c) == ["legacy", "legacy", "manager", "legacy"])

            contextA.settings.passwordProvider = .credentialManager
            for page in [a1, a2] {
                #expect(try await waitUntil { try await route(of: page) == "manager" }, "legacy to manager on A's live pages")
            }
            // Native's own answers: A's pages are now the manager's, B and C are exactly where their own settings put them.
            #expect([provider(of: try await fence(a1)), provider(of: try await fence(b)), provider(of: try await fence(c))] == ["manager", "manager", "legacy"])
            #expect(try await routes(b, c) == ["manager", "legacy"], "other contexts keep their own provider")

            // A document loaded after the change starts on the new route, from the replaced document-start script.
            try await realm.navigate(a1, to: realm.url("/next"))
            #expect(try await route(of: a1) == "manager")

            contextA.settings.passwordProvider = .legacy
            for page in [a1, a2] {
                #expect(try await waitUntil { try await route(of: page) == "legacy" }, "manager to legacy on A's live pages")
            }
            try await realm.navigate(a2, to: realm.url("/next"))
            #expect(try await route(of: a2) == "legacy")
            #expect([provider(of: try await fence(b)), provider(of: try await fence(c))] == ["manager", "legacy"])
            #expect(try await routes(b, c) == ["manager", "legacy"])

            // And the other way round: B's change leaves A and C where they are.
            contextB.settings.passwordProvider = .legacy
            #expect(try await waitUntil { try await route(of: b) == "legacy" })
            #expect([provider(of: try await fence(a1)), provider(of: try await fence(a2)), provider(of: try await fence(c))] == ["legacy", "legacy", "legacy"])
            #expect(try await routes(a1, a2, c) == ["legacy", "legacy", "legacy"])
        }
    }

    /// A private page is never the manager's, whatever its context's settings say: its route is the engine's own, and a
    /// manager request the page forges through the relay is refused by the adapter. A regular manager page is the control.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func aPrivateContextNeverServesManagerRequestsEvenWhenItsSettingsSayCredentialManager(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let regular = realm.context(.credentialManager)
            let privateContext = realm.privateContext(.credentialManager)
            let control = try await realm.open(regular)
            let page = try await realm.open(privateContext)
            #expect(privateContext.settings.passwordProvider == .credentialManager && page.isPrivate && !control.isPrivate)
            #expect(try await route(of: page) == "legacy", "a private page is never announced as the manager's")
            #expect(try await route(of: control) == "manager")

            for target in [page, control] {
                try await recordResults(in: target)
            }
            try await sendRawConditionalGet("raw-private-1", in: page)
            try await sendRawConditionalGet("raw-control", in: control)
            #expect(try await waitUntil { try await results(of: page).count == 1 })
            let refusal = try #require(try await results(of: page).first)
            #expect(refusal["id"] as? String == "raw-private-1" && errorName(refusal) == "NotAllowedError")
            // Native answered the control after its raw request: that request is registered and pending, not refused.
            #expect(provider(of: try await fence(control)) == "manager")
            #expect(try await results(of: control).isEmpty, "the same request is a pending discovery on a regular manager page")

            // Toggling the private context's setting changes nothing: still the engine's route, still refused.
            privateContext.settings.passwordProvider = .legacy
            privateContext.settings.passwordProvider = .credentialManager
            #expect(provider(of: try await fence(page)) == "legacy", "asked which provider owns it, a private page is told the engine")
            #expect(try await route(of: page) == "legacy")
            try await sendRawConditionalGet("raw-private-2", in: page)
            #expect(try await waitUntil { try await results(of: page).count == 2 })
            let second = try #require(try await results(of: page).last)
            #expect(second["id"] as? String == "raw-private-2" && errorName(second) == "NotAllowedError")

            // The raw capabilities answer for a private page is the engine's, never an enabled manager.
            let capabilities = try #require(try await fence(page)["result"] as? [String: Any])
            #expect(capabilities["provider"] as? String == "legacy" && capabilities["enabled"] as? Bool == false)

            // The control request was a registered entry the whole time: a profile cancel refuses it.
            WebAuthnAdapter.cancel(profileID: regular.profile.id)
            #expect(try await waitUntil { try await results(of: control).count == 1 })
            let released = try #require(try await results(of: control).first)
            #expect(errorName(released) == "NotAllowedError")
        }
    }

    /// A profile cancel (what a lock, a profile switch or an erase calls) refuses exactly that profile's pending ceremonies,
    /// on every page of every context it owns, and leaves every other profile's and every unknown id's alone.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func cancellingByProfileIDRefusesOnlyThatProfilesPendingCeremonies(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let contextA = realm.context(.credentialManager), contextB = realm.context(.credentialManager)
            let a1 = try await realm.open(contextA), a2 = try await realm.open(contextA), b = try await realm.open(contextB)
            for page in [a1, a2, b] {
                try await requestConditionalGet(in: page)
            }

            WebAuthnAdapter.cancel(profileID: UUID())
            for page in [a1, a2, b] {
                try await fence(page)
                #expect(try await outcomes(of: page).isEmpty, "an unknown profile cancels nothing")
            }

            WebAuthnAdapter.cancel(profileID: contextA.profile.id)
            for page in [a1, a2] {
                #expect(try await waitUntil { try await outcomes(of: page) == ["NotAllowedError"] }, "A's pending ceremonies are refused")
            }
            try await fence(b)
            #expect(try await outcomes(of: b).isEmpty, "B's ceremony is untouched by a cancel of A's profile")
            #expect(contextA.settings.passwordProvider == .credentialManager && contextB.settings.passwordProvider == .credentialManager)
            #expect(try await route(of: a1) == "manager", "a cancel is not a provider change")

            WebAuthnAdapter.cancel(profileID: contextB.profile.id)
            #expect(try await waitUntil { try await outcomes(of: b) == ["NotAllowedError"] })
            for page in [a1, a2] {
                try await fence(page)
                #expect(try await outcomes(of: page) == ["NotAllowedError"], "no second outcome for A")
            }
        }
    }
}
