// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A passkey imported from Apple Passwords signs in the way Google's sign-in asks for it: from the page's own script, while
/// the page is still loading, after earlier navigations in the same tab, and with a long challenge. Each case runs the
/// production path end to end (tab, page script, relay, adapter, vault) with only the person scripted, and the assertion is
/// checked independently.
@MainActor
@Suite(.serialized, .boundedWebViews)
final class WebAuthnPageLoadTests {
    private let key = P256.Signing.PrivateKey()
    private let credentialID = Data((0..<20).map { UInt8(0xA0 &+ $0) })
    private let userHandle = Data((0..<16).map { UInt8(0x30 &+ $0) })

    private struct Rig {
        let tab: BrowserTab
        let window: NSWindow
        let server: HTTPFixtureServer
        let profile: Profile
        let base: URL
        let origin: String

        var page: BrowserPage {
            tab.page
        }

        func url(_ path: String) throws -> URL {
            try #require(URL(string: path, relativeTo: base)?.absoluteURL)
        }
    }

    /// The vault's only passkey, as Apple Passwords exports it (OneAsymmetricKey PKCS#8, a 20-byte credential ID), through
    /// the same import preview and apply the Credential Exchange import uses.
    private func importedAccounts() throws -> [CredentialAccount] {
        let exchange = CredentialExchangeTests()
        // A login address as Apple sends one; the vault keeps only https addresses, and the passkey's own website is its rpID.
        let scope = try #require(URL(string: "https://localhost/sign-in"))
        let incoming = exchange.data(
            scope: ASImportableCredentialScope(urls: [scope], androidApps: []),
            credentials: [
                exchange.basicAuthentication(username: "ada", password: "pw"),
                exchange.passkey(id: credentialID, rpID: "localhost", userHandle: userHandle, key: key.derRepresentation),
            ]
        )
        let preview = try CredentialExchangeCodec.preview(incoming, against: exchange.snapshot([]))
        try #require(preview.omitted.isEmpty, "\(preview.omitted)")
        let accounts = try CredentialExchangeCodec.apply(preview, decisions: [])
        try #require(accounts.flatMap(\.passkeys).map(\.source) == [WebsitePasskeySource.imported])
        return accounts
    }

    private func rig(_ engine: BrowserEngine, routes: [String: HTTPFixtureServer.Response]) async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: routes)
        var components = try #require(URLComponents(url: try server.url(), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let base = try #require(components.url)
        let made = try await VaultManagerFixture.make(vaults: [.unlocked])
        let vault = try #require(made.vaults.first)
        _ = try await VaultManagerFixture.save(try importedAccounts(), in: vault)
        let user = WebsiteAuthenticatorCeremonyTests.User()
        user.respond = { prompt in .approved(choice: prompt.choices.first?.id) }
        WebAuthnAdapter.interactionForTesting[made.profile.id] = { user }

        let context = BrowserProfileContext(profile: made.profile)
        context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: base))
        let tab = BrowserTab(opensBlank: false, privately: false, context: context)
        switch engine {
        case .webKit:
            tab.adopt(BrowserPage(webKit: context.webViewPool.acquire(), context: context))
        case .chromium:
            try ChromiumRuntime.shared.ensureInitialized()
            tab.adopt(BrowserPage(chromium: ChromiumPage(context: context)))
        }
        // The relay hands a signed result only to a visible document.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFrontRegardless()
        let port = try #require(base.port)
        return Rig(tab: tab, window: window, server: server, profile: made.profile, base: base,
                   origin: "http://localhost:\(port)")
    }

    private func withRig(
        _ engine: BrowserEngine, routes: [String: HTTPFixtureServer.Response], _ body: (Rig) async throws -> Void
    ) async throws {
        let rig = try await rig(engine, routes: routes)
        func close() async {
            rig.tab.detach()
            await rig.tab.waitForRetirement()
            rig.window.close()
            WebAuthnAdapter.interactionForTesting[rig.profile.id] = nil
            await VaultManagerFixture.erase(rig.profile)
            withExtendedLifetime(rig.server) {}
        }
        do { try await body(rig) } catch { await close(); throw error }
        await close()
    }

    /// The sign-in page: `signIn()` asks for the vault's passkey as Google does and keeps how the promise ended in
    /// `window.outcome`. `asksWhileLoading` asks from the inline script itself, before the held image lets `load` fire.
    private func signInPage(challenge: Data, asksWhileLoading: Bool = false) -> String {
        """
        <!doctype html><title>Sign in</title>
        <script>
        const bytes = text => Uint8Array.from(atob(text), c => c.charCodeAt(0));
        const text = buffer => btoa(String.fromCharCode(...new Uint8Array(buffer)));
        window.outcome = null;
        window.signIn = () => navigator.credentials.get({ publicKey: {
            challenge: bytes('\(challenge.base64EncodedString())'), rpId: 'localhost', timeout: 60000,
            allowCredentials: [{ type: 'public-key', id: bytes('\(credentialID.base64EncodedString())') }],
            userVerification: 'preferred' } })
          .then(credential => JSON.stringify({
              readyState: document.readyState,
              authenticatorData: text(credential.response.authenticatorData),
              clientDataJSON: text(credential.response.clientDataJSON),
              signature: text(credential.response.signature),
              userHandle: credential.response.userHandle ? text(credential.response.userHandle) : null }),
            error => JSON.stringify({ error: error.name }))
          .then(outcome => { window.outcome = outcome; });
        \(asksWhileLoading ? "signIn();" : "")
        </script>
        <img src="/held.png" alt="">
        """
    }

    private func load(_ url: URL, in rig: Rig) async throws {
        rig.page.load(URLRequest(url: url))
        try #require(await waitUntil { rig.page.url?.path == url.path && !rig.page.isLoading })
    }

    /// Waits for the page's own `signIn()` to end and checks its assertion: it was made by the imported passkey, for this
    /// challenge, this origin and `localhost`. Returns the document's readyState when the assertion arrived.
    @discardableResult
    private func signedIn(_ rig: Rig, challenge: Data) async throws -> String {
        var raw: String?
        try #require(await waitUntil {
            raw = try? await rig.page.evaluateJavaScript("window.outcome") as? String
            return raw != nil
        }, "the page's request never ended")
        let outcome = try #require(raw.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        try #require(outcome["error"] == nil, "refused: \(outcome["error"] ?? "")")
        func bytes(_ key: String) throws -> Data {
            try #require((outcome[key] as? String).flatMap { Data(base64Encoded: $0) }, "\(key) is missing")
        }
        #expect(try bytes("userHandle") == userHandle)
        _ = try WebAuthnVerifier.assertion(
            authenticatorData: try bytes("authenticatorData"), clientDataJSON: try bytes("clientDataJSON"),
            signature: try bytes("signature"), publicKey: WebAuthnVerifier.publicKey(x963: key.publicKey.x963Representation),
            challenge: challenge, origin: .init(origin: rig.origin), rpID: "localhost", userHandle: userHandle
        )
        return try #require(outcome["readyState"] as? String)
    }

    private func signIn(_ rig: Rig, challenge: Data) async throws {
        _ = try await rig.page.evaluateJavaScript("window.outcome = null; signIn(); true")
        try await signedIn(rig, challenge: challenge)
    }

    private let challenge = Data((0..<32).map { UInt8($0 &* 5) })

    private func heldImage(_ gate: ResponseGate) -> HTTPFixtureServer.Response {
        HTTPFixtureServer.Response(status: "200 OK", headers: ["Content-Type": "image/png"], body: Data(), gate: gate)
    }

    // MARK: - Cases

    /// Google asks while its page still loads. That was refused before anything was shown; now it signs in.
    @Test(arguments: BrowserEngine.allCases)
    func aPasskeyAskedForWhileThePageLoadsSignsIn(_ engine: BrowserEngine) async throws {
        let held = ResponseGate()
        defer { held.open() }
        try await withRig(engine, routes: [
            "/": .html(signInPage(challenge: challenge, asksWhileLoading: true)),
            "/held.png": heldImage(held),
        ]) { rig in
            rig.page.load(URLRequest(url: try rig.url("/")))
            #expect(await held.waitForRequest())
            let readyState = try await signedIn(rig, challenge: challenge)
            #expect(readyState != "complete", "the page had finished loading")
            #expect(rig.page.isLoading, "the held image no longer holds the load back")
        }
    }

    /// A navigation the next one replaced, before any answer, leaves the tab able to sign in on the next document and the
    /// one after it.
    @Test(arguments: BrowserEngine.allCases)
    func aPasskeyAskedForAfterAReplacedNavigationSignsIn(_ engine: BrowserEngine) async throws {
        let replaced = ResponseGate()
        defer { replaced.open() }
        let open = ResponseGate()
        open.open()
        try await withRig(engine, routes: [
            "/": .html("<!doctype html><title>Start</title>"),
            "/replaced": .html("<!doctype html><title>Replaced</title>", gate: replaced),
            "/sign-in": .html(signInPage(challenge: challenge)),
            "/again": .html(signInPage(challenge: challenge)),
            "/held.png": heldImage(open),
        ]) { rig in
            try await load(try rig.url("/"), in: rig)
            rig.page.load(URLRequest(url: try rig.url("/replaced")))
            #expect(await replaced.waitForRequest())
            try await load(try rig.url("/sign-in"), in: rig)
            try await signIn(rig, challenge: challenge)
            try await load(try rig.url("/again"), in: rig)
            try await signIn(rig, challenge: challenge)
        }
    }

    /// A navigation that became a download ends without a document; the page that stayed still signs in.
    @Test(arguments: BrowserEngine.allCases)
    func aPasskeyAskedForAfterADownloadSignsIn(_ engine: BrowserEngine) async throws {
        let open = ResponseGate()
        open.open()
        let served = ResponseGate()
        served.open()
        var download = HTTPFixtureServer.Response.download(Data(repeating: 7, count: 64), filename: "report.bin")
        download.gate = served
        try await withRig(engine, routes: [
            "/sign-in": .html(signInPage(challenge: challenge)),
            "/report.bin": download,
            "/held.png": heldImage(open),
        ]) { rig in
            let page = try rig.url("/sign-in")
            try await load(page, in: rig)
            rig.page.load(URLRequest(url: try rig.url("/report.bin")))
            #expect(await served.waitForRequest())
            try #require(await waitUntil { !rig.page.isLoading && rig.page.url?.path == page.path })
            try await signIn(rig, challenge: challenge)
        }
    }

    /// A website may send a long challenge: 2 KiB signs in, as it does in other browsers.
    @Test(arguments: BrowserEngine.allCases)
    func aTwoKilobyteChallengeSignsIn(_ engine: BrowserEngine) async throws {
        let long = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        let open = ResponseGate()
        open.open()
        try await withRig(engine, routes: [
            "/sign-in": .html(signInPage(challenge: long)),
            "/held.png": heldImage(open),
        ]) { rig in
            try await load(try rig.url("/sign-in"), in: rig)
            try await signIn(rig, challenge: long)
        }
    }
}
