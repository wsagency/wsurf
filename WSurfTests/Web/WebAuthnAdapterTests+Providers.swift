// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Testing
import WebKit

@testable import WSurf

extension WebAuthnAdapterTests {
    // MARK: Route by page

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

        /// A fresh regular profile with its own context, holding `vaults` (real managers in the registry, made with `passkeys`). It
        /// holds the registry gate (shared) until `close`: a ceremony here can register a store, which a session-wide lock
        /// elsewhere would reach.
        func context(passkeys: VaultPasskeys = VaultPasskeys(), vaults: [VaultState] = []) async throws -> BrowserProfileContext {
            let profile: Profile
            if vaults.isEmpty {
                profile = try await VaultManagerFixture.newProfile("Provider \(profiles.count)")
            } else {
                profile = try await VaultManagerFixture.make(passkeys: passkeys, vaults: vaults).profile
            }
            profiles.append(profile)
            return BrowserProfileContext(profile: profile)
        }

        /// A private context's settings are in memory only; nothing of it is persisted.
        func privateContext() -> BrowserProfileContext {
            let context = BrowserProfileContext(profile: .privateBrowsing())
            privateContexts.append(context)
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

        /// The page's view moves to another window of its own: the page is the same, its window is not.
        func moveToNewWindow(_ page: BrowserPage) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            window.orderBack(nil)
            windows.append(window)
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
                await VaultManagerFixture.erase(profile)
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

    /// A page's route follows only whether it is private: a normal page is always the vault's and a private page is always the
    /// engine's, in a fresh document as well as in the live one, and a request the page forges for the other route is refused.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func aNormalPageIsAlwaysTheVaultsAndAPrivatePageAlwaysTheEngines(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            // A conditional request stays registered only where a vault could answer it, so the page that makes one has a locked vault.
            let regularContext = try await realm.context(vaults: [.locked]), otherRegularContext = try await realm.context()
            let privateContext = realm.privateContext()
            let regular = try await realm.open(regularContext), other = try await realm.open(otherRegularContext)
            let page = try await realm.open(privateContext)
            #expect(page.isPrivate && !regular.isPrivate && !other.isPrivate)
            #expect(try await routes(regular, other, page) == ["manager", "manager", "legacy"])

            // Native's own answers agree with what the pages were told.
            #expect([provider(of: try await fence(regular)), provider(of: try await fence(other)), provider(of: try await fence(page))]
                == ["manager", "manager", "legacy"])
            let capabilities = try #require(try await fence(page)["result"] as? [String: Any])
            #expect(capabilities["provider"] as? String == "legacy" && capabilities["enabled"] as? Bool == false)

            // A fresh document starts on the same route, from the script installed once with the page.
            try await realm.navigate(regular, to: realm.url("/next"))
            try await realm.navigate(page, to: realm.url("/next"))
            #expect(try await routes(regular, page) == ["manager", "legacy"])

            // A manager request forged on the private page through the relay is refused, never served or handed to the engine.
            for target in [page, regular] {
                try await recordResults(in: target)
            }
            try await sendRawConditionalGet("raw-private-1", in: page)
            try await sendRawConditionalGet("raw-control", in: regular)
            #expect(try await waitUntil { try await results(of: page).count == 1 })
            let refusal = try #require(try await results(of: page).first)
            #expect(refusal["id"] as? String == "raw-private-1" && errorName(refusal) == "NotAllowedError")
            // Native answered the control after its raw request: that request is registered and pending, not refused.
            #expect(provider(of: try await fence(regular)) == "manager")
            #expect(try await results(of: regular).isEmpty, "the same request is a pending discovery on a normal page")

            // The control request was a registered entry the whole time: a profile cancel refuses it, and only it.
            WebAuthnAdapter.cancel(profileID: regularContext.profile.id)
            #expect(try await waitUntil { try await results(of: regular).count == 1 })
            #expect(errorName(try #require(try await results(of: regular).first)) == "NotAllowedError")
            #expect(provider(of: try await fence(other)) == "manager")
        }
    }

    /// A profile cancel (what a lock, a profile switch or an erase calls) refuses exactly that profile's pending ceremonies,
    /// on every page of every context it owns, and leaves every other profile's and every unknown id's alone.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func cancellingByProfileIDRefusesOnlyThatProfilesPendingCeremonies(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let contextA = try await realm.context(vaults: [.locked]), contextB = try await realm.context(vaults: [.locked])
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
            #expect(try await route(of: a1) == "manager", "a cancel does not change a page's route")

            WebAuthnAdapter.cancel(profileID: contextB.profile.id)
            #expect(try await waitUntil { try await outcomes(of: b) == ["NotAllowedError"] })
            for page in [a1, a2] {
                try await fence(page)
                #expect(try await outcomes(of: page) == ["NotAllowedError"], "no second outcome for A")
            }
        }
    }

    // MARK: Route and vault choice

    /// A modal `get` the page leaves pending. Unlike a conditional one it runs the ceremony at once: route, choice, then the ceremony.
    private func requestModalGet(in page: BrowserPage) async throws {
        _ = try await page.evaluateJavaScript("""
        window.outcomes = [];
        navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) } })
          .then(() => outcomes.push('resolved'), e => outcomes.push(e.name)); true
        """)
    }

    /// A "which vault?" answer that waits for the test, like a prompt the user has not answered yet.
    @MainActor private final class OpenChoice {
        private(set) var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            isOpen = true
            await withCheckedContinuation { continuation = $0 }
        }

        func answer() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// The relay's result events as the page world sees them, minus the fence's own questions (see `recordResults`), that carry a
    /// hand-off: the mode native named.
    private func handOffs(of page: BrowserPage) async throws -> [String] {
        try await results(of: page).compactMap { $0["handoff"] as? String }
    }

    /// What a page can see of a profile's vault: nothing. The same request makes the same observable sequence, whether the profile
    /// has no vault, an open vault with no passkey for the site, or a locked one: nothing at all until the user answers the
    /// step, then the same single ending for the same answer. Only the explicit choice of the system's authenticator reaches
    /// the engine.
    private enum ProfileVault: CaseIterable { case noVault, openVaultWithNoMatch, lockedVault }

    /// A user whose answer to the first step is the test's to give, so what the page saw while the step was open can be read.
    @MainActor private final class StepUser: WebAuthnCeremonyInteraction {
        private(set) var steps = 0
        private(set) var isOpen = false
        private var pending: CheckedContinuation<WebAuthnDecision, Never>?
        var canVerifyUser: Bool {
            true
        }

        private func ask() async -> WebAuthnDecision {
            steps += 1
            isOpen = true
            let decision = await withCheckedContinuation { pending = $0 }
            isOpen = false
            return decision
        }

        func answer(_ decision: WebAuthnDecision) {
            pending?.resume(returning: decision)
            pending = nil
        }

        func decide(_ prompt: WebAuthnPrompt, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
            await ask()
        }

        func offerStart(operation: WebAuthnPrompt.Operation, origin: String, locked: Bool, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
            await ask()
        }

        func verifyUser(reason: String, until deadline: ContinuousClock.Instant?) async throws {}
        func reportUnconfirmedRegistration(rpID: String, userName: String, in anchor: ASPresentationAnchor) {}
    }

    private func makeContext(_ state: ProfileVault, _ realm: Realm) async throws -> BrowserProfileContext {
        switch state {
        case .noVault:
            try await realm.context()
        case .openVaultWithNoMatch:
            try await realm.context(vaults: [.unlocked])
        case .lockedVault:
            try await realm.context(vaults: [.locked])
        }
    }

    /// Every page-visible effect of one request in a profile in `state`, answered by `decision`: what the page saw while the
    /// step was open, and then the result events it got.
    private func observe(_ state: ProfileVault, engine: BrowserEngine, answering decision: WebAuthnDecision, create: Bool = false) async throws -> [String] {
        var trace: [String] = []
        let realm = try await Realm.start(engine: engine)
        do {
            let context = try await makeContext(state, realm)
            let user = StepUser()
            WebAuthnAdapter.interactionForTesting[context.profile.id] = { user }
            defer { WebAuthnAdapter.interactionForTesting[context.profile.id] = nil }
            let page = try await realm.open(context)
            try await recordResults(in: page)
            if create {
                _ = try await page.evaluateJavaScript("""
                window.outcomes = [];
                navigator.credentials.create({ publicKey: { challenge: new Uint8Array(4), rp: { name: 'Example' },
                  user: { id: new Uint8Array([1]), name: 'ada', displayName: 'Ada' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }] } })
                  .then(() => outcomes.push('resolved'), e => outcomes.push(e.name)); true
                """)
            } else {
                try await requestModalGet(in: page)
            }
            #expect(await waitUntil { user.isOpen }, "a step is shown in every state: \(state)")
            try await fence(page)
            trace.append("while open: \(try await results(of: page).count) events, \(try await outcomes(of: page).count) outcomes, steps \(user.steps)")
            user.answer(decision)
            #expect(try await waitUntil { try await !results(of: page).isEmpty })
            try await fence(page)
            for event in try await results(of: page) {
                let error = event["error"] as? [String: Any]
                trace.append("event: \(event["handoff"] as? String ?? "-") \(error?["name"] as? String ?? "-") \(error?["message"] as? String ?? "-")")
            }
        } catch {
            await realm.close()
            throw error
        }
        await realm.close()
        return trace
    }

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func aModalRequestLooksTheSameToThePageInEveryVaultStateUntilTheUserChoosesTheSystem(engine: BrowserEngine) async throws {
        for decision in [WebAuthnDecision.declined, .cancelled, .expired, .handOff] {
            var traces: [[String]] = []
            for state in ProfileVault.allCases {
                traces.append(try await observe(state, engine: engine, answering: decision))
            }
            #expect(traces.dropFirst().allSatisfy { $0 == traces[0] }, "\(decision): \(traces)")
            let first = try #require(traces.first)
            #expect(first.first == "while open: 0 events, 0 outcomes, steps 1", "nothing reaches the page before the user answers")
            if decision == .handOff {
                #expect(first.dropFirst() == ["event: modal - -"], "exactly one hand-off and no error")
            } else {
                #expect(first.dropFirst().count == 1 && first.dropFirst().first?.hasPrefix("event: - ") == true, "one refusal, never a hand-off")
            }
        }
    }

    /// A registration asks the same question of a profile with no vault, and hands over only on the choice.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func aModalRegistrationLooksTheSameWithAndWithoutAVaultUntilTheUserChoosesTheSystem(engine: BrowserEngine) async throws {
        for decision in [WebAuthnDecision.declined, .handOff] {
            let without = try await observe(.noVault, engine: engine, answering: decision, create: true)
            let with = try await observe(.openVaultWithNoMatch, engine: engine, answering: decision, create: true)
            #expect(without == with, "\(decision)")
            #expect(without.first == "while open: 0 events, 0 outcomes, steps 1")
        }
    }

    /// A discovery (a conditional request) is pending in exactly the same way in every vault state, and nothing is handed over
    /// until the user clicks a webauthn field (here the relay's own report of that gesture is posted, as the relay does only for a
    /// trusted one) and then chooses the system's authenticator. Declining the step leaves it pending.
    @Test(.boundedWebViews) func aConditionalRequestIsPendingAlikeInEveryVaultStateAndHandedOverOnlyAfterAGestureAndTheChoice() async throws {
        var traces: [[String]] = []
        for state in ProfileVault.allCases {
            let realm = try await Realm.start(engine: .webKit)
            var trace: [String] = []
            do {
                let context = try await makeContext(state, realm)
                let user = StepUser()
                WebAuthnAdapter.interactionForTesting[context.profile.id] = { user }
                defer { WebAuthnAdapter.interactionForTesting[context.profile.id] = nil }
                let page = try await realm.open(context)
                try await recordResults(in: page)
                _ = try await page.evaluateJavaScript("""
                window.ids = []; document.addEventListener('wsurf-webauthn-request', event => {
                  const body = JSON.parse(event.detail);
                  if (body.action === 'request' && body.operation !== 'capabilities') ids.push(body.id);
                }); true
                """)
                try await requestConditionalGet(in: page)
                try await fence(page)
                trace.append("registered: \(try await results(of: page).count) events, \(try await outcomes(of: page).count) outcomes, steps \(user.steps)")

                // The user's click on a webauthn field, as the relay reports it. A step is shown; the page still sees nothing.
                func click() async throws {
                    let id = try #require(try await page.evaluateJavaScript("ids[0]") as? String)
                    _ = try await page.callAsyncJavaScript(
                        "globalThis.__wsurfSend('wsurfWebAuthn', { action: 'conditionalActivate', id, document: globalThis.__wsurfNativeFrameNonce });",
                        arguments: ["id": id], in: nil, contentWorld: PageAutomationGuard.world
                    )
                }
                try await click()
                #expect(await waitUntil { user.isOpen }, "a step follows the gesture in every state: \(state)")
                try await fence(page)
                trace.append("step open: \(try await results(of: page).count) events, \(try await outcomes(of: page).count) outcomes")

                // Declining leaves the discovery pending, as it always does; clicking again asks again; only the choice hands over.
                user.answer(.declined)
                #expect(await waitUntil { !user.isOpen })
                try await fence(page)
                trace.append("declined: \(try await results(of: page).count) events, \(try await outcomes(of: page).count) outcomes")
                try await click()
                #expect(await waitUntil { user.isOpen && user.steps == 2 })
                user.answer(.handOff)
                #expect(try await waitUntil { try await !results(of: page).isEmpty })
                trace.append("chosen: \(try await results(of: page).compactMap { $0["handoff"] as? String })")
            } catch {
                await realm.close()
                throw error
            }
            await realm.close()
            traces.append(trace)
        }
        #expect(traces.dropFirst().allSatisfy { $0 == traces[0] }, "\(traces)")
        #expect(traces.first == [
            "registered: 0 events, 0 outcomes, steps 0", "step open: 0 events, 0 outcomes", "declined: 0 events, 0 outcomes", "chosen: [\"modal\"]",
        ])
    }

    /// "Use Another Device or Key…" on the offer a locked vault shows first: the request is handed over and the vault was never
    /// unlocked for it. The vault's own unlock passkey is a separate ceremony and still opens it afterwards.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func anotherDeviceOrKeyOnTheLockedOfferHandsOverWithoutUnlocking(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let passkeys = VaultPasskeys()
            let context = try await realm.context(passkeys: passkeys, vaults: [.locked])
            let profileID = context.profile.id
            let user = WebsiteAuthenticatorCeremonyTests.User()
            user.offer = { _ in .handOff }
            WebAuthnAdapter.interactionForTesting[profileID] = { user }
            defer { WebAuthnAdapter.interactionForTesting[profileID] = nil }
            let page = try await realm.open(context)
            let before = passkeys.assertions.count

            try await recordResults(in: page)
            try await requestModalGet(in: page)
            #expect(try await waitUntil { try await handOffs(of: page) == ["modal"] })
            #expect(user.offers == [true] && user.prompts.isEmpty && user.verifications == 0, "the offer was the only sheet")
            #expect(passkeys.assertions.count == before, "no unlock passkey was used for the request")
            #expect(CredentialManager.unlockedManagers(for: context.profile).isEmpty)

            // The vault's own unlock still works, with its own passkey, after a request was handed over.
            let listing = try await CredentialManager.store(for: context.profile).listing()
            let vault = try CredentialManager.forVault(context.profile, vaultID: try #require(listing.first).vaultID, native: passkeys.native)
            try await vault.unlock(in: VaultManagerFixture.anchor())
            #expect(vault.isUnlocked && passkeys.assertions.count == before + 1)
        }
    }

    /// The "which vault?" prompt of a passkey request offers the same way out, and taking it unlocks nothing.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func anotherDeviceOrKeyOnTheVaultChoiceHandsOverWithoutUnlocking(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let passkeys = VaultPasskeys()
            let context = try await realm.context(passkeys: passkeys, vaults: [.locked, .locked])
            let profileID = context.profile.id
            VaultChoicePrompt.handOffForTesting.insert(profileID)
            defer { VaultChoicePrompt.handOffForTesting.remove(profileID) }
            let page = try await realm.open(context)
            let before = passkeys.assertions.count

            try await recordResults(in: page)
            try await requestModalGet(in: page)
            #expect(try await waitUntil { try await handOffs(of: page) == ["modal"] })
            #expect(passkeys.assertions.count == before && CredentialManager.unlockedManagers(for: context.profile).isEmpty)
            #expect(try await results(of: page).allSatisfy { $0["error"] == nil })
        }
    }

    /// What happens to the page while the "which vault?" prompt is open.
    enum WhileChoosing: CaseIterable {
        case theViewMovesToAnotherWindow, theProfileLocks
    }

    /// The route is `needsChoice` (two locked vaults) and the prompt suspends the run before any manager is bound. Whatever then
    /// invalidates the request, the answer that arrives afterwards binds nothing: the page gets one `NotAllowedError`, no native
    /// unlock follows, and no vault is unlocked.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium], WhileChoosing.allCases)
    func aVaultChoiceAnsweredAfterTheRequestWasInvalidatedBindsNothing(engine: BrowserEngine, change: WhileChoosing) async throws {
        try await withRealm(engine) { realm in
            let passkeys = VaultPasskeys()
            let context = try await realm.context(passkeys: passkeys, vaults: [.locked, .locked])
            let profileID = context.profile.id
            let page = try await realm.open(context)
            let choice = OpenChoice()
            VaultChoicePrompt.answersForTesting[profileID] = { candidates in
                await choice.wait()
                return candidates.first?.vaultID
            }
            defer { VaultChoicePrompt.answersForTesting[profileID] = nil }
            let before = passkeys.assertions.count

            try await requestModalGet(in: page)
            #expect(await waitUntil { choice.isOpen }, "the run reached the vault choice")
            #expect(try await outcomes(of: page).isEmpty, "the request is pending while the user chooses")

            switch change {
            case .theViewMovesToAnotherWindow:
                realm.moveToNewWindow(page)
            case .theProfileLocks:
                CredentialManager.lock(profileID: profileID, reason: .profileSwitch)
            }
            choice.answer()

            #expect(try await waitUntil { try await outcomes(of: page) == ["NotAllowedError"] }, "the late answer is refused")
            try await fence(page)
            #expect(try await outcomes(of: page) == ["NotAllowedError"], "exactly one refusal and nothing after it")
            #expect(passkeys.assertions.count == before, "no native unlock follows the invalidation")
            #expect(CredentialManager.unlockedManagers(for: context.profile).isEmpty)
        }
    }

    /// A vault-level cancel only reaches ceremonies already bound to that vault: one still choosing has no vault yet, and only the
    /// profile's own access ending stops it.
    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func aVaultCancelLeavesARequestStillChoosingItsVaultAndAProfileCancelStopsIt(engine: BrowserEngine) async throws {
        try await withRealm(engine) { realm in
            let passkeys = VaultPasskeys()
            let context = try await realm.context(passkeys: passkeys, vaults: [.locked, .locked])
            let profileID = context.profile.id
            let page = try await realm.open(context)
            let choice = OpenChoice()
            VaultChoicePrompt.answersForTesting[profileID] = { candidates in
                await choice.wait()
                return candidates.first?.vaultID
            }
            defer { VaultChoicePrompt.answersForTesting[profileID] = nil }

            try await requestModalGet(in: page)
            #expect(await waitUntil { choice.isOpen })
            let listing = try await CredentialManager.store(for: context.profile).listing()
            let vault = try CredentialManager.forVault(context.profile, vaultID: try #require(listing.first).vaultID)
            WebAuthnAdapter.cancel(manager: vault)
            try await fence(page)
            #expect(try await outcomes(of: page).isEmpty, "a request with no bound vault is not a vault's ceremony")

            WebAuthnAdapter.cancel(profileID: profileID)
            #expect(try await waitUntil { try await outcomes(of: page) == ["NotAllowedError"] })
            choice.answer()
        }
    }
}
