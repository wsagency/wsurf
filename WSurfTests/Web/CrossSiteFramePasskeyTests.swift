// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import AuthenticationServices
import Foundation
import Testing
import WebKit

@testable import WSurf
@testable import WSurfVault

/// Passkeys in a Chromium frame in a process and a DevTools session of its own, YouTube's Verify step in shape. The only origins that
/// can ask here are `http://localhost` ones, one site to Chromium, so the frame's server asks for a process of its own with
/// `Origin-Agent-Cluster`; each test proves the frame got it. Everything but the person is real: the tab, the scripts, the permissions
/// policy Chromium reports, the ceremony, a vault with a passkey registered through it.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct CrossSiteFramePasskeyTests {
    private static let frameAllowed = #"allow="publickey-credentials-get *""#

    private static let ownProcess = ["Origin-Agent-Cluster": "?1"]

    private static func host(frame: String, _ attributes: String, headers: [String: String] = [:], script: String = "") -> HTTPFixtureServer.Response {
        .html(
            """
            <!doctype html><title>Host</title><iframe id="frame" \(attributes) src="\(frame)"></iframe><script>\(script)</script>
            """,
            headers: headers
        )
    }

    /// The frame's server. `/middle` holds the probe of the origin above it.
    private static let frameRoutes: [String: HTTPFixtureServer.Response] = [
        "/probe": .html("<!doctype html><title>Probe</title>", headers: ownProcess),
        "/middle": .html("""
            <!doctype html><title>Middle</title><iframe \(frameAllowed)></iframe><script>
            document.querySelector('iframe').src = location.ancestorOrigins[0] + '/probe';
            </script>
            """, headers: ownProcess),
    ]

    /// The top pages, whose frame is `frameOrigin`'s `/probe`.
    private static func routes(frameOrigin: String) -> [String: HTTPFixtureServer.Response] {
        let frame = frameOrigin + "/probe"
        return [
            "/probe": .html("<!doctype html><title>Probe</title>"),
            "/permitted": host(frame: frame, frameAllowed),
            "/not-listed": host(frame: frame, ""),
            "/another-origin": host(frame: frame, #"allow="publickey-credentials-get https://example.com""#),
            "/page-forbids": host(frame: frame, frameAllowed, headers: ["Permissions-Policy": "publickey-credentials-get=()"]),
            // An `allow` set after the frame loaded changes nothing for its document.
            "/allowed-too-late": host(frame: frame, "", script: """
                document.getElementById('frame').addEventListener('load', event => {
                  event.target.allow = 'publickey-credentials-get *';
                });
                """),
            "/sandboxed": host(frame: frame, #"sandbox="allow-scripts" allow="publickey-credentials-get *""#),
            // Top > another origin > the top's origin: the requester's origin is the top's, with another's between them.
            "/nested": host(frame: frameOrigin + "/middle", frameAllowed),
        ]
    }

    private final class User: WebAuthnCeremonyInteraction {
        private(set) var prompts: [WebAuthnPrompt] = []
        private(set) var offers = 0
        var canVerifyUser: Bool {
            true
        }

        func decide(_ prompt: WebAuthnPrompt, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
            prompts.append(prompt)
            return .approved(choice: prompt.choices.first?.id)
        }

        func offerStart(
            operation: WebAuthnPrompt.Operation, origin: String, topOrigin: String?, locked: Bool, in anchor: ASPresentationAnchor,
            until deadline: ContinuousClock.Instant?
        ) async -> WebAuthnDecision {
            offers += 1
            return .approved(choice: nil)
        }

        func verifyUser(reason: String, until deadline: ContinuousClock.Instant?) async throws {}
        func reportUnconfirmedRegistration(rpID: String, userName: String, in anchor: ASPresentationAnchor) {}
    }

    @MainActor
    private struct Rig {
        /// Keeps both servers alive; the first is the top pages', the second the frame's.
        let servers: [HTTPFixtureServer]
        let topOrigin: String
        let frameOrigin: String
        let profile: Profile
        let tab: BrowserTab
        let user: User

        var chromium: ChromiumPage {
            get throws { try #require(tab.page.chromium) }
        }

        /// Opens `path` on `host`, then the frame at `/probe` once its relay is in.
        func probeFrame(_ path: String) async throws -> BrowserFrame {
            let url = try #require(URL(string: topOrigin + path))
            tab.page.load(URLRequest(url: url))
            let devTools = try chromium.devTools
            var found: BrowserFrame?
            let loaded = try await waitUntil {
                found = try? await devTools.framesIncludingCrossSiteFrames().first { !$0.isMainFrame && $0.request.url?.path == "/probe" }
                guard let found else { return false }
                return try await tab.page.callAsyncJavaScript(
                    "return typeof globalThis.__wsurfWebAuthnFence;", in: found, contentWorld: PageAutomationGuard.world
                ) as? String == "object"
            }
            try #require(loaded, "the frame's relay is in")
            let frame = try #require(found)
            #expect(devTools.session(for: frame).sessionID != nil, "a frame in a session of its own")
            return frame
        }

        /// Registers a passkey for `localhost` from a top page, as a person would; the key verifies what the frame signs later.
        func seedPasskey() async throws -> SecKey {
            let url = try #require(URL(string: topOrigin + "/probe"))
            tab.page.load(URLRequest(url: url))
            try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading }, "the page loaded")
            let answer = try await ask(in: nil, """
                navigator.credentials.create({publicKey: {challenge: new TextEncoder().encode('seed'), rp: {name: 'Probe'},
                  user: {id: new Uint8Array([1]), name: 'ada', displayName: 'Ada'}, pubKeyCredParams: [{type: 'public-key', alg: -7}]}})
                """)
            let response = try #require(answer["response"] as? [String: Any], "\(answer)")
            return try WebAuthnVerifier.registration(
                attestationObject: try WebAuthnWire.base64URLDecode(response["attestationObject"]),
                clientDataJSON: try WebAuthnWire.base64URLDecode(response["clientDataJSON"]),
                challenge: Data("seed".utf8), origin: topOrigin, topOrigin: nil, crossOrigin: false, rpID: "localhost"
            ).publicKey
        }

        /// The page's own call in `frame`, as the page would make it: what it resolves to, or `outcome`, the error's name.
        func ask(in frame: BrowserFrame?, _ call: String) async throws -> [String: Any] {
            let answer = try await tab.page.callAsyncJavaScript("""
                try { return (await \(call)).toJSON(); } catch (error) { return {outcome: error.name}; }
                """, in: frame, contentWorld: .page)
            return try #require(answer as? [String: Any])
        }

        func get(in frame: BrowserFrame, rpID: String = "localhost") async throws -> [String: Any] {
            try await ask(in: frame, """
                navigator.credentials.get({publicKey: {challenge: new TextEncoder().encode('frame'), rpId: '\(rpID)', timeout: 20000}})
                """)
        }
    }

    private func withRig(_ body: (Rig) async throws -> Void) async throws {
        let holder = try await HTTPFixtureServer.start(routes: Self.frameRoutes)
        let frameOrigin = "http://localhost:\(try #require(holder.url("/").port))"
        let top = try await HTTPFixtureServer.start(routes: Self.routes(frameOrigin: frameOrigin))
        let topOrigin = "http://localhost:\(try #require(top.url("/").port))"
        let profile = try await VaultManagerFixture.make(vaults: [.unlocked]).profile
        let context = BrowserProfileContext(profile: profile)
        for origin in [topOrigin, frameOrigin] {
            context.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: URL(string: origin)))
        }
        try ChromiumRuntime.shared.ensureInitialized()
        let tab = BrowserTab(opensBlank: false, privately: false, context: context)
        tab.adopt(BrowserPage(chromium: ChromiumPage(context: context)))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        let user = User()
        WebAuthnAdapter.interactionForTesting[profile.id] = { user }
        WebAuthnRefusal.recordedForTesting[profile.id] = []
        var failure: (any Error)?
        do {
            try await body(Rig(servers: [top, holder], topOrigin: topOrigin, frameOrigin: frameOrigin, profile: profile, tab: tab, user: user))
        } catch {
            failure = error
        }
        WebAuthnAdapter.interactionForTesting[profile.id] = nil
        WebAuthnRefusal.recordedForTesting[profile.id] = nil
        tab.detach()
        await tab.waitForRetirement()
        window.contentView = nil
        window.close()
        await VaultManagerFixture.erase(profile)
        if let failure {
            throw failure
        }
    }

    private func verify(
        _ answer: [String: Any], key: SecKey, origin: String, topOrigin: String
    ) throws {
        let response = try #require(answer["response"] as? [String: Any], "\(answer)")
        _ = try WebAuthnVerifier.assertion(
            authenticatorData: try WebAuthnWire.base64URLDecode(response["authenticatorData"]),
            clientDataJSON: try WebAuthnWire.base64URLDecode(response["clientDataJSON"]),
            signature: try WebAuthnWire.base64URLDecode(response["signature"]),
            publicKey: key,
            challenge: Data("frame".utf8),
            origin: .init(origin: origin, topOrigin: topOrigin, crossOrigin: true),
            rpID: "localhost",
            userHandle: try response["userHandle"].map { try WebAuthnWire.base64URLDecode($0) }
        )
    }

    /// A frame the page permits signs in for its own site: one sheet, naming the frame's site and the page's; a signature bound to
    /// both in clientDataJSON. The page's own script asked, not a person, so the sheet's sensor stays off.
    @Test func aPermittedFrameSignsInForItsOwnSiteNamingBoth() async throws {
        try await withRig { rig in
            let key = try await rig.seedPasskey()
            let frame = try await rig.probeFrame("/permitted")
            let answer = try await rig.get(in: frame)
            try verify(answer, key: key, origin: rig.frameOrigin, topOrigin: rig.topOrigin)
            let prompt = try #require(rig.user.prompts.last)
            #expect(rig.user.prompts.count == 2, "one sheet for the registration, one for the sign-in")
            #expect(prompt.origin == rig.frameOrigin && prompt.topOrigin == rig.topOrigin && prompt.rpID == "localhost")
            #expect(prompt.sensor == .off, "no person started this request")
        }
    }

    /// A frame of the top's own origin under a frame of another's is still cross-origin, through two sessions.
    @Test func aFrameOfTheTopsOriginUnderAnotherSiteIsCrossOrigin() async throws {
        try await withRig { rig in
            let key = try await rig.seedPasskey()
            let frame = try await rig.probeFrame("/nested")
            let answer = try await rig.get(in: frame)
            try verify(answer, key: key, origin: rig.topOrigin, topOrigin: rig.topOrigin)
        }
    }

    /// Chromium's answer decides, whichever way the permission is missing, and the frame's page has no say: refused before any sheet.
    @Test(arguments: ["/not-listed", "/another-origin", "/page-forbids", "/allowed-too-late"])
    func aFrameWithoutThePermissionIsRefused(path: String) async throws {
        try await withRig { rig in
            let frame = try await rig.probeFrame(path)
            let answer = try await rig.get(in: frame)
            let recorded = WebAuthnRefusal.recordedForTesting[rig.profile.id] ?? []
            #expect(answer["outcome"] as? String == "NotAllowedError", "\(answer)")
            #expect(recorded == ["ended:context.policyDenied"], "\(recorded)")
            #expect(rig.user.prompts.isEmpty && rig.user.offers == 0)
        }
    }

    /// The RP ID is checked against the frame's origin: another site cannot be named.
    @Test(arguments: ["example.com", "evil.localhost"])
    func aFrameCannotNameAnotherRelyingParty(rpID: String) async throws {
        try await withRig { rig in
            _ = try await rig.seedPasskey()
            let frame = try await rig.probeFrame("/permitted")
            let answer = try await rig.get(in: frame, rpID: rpID)
            #expect(answer["outcome"] as? String == "SecurityError", "\(answer)")
            #expect(rig.user.prompts.count == 1, "only the registration's sheet")
        }
    }

    /// Chromium reports a sandboxed frame under the address's origin; it has none of its own, so it never gets a sheet.
    @Test func aSandboxedFrameIsRefused() async throws {
        try await withRig { rig in
            let frame = try await rig.probeFrame("/sandboxed")
            let answer = try await rig.get(in: frame)
            #expect(answer["outcome"] != nil, "\(answer)")
            #expect(rig.user.prompts.isEmpty && rig.user.offers == 0)
        }
    }

    /// A locked vault's offer, the first sheet of such a request, names the page around the frame too.
    @Test func theOfferNamesThePageAroundTheFrame() {
        #expect(NativeWebAuthnInteraction.offerText(origin: "https://a.example", topOrigin: "https://b.example", locked: true)
            .contains("https://b.example"))
    }
}
