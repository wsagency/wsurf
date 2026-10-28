// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

/// A passkey request from a tab the person is not looking at waits for that tab, as its page dialogs do: no step is shown over
/// the tab in front, and the first one comes up in the tab's own window when it is brought to the front. While it waits the
/// request still ends as it should. The window is the one the app builds, its profile is fresh with no vault, and its pages are
/// on a loopback server at `localhost`, on each engine. A scripted user stands in for the sheets and records where each is shown.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct BackgroundPasskeyTests {
    /// A user who answers when the test says so, and records the window each step was shown in.
    @MainActor private final class User: WebAuthnCeremonyInteraction {
        private(set) var anchors: [NSWindow] = []
        private var pending: CheckedContinuation<WebAuthnDecision, Never>?
        var isAsking: Bool {
            pending != nil
        }
        var canVerifyUser: Bool {
            true
        }

        private func ask(in anchor: ASPresentationAnchor) async -> WebAuthnDecision {
            anchors.append(anchor)
            return await withCheckedContinuation { pending = $0 }
        }

        func answer(_ decision: WebAuthnDecision) {
            pending?.resume(returning: decision)
            pending = nil
        }

        func decide(_ prompt: WebAuthnPrompt, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
            await ask(in: anchor)
        }

        func offerStart(
            operation: WebAuthnPrompt.Operation, origin: String, locked: Bool, in anchor: ASPresentationAnchor,
            until deadline: ContinuousClock.Instant?
        ) async -> WebAuthnDecision {
            await ask(in: anchor)
        }

        func verifyUser(reason: String, until deadline: ContinuousClock.Instant?) async throws {}
        func reportUnconfirmedRegistration(rpID: String, userName: String, in anchor: ASPresentationAnchor) {}
    }

    /// Runs `body` in the rig's window with `user` answering its profile's passkey steps.
    private func withRig(_ engine: BrowserEngine, _ body: @MainActor (LiveWindowRig, User) async throws -> Void) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let profileID = rig.browser.context.profile.id
            // A ceremony here can register a store, which a session-wide lock elsewhere would reach (`VaultManagerFixture`).
            try await RegistryGate.shared.enterShared(profileID)
            let user = User()
            WebAuthnAdapter.interactionForTesting[profileID] = { user }
            WebAuthnRefusal.recordedForTesting[profileID] = []
            defer {
                user.answer(.cancelled)
                WebAuthnAdapter.interactionForTesting[profileID] = nil
                WebAuthnRefusal.recordedForTesting[profileID] = nil
                RegistryGate.shared.leaveShared(profileID)
            }
            try await body(rig, user)
        }
    }

    /// A tab on the rig's server at `localhost` (a relying party, unlike 127.0.0.1) that is in front once its document can carry
    /// passkey requests: in the window, with its relay and, on WebKit, its native frame handshake ready.
    private func openPasskeyPage(_ rig: LiveWindowRig) async throws -> BrowserTab {
        var components = try #require(URLComponents(url: rig.server.url("/still"), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let url = try #require(components.url)
        rig.browser.context.sitePermissions.setEngine(rig.engine, for: SitePermissions.origin(for: url))
        let tab = rig.browser.newTab(url: url, engine: rig.engine)
        tab.backgroundHidingGrace = .zero
        tab.page.ignoresWindowOcclusion = true
        try #require(await waitUntil(timeout: .seconds(60)) { tab.page.url == url && !tab.page.isLoading })
        try #require(await waitUntil { tab.page.window === rig.window })
        let handshake = tab.page.chromium == nil ? "await globalThis.__wsurfNativeFrameReady" : "true"
        let ready = try await tab.page.callAsyncJavaScript(
            "return (\(handshake)) === true && typeof globalThis.__wsurfWebAuthnFence === 'object';",
            in: nil, contentWorld: PageAutomationGuard.world
        ) as? Bool
        try #require(ready == true, "the document's relay is ready")
        return tab
    }

    /// A modal `get` the page leaves pending, with an abort signal the test can fire. `outcomes` records how it ended.
    private func requestGet(in tab: BrowserTab) async throws {
        _ = try await tab.page.evaluateJavaScript("""
            window.outcomes = []; window.passkeyAbort = new AbortController();
            navigator.credentials.get({ publicKey: { challenge: new Uint8Array(4) }, signal: passkeyAbort.signal })
              .then(() => outcomes.push('resolved'), e => outcomes.push(e.name)); true
            """)
    }

    private func outcomes(of tab: BrowserTab) async -> [String] {
        let joined = (try? await tab.page.evaluateJavaScript("outcomes.join()")) as? String ?? ""
        return joined.isEmpty ? [] : joined.split(separator: ",").map(String.init)
    }

    /// Waits until the request reached native: it waits for its tab, or (where the tab's place is ignored) a step is up.
    private func requestArrives(in tab: BrowserTab, _ user: User) async -> Bool {
        await waitUntil { tab.dialogs.waitsToBeShown || user.isAsking }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aBackgroundTabsRequestWaitsUntilTheTabIsInFront(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, user in
            let background = try await openPasskeyPage(rig)
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try await requestGet(in: background)
            try #require(await requestArrives(in: background, user))
            #expect(user.anchors.isEmpty, "\(engine): no step is shown over the tab in front")

            rig.browser.activate(background)
            #expect(await waitUntil { user.isAsking }, "\(engine): the step comes up once its tab is in front")
            #expect(user.anchors.count == 1 && user.anchors.first === rig.window, "\(engine): in the tab's own window")
            user.answer(.declined)
            #expect(await waitUntil { await outcomes(of: background) == ["NotAllowedError"] }, "\(engine): the person's answer")
            #expect(!background.dialogs.waitsToBeShown)
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func closingABackgroundTabEndsItsWaitingRequest(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, user in
            let background = try await openPasskeyPage(rig)
            _ = try await rig.open("/still")
            let profileID = rig.browser.context.profile.id
            try await requestGet(in: background)
            try #require(await requestArrives(in: background, user))
            #expect(user.anchors.isEmpty, "\(engine): no step is shown over the tab in front")

            rig.browser.close(background)
            #expect(await waitUntil { WebAuthnRefusal.recordedForTesting[profileID]?.isEmpty == false }, "\(engine): the request ended")
            #expect(!background.dialogs.waitsToBeShown)
            await background.waitForRetirement()
            #expect(user.anchors.isEmpty, "\(engine): and nothing was shown")
            let ended = WebAuthnRefusal.recordedForTesting[profileID] ?? []
            #expect(ended.allSatisfy { ["no-window", "document-replaced", "ended:notAllowed"].contains($0) }, "\(engine): \(ended)")
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func abortingAWaitingRequestEndsItWithAbortError(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, user in
            let background = try await openPasskeyPage(rig)
            _ = try await rig.open("/still")
            try await requestGet(in: background)
            try #require(await requestArrives(in: background, user))
            #expect(user.anchors.isEmpty, "\(engine): no step is shown over the tab in front")

            _ = try await background.page.evaluateJavaScript("passkeyAbort.abort(); true")
            #expect(await waitUntil { await outcomes(of: background) == ["AbortError"] }, "\(engine): the page's abort ends it")
            #expect(await waitUntil { !background.dialogs.waitsToBeShown }, "\(engine): native stops waiting")

            rig.browser.activate(background)
            #expect(await waitUntil { background.page.window === rig.window && !background.page.isParked })
            #expect(user.anchors.isEmpty, "\(engine): nothing is shown for the aborted request when the tab comes back")
            #expect(await outcomes(of: background) == ["AbortError"])
        }
    }

    /// A favorite kept alive behind the tab in front is in the window, though not shown: its request waits like any other tab's.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aKeptAliveFavoritesRequestDoesNotShowOverTheTabInFront(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, user in
            let favorite = try await openPasskeyPage(rig)
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front && favorite.page.window === rig.window)
            try await requestGet(in: favorite)
            try #require(await requestArrives(in: favorite, user))
            #expect(user.anchors.isEmpty, "\(engine): no step is shown over the tab in front")

            rig.browser.activate(favorite)
            #expect(await waitUntil { user.isAsking }, "\(engine): the step comes up once the favorite is in front")
            #expect(user.anchors.first === rig.window)
            user.answer(.declined)
            #expect(await waitUntil { await outcomes(of: favorite) == ["NotAllowedError"] })
        }
    }
}
